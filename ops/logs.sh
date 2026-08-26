#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"
cd "$HEAD_PROJECT_DIR"
if [ "${1:-}" = "--follow" ]; then
  exec ./logs-deepseek-v4-flash-dspark.sh -f
fi
exec ./logs-deepseek-v4-flash-dspark.sh
