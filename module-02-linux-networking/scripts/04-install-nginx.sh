#!/usr/bin/env bash
# =============================================================================
# 04-install-nginx.sh  —  Module 02, Step 4
#
# Deploys a service: installs the Nginx web server and publishes the
# Chaos Arena teaser page from /srv/chaos-arena/site.
# Also adds a /health endpoint that monitoring will use in Module 05.
#
# Usage:    sudo ./04-install-nginx.sh [domain]
# Example:  sudo ./04-install-nginx.sh my-chaos-arena.duckdns.org
#           (no domain yet? leave it out and the site answers on the IP address;
#            re-run with the domain once DuckDNS is set up)
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN="${1:-_}"    # "_" means "any hostname" in Nginx
if [[ ! "$DOMAIN" =~ ^(_|[A-Za-z0-9.-]+)$ ]]; then
  echo "ERROR: '$DOMAIN' doesn't look like a valid domain name." >&2
  exit 1
fi

# Find this repo's files no matter which folder the script is run from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="/srv/chaos-arena"
SITE_CONF="/etc/nginx/sites-available/chaos-arena"

if ! id deployer &>/dev/null; then
  echo "ERROR: user 'deployer' not found. Run 02-users-and-permissions.sh first." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "==> [1/4] Installing Nginx..."
apt-get install -y nginx

echo "==> [2/4] Publishing the teaser page to $APP_DIR/site..."
DEPLOYED_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"
sed "s|__DEPLOYED_AT__|$DEPLOYED_AT|g" "$MODULE_DIR/site/index.html" > "$APP_DIR/site/index.html"
chown deployer:arena "$APP_DIR/site/index.html"
chmod 664 "$APP_DIR/site/index.html"   # owner+group can edit, nginx (others) can read

echo "==> [3/4] Writing Nginx config for '$DOMAIN'..."
# Hide the Nginx version on EVERY response, including error pages and the
# extra port-80 block certbot creates in step 5 (not just our own site block).
echo "server_tokens off;" > /etc/nginx/conf.d/chaos-arena-hardening.conf

if grep -q "managed by Certbot" "$SITE_CONF" 2>/dev/null && [[ "${FORCE:-0}" != "1" ]]; then
  # HTTPS was already added by 05-enable-https.sh. Overwriting the site config
  # would remove it, so keep it (the page above was still updated).
  echo "    HTTPS is already set up in $SITE_CONF, keeping it."
  echo "    (To rebuild it anyway: sudo FORCE=1 $0 $DOMAIN, then re-run 05-enable-https.sh)"
else
  sed "s|__DOMAIN__|$DOMAIN|g" "$MODULE_DIR/nginx/chaos-arena.conf" > "$SITE_CONF"
fi
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/chaos-arena   # "enable" the site
rm -f /etc/nginx/sites-enabled/default                     # remove the Nginx demo page

echo "==> [4/4] Testing config and (re)starting Nginx..."
nginx -t                           # always test before reloading!
systemctl enable nginx             # start automatically on boot
systemctl reload-or-restart nginx

echo
echo "================ Step 4 complete ================"
systemctl --no-pager --lines=0 status nginx
echo
echo "--- Local test: /health ---"
curl -s http://localhost/health
echo "--- Local test: homepage headers ---"
curl -sI http://localhost | head -n 5
echo
PUBLIC_IP="$(curl -s --max-time 5 https://checkip.amazonaws.com || echo '<your-elastic-ip>')"
echo ">>> Open http://$PUBLIC_IP in your browser to see the page. <<<"
