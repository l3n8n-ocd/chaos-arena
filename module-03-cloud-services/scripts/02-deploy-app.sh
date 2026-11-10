#!/usr/bin/env bash
# =============================================================================
# 02-deploy-app.sh  —  Module 03, Step 2
#
# Deploys the game onto this server:
#   1. checks the server is wearing its IAM role (no access keys anywhere!)
#   2. copies app/ to /srv/chaos-arena/app and installs its dependencies
#   3. writes the settings + secret to /etc/chaos-arena/chaos-arena.env (root only)
#   4. installs the systemd service (auto-restart) and log rotation
#   5. starts the game and checks DynamoDB + S3 are reachable
#
# Run infra/aws/setup-aws.sh in AWS CloudShell BEFORE this script.
# Safe to re-run: it is also how you deploy a new version of the app.
#
# Usage:  sudo ./02-deploy-app.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$MODULE_DIR")"

APP_SRC="$REPO_DIR/app"
APP_DIR="/srv/chaos-arena/app"
LOG_DIR="/srv/chaos-arena/logs"
ENV_DIR="/etc/chaos-arena"
ENV_FILE="$ENV_DIR/chaos-arena.env"
EXPECTED_ROLE="chaos-arena-ec2-role"
PORT=3000

command -v node >/dev/null || { echo "ERROR: Node.js not found. Run 01-install-node.sh first." >&2; exit 1; }
id deployer &>/dev/null   || { echo "ERROR: user 'deployer' not found. Finish Module 02 first." >&2; exit 1; }

# -----------------------------------------------------------------------------
echo "==> [1/5] Checking this server's identity (instance metadata service)..."
# IMDSv2: first get a short-lived token, then use it to read the metadata.
IMDS="http://169.254.169.254/latest"
TOKEN="$(curl -sf -m 3 -X PUT "$IMDS/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 120' || true)"
[[ -n "$TOKEN" ]] || { echo "ERROR: cannot reach the EC2 metadata service. Is this an EC2 instance?" >&2; exit 1; }
imds() { curl -sf -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/$1" || true; }

IDENTITY="$(imds dynamic/instance-identity/document)"
[[ -n "$IDENTITY" ]] || { echo "ERROR: could not read the instance identity document." >&2; exit 1; }
REGION="$(node -pe 'JSON.parse(process.argv[1]).region' "$IDENTITY")"
ACCOUNT_ID="$(node -pe 'JSON.parse(process.argv[1]).accountId' "$IDENTITY")"
ROLE_NAME="$(imds meta-data/iam/security-credentials/)"

if [[ "$ROLE_NAME" != "$EXPECTED_ROLE" ]]; then
  cat >&2 <<EOF
ERROR: this server is not using the IAM role '$EXPECTED_ROLE' (found: '${ROLE_NAME:-none}').
       1. Open AWS CloudShell and run:  chaos-arena/infra/aws/setup-aws.sh
       2. Wait about a minute, then run this script again.
EOF
  exit 1
fi

TABLE_NAME="chaos-arena"
BUCKET_NAME="chaos-arena-${ACCOUNT_ID}-${REGION}"
echo "    Region: $REGION | IAM role: $ROLE_NAME"
echo "    Table : $TABLE_NAME | Bucket: $BUCKET_NAME"

# -----------------------------------------------------------------------------
echo "==> [2/5] Copying the app to $APP_DIR and installing dependencies..."
install -d -o deployer -g arena -m 2775 "$APP_DIR"
# --delete removes files that no longer exist in the repo; node_modules is kept out of the copy.
rsync -a --delete --exclude node_modules --exclude .data --exclude '.env' "$APP_SRC/" "$APP_DIR/"
chown -R deployer:arena "$APP_DIR"
# "npm ci" installs EXACTLY the versions in package-lock.json; --omit=dev skips test-only packages.
# It runs as the low-privilege deployer user, not as root.
sudo -u deployer -H bash -c "cd '$APP_DIR' && npm ci --omit=dev --no-audit --no-fund"

# -----------------------------------------------------------------------------
echo "==> [3/5] Writing settings to $ENV_FILE (readable by root only)..."
# Keep the existing admin secret on re-deploys; create one the first time.
ADMIN_TOKEN=""
if [[ -f "$ENV_FILE" ]]; then
  ADMIN_TOKEN="$(grep -E '^ADMIN_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"
fi
[[ -n "$ADMIN_TOKEN" ]] || ADMIN_TOKEN="$(openssl rand -hex 24)"

install -d -o root -g root -m 700 "$ENV_DIR"
umask 077   # files created from here on are private to root
cat > "$ENV_FILE" <<EOF
# Chaos Arena settings. Written by 02-deploy-app.sh on $(date -u '+%Y-%m-%d %H:%M UTC').
# This file holds a secret: it is root-only (chmod 600) and must never be committed to Git.
NODE_ENV=production
HOST=127.0.0.1
PORT=$PORT
STORE=dynamo
AWS_REGION=$REGION
TABLE_NAME=$TABLE_NAME
BUCKET_NAME=$BUCKET_NAME
WIN_AT=50
CHAOS_COOLDOWN_SEC=60
ADMIN_TOKEN=$ADMIN_TOKEN
EOF
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
umask 022

# -----------------------------------------------------------------------------
echo "==> [4/5] Installing the systemd service and log rotation..."
install -d -o deployer -g arena -m 2775 "$LOG_DIR"
# Create the log file up front so it belongs to deployer (needed for log rotation).
touch "$LOG_DIR/app.log"
chown deployer:arena "$LOG_DIR/app.log"
chmod 664 "$LOG_DIR/app.log"

install -m 644 "$MODULE_DIR/systemd/chaos-arena.service"   /etc/systemd/system/chaos-arena.service
install -m 644 "$MODULE_DIR/systemd/chaos-arena.logrotate" /etc/logrotate.d/chaos-arena
systemctl daemon-reload            # tell systemd to re-read its unit files
systemctl enable chaos-arena       # start automatically on boot
systemctl restart chaos-arena

# -----------------------------------------------------------------------------
echo "==> [5/5] Waiting for the game to come up..."
UP=0
for _ in $(seq 1 30); do
  if curl -sf -m 2 "http://127.0.0.1:$PORT/api/health" >/dev/null; then UP=1; break; fi
  sleep 1
done
if [[ "$UP" -ne 1 ]]; then
  echo "ERROR: the app did not start. Last log lines:" >&2
  tail -n 20 "$LOG_DIR/app.log" >&2 || true
  echo "(More:  sudo systemctl status chaos-arena   |   sudo journalctl -u chaos-arena -n 50)" >&2
  exit 1
fi

echo
echo "================ Step 2 complete ================"
systemctl --no-pager --lines=0 status chaos-arena | head -n 6
echo
echo "--- Deep health check (database + storage through the IAM role) ---"
STATUS_JSON="$(curl -s -m 10 "http://127.0.0.1:$PORT/api/status")"
node -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]), null, 2))' "$STATUS_JSON" || echo "$STATUS_JSON"
if ! grep -q '"status":"ok"' <<<"$STATUS_JSON"; then
  echo
  echo "WARNING: the app is running but a check failed (see 'detail' above)." >&2
  echo "         If you just ran setup-aws.sh, wait a minute and run this script again." >&2
  exit 1
fi
echo
echo ">>> The game is running on 127.0.0.1:$PORT. Next: 03-configure-nginx.sh to put it online. <<<"
