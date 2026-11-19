#!/usr/bin/env bash
# =============================================================================
# setup-monitoring.sh — CloudWatch monitoring for Chaos Arena (Module 05)
#
# Run in AWS CloudShell (same region as the server):
#     ./setup-monitoring.sh you@example.com
#
# Creates (safe to run again):
#   - SNS topic "chaos-arena-alerts" + an email subscription (confirm the email!)
#   - Metric filters: turn JSON log lines into numbers (recovery time, crashes,
#     errors, rounds, deploys, rollbacks, healed containers)
#   - 7 alarms that email you, two of which also repair the EC2 instance
#   - Dashboard "chaos-arena" with charts + a live log query
# =============================================================================
set -euo pipefail

EMAIL="${1:-}"
LOG_GROUP="/chaos-arena/app"
NS="ChaosArena"
TOPIC_NAME="chaos-arena-alerts"
INSTANCE_NAME="${INSTANCE_NAME:-chaos-arena}"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

command -v aws >/dev/null || die "Run this in AWS CloudShell."
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
[[ -n "$REGION" ]] || die "Could not detect the region. Run: AWS_REGION=<region> $0 $EMAIL"
export AWS_DEFAULT_REGION="$REGION"

INSTANCE_ID="${INSTANCE_ID:-$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)}"
[[ "$INSTANCE_ID" == i-* ]] || die "No instance named '$INSTANCE_NAME' in $REGION. Switch region (top-right) and open a new CloudShell."
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0].logGroupName' --output text | grep -qx "$LOG_GROUP" \
  || die "Log group $LOG_GROUP not found. Run ./setup-aws.sh first."

echo "Region: $REGION | Instance: $INSTANCE_ID"

# -----------------------------------------------------------------------------
step "[1/4] Email alerts (SNS topic $TOPIC_NAME)..."
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC_NAME" --tags Key=Project,Value=chaos-arena --query TopicArn --output text)"
echo "    Topic: $TOPIC_ARN"
if [[ -n "$EMAIL" ]]; then
  if aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].Endpoint' --output text | tr '\t' '\n' | grep -qxi "$EMAIL"; then
    echo "    $EMAIL is already subscribed."
  else
    aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
    echo "    Subscription created. >>> Open the email from AWS Notifications and click 'Confirm subscription'. <<<"
  fi
else
  echo "    (No email given: alarms will still appear on the dashboard. Re-run with your email to get alerts.)"
fi

# -----------------------------------------------------------------------------
step "[2/4] Metric filters (log lines -> metrics in namespace $NS)..."
filter() {  # name pattern metricName value unit
  aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name "$1" --filter-pattern "$2" \
    --metric-transformations "[{\"metricName\":\"$3\",\"metricNamespace\":\"$NS\",\"metricValue\":\"$4\",\"unit\":\"$5\"}]"
  echo "    $3  <-  $2"
}
filter recovery-time    '{ $.msg = "recovered from crash" }'                     RecoveryTimeMs   '$.recoveryMs' Milliseconds
filter chaos-presses    '{ $.msg = "CHAOS button pressed: crashing on purpose" }' ChaosPresses     1 Count
filter rounds-finished  '{ $.msg = "round finished" }'                            RoundsFinished   1 Count
filter app-errors       '{ $.level = "error" && $.msg != "process exiting with code 1 (deliberate crash)" }' AppErrors 1 Count
filter deploys-ok       '{ $.event = "deploy_succeeded" }'                        DeploySucceeded  1 Count
filter deploys-rollback '{ $.event = "deploy_rolled_back" }'                      DeployRolledBack 1 Count
filter containers-healed '{ $.event = "container_healed" }'                       ContainersHealed 1 Count

# -----------------------------------------------------------------------------
step "[3/4] Alarms..."
alarm() {  # name description namespace metric stat comparison threshold period evals [extra actions...]
  local name="$1" desc="$2" ns="$3" metric="$4" stat="$5" cmp="$6" thr="$7" period="$8" evals="$9"; shift 9
  local dims=()
  [[ "$ns" == "AWS/EC2" ]] && dims=(--dimensions "Name=InstanceId,Value=$INSTANCE_ID")
  aws cloudwatch put-metric-alarm --alarm-name "$name" --alarm-description "$desc" \
    --namespace "$ns" --metric-name "$metric" "${dims[@]}" --statistic "$stat" \
    --comparison-operator "$cmp" --threshold "$thr" --period "$period" --evaluation-periods "$evals" \
    --treat-missing-data notBreaching --alarm-actions "$TOPIC_ARN" "$@" --ok-actions "$TOPIC_ARN" \
    --tags Key=Project,Value=chaos-arena
  echo "    $name"
}
alarm chaos-arena-slow-recovery   "A crash took more than 5 s to heal"            "$NS" RecoveryTimeMs   Maximum GreaterThanThreshold          5000 60  1
alarm chaos-arena-app-errors      "5+ real errors (not CHAOS) in 5 minutes"      "$NS" AppErrors        Sum     GreaterThanOrEqualToThreshold 5    300 1
alarm chaos-arena-deploy-rollback "A new version was unhealthy and rolled back"  "$NS" DeployRolledBack Sum     GreaterThanOrEqualToThreshold 1    60  1
alarm chaos-arena-container-healed "A frozen container was restarted by the deploy agent" "$NS" ContainersHealed Sum GreaterThanOrEqualToThreshold 1 60 1
alarm chaos-arena-high-cpu        "Server CPU above 80% for 15 minutes"          AWS/EC2 CPUUtilization Average GreaterThanThreshold        80   300 3
# Self-healing for the VM itself: AWS moves the instance to healthy hardware...
alarm chaos-arena-instance-recover "AWS hardware/system problem: recover the instance" AWS/EC2 StatusCheckFailed_System Maximum GreaterThanOrEqualToThreshold 1 60 2 \
  "arn:aws:automate:$REGION:ec2:recover"
# ...or reboots it if the operating system stops responding.
alarm chaos-arena-instance-reboot "Server OS not responding: reboot it"          AWS/EC2 StatusCheckFailed_Instance Maximum GreaterThanOrEqualToThreshold 1 60 3 \
  "arn:aws:automate:$REGION:ec2:reboot"

# -----------------------------------------------------------------------------
step "[4/4] Dashboard 'chaos-arena'..."
ALARM_ARNS="$(aws cloudwatch describe-alarms --alarm-name-prefix chaos-arena- --query 'MetricAlarms[].AlarmArn' --output json)"
DASHBOARD="$(cat <<EOF
{
  "widgets": [
    {"type":"text","x":0,"y":0,"width":24,"height":2,"properties":{"markdown":"# Chaos Arena\\nA tug-of-war you're allowed to crash. Live: [chaos-arena.duckdns.org](https://chaos-arena.duckdns.org) · Code: [GitHub](https://github.com/l3n8n-ocd/chaos-arena)"}},
    {"type":"metric","x":0,"y":2,"width":12,"height":6,"properties":{"title":"Recovery time after a crash (ms)","region":"$REGION","view":"timeSeries","stat":"Maximum","period":300,
      "metrics":[["$NS","RecoveryTimeMs",{"stat":"Average","label":"average"}],["$NS","RecoveryTimeMs",{"stat":"Maximum","label":"worst"}]],
      "annotations":{"horizontal":[{"label":"alarm","value":5000}]},"yAxis":{"left":{"min":0}}}},
    {"type":"metric","x":12,"y":2,"width":12,"height":6,"properties":{"title":"Crashes vs rounds played","region":"$REGION","view":"timeSeries","stat":"Sum","period":300,
      "metrics":[["$NS","ChaosPresses",{"label":"CHAOS presses"}],["$NS","RoundsFinished",{"label":"rounds finished"}]]}},
    {"type":"metric","x":0,"y":8,"width":12,"height":6,"properties":{"title":"Deployments & self-healing","region":"$REGION","view":"bar","stat":"Sum","period":3600,
      "metrics":[["$NS","DeploySucceeded",{"label":"deploys"}],["$NS","DeployRolledBack",{"label":"rollbacks"}],["$NS","ContainersHealed",{"label":"frozen containers healed"}],["$NS","AppErrors",{"label":"real errors"}]]}},
    {"type":"metric","x":12,"y":8,"width":12,"height":6,"properties":{"title":"Server (EC2)","region":"$REGION","view":"timeSeries","stat":"Average","period":300,
      "metrics":[["AWS/EC2","CPUUtilization","InstanceId","$INSTANCE_ID",{"label":"CPU %"}],["AWS/EC2","StatusCheckFailed","InstanceId","$INSTANCE_ID",{"stat":"Maximum","label":"status check failed","yAxis":"right"}]]}},
    {"type":"alarm","x":0,"y":14,"width":24,"height":3,"properties":{"title":"Alarms","alarms":$ALARM_ARNS}},
    {"type":"log","x":0,"y":17,"width":24,"height":7,"properties":{"title":"Latest crashes, recoveries and deploys","region":"$REGION","view":"table",
      "query":"SOURCE '$LOG_GROUP' | fields @timestamp, coalesce(event, msg) as what, recoveryMs, version | filter msg in ['CHAOS button pressed: crashing on purpose', 'recovered from crash'] or ispresent(event) | sort @timestamp desc | limit 20"}}
  ]
}
EOF
)"
aws cloudwatch put-dashboard --dashboard-name chaos-arena --dashboard-body "$DASHBOARD" --query 'DashboardValidationMessages' --output text
echo "    Dashboard saved."

cat <<EOF

================ Monitoring ready ================
Dashboard : https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards/dashboard/chaos-arena
Alarms    : https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#alarmsV2:
Email     : ${EMAIL:-(none)}   <- confirm the subscription email if you haven't yet
Metrics appear after the next crash / round / deploy (they come from log lines).
EOF
