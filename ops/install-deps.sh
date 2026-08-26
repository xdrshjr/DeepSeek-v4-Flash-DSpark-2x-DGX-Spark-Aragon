#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx rsync zstd iproute2 curl jq
nvidia-ctk runtime configure --runtime=docker
usermod -aG docker "$HEAD_USER"
systemctl daemon-reload
systemctl restart docker
docker info --format '{{json .Runtimes}}' | grep -q 'nvidia'
