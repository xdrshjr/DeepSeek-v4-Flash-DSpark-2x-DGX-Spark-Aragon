#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

systemctl disable --now deepseek-v4-flash.service 2>/dev/null || true
runuser -u "$HEAD_USER" -- env HOME="/home/$HEAD_USER" \
  bash -c 'cd "$1" && ./stop-deepseek-v4-flash-dspark.sh' bash "$HEAD_PROJECT_DIR" || true
rm -f /etc/systemd/system/deepseek-v4-flash.service
rm -f /etc/nginx/sites-enabled/deepseek-v4-flash
rm -f /etc/nginx/sites-available/deepseek-v4-flash
systemctl daemon-reload
systemctl reload nginx 2>/dev/null || true

if [ "${PURGE_MODEL:-0}" = "1" ]; then
  echo "PURGE_MODEL=1 requested; model cache removal is intentionally manual:" >&2
  echo "  head:   $HEAD_HF_CACHE" >&2
  echo "  worker: $WORKER_HF_CACHE" >&2
fi
echo "Service and gateway removed; project files, images, and model caches were retained."
