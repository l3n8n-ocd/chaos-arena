#!/usr/bin/env bash
# =============================================================================
# 04-install-cloudwatch-agent.sh  —  Module 03, Step 4
#
# Cloud monitoring: installs the Amazon CloudWatch agent and tells it to ship
# three log files to CloudWatch Logs, so they can be read and searched in the
# AWS Console even if the server itself is gone:
#
#   /srv/chaos-arena/logs/app.log           -> log group /chaos-arena/app
#   /var/log/nginx/chaos-arena.access.log   -> log group /chaos-arena/nginx
#   /var/log/nginx/chaos-arena.error.log    -> log group /chaos-arena/nginx
#
# The agent authenticates with the server's IAM role: no access keys.
#
# Usage:  sudo ./04-install-cloudwatch-agent.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_CTL="/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"
CONFIG_SRC="$MODULE_DIR/cloudwatch/agent-config.json"
CONFIG_DST="/opt/aws/amazon-cloudwatch-agent/etc/chaos-arena-config.json"

export DEBIAN_FRONTEND=noninteractive

if [[ -x "$AGENT_CTL" ]]; then
  echo "==> [1/3] CloudWatch agent is already installed, skipping download."
else
  echo "==> [1/3] Downloading and installing the CloudWatch agent..."
  ARCH="$(dpkg --print-architecture)"    # amd64 (t3) or arm64 (t4g)
  DEB="$(mktemp --suffix=.deb)"
  trap 'rm -f "$DEB"' EXIT
  curl -fsSL "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/${ARCH}/latest/amazon-cloudwatch-agent.deb" -o "$DEB"
  dpkg -i -E "$DEB"
fi

echo "==> [2/3] Loading the Chaos Arena log configuration..."
install -m 644 "$CONFIG_SRC" "$CONFIG_DST"
# fetch-config: read our config file | -m ec2: we are on EC2 | -s: (re)start the agent
"$AGENT_CTL" -a fetch-config -m ec2 -s -c "file:$CONFIG_DST"

echo "==> [3/3] Enabling the agent on boot..."
systemctl enable amazon-cloudwatch-agent >/dev/null 2>&1 || true
sleep 3

echo
echo "================ Step 4 complete ================"
"$AGENT_CTL" -a status -m ec2
echo
echo "--- Last lines of the agent's own log (look for errors such as AccessDenied) ---"
tail -n 8 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log 2>/dev/null || true
echo
echo ">>> In the AWS Console: CloudWatch > Log groups > /chaos-arena/app <<<"
echo ">>> New log lines appear there within about a minute.               <<<"
