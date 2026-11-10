#!/usr/bin/env bash
# =============================================================================
# 01-install-node.sh  —  Module 03, Step 1
#
# Installs Node.js 22 (LTS) from the official NodeSource package repository.
# (Ubuntu's own "nodejs" package is too old for the AWS SDK.)
#
# Usage:  sudo ./01-install-node.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

NODE_MAJOR=22
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

current_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }

if [[ "$(current_major)" == "$NODE_MAJOR" ]]; then
  echo "==> Node.js $(node -v) is already installed, skipping."
else
  echo "==> [1/2] Adding the NodeSource repository for Node.js $NODE_MAJOR..."
  # Download the setup script to a file first (so we never pipe the internet
  # straight into a root shell), then run it.
  SETUP_SCRIPT="$(mktemp)"
  trap 'rm -f "$SETUP_SCRIPT"' EXIT
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$SETUP_SCRIPT"
  bash "$SETUP_SCRIPT"

  echo "==> [2/2] Installing Node.js..."
  apt-get install -y nodejs
fi

# rsync copies the app into place; openssl generates the admin secret.
apt-get install -y rsync openssl >/dev/null

echo
echo "================ Step 1 complete ================"
echo "node : $(node -v)   ($(command -v node))"
echo "npm  : $(npm -v)"
