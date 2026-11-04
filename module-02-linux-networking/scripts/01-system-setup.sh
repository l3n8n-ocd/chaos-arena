#!/usr/bin/env bash
# =============================================================================
# 01-system-setup.sh  —  Module 02, Step 1
#
# Prepares a fresh Ubuntu 24.04 EC2 server:
#   1. updates every installed package
#   2. installs everyday command-line tools
#   3. sets the hostname ("chaos-arena") and the timezone
#   4. adds a 2 GB swap file (t3.micro has only 1 GB RAM; Docker needs more later)
#
# Usage:    sudo ./01-system-setup.sh [timezone]
# Example:  sudo ./01-system-setup.sh Asia/Manila
#           (list all timezones with:  timedatectl list-timezones)
# =============================================================================
set -euo pipefail   # stop on any error, on unset variables, and on failed pipes

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0 $*" >&2
  exit 1
fi

TIMEZONE="${1:-UTC}"
NEW_HOSTNAME="chaos-arena"
SWAP_SIZE="2G"

# Make apt fully non-interactive (no pop-up questions in the middle of upgrades)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "==> [1/4] Updating package lists and upgrading installed packages..."
apt-get update -y
apt-get upgrade -y

echo "==> [2/4] Installing everyday tools..."
#   curl / wget  -> make HTTP requests from the terminal
#   git          -> clone this repository
#   ufw          -> simple firewall (configured in step 3)
#   htop         -> live, colourful process viewer
#   tree         -> show folders as a tree
#   dnsutils     -> dig / nslookup for DNS testing
apt-get install -y curl wget git ufw htop tree unzip dnsutils ca-certificates

echo "==> [3/4] Setting hostname to '$NEW_HOSTNAME' and timezone to '$TIMEZONE'..."
hostnamectl set-hostname "$NEW_HOSTNAME"
# Stop cloud-init (AWS's first-boot tool) from resetting the hostname on reboot
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
fi
# Let the server resolve its own new name (avoids "sudo: unable to resolve host")
grep -q "127.0.1.1 $NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
timedatectl set-timezone "$TIMEZONE"

echo "==> [4/4] Creating a $SWAP_SIZE swap file..."
if swapon --show | grep -q '/swapfile'; then
  echo "    Swap is already active, skipping."
else
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile        # only root may read it (it can hold copies of memory)
  mkswap /swapfile
  swapon /swapfile
  # Add to /etc/fstab so the swap comes back after a reboot
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo
echo "================ Step 1 complete ================"
echo "Hostname : $(hostnamectl --static)"
timedatectl | grep 'Time zone'
free -h
if [[ -f /var/run/reboot-required ]]; then
  echo
  echo "NOTE: A reboot is recommended (kernel was updated)."
  echo "      Run:  sudo reboot     then wait ~1 minute and SSH back in."
fi
