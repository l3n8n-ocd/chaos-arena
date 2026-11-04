#!/usr/bin/env bash
# =============================================================================
# 02-users-and-permissions.sh  —  Module 02, Step 2
#
# Creates the Linux users, groups and folders Chaos Arena will use:
#   - group  "arena"     : everyone allowed to manage the app files
#   - user   "deployer"  : a low-privilege account for deployments (Module 05)
#                          -> SSH key login only, NO password, NO sudo
#   - folder /srv/chaos-arena : where the website / app will live
#
# Usage:  sudo ./02-users-and-permissions.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

GROUP_NAME="arena"
USER_NAME="deployer"
APP_DIR="/srv/chaos-arena"

echo "==> [1/4] Creating group '$GROUP_NAME'..."
groupadd --force "$GROUP_NAME"     # --force = no error if it already exists

echo "==> [2/4] Creating user '$USER_NAME'..."
if id "$USER_NAME" &>/dev/null; then
  echo "    User '$USER_NAME' already exists, skipping."
else
  useradd --create-home --shell /bin/bash \
          --groups "$GROUP_NAME" \
          --comment "Chaos Arena deploy user" \
          "$USER_NAME"
fi
# '*' = "no password can ever match" -> password login is impossible,
# but SSH key login still works (unlike a fully locked '!' account).
usermod -p '*' "$USER_NAME"
# Also add the default admin user to the group so you can edit app files.
usermod -aG "$GROUP_NAME" ubuntu

echo "==> [3/4] Giving '$USER_NAME' SSH key access..."
# For now deployer trusts the same public key as 'ubuntu'.
# In Module 05 we will add a separate key just for GitHub Actions.
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.ssh"
install -m 600 -o "$USER_NAME" -g "$USER_NAME" \
        /home/ubuntu/.ssh/authorized_keys "/home/$USER_NAME/.ssh/authorized_keys"
#   700 on ~/.ssh           -> only the owner can enter the folder
#   600 on authorized_keys  -> only the owner can read/write the file
#   (SSH refuses to use keys if these permissions are too open)

echo "==> [4/4] Creating app folder $APP_DIR..."
for dir in "$APP_DIR" "$APP_DIR/site" "$APP_DIR/logs"; do
  install -d -o "$USER_NAME" -g "$GROUP_NAME" "$dir"
  chmod 2775 "$dir"
done
#   2775 explained:
#     2   = setgid bit: new files created inside inherit the 'arena' group
#     7   = owner (deployer)      : read + write + enter
#     7   = group (arena)         : read + write + enter
#     5   = others (e.g. nginx)   : read + enter, but NOT write

echo
echo "================ Step 2 complete ================"
echo "--- Users and their groups ---"
id ubuntu
id "$USER_NAME"
echo
echo "--- App folder permissions ---"
ls -ld "$APP_DIR" "$APP_DIR"/*
echo
echo "--- deployer's SSH folder ---"
ls -la "/home/$USER_NAME/.ssh"
echo
echo "NOTE: 'ubuntu' joins the 'arena' group on your NEXT login (exit and SSH back in)."
