#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

"$OPS_DIR/install-deps.sh"
test -s "$HEAD_PROJECT_DIR/.env.dspark"

nginx_tmp="$(mktemp)"
service_tmp="$(mktemp)"
trap 'rm -f "$nginx_tmp" "$service_tmp"' EXIT
sed \
  -e "s|@@PUBLIC_PORT@@|$PUBLIC_PORT|g" \
  -e "s|@@VLLM_PORT@@|$VLLM_PORT|g" \
  "$OPS_DIR/templates/nginx-deepseek.conf" >"$nginx_tmp"
install -m 0644 "$nginx_tmp" /etc/nginx/sites-available/deepseek-v4-flash
ln -sfn /etc/nginx/sites-available/deepseek-v4-flash /etc/nginx/sites-enabled/deepseek-v4-flash
if [ -L /etc/nginx/sites-enabled/default ]; then
  unlink /etc/nginx/sites-enabled/default
fi
nginx -t
systemctl enable nginx
# The Debian package starts Nginx during apt installation. reload-or-restart
# is required so a newly installed site is picked up even when it is already
# active; enable --now alone does not reload an existing master process.
systemctl reload-or-restart nginx

sed \
  -e "s|@@HEAD_USER@@|$HEAD_USER|g" \
  -e "s|@@PROJECT_DIR@@|$HEAD_PROJECT_DIR|g" \
  "$OPS_DIR/templates/deepseek-v4-flash.service" >"$service_tmp"
install -m 0644 "$service_tmp" /etc/systemd/system/deepseek-v4-flash.service
systemctl daemon-reload
systemctl enable deepseek-v4-flash.service

echo "Dependencies, Nginx gateway, and boot service are installed."
