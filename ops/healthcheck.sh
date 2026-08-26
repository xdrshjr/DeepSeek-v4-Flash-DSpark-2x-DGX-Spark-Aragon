#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"
cd "$HEAD_PROJECT_DIR"
set -a
# shellcheck disable=SC1091
source ./.env.dspark
set +a

curl -fsS "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null
curl -fsS \
  -H "Authorization: Bearer ${VLLM_API_KEY:?VLLM_API_KEY is required}" \
  "http://127.0.0.1:${PUBLIC_PORT}/v1/models" \
  | jq -e --arg model "$SERVED_MODEL_NAME" '.data[] | select(.id == $model)' >/dev/null
echo "DeepSeek V4 Flash API is healthy on port $PUBLIC_PORT."
