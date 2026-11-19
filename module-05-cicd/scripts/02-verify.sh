#!/usr/bin/env bash
# =============================================================================
# 02-verify.sh  —  Module 05 evidence report
#
# Shows the CI/CD + monitoring setup working on the server:
# what's deployed vs the latest commit on GitHub, the deploy agent, its
# history, the images it pulled, monitoring/log shipping, and optionally:
#   --freeze   freeze the app (it stays "running" but stops answering) and
#              watch the deploy agent detect and heal it
#
# Usage:    sudo ./02-verify.sh [--freeze] | tee ~/module-05-verify-output.txt
# =============================================================================
set -u

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi
FREEZE=0
[[ "${1:-}" == "--freeze" ]] && FREEZE=1

SITE="https://chaos-arena.duckdns.org"
LOG=/srv/chaos-arena/logs/deploy.log
section() { echo; echo "=================== $1 ==================="; }
run()     { echo "\$ $*"; bash -c "$*" 2>&1; echo; }

echo "Chaos Arena — Module 05 verification report"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "1. LIVE VERSION vs LATEST COMMIT ON GITHUB"
LATEST="$(curl -s -m 10 https://api.github.com/repos/l3n8n-ocd/chaos-arena/commits/main | grep -m1 '"sha"' | cut -d'"' -f4)"
LIVE="$(curl -s -m 10 "$SITE/api/health" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)"
echo "Latest commit on main : ${LATEST:-unknown}"
echo "Running on $SITE : ${LIVE:-unknown}"
if [[ -n "$LATEST" && "$LATEST" == "$LIVE" ]]; then
  echo "RESULT: the live site runs the latest commit (continuous deployment works)."
else
  echo "RESULT: not the same yet (a deploy may be in progress, or it was rolled back; see section 3)."
fi
echo

section "2. DEPLOY AGENT"
run "systemctl is-enabled arena-deploy.timer && systemctl is-active arena-deploy.timer"
run "systemctl list-timers arena-deploy.timer --no-pager | head -n 2"
run "echo \"Deployed tag: \$(cat /var/lib/chaos-arena/deployed-tag 2>/dev/null || echo none)\"; echo \"Rolled-back tags: \$(cat /var/lib/chaos-arena/bad-tags 2>/dev/null | tr '\n' ' ' || true)\""

section "3. DEPLOYMENT HISTORY (agent log, newest last)"
run "grep -E 'deploy_(started|succeeded|failed|rolled_back)|container_healed' $LOG | tail -n 12 | cut -c1-200"

section "4. IMAGES FROM THE PIPELINE (GitHub Container Registry)"
run "docker image ls 'ghcr.io/l3n8n-ocd/*' --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'"
run "docker inspect chaos-arena-app-1 chaos-arena-web-1 --format '{{.Name}} runs {{.Config.Image}} (health: {{.State.Health.Status}})'"
run "docker image inspect \$(docker inspect -f '{{.Config.Image}}' chaos-arena-app-1) --format 'built from commit: {{index .Config.Labels \"org.opencontainers.image.revision\"}}'"

section "5. MONITORING"
run "curl -s -m 10 $SITE/api/status"
echo
run "docker inspect chaos-arena-app-1 --format 'app logs -> {{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config \"awslogs-group\"}}'"
if [[ -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]]; then
  run "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status -m ec2 | grep -E '\"status\"'"
  run "grep -o '\"file_path\": \"[^\"]*\"' /opt/aws/amazon-cloudwatch-agent/etc/chaos-arena-config.json"
fi

if [[ "$FREEZE" -eq 1 ]]; then
  section "6. FREEZE TEST (app hangs without crashing; the agent heals it)"
  echo "Docker's restart policy only reacts to a CRASH. Here the app is frozen instead:"
  echo "still 'running', but it stops answering. Its health check fails, Docker marks it"
  echo "unhealthy, and the deploy agent (every minute) restarts it."
  echo
  START=$(date +%s)
  echo "\$ docker exec chaos-arena-app-1 kill -STOP <node process>"
  docker exec chaos-arena-app-1 sh -c 'kill -STOP $(pgrep -o -x node)'
  echo "Frozen at $(date -u +%H:%M:%S). Waiting (health check needs ~30-40 s, agent runs every minute)..."
  HEALED=0
  for _ in $(seq 1 60); do
    sleep 5
    STATUS="$(docker inspect -f '{{.State.Health.Status}}' chaos-arena-app-1)"
    if grep -q container_healed <(tail -n 3 "$LOG") && [[ "$STATUS" == healthy ]]; then HEALED=1; break; fi
  done
  END=$(date +%s)
  if [[ "$HEALED" -eq 1 ]]; then
    echo "RESULT: healed. Frozen app detected and restarted in $((END - START)) s, no human involved."
  else
    echo "RESULT: not healed within 5 minutes. Unfreezing it now."
    docker exec chaos-arena-app-1 sh -c 'kill -CONT $(pgrep -o -x node)' 2>/dev/null || docker restart chaos-arena-app-1
  fi
  run "grep container_healed $LOG | tail -n 1 | cut -c1-200"
  run "curl -s -m 5 $SITE/api/health"
else
  section "6. FREEZE TEST"
  echo "(skipped: add --freeze to hang the app and watch the agent heal it)"
fi

echo
echo "=================== END OF REPORT ==================="
