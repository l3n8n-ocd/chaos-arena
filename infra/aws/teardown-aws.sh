#!/usr/bin/env bash
# =============================================================================
# teardown-aws.sh — DELETES everything setup-aws.sh created.
#
# Only run this when the project is finished (e.g. before your AWS free plan
# ends). The game data, backups and logs are permanently deleted.
# It does NOT touch the EC2 instance, its Elastic IP or its security group.
#
# Run it in AWS CloudShell:   ./teardown-aws.sh
# =============================================================================
set -uo pipefail   # no "-e": keep going so one missing resource doesn't stop the cleanup

TABLE="${TABLE_NAME:-chaos-arena}"
ROLE="chaos-arena-ec2-role"
PROFILE="chaos-arena-ec2-profile"
POLICY="chaos-arena-app-policy"
LOG_GROUPS=("/chaos-arena/app" "/chaos-arena/nginx")

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
[[ -n "$REGION" ]] || { echo "ERROR: could not detect the AWS region." >&2; exit 1; }
export AWS_DEFAULT_REGION="$REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || exit 1
BUCKET="${BUCKET_NAME:-chaos-arena-${ACCOUNT_ID}-${REGION}}"

cat <<EOF
This will PERMANENTLY DELETE in region $REGION:
  - DynamoDB table   $TABLE
  - S3 bucket        $BUCKET  (and every object in it)
  - IAM role         $ROLE, instance profile $PROFILE
  - Log groups       ${LOG_GROUPS[*]}
EOF
read -r -p 'Type "delete" to continue: ' ANSWER
[[ "$ANSWER" == "delete" ]] || { echo "Cancelled. Nothing was deleted."; exit 0; }

echo "==> Detaching the role from any EC2 instance..."
for assoc in $(aws ec2 describe-iam-instance-profile-associations \
    --query "IamInstanceProfileAssociations[?ends_with(IamInstanceProfile.Arn, '/$PROFILE')].AssociationId" \
    --output text); do
  aws ec2 disassociate-iam-instance-profile --association-id "$assoc" >/dev/null && echo "    detached $assoc"
done

echo "==> Deleting IAM instance profile and role..."
aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null
aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null
aws iam delete-role --role-name "$ROLE" 2>/dev/null

echo "==> Deleting CloudWatch log groups..."
for group in "${LOG_GROUPS[@]}"; do
  aws logs delete-log-group --log-group-name "$group" 2>/dev/null
done

echo "==> Emptying and deleting the S3 bucket..."
aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1
aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null

echo "==> Deleting the DynamoDB table..."
aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1

echo
echo "Done. Remember to also stop/terminate the EC2 instance and release the"
echo "Elastic IP in the console when you no longer need the server."
