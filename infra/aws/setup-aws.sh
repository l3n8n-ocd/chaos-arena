#!/usr/bin/env bash
# =============================================================================
# setup-aws.sh — creates every AWS resource Chaos Arena needs (Module 03).
#
# WHERE TO RUN IT: in AWS CloudShell (the >_ icon at the top of the AWS Console).
# CloudShell already has the AWS CLI and is logged in as you, so no access keys
# are ever created or stored.
#
#     git clone https://github.com/l3n8n-ocd/chaos-arena.git
#     cd chaos-arena/infra/aws
#     ./setup-aws.sh
#
# WHAT IT CREATES (all inside the free allowance):
#   1. DynamoDB table   chaos-arena                    game state, rounds, incidents
#   2. S3 bucket        chaos-arena-<account>-<region> private backups
#   3. IAM role         chaos-arena-ec2-role           least-privilege permissions
#      + instance profile, attached to your EC2 instance
#   4. CloudWatch log groups  /chaos-arena/app, /chaos-arena/nginx  (14-day retention)
#
# It is safe to run more than once: anything that already exists is kept.
# =============================================================================
set -euo pipefail

TABLE="${TABLE_NAME:-chaos-arena}"
ROLE="chaos-arena-ec2-role"
PROFILE="chaos-arena-ec2-profile"
POLICY="chaos-arena-app-policy"
INSTANCE_NAME="${INSTANCE_NAME:-chaos-arena}"
LOG_GROUPS=("/chaos-arena/app" "/chaos-arena/nginx")
LOG_RETENTION_DAYS=14

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

command -v aws >/dev/null || die "The AWS CLI is not installed. Run this script in AWS CloudShell."

# CloudShell sets AWS_REGION to the region selected in the console.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
[[ -n "$REGION" ]] || die "Could not detect the AWS region. Run:  AWS_REGION=<your-region> ./setup-aws.sh"
export AWS_DEFAULT_REGION="$REGION"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET_NAME:-chaos-arena-${ACCOUNT_ID}-${REGION}}"

echo "Account : $ACCOUNT_ID"
echo "Region  : $REGION"

# -----------------------------------------------------------------------------
step "[0/4] Finding your EC2 instance (Name = $INSTANCE_NAME)..."
INSTANCE_ID="${INSTANCE_ID:-}"
if [[ -z "$INSTANCE_ID" ]]; then
  mapfile -t FOUND < <(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sed '/^$/d')
  if [[ ${#FOUND[@]} -eq 0 ]]; then
    die "No EC2 instance named '$INSTANCE_NAME' in region $REGION.
       - Is the console set to the region your server is in? (top-right corner)
         Switch region, open a NEW CloudShell, and run this again.
       - Or pass the ID directly:  INSTANCE_ID=i-0123456789abcdef0 ./setup-aws.sh"
  elif [[ ${#FOUND[@]} -gt 1 ]]; then
    die "More than one instance is named '$INSTANCE_NAME': ${FOUND[*]}
       Pick one:  INSTANCE_ID=<id> ./setup-aws.sh"
  fi
  INSTANCE_ID="${FOUND[0]}"
fi
echo "    Instance: $INSTANCE_ID"

# -----------------------------------------------------------------------------
step "[1/4] DynamoDB table '$TABLE' (managed NoSQL database)..."
if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  echo "    Already exists, keeping it."
else
  # pk = partition key, sk = sort key. 5 read + 5 write units is far inside the
  # always-free allowance of 25 each.
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --billing-mode PROVISIONED \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --tags Key=Project,Value=chaos-arena >/dev/null
  echo "    Creating... (waiting until it is ACTIVE)"
  aws dynamodb wait table-exists --table-name "$TABLE"
  echo "    Created."
fi

# -----------------------------------------------------------------------------
step "[2/4] S3 bucket '$BUCKET' (object storage for backups)..."
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "    Already exists, keeping it."
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  echo "    Created."
fi
# Security settings are (re)applied every run:
#   - block ALL public access   - encrypt everything at rest
#   - delete incident reports after 90 days so storage never grows forever
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "file://$HERE/s3-lifecycle.json"
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=Project,Value=chaos-arena}]'
echo "    Private, encrypted, with a 90-day cleanup rule."

# -----------------------------------------------------------------------------
step "[3/4] IAM role '$ROLE' (what the server is allowed to do)..."
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "    Role already exists, keeping it."
else
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "file://$HERE/trust-policy.json" \
    --description "Chaos Arena EC2 server: DynamoDB table, S3 backups, CloudWatch logs only" \
    --tags Key=Project,Value=chaos-arena >/dev/null
  echo "    Role created."
fi

# Fill in the policy template with this account's exact resource names
# ("least privilege": the server can touch ONLY its own table, bucket and logs).
POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
sed -e "s|__REGION__|$REGION|g" -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" \
    -e "s|__TABLE__|$TABLE|g" -e "s|__BUCKET__|$BUCKET|g" \
    "$HERE/iam-policy.template.json" > "$POLICY_FILE"
aws iam put-role-policy --role-name "$ROLE" --policy-name "$POLICY" \
  --policy-document "file://$POLICY_FILE"
echo "    Permissions policy '$POLICY' applied."

# An "instance profile" is the wrapper that lets an EC2 instance wear a role.
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
  echo "    Instance profile created."
fi
ROLES_IN_PROFILE="$(aws iam get-instance-profile --instance-profile-name "$PROFILE" \
  --query 'InstanceProfile.Roles[].RoleName' --output text)"
if [[ " $ROLES_IN_PROFILE " != *" $ROLE "* && "$ROLES_IN_PROFILE" != "$ROLE" ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE"
fi

CURRENT_PROFILE="$(aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" "Name=state,Values=associating,associated" \
  --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' --output text)"
if [[ "$CURRENT_PROFILE" == *"/$PROFILE" ]]; then
  echo "    Already attached to $INSTANCE_ID."
elif [[ -z "$CURRENT_PROFILE" || "$CURRENT_PROFILE" == "None" ]]; then
  echo "    Attaching to $INSTANCE_ID (new IAM objects can take up to a minute to be usable)..."
  ATTACHED=0
  for _ in $(seq 1 12); do
    if aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" \
         --iam-instance-profile "Name=$PROFILE" >/dev/null 2>&1; then
      ATTACHED=1
      break
    fi
    sleep "${RETRY_SLEEP:-5}"
  done
  [[ "$ATTACHED" -eq 1 ]] || die "Could not attach the role. Wait a minute and run this script again."
  echo "    Attached."
else
  die "The instance already uses a different instance profile:
         $CURRENT_PROFILE
       Remove it first: EC2 > Instances > select > Actions > Security > Modify IAM role."
fi

# Require IMDSv2 (the safer, token-based way for the server to fetch its role credentials).
aws ec2 modify-instance-metadata-options --instance-id "$INSTANCE_ID" \
  --http-tokens required --http-endpoint enabled >/dev/null
echo "    Instance metadata service set to IMDSv2-only."

# -----------------------------------------------------------------------------
step "[4/4] CloudWatch log groups (cloud monitoring)..."
for group in "${LOG_GROUPS[@]}"; do
  EXISTS="$(aws logs describe-log-groups --log-group-name-prefix "$group" \
    --query "length(logGroups[?logGroupName=='$group'])" --output text)"
  if [[ "$EXISTS" == "0" ]]; then
    aws logs create-log-group --log-group-name "$group" --tags Project=chaos-arena
    echo "    Created $group"
  else
    echo "    $group already exists, keeping it."
  fi
  # Retention = a storage quota: old logs are deleted automatically.
  aws logs put-retention-policy --log-group-name "$group" --retention-in-days "$LOG_RETENTION_DAYS"
done

# -----------------------------------------------------------------------------
cat <<EOF

================ AWS setup complete ================
Region            : $REGION
EC2 instance      : $INSTANCE_ID
DynamoDB table    : $TABLE
S3 bucket         : $BUCKET
IAM role          : $ROLE  (instance profile: $PROFILE)
CloudWatch logs   : ${LOG_GROUPS[*]}  (kept $LOG_RETENTION_DAYS days)

Next: SSH into the server and run the Module 03 scripts.
(The server finds the region, table and bucket by itself; nothing to copy.)
EOF
