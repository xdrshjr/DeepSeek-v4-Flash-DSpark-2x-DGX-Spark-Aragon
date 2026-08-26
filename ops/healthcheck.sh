#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"
# shellcheck disable=SC1091
source "$OPS_DIR/lib.sh"

ENV_FILE="$HEAD_PROJECT_DIR/.env.dspark"
dspark_require_secure_env_file "$ENV_FILE" "$HEAD_USER"

env_snapshot="$(mktemp)"
cleanup() {
  VLLM_API_KEY=""
  DSPARK_API_KEYS=""
  api_key=""
  key=""
  dspark_keys=()
  rm -f -- "$env_snapshot"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 600 "$env_snapshot"
sed $'1s/^\xEF\xBB\xBF//; s/\r$//' "$ENV_FILE" >"$env_snapshot"

# The checked file is authoritative. Do not inherit ambient credentials and do
# not export credentials from the sourced file to curl, jq, docker, or ssh.
unset VLLM_API_KEY DSPARK_API_KEYS
# shellcheck disable=SC1090
source "$env_snapshot"
export -n VLLM_API_KEY DSPARK_API_KEYS 2>/dev/null || true

case "${VLLM_API_KEY:-}${DSPARK_API_KEYS:-}" in
  *[$'\r\n\v\f']*)
    echo "API keys must be single-line values." >&2
    exit 2
    ;;
esac

dspark_keys=()
if [ -n "${DSPARK_API_KEYS:-}" ]; then
  case "$DSPARK_API_KEYS" in
    *\\*)
      echo "DSPARK_API_KEYS must not contain backslashes." >&2
      exit 2
      ;;
  esac
  read -r -a dspark_keys <<<"$DSPARK_API_KEYS"
  for key in "${dspark_keys[@]}"; do
    case "$key" in
      -*) echo "DSPARK_API_KEYS contains a token beginning with '-'." >&2; exit 2 ;;
    esac
  done
fi

if [ -n "${VLLM_API_KEY:-}" ] && [ "${#dspark_keys[@]}" -gt 0 ]; then
  echo "VLLM_API_KEY and DSPARK_API_KEYS are mutually exclusive." >&2
  exit 2
elif [ -n "${VLLM_API_KEY:-}" ]; then
  api_key="$VLLM_API_KEY"
elif [ "${#dspark_keys[@]}" -gt 0 ]; then
  api_key="${dspark_keys[0]}"
else
  echo "VLLM_API_KEY or DSPARK_API_KEYS is required for the public deployment." >&2
  exit 2
fi

: "${WORKER_HOST:?WORKER_HOST is required in $ENV_FILE}"
: "${SERVED_MODEL_NAME:?SERVED_MODEL_NAME is required in $ENV_FILE}"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
case "$PROJECT_NAME" in
  *[!A-Za-z0-9_.-]*) echo "Unsafe PROJECT_NAME: $PROJECT_NAME" >&2; exit 2 ;;
esac

CURL_CONNECT_TIMEOUT="${HEALTHCHECK_CONNECT_TIMEOUT:-5}"
CURL_CONTROL_TIMEOUT="${HEALTHCHECK_CONTROL_TIMEOUT:-15}"
CURL_INFERENCE_TIMEOUT="${HEALTHCHECK_INFERENCE_TIMEOUT:-120}"

curl_with_bearer() {
  local escaped_key
  escaped_key="${api_key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  printf 'header = "Authorization: Bearer %s"\n' "$escaped_key" \
    | curl -q --config - "$@"
}

echo "Checking the head API and both Compose ranks..."
curl -q -fsS \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_CONTROL_TIMEOUT" \
  "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null

docker ps \
  --filter "label=com.docker.compose.project=$PROJECT_NAME" \
  --filter "label=com.docker.compose.service=vllm-dspark" \
  --format '{{.ID}}' | grep -q .
ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" \
  "docker ps --filter 'label=com.docker.compose.project=$PROJECT_NAME' --filter 'label=com.docker.compose.service=vllm-dspark' --format '{{.ID}}' | grep -q ."

models_url="http://127.0.0.1:${PUBLIC_PORT}/v1/models"
anonymous_status="$(curl -q -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_CONTROL_TIMEOUT" \
  "$models_url")"
case "$anonymous_status" in
  401|403) ;;
  *)
    echo "Public API authentication is not enforced: anonymous /v1/models returned HTTP $anonymous_status." >&2
    exit 1
    ;;
esac

curl_with_bearer -fsS \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_CONTROL_TIMEOUT" \
  "$models_url" \
  | jq -e --arg model "$SERVED_MODEL_NAME" \
      '(.data | type) == "array" and any(.data[]; .id == $model)' >/dev/null

chat_payload="$(jq -nc --arg model "$SERVED_MODEL_NAME" '{
  model: $model,
  messages: [{role: "user", content: "Reply with OK."}],
  max_tokens: 1,
  temperature: 0
}')"
curl_with_bearer -fsS \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_INFERENCE_TIMEOUT" \
  -H 'Content-Type: application/json' \
  --data-binary "$chat_payload" \
  "http://127.0.0.1:${PUBLIC_PORT}/v1/chat/completions" \
  | jq -e '(.choices | type) == "array" and (.choices | length) > 0' >/dev/null

echo "DeepSeek V4 Flash authenticated two-node inference is healthy on port $PUBLIC_PORT."
