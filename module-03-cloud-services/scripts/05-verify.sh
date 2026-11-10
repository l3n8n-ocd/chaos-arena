#!/usr/bin/env bash
# =============================================================================
# 05-verify.sh  —  Module 03, Step 5
#
# Tests the whole deployment and prints an evidence report:
# runtime, service + quotas, settings + secrets, IAM role, network, database,
# storage, HTTPS, logs, and (with --chaos) a real crash-and-recover test.
#
# The report is saved OUTSIDE the Git folder so "git pull" keeps working.
#
# Usage:    sudo ./05-verify.sh <domain> [--chaos] | tee ~/module-03-verify-output.txt
# Example:  sudo ./05-verify.sh chaos-arena.duckdns.org --chaos | tee ~/module-03-verify-output.txt
# =============================================================================
set -u   # no "set -e": the report should continue even if one check fails

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN=""
RUN_CHAOS=0
for arg in "$@"; do
  case "$arg" in
    --chaos) RUN_CHAOS=1 ;;
    *) DOMAIN="$arg" ;;
  esac
done
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo $0 <domain> [--chaos]" >&2
  exit 1
fi

ENV_FILE="/etc/chaos-arena/chaos-arena.env"
LOG_FILE="/srv/chaos-arena/logs/app.log"
APP="http://127.0.0.1:3000"
SITE="https://$DOMAIN"
RESOLVE="--resolve $DOMAIN:443:127.0.0.1"          # used inside run "..." strings
RESOLVE_ARGS=(--resolve "$DOMAIN:443:127.0.0.1")    # used in direct curl calls

section() { echo; echo "=================== $1 ==================="; }
run()     { echo "\$ $*"; bash -c "$*" 2>&1; echo; }
pretty()  { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.stringify(JSON.parse(s),null,2))}catch{console.log(s)}})'; }
export -f pretty

echo "Chaos Arena — Module 03 verification report"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "1. RUNTIME (cloud compute)"
run "node -v && npm -v"
run "uptime -p && free -h | head -n 2"

section "2. SERVICE, SELF-HEALING & RESOURCE QUOTAS (systemd)"
run "systemctl is-active chaos-arena nginx && systemctl is-enabled chaos-arena"
run "systemctl show chaos-arena -p User -p Group -p Restart -p RestartUSec -p NRestarts -p MemoryMax -p MemoryHigh -p CPUQuotaPerSecUSec -p TasksMax -p NoNewPrivileges -p ProtectSystem"
run "systemctl show chaos-arena -p MemoryCurrent -p TasksCurrent"
run "ps -o pid,user,group,rss,etime,args -C node"

section "3. ENVIRONMENT VARIABLES & SECRETS"
run "stat -c '%A  %U:%G  %n' /etc/chaos-arena $ENV_FILE"
echo "# Settings file with the secret hidden:"
run "grep -v '^#' $ENV_FILE | sed -E 's/^(ADMIN_TOKEN)=.*/\1=******** (hidden)/'"
echo "# No AWS access keys anywhere on this server (the IAM role is used instead):"
run "grep -c 'AWS_ACCESS_KEY\|AWS_SECRET' $ENV_FILE; ls -d /root/.aws /home/*/.aws 2>/dev/null || echo 'no ~/.aws folders: OK'"
echo "# The secret is not in the Git repository:"
run "cd /srv/chaos-arena/app && ls -a | grep -c '^\.env$' ; echo '(0 = no .env file deployed: OK)'"

section "4. IAM ROLE (identity of this server)"
TOKEN="$(curl -sf -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
echo "\$ (instance metadata service, IMDSv2)"
echo "Role in use      : $(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ || echo none)"
echo "Instance profile : $(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/info | grep -o 'arn:aws:iam[^"]*' || echo none)"
echo "Region / AZ      : $(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone || echo unknown)"
echo "IMDSv1 blocked?  : $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/) (401 = yes, token required)"
echo

section "5. NETWORKING"
echo "# The app listens on localhost only; Nginx is the only public door:"
run "ss -tlnp | grep -E ':(22|80|443|3000)\\b' | awk '{print \$4, \$6}'"
run "ufw status | grep -E '^(Status|22|80|443|3000)'"

section "6. DATABASE & STORAGE (DynamoDB + S3 through the IAM role)"
run "curl -s -m 10 $APP/api/status | pretty"

section "7. LIVE WEB APPLICATION (through Nginx + HTTPS)"
run "curl -s $RESOLVE $SITE/health"
run "curl -s $RESOLVE $SITE/api/health"
run "curl -sI $RESOLVE $SITE/ | grep -Ei '^(HTTP|server|strict-transport|content-security|x-frame|x-content)'"
run "curl -s $RESOLVE $SITE/ | grep -o '<title>.*</title>'"
run "curl -sI http://$DOMAIN/ --resolve $DOMAIN:80:127.0.0.1 | grep -Ei '^(HTTP|location)'"
echo "# Play one click for each team through the public API (rope ends where it started):"
run "curl -s $RESOLVE -X POST -H 'Content-Type: application/json' -d '{\"team\":\"red\",\"count\":1,\"pid\":\"verify-script\"}' $SITE/api/pull | pretty | grep -E '\"(rope|round|totalClicks)\"'"
run "curl -s $RESOLVE -X POST -H 'Content-Type: application/json' -d '{\"team\":\"blue\",\"count\":1,\"pid\":\"verify-script\"}' $SITE/api/pull | pretty | grep -E '\"(rope|round|totalClicks)\"'"
echo "# Bad input and the admin endpoint are rejected:"
run "curl -s -o /dev/null -w 'bad team -> HTTP %{http_code}\n' $RESOLVE -X POST -H 'Content-Type: application/json' -d '{\"team\":\"green\"}' $SITE/api/pull"
run "curl -s -o /dev/null -w 'admin reset without token -> HTTP %{http_code}\n' $RESOLVE -X POST $SITE/api/admin/reset"

section "8. APPLICATION LOGGING"
run "ls -l $LOG_FILE && tail -n 4 $LOG_FILE | cut -c1-220"
run "cat /etc/logrotate.d/chaos-arena | grep -vE '^\s*#'"
if [[ -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]]; then
  run "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status -m ec2 | grep -E '\"(status|configstatus)\"'"
else
  echo "(CloudWatch agent not installed: run 04-install-cloudwatch-agent.sh)"
fi

if [[ "$RUN_CHAOS" -eq 1 ]]; then
  section "9. CHAOS TEST (crash the app on purpose, measure self-healing)"
  BEFORE="$(systemctl show chaos-arena -p NRestarts --value)"
  OLD_PID="$(systemctl show chaos-arena -p MainPID --value)"
  echo "Restarts so far: $BEFORE | current PID: $OLD_PID"
  echo "\$ curl -X POST $SITE/api/chaos"
  START_MS="$(date +%s%3N)"
  RESPONSE="$(curl -s "${RESOLVE_ARGS[@]}" -X POST -H 'Content-Type: application/json' -d '{"pid":"verify-script"}' "$SITE/api/chaos")"
  echo "$RESPONSE"
  if grep -q '"status":"crashing"' <<<"$RESPONSE"; then
    sleep 0.4
    echo
    echo "# While it is down, Nginx answers for it:"
    curl -s "${RESOLVE_ARGS[@]}" -o /dev/null -w 'GET /api/health -> HTTP %{http_code}\n' "$SITE/api/health"
    curl -s "${RESOLVE_ARGS[@]}" -o /dev/null -w 'GET /           -> HTTP %{http_code} (the page itself still loads)\n' "$SITE/"
    HEALED=0
    for _ in $(seq 1 100); do
      if curl -sf -m 1 "$APP/api/health" >/dev/null; then HEALED=1; break; fi
      sleep 0.1
    done
    END_MS="$(date +%s%3N)"
    echo
    if [[ "$HEALED" -eq 1 ]]; then
      echo "RESULT: healed. Back online $((END_MS - START_MS)) ms after the CHAOS request."
    else
      echo "RESULT: NOT healed within 10 seconds. Check: sudo systemctl status chaos-arena"
    fi
    echo "Restarts now: $(systemctl show chaos-arena -p NRestarts --value) | new PID: $(systemctl show chaos-arena -p MainPID --value)"
    echo
    echo "# What the app itself recorded in DynamoDB:"
    run "curl -s $APP/api/state | pretty | grep -A 8 '\"chaos\"'"
    echo "# The story in the log file:"
    run "grep -E 'CHAOS|deliberate crash|recovered from crash|listening' $LOG_FILE | tail -n 4 | cut -c1-200"
  else
    echo
    echo "(The chaos button is cooling down, or the app refused. Wait a minute and run again.)"
  fi
else
  section "9. CHAOS TEST"
  echo "(skipped: add --chaos to crash the app on purpose and measure the recovery)"
fi

echo
echo "=================== END OF REPORT ==================="
