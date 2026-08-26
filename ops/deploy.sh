#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

"$OPS_DIR/install.sh"
"$OPS_DIR/download-model-limited.sh"
"$OPS_DIR/finalize-deployment.sh"
