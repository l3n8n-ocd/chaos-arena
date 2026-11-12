#!/usr/bin/env bash
# =============================================================================
# 02-run-containers.sh  —  Module 04, Step 2
#
# Moves the game from systemd (Module 03) into Docker containers:
#   1. installs the "arena" shortcut command
#   2. builds the two images (app + web)
#   3. checks a container can get the server's IAM role credentials
#   4. stops the old systemd service, starts the containers
#   5. waits until both are healthy and checks DynamoDB + S3
#
# Safe to re-run: it is also how you deploy a new version.
# To undo everything: sudo ./rollback-to-systemd.sh <domain>
#
# Usage:  sudo ./02-run-containers.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$MODULE_DIR")"
ENV_FILE="/etc/chaos-arena/chaos-arena.env"

command -v docker >/dev/null || { echo "ERROR: Docker is not installed. Run 01-install-docker.sh first." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Finish Module 03 first." >&2; exit 1; }
[[ -f "$REPO_DIR/compose.yaml" ]] || { echo "ERROR: compose.yaml not found in $REPO_DIR. Run: git fetch origin && git reset --hard origin/main" >&2; exit 1; }

# -----------------------------------------------------------------------------
echo "==> [1/5] Installing the 'arena' shortcut command..."
sed "s|__REPO_DIR__|$REPO_DIR|g" "$MODULE_DIR/arena" > /usr/local/bin/arena
chmod 755 /usr/local/bin/arena
echo "    Try later:  arena ps   |   arena logs -f app   |   arena restart app"

# -----------------------------------------------------------------------------
echo "==> [2/5] Building the images (first time takes 1-3 minutes)..."
arena build
docker image ls --format '    {{.Repository}}:{{.Tag}}  {{.Size}}' | grep chaos-arena

# -----------------------------------------------------------------------------
echo "==> [3/5] Checking that a container can reach the IAM role..."
# From inside a container, ask the metadata service for a token. This only
# works if the instance's "hop limit" is 2 (setup-aws.sh sets it).
if ! docker run --rm --entrypoint node chaos-arena-app:local -e "
  fetch('http://169.254.169.254/latest/api/token', {
    method: 'PUT',
    headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '60' },
    signal: AbortSignal.timeout(3000),
  }).then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1));
"; then
  cat >&2 <<'EOF'
ERROR: containers cannot get AWS credentials yet (metadata hop limit is still 1).
       Fix it in AWS CloudShell, then run this script again:
         cd ~/chaos-arena && git pull && cd infra/aws && ./setup-aws.sh
EOF
  exit 1
fi
echo "    OK: containers can use the server's IAM role."

# -----------------------------------------------------------------------------
echo "==> [4/5] Switching from systemd to Docker..."
if systemctl is-active --quiet chaos-arena 2>/dev/null || systemctl is-enabled --quiet chaos-arena 2>/dev/null; then
  # Stop the Module 03 service first, so two copies of the game never run at once.
  systemctl disable --now chaos-arena
  echo "    Stopped and disabled the old systemd service 'chaos-arena'."
fi
arena up -d --remove-orphans

# -----------------------------------------------------------------------------
echo "==> [5/5] Waiting for both containers to be healthy..."
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing; }
for _ in $(seq 1 60); do
  if [[ "$(health chaos-arena-app-1)" == healthy && "$(health chaos-arena-web-1)" == healthy ]]; then break; fi
  sleep 2
done
if [[ "$(health chaos-arena-app-1)" != healthy || "$(health chaos-arena-web-1)" != healthy ]]; then
  echo "ERROR: containers are not healthy (app: $(health chaos-arena-app-1), web: $(health chaos-arena-web-1))." >&2
  echo "Last app log lines:" >&2
  arena logs --tail 20 app >&2 || true
  echo "To go back to Module 03:  sudo ./rollback-to-systemd.sh <domain>" >&2
  exit 1
fi

echo
echo "================ Step 2 complete ================"
arena ps
echo
echo "--- Deep health check through the web container (database + storage) ---"
STATUS_JSON="$(curl -s -m 10 http://127.0.0.1:8080/api/status)"
node -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]), null, 2))' "$STATUS_JSON" 2>/dev/null || echo "$STATUS_JSON"
if ! grep -q '"status":"ok"' <<<"$STATUS_JSON"; then
  echo "WARNING: a check failed (see 'detail' above)." >&2
  exit 1
fi
echo
echo ">>> Containers are running on 127.0.0.1:8080. Next: 03-switch-nginx.sh to send visitors to them. <<<"
echo ">>> (Until then the website shows 'healing...' because the old app is stopped.)               <<<"
