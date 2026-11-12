#!/usr/bin/env bash
# =============================================================================
# 03-switch-nginx.sh  —  Module 04, Step 3
#
# Points the host Nginx at the containers: every request now goes to the web
# container on 127.0.0.1:8080. HTTPS, the redirect and the request quota stay
# on the host. If the new config is broken, the old one is restored.
#
# Usage:    sudo ./03-switch-nginx.sh <domain>
# Example:  sudo ./03-switch-nginx.sh chaos-arena.duckdns.org
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN="${1:-}"
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "Usage: sudo $0 <domain>     e.g. sudo $0 chaos-arena.duckdns.org" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$MODULE_DIR")"
SITE_CONF="/etc/nginx/sites-available/chaos-arena"
SNIPPET="/etc/nginx/snippets/chaos-arena-proxy.conf"
LIMITS_CONF="/etc/nginx/conf.d/chaos-arena-limits.conf"
BACKUP_DIR="/var/backups/chaos-arena"

[[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || { echo "ERROR: no HTTPS certificate for $DOMAIN." >&2; exit 1; }
curl -sf -m 3 http://127.0.0.1:8080/health >/dev/null || {
  echo "ERROR: the web container is not answering on 127.0.0.1:8080. Run 02-run-containers.sh first." >&2
  exit 1
}

echo "==> [1/4] Backing up the current Nginx config..."
install -d -m 700 "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/nginx-chaos-arena.$(date +%Y%m%d-%H%M%S).conf"
cp -a "$SITE_CONF" "$BACKUP"
echo "    Saved to $BACKUP"

echo "==> [2/4] Refreshing the fallback copy of the web page..."
# Served by the host only if the whole web container is down.
install -d -o deployer -g arena -m 2775 /srv/chaos-arena/app/public
rsync -a --delete "$REPO_DIR/app/public/" /srv/chaos-arena/app/public/
chown -R deployer:arena /srv/chaos-arena/app/public

echo "==> [3/4] Writing the new config for $DOMAIN..."
install -d -m 755 /etc/nginx/snippets
install -m 644 "$MODULE_DIR/nginx/chaos-arena-proxy.conf" "$SNIPPET"
if [[ ! -f "$LIMITS_CONF" ]]; then
  printf '%s\n' '# Chaos Arena request quota: 100 requests/second per IP address.' \
    'limit_req_zone $binary_remote_addr zone=arena_api:10m rate=100r/s;' \
    'limit_req_status 429;' > "$LIMITS_CONF"
fi
sed "s|__DOMAIN__|$DOMAIN|g" "$MODULE_DIR/nginx/chaos-arena.conf" > "$SITE_CONF"

echo "==> [4/4] Testing and reloading Nginx..."
if ! nginx -t; then
  echo "ERROR: the new config is invalid. Restoring the previous one." >&2
  cp -a "$BACKUP" "$SITE_CONF"
  nginx -t && systemctl reload nginx
  exit 1
fi
systemctl reload nginx
sleep 1   # the reload finishes in the background; give the new workers a moment

echo
echo "================ Step 3 complete ================"
R=(--resolve "$DOMAIN:443:127.0.0.1")
echo "--- Host Nginx alive? ---";         curl -s "${R[@]}" "https://$DOMAIN/health"
echo "--- Game API (via containers) ---"; curl -s "${R[@]}" "https://$DOMAIN/api/health"; echo
echo "--- Web page headers ---"
curl -sI "${R[@]}" "https://$DOMAIN/" | grep -Ei '^(HTTP|server|content-security-policy|strict-transport|x-frame)'
echo
echo ">>> Open https://$DOMAIN : the game now runs in Docker containers. <<<"
