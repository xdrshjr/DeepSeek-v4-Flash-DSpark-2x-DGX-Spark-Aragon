#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"
# shellcheck disable=SC1091
source "$OPS_DIR/lib.sh"

SERVICE_NAME="deepseek-v4-flash.service"
FORCE_RESTART=0

usage() {
  cat <<EOF
Usage: sudo ./ops/start.sh [--force-restart]

Start the deployed two-node DeepSeek V4 Flash LLM service and wait until its
authenticated public API is healthy. A healthy running service is left intact.

Options:
  --force-restart  Restart the service even when it is already healthy.
  -h, --help       Show this help message.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-restart)
      FORCE_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  sudo_args=()
  if [ "$FORCE_RESTART" = "1" ]; then
    sudo_args+=(--force-restart)
  fi
  exec sudo -- "$0" "${sudo_args[@]}"
fi

as_head() {
  runuser -u "$HEAD_USER" -- env HOME="/home/$HEAD_USER" "$@"
}

diagnose() {
  echo >&2
  echo "===== DeepSeek service diagnostics =====" >&2
  systemctl --no-pager --full status "$SERVICE_NAME" nginx >&2 || true
  journalctl -u "$SERVICE_NAME" -n 120 --no-pager >&2 || true
  as_head bash -c 'cd "$1" && ./status-deepseek-v4-flash-dspark.sh' bash \
    "$HEAD_PROJECT_DIR" >&2 || true
}

dspark_require_secure_env_file "$HEAD_PROJECT_DIR/.env.dspark" "$HEAD_USER"
if ! systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "$SERVICE_NAME is not installed. Run: sudo ./ops/install.sh" >&2
  exit 1
fi

echo "Ensuring the Nginx API gateway is running..."
if ! systemctl start nginx; then
  diagnose
  exit 1
fi

if [ "$FORCE_RESTART" = "0" ] \
  && systemctl is-active --quiet "$SERVICE_NAME" \
  && curl -fsS --max-time 5 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null; then
  echo "DeepSeek V4 Flash is already running; leaving the healthy service intact."
else
  action=start
  if [ "$FORCE_RESTART" = "1" ] || systemctl is-active --quiet "$SERVICE_NAME"; then
    action=restart
  fi

  echo "Running: systemctl $action $SERVICE_NAME"
  if ! systemctl "$action" "$SERVICE_NAME"; then
    diagnose
    exit 1
  fi
fi

echo "Verifying the authenticated two-node API..."
if ! as_head "$OPS_DIR/healthcheck.sh"; then
  diagnose
  exit 1
fi

echo "DeepSeek V4 Flash LLM service is ready."
echo "OpenAI-compatible endpoint: http://${HEAD_MGMT_IP}:${PUBLIC_PORT}/v1"
