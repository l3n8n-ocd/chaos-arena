#!/usr/bin/env bash
# =============================================================================
# 01-install-deploy-agent.sh  —  Module 05, server step
#
# Connects the server to the CI/CD pipeline:
#   1. updates the "arena" command (it now knows about published images)
#   2. installs the deploy agent + a systemd timer that runs it every minute
#   3. ships the agent's log to CloudWatch (for alarms + the dashboard)
#   4. checks the server can download the pipeline's images
#   5. runs the agent once: the latest pipeline build goes live right away
#
# Usage:  sudo ./01-install-deploy-agent.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$MODULE_DIR")"
REGISTRY="ghcr.io/l3n8n-ocd"
CW_CTL="/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"

command -v docker >/dev/null || { echo "ERROR: Docker not found. Finish Module 04 first." >&2; exit 1; }
docker inspect chaos-arena-app-1 >/dev/null 2>&1 || { echo "ERROR: containers not running. Finish Module 04 first." >&2; exit 1; }

echo "==> [1/5] Updating the 'arena' command..."
sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/module-04-docker/arena" > /usr/local/bin/arena
chmod 755 /usr/local/bin/arena

echo "==> [2/5] Installing the deploy agent + timer..."
install -m 755 "$MODULE_DIR/arena-deploy" /usr/local/bin/arena-deploy
install -m 644 "$MODULE_DIR/systemd/arena-deploy.service" /etc/systemd/system/arena-deploy.service
install -m 644 "$MODULE_DIR/systemd/arena-deploy.timer"   /etc/systemd/system/arena-deploy.timer
install -m 644 "$MODULE_DIR/systemd/arena-deploy.logrotate" /etc/logrotate.d/arena-deploy
install -d -o deployer -g arena -m 2775 /srv/chaos-arena/logs
touch /srv/chaos-arena/logs/deploy.log
install -d -m 755 /var/lib/chaos-arena
systemctl daemon-reload

echo "==> [3/5] Sending the agent's log to CloudWatch..."
if [[ -x "$CW_CTL" ]]; then
  install -m 644 "$MODULE_DIR/cloudwatch/agent-config.json" /opt/aws/amazon-cloudwatch-agent/etc/chaos-arena-config.json
  "$CW_CTL" -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/chaos-arena-config.json >/dev/null
  echo "    Done: CloudWatch log group /chaos-arena/app, stream 'deploy-agent'."
else
  echo "    (CloudWatch agent not installed: skipped. See Module 03, script 04.)"
fi

echo "==> [4/5] Checking the server can download the pipeline's images..."
if ! docker pull -q "$REGISTRY/chaos-arena-app:main" >/dev/null 2>&1 || ! docker pull -q "$REGISTRY/chaos-arena-web:main" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: cannot download $REGISTRY/chaos-arena-app:main and/or chaos-arena-web:main.
       1. Has the CI/CD pipeline finished at least once on main?
          https://github.com/l3n8n-ocd/chaos-arena/actions
       2. Are both packages PUBLIC? For each one open the link below, then
          "Change visibility" -> Public:
          https://github.com/users/l3n8n-ocd/packages/container/chaos-arena-app/settings
          https://github.com/users/l3n8n-ocd/packages/container/chaos-arena-web/settings
       Then run this script again.
EOF
  exit 1
fi
echo "    OK: images are reachable."

echo "==> [5/5] Starting the agent (first deploy happens now, ~1 minute)..."
systemctl enable --now arena-deploy.timer >/dev/null
systemctl start arena-deploy.service || true

echo
echo "================ Deploy agent installed ================"
systemctl list-timers arena-deploy.timer --no-pager | head -n 2
echo
echo "--- Agent log (newest last) ---"
tail -n 5 /srv/chaos-arena/logs/deploy.log
echo
echo "--- What's live now ---"
curl -s -m 5 http://127.0.0.1:8080/api/health; echo
echo "Deployed tag: $(cat /var/lib/chaos-arena/deployed-tag 2>/dev/null || echo 'none yet')"
echo
echo ">>> From now on, every push to main is tested, built and deployed automatically. <<<"
