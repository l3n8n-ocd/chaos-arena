#!/usr/bin/env bash
# =============================================================================
# 01-install-docker.sh  —  Module 04, Step 1
#
# Installs Docker Engine + the Compose plugin from Docker's official package
# repository, and sets safe defaults for the Docker daemon:
#   - log rotation (container logs can't fill the disk)
#   - live-restore (containers keep running while Docker itself is updated)
#
# Usage:  sudo ./01-install-docker.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "==> [1/3] Docker $(docker --version | cut -d' ' -f3 | tr -d ,) is already installed, skipping."
else
  echo "==> [1/3] Adding Docker's official package repository..."
  apt-get update -y
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  # Docker's signing key: apt refuses packages that aren't signed with it.
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  echo "    Installing Docker Engine, CLI, containerd, Buildx and Compose..."
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

echo "==> [2/3] Configuring the Docker daemon (/etc/docker/daemon.json)..."
install -d -m 755 /etc/docker
NEW_CONFIG='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}'
if [[ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$NEW_CONFIG" ]]; then
  [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  echo "$NEW_CONFIG" > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker containerd >/dev/null 2>&1

echo "==> [3/3] Test: running a tiny container..."
# hello-world from AWS's public registry: proves Docker can download and run images.
docker run --rm public.ecr.aws/docker/library/hello-world:latest | grep -m1 "Hello from Docker"

echo
echo "================ Step 1 complete ================"
docker version --format 'Docker Engine : {{.Server.Version}}'
docker compose version
echo
cat <<'EOF'
NOTE: we do NOT add "ubuntu" to the "docker" group. Anyone who can run docker
commands can easily become root, so every docker command in this module
uses sudo (or the "arena" shortcut installed in step 2, which asks for sudo).
EOF
