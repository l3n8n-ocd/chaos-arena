#!/usr/bin/env bash
# =============================================================================
# 03-harden-ssh-and-firewall.sh  —  Module 02, Step 3
#
# Secures access to the server:
#   1. SSH hardening  : no root login, no passwords, keys only, fewer retries
#   2. UFW firewall   : block everything incoming except SSH, HTTP, HTTPS
#   3. fail2ban       : temporarily bans IPs that keep failing SSH logins
#
# !! IMPORTANT !!
#   Keep your current SSH window OPEN while running this.
#   Afterwards, open a SECOND terminal and confirm you can still log in
#   before closing the first one. If something is wrong, fix it from the
#   first window.
#
# Usage:  sudo ./03-harden-ssh-and-firewall.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SSHD_DROPIN="/etc/ssh/sshd_config.d/01-chaos-arena-hardening.conf"

echo "==> [1/3] Hardening SSH..."
# Ubuntu reads every file in /etc/ssh/sshd_config.d/ in alphabetical order,
# and sshd keeps the FIRST value it sees for each setting.
# Our file starts with "01-" so it wins over AWS's "50-cloud-init.conf".
cat > "$SSHD_DROPIN" <<'EOF'
# Chaos Arena SSH hardening (Module 02)
# Never allow logging in directly as root
PermitRootLogin no
# Passwords can be guessed; keys cannot -> keys only
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
# Disconnect after 3 failed attempts; 30 seconds to finish logging in
MaxAuthTries 3
LoginGraceTime 30
# No remote GUI windows needed
X11Forwarding no
# Only these accounts may log in over SSH
AllowUsers ubuntu deployer
EOF
chmod 644 "$SSHD_DROPIN"

mkdir -p /run/sshd   # sshd's test mode needs this folder
if ! sshd -t; then
  echo "ERROR: SSH config test failed. Removing the new file so nothing breaks." >&2
  rm -f "$SSHD_DROPIN"
  exit 1
fi
systemctl restart ssh
echo "    SSH restarted with the hardened config."

echo "==> [2/3] Configuring UFW firewall..."
ufw default deny incoming       # block all incoming traffic by default...
ufw default allow outgoing      # ...but let the server reach the internet
ufw limit 22/tcp  comment 'SSH (rate-limited)'   # allow SSH, max 6 tries / 30 s per IP
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable              # --force skips the "are you sure?" prompt

echo "==> [3/3] Installing fail2ban..."
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
# Chaos Arena fail2ban settings (Module 02)
# 5 failed logins within 10 minutes = banned for 1 hour
[sshd]
enabled  = true
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban
sleep 2   # give fail2ban a moment to start

echo
echo "================ Step 3 complete ================"
echo "--- Effective SSH settings ---"
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|allowusers) '
echo
echo "--- Firewall ---"
ufw status verbose
echo
echo "--- fail2ban ---"
fail2ban-client status sshd || echo "(fail2ban still starting, check again with: sudo fail2ban-client status sshd)"
echo
echo ">>> NOW: open a NEW terminal and run 'ssh chaos-arena' to confirm you can still log in. <<<"
