#!/usr/bin/env bash
# =============================================================================
# 05-enable-https.sh  —  Module 02, Step 5
#
# Gets a free HTTPS certificate from Let's Encrypt (via certbot) for your
# DuckDNS domain, redirects HTTP -> HTTPS, and checks auto-renewal.
#
# Before running:
#   - your DuckDNS domain must point to this server's Elastic IP
#   - 04-install-nginx.sh must have been run WITH the same domain
#   - port 80 must be open (security group + ufw) so Let's Encrypt can verify you
#
# Usage:    sudo ./05-enable-https.sh <domain> [email]
# Example:  sudo ./05-enable-https.sh my-chaos-arena.duckdns.org
#           (email is optional; it is only used for Let's Encrypt account notices)
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN="${1:-}"
EMAIL="${2:-}"
SITE_CONF="/etc/nginx/sites-available/chaos-arena"

if [[ -z "$DOMAIN" || "$DOMAIN" == "_" ]]; then
  echo "Usage: sudo $0 <domain> [email]" >&2
  exit 1
fi

echo "==> [1/4] Checking that DNS points to this server..."
PUBLIC_IP="$(curl -s --max-time 5 https://checkip.amazonaws.com)"
DNS_IP="$(dig +short "$DOMAIN" A | tail -n 1)"
echo "    This server's public IP : $PUBLIC_IP"
echo "    $DOMAIN resolves to : ${DNS_IP:-<nothing>}"
if [[ "$PUBLIC_IP" != "$DNS_IP" ]]; then
  echo "ERROR: DNS does not point here yet. Update the IP on duckdns.org," >&2
  echo "       wait a minute, and try again." >&2
  exit 1
fi

if ! grep -q "server_name $DOMAIN;" "$SITE_CONF"; then
  echo "ERROR: Nginx isn't configured for $DOMAIN yet." >&2
  echo "       Run first:  sudo ./04-install-nginx.sh $DOMAIN" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "==> [2/4] Installing certbot..."
apt-get install -y certbot python3-certbot-nginx

echo "==> [3/4] Requesting the certificate..."
if [[ -n "$EMAIL" ]]; then
  EMAIL_ARGS=(-m "$EMAIL")
else
  EMAIL_ARGS=(--register-unsafely-without-email)
fi
# --nginx    : certbot edits the Nginx config for us
# --redirect : send every http:// visitor to https://
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect "${EMAIL_ARGS[@]}"

echo "==> [4/4] Testing automatic renewal (certificates last 90 days)..."
certbot renew --dry-run

echo
echo "================ Step 5 complete ================"
systemctl list-timers --no-pager | grep -i certbot || true
echo
echo "--- HTTPS test ---"
curl -sI "https://$DOMAIN" | head -n 1
curl -sI "http://$DOMAIN"  | grep -i '^location' || true
echo
echo ">>> Open https://$DOMAIN in your browser and look for the padlock. <<<"
