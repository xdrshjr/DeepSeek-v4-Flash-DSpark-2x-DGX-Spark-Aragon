#!/usr/bin/env bash
set -Eeuo pipefail

OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPS_DIR/config.env"

IFB_DEV=ifb-dspark
RUN_AS="${HEAD_USER}"
RUN_HOME="$(getent passwd "$RUN_AS" | cut -d: -f6)"
IPV6_DISABLE_PATH="/proc/sys/net/ipv6/conf/${HEAD_WAN_IF}/disable_ipv6"
ORIGINAL_IPV6_DISABLE="$(cat "$IPV6_DISABLE_PATH" 2>/dev/null || printf '0')"
IPV6_STATE_FILE=/run/dspark-download-ipv6-original

if [ "${1:-}" = "--cleanup" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" --cleanup
  fi
  tc qdisc del dev "$HEAD_WAN_IF" ingress 2>/dev/null || true
  tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
  ip link del "$IFB_DEV" type ifb 2>/dev/null || true
  if [ -r "$IPV6_STATE_FILE" ] && [ -w "$IPV6_DISABLE_PATH" ]; then
    cat "$IPV6_STATE_FILE" >"$IPV6_DISABLE_PATH"
    rm -f "$IPV6_STATE_FILE"
  fi
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

if tc qdisc show dev "$HEAD_WAN_IF" | grep -Eq ' ingress | clsact '; then
  echo "Refusing to replace an existing ingress/clsact qdisc on $HEAD_WAN_IF." >&2
  echo "Inspect it first, or remove a stale DSpark limiter with: $0 --cleanup" >&2
  exit 1
fi
if ip link show "$IFB_DEV" >/dev/null 2>&1; then
  echo "Dedicated limiter device $IFB_DEV already exists; run $0 --cleanup first." >&2
  exit 1
fi

cleanup() {
  tc qdisc del dev "$HEAD_WAN_IF" ingress 2>/dev/null || true
  tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
  ip link del "$IFB_DEV" type ifb 2>/dev/null || true
  if [ -r "$IPV6_STATE_FILE" ] && [ -w "$IPV6_DISABLE_PATH" ]; then
    cat "$IPV6_STATE_FILE" >"$IPV6_DISABLE_PATH"
    rm -f "$IPV6_STATE_FILE"
  fi
}
trap cleanup EXIT INT TERM

# GHCR's IPv6 CDN path is unusably slow on this management network. Restrict
# only the Wi-Fi egress interface during the bounded download window; cleanup
# restores its exact prior value and the private RoCE IPv4 rails are untouched.
if [ -w "$IPV6_DISABLE_PATH" ]; then
  printf '%s' "$ORIGINAL_IPV6_DISABLE" >"$IPV6_STATE_FILE"
  printf '1' >"$IPV6_DISABLE_PATH"
fi
modprobe ifb
ip link add "$IFB_DEV" type ifb
ip link set dev "$IFB_DEV" up
tc qdisc add dev "$HEAD_WAN_IF" handle ffff: ingress
tc filter add dev "$HEAD_WAN_IF" parent ffff: protocol all u32 \
  match u32 0 0 action mirred egress redirect dev "$IFB_DEV"
tc qdisc add dev "$IFB_DEV" root tbf \
  rate "${MODEL_DOWNLOAD_RATE_MBIT}mbit" burst 1mb latency 250ms

echo "Inbound download cap active on $HEAD_WAN_IF: ${MODEL_DOWNLOAD_RATE_MBIT} Mbit/s ($((MODEL_DOWNLOAD_RATE_MBIT / 8)) MB/s integer display)."
tc -s qdisc show dev "$IFB_DEV"

install -d -o "$RUN_AS" -g "$RUN_AS" "$HEAD_HF_CACHE"
runuser -u "$RUN_AS" -- env \
  HOME="$RUN_HOME" \
  HF_ENDPOINT="$HF_ENDPOINT" \
  HF_DOWNLOAD_WORKERS=1 \
  PREPARE_WORKER=0 \
  PROJECT_DIR="$HEAD_PROJECT_DIR" \
  bash -c '
    set -Eeuo pipefail
    cd "$PROJECT_DIR"
    set -a
    # shellcheck disable=SC1091
    source ./.env.dspark
    set +a
    docker pull "$DSPARK_VLLM_IMAGE"
    PREPARE_WORKER=0 HF_ENDPOINT="$HF_ENDPOINT" HF_DOWNLOAD_WORKERS=1 \
      ./prepare-dspark-model-cache.sh --yes
  '

chown -R "$RUN_AS:$RUN_AS" "$HEAD_HF_CACHE"
echo "Image and model cache prepared successfully on the head node."
