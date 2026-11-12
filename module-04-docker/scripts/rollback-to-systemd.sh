#!/usr/bin/env bash
# =============================================================================
# rollback-to-systemd.sh  —  Module 04 safety net
#
# Puts the server back exactly as it was at the end of Module 03:
# stops the containers, restarts the systemd service, restores the Module 03
# Nginx config. Game data is in DynamoDB, so nothing is lost either way.
#
# Usage:  sudo ./rollback-to-systemd.sh <domain>
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi
DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || { echo "Usage: sudo $0 <domain>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "==> [1/3] Stopping the containers (data is kept)..."
if command -v arena >/dev/null; then arena down || true; fi

echo "==> [2/3] Starting the Module 03 systemd service..."
systemctl enable --now chaos-arena
sleep 3
curl -sf -m 3 http://127.0.0.1:3000/api/health >/dev/null && echo "    App is back on 127.0.0.1:3000."

echo "==> [3/3] Restoring the Module 03 Nginx config..."
"$REPO_DIR/module-03-cloud-services/scripts/03-configure-nginx.sh" "$DOMAIN"

echo
echo "Rolled back to Module 03 (systemd). Run 02-run-containers.sh again to return to Docker."
