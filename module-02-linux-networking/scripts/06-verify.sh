#!/usr/bin/env bash
# =============================================================================
# 06-verify.sh  —  Module 02, Step 6
#
# Tests connectivity and prints a full "evidence report" of everything set up
# in Steps 1-5. Save the output into the repo as proof of your work.
#
# Usage:    sudo ./06-verify.sh [domain] | tee ../evidence/verify-output.txt
# Example:  sudo ./06-verify.sh my-chaos-arena.duckdns.org | tee ../evidence/verify-output.txt
# =============================================================================
set -u   # no "set -e": we want the report to continue even if one check fails

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

DOMAIN="${1:-}"

section() { echo; echo "=================== $1 ==================="; }
run()     { echo "\$ $*"; bash -c "$*" 2>&1; echo; }

echo "Chaos Arena — Module 02 verification report"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "1. SYSTEM"
run "hostnamectl --static"
run "lsb_release -ds"
run "uptime -p"
run "timedatectl | grep 'Time zone'"
run "free -h"
run "df -h /"

section "2. USERS, GROUPS & PERMISSIONS"
run "id ubuntu"
run "id deployer"
run "getent group arena"
run "ls -ld /srv/chaos-arena /srv/chaos-arena/*"
run "ls -la /home/deployer/.ssh"
run "sudo -l -U deployer | tail -n 1"

section "3. PROCESSES & SERVICES"
run "systemctl is-active ssh nginx fail2ban"
run "systemctl is-enabled nginx fail2ban"
run "ps -eo pid,user,%cpu,%mem,comm --sort=-%mem | head -n 8"

section "4. SSH HARDENING"
run "sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|allowusers) '"

section "5. FIREWALL (UFW) & FAIL2BAN"
run "ufw status verbose"
run "fail2ban-client status sshd"

section "6. NETWORK: IP ADDRESSES & ROUTES"
run "ip -4 -brief address"
run "ip route show default"
run "echo \"Public IP: \$(curl -s --max-time 5 https://checkip.amazonaws.com)\""
run "resolvectl dns"

section "7. LISTENING PORTS"
run "ss -tulpn | grep LISTEN"

section "8. HTTP TESTS (from the server itself)"
if [[ -n "$DOMAIN" ]]; then
  # --resolve sends the request to this server (127.0.0.1) while still using
  # the real domain name, so Nginx picks the right site and certificate.
  run "curl -s --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/health"
  run "curl -sI --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN | grep -Ei '^(HTTP|server)'"
else
  run "curl -s http://localhost/health"
  run "curl -sI http://localhost | grep -Ei '^(HTTP|server)'"
fi

if [[ -n "$DOMAIN" ]]; then
  section "9. DNS & HTTPS TESTS for $DOMAIN"
  run "dig +short $DOMAIN A"
  run "curl -sI http://$DOMAIN | grep -Ei '^(HTTP|location)'"
  run "curl -sI https://$DOMAIN | head -n 1"
  run "curl -s https://$DOMAIN/health"
  run "echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -issuer -subject -dates"
  run "systemctl list-timers --no-pager | grep -i certbot"
else
  section "9. DNS & HTTPS TESTS"
  echo "(skipped — run again with your domain: sudo $0 your-name.duckdns.org)"
fi

echo
echo "=================== END OF REPORT ==================="
