#!/usr/bin/env bash
# =============================================================================
# 03-configure-nginx.sh  —  Module 03, Step 3
#
# Puts the game online: replaces the Module 02 teaser-page config with one that
#   - serves the game's web page from /srv/chaos-arena/app/public
#   - forwards /api/ requests to the Node.js app (a "reverse proxy")
#   - keeps the existing HTTPS certificate from Module 02
#
# If the new config is broken, the old one is restored automatically.
#
# Usage:    sudo ./03-configure-nginx.sh <domain>
# Example:  sudo ./03-configure-nginx.sh chaos-arena.duckdns.org
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
SITE_CONF="/etc/nginx/sites-available/chaos-arena"
LIMITS_CONF="/etc/nginx/conf.d/chaos-arena-limits.conf"
BACKUP_DIR="/var/backups/chaos-arena"
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

[[ -f "$CERT" ]] || {
  echo "ERROR: no HTTPS certificate found for $DOMAIN ($CERT)." >&2
  echo "       Finish Module 02 first (05-enable-https.sh $DOMAIN)." >&2
  exit 1
}
[[ -f /srv/chaos-arena/app/public/index.html ]] || {
  echo "ERROR: the app is not deployed yet. Run 02-deploy-app.sh first." >&2
  exit 1
}

echo "==> [1/3] Backing up the current Nginx config..."
install -d -m 700 "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/nginx-chaos-arena.$(date +%Y%m%d-%H%M%S).conf"
if [[ -f "$SITE_CONF" ]]; then
  cp -a "$SITE_CONF" "$BACKUP"
  echo "    Saved to $BACKUP"
fi

echo "==> [2/3] Writing the new config for $DOMAIN..."
# Request quota for the API. This must live in Nginx's top-level "http" section,
# which is what files in conf.d/ are included into.
cat > "$LIMITS_CONF" <<'EOF'
# Chaos Arena request quota (Module 03): 100 requests/second per IP address.
limit_req_zone $binary_remote_addr zone=arena_api:10m rate=100r/s;
limit_req_status 429;
EOF
sed "s|__DOMAIN__|$DOMAIN|g" "$MODULE_DIR/nginx/chaos-arena.conf" > "$SITE_CONF"
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/chaos-arena
rm -f /etc/nginx/sites-enabled/default

echo "==> [3/3] Testing and reloading Nginx..."
if ! nginx -t; then
  echo "ERROR: the new config is invalid. Restoring the previous one." >&2
  if [[ -f "$BACKUP" ]]; then cp -a "$BACKUP" "$SITE_CONF"; fi
  rm -f "$LIMITS_CONF"
  nginx -t && systemctl reload nginx
  exit 1
fi
systemctl reload nginx

echo
echo "================ Step 3 complete ================"
# --resolve sends the request to this server while still using the real domain name.
R=(--resolve "$DOMAIN:443:127.0.0.1")
echo "--- Web server alive? (/health, answered by Nginx) ---"
curl -s "${R[@]}" "https://$DOMAIN/health"
echo "--- App alive? (/api/health, answered by Node.js through Nginx) ---"
curl -s "${R[@]}" "https://$DOMAIN/api/health"; echo
echo "--- Web page ---"
curl -sI "${R[@]}" "https://$DOMAIN/" | grep -Ei '^(HTTP|server|content-security-policy|strict-transport)'
echo
echo ">>> Open https://$DOMAIN in your browser. The game is live! <<<"
