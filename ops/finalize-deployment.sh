#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

as_head() {
  runuser -u "$HEAD_USER" -- env HOME="/home/$HEAD_USER" "$@"
}

as_head "$OPS_DIR/sync-worker.sh"
as_head bash -c 'cd "$1" && ./validate-dspark-config.sh' bash "$HEAD_PROJECT_DIR"
systemctl start deepseek-v4-flash.service
as_head "$OPS_DIR/healthcheck.sh"
echo "Two-node DeepSeek V4 Flash deployment finalized successfully."
