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

ssh -o BatchMode=yes -o Compression=no "$WORKER_SSH_ALIAS" \
  "mkdir -p '$WORKER_PROJECT_DIR' '$WORKER_HF_CACHE'"

if ssh -o BatchMode=yes "$WORKER_SSH_ALIAS" \
  "docker image inspect '$DSPARK_VLLM_IMAGE' >/dev/null 2>&1"; then
  echo "Worker already has the digest-pinned runtime image; skipping image copy."
else
  echo "Copying the digest-pinned runtime image over the 200G private fabric..."
  docker save "$DSPARK_VLLM_IMAGE" \
    | zstd -T0 -1 \
    | ssh -o BatchMode=yes -o Compression=no "$WORKER_SSH_ALIAS" \
        "zstd -T0 -d | docker load"
  # docker save/load preserves the image content but can omit a RepoDigest
  # association when the source was addressed only by digest. Pulling the
  # manifest now reattaches that immutable reference; all layer blobs already
  # exist locally, so this is metadata-only rather than a duplicate transfer.
  ssh -o BatchMode=yes "$WORKER_SSH_ALIAS" \
    "docker pull '$DSPARK_VLLM_IMAGE' >/dev/null"
fi

echo "Synchronizing the verified Hugging Face cache over the 200G private fabric..."
if [ "${ABLITERATED:-0}" = "1" ]; then
  SELECTED_MODEL="$DSPARK_MODEL_ABLITERATED"
else
  SELECTED_MODEL="$DSPARK_MODEL_OFFICIAL"
fi

sync_model_repo() {
  local repo_id="$1"
  local hub_dir="models--${repo_id//\//--}"
  local source_dir="$HEAD_HF_CACHE/hub/$hub_dir"
  local target_dir="$WORKER_HF_CACHE/hub/$hub_dir"
  test -d "$source_dir" || {
    echo "Missing verified model cache: $source_dir" >&2
    return 1
  }
  ssh -o BatchMode=yes "$WORKER_SSH_ALIAS" "mkdir -p '$target_dir'"
  rsync -aH --partial --info=stats2,progress2 \
    -e 'ssh -o BatchMode=yes -o Compression=no' \
    "$source_dir/" "$WORKER_SSH_ALIAS:$target_dir/"
}

# Do not synchronize the whole HF cache after the service has started. Runtime
# JIT trees (TileLang/Triton/FlashInfer/B12X) are container-created and can be
# root-owned on each node; they are node-local artifacts, not model inputs.
sync_model_repo "$SELECTED_MODEL"
if [ -n "${VL_SIDECAR_MODEL:-}" ] && \
  [ -d "$HEAD_HF_CACHE/hub/models--${VL_SIDECAR_MODEL//\//--}" ]; then
  sync_model_repo "$VL_SIDECAR_MODEL"
fi

ssh -o BatchMode=yes "$WORKER_SSH_ALIAS" \
  "docker image inspect '$DSPARK_VLLM_IMAGE' >/dev/null && test -d '$WORKER_HF_CACHE/hub/models--${SELECTED_MODEL//\//--}'"
echo "Worker image and model cache are ready."
