#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

OPS_DIR="$TEST_DIR/ops"
PROJECT_DIR="$TEST_DIR/project"
MOCK_BIN="$TEST_DIR/bin"
ARGS_LOG="$TEST_DIR/curl-args.log"
CONFIG_LOG="$TEST_DIR/curl-config.log"
mkdir -p "$OPS_DIR" "$PROJECT_DIR" "$MOCK_BIN"
cp "$ROOT_DIR/ops/healthcheck.sh" "$ROOT_DIR/ops/lib.sh" "$OPS_DIR/"

cat >"$OPS_DIR/config.env" <<EOF
HEAD_PROJECT_DIR=$PROJECT_DIR
HEAD_USER=$(id -un)
VLLM_PORT=8888
PUBLIC_PORT=8000
EOF

cat >"$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$MOCK_ARGS_LOG"

read_config=0
previous=""
for argument in "$@"; do
  if [ "$previous" = "--config" ] && [ "$argument" = "-" ]; then
    read_config=1
  fi
  previous="$argument"
done
if [ "$read_config" = "1" ]; then
  config="$(cat)"
  printf '%s\n' "$config" >>"$MOCK_CONFIG_LOG"
fi

if [ -n "${VLLM_API_KEY:-}" ] || [ -n "${DSPARK_API_KEYS:-}" ]; then
  echo "credential leaked through the curl environment" >&2
  exit 90
fi

case " $* " in
  *" %{http_code} "*) printf '%s' "${MOCK_ANON_CODE:-401}" ;;
  *"/health"*) ;;
  *"/v1/models"*) printf '%s\n' '{"data":[{"id":"deepseek-v4-flash-0731"}]}' ;;
  *"/v1/chat/completions"*) printf '%s\n' '{"choices":[{"message":{"content":"OK"}}]}' ;;
  *) echo "unexpected curl call: $*" >&2; exit 91 ;;
esac
EOF

cat >"$MOCK_BIN/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -nc "*) printf '%s\n' '{"model":"deepseek-v4-flash-0731","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":1,"temperature":0}' ;;
  *) input="$(cat)"; [ -n "$input" ] ;;
esac
EOF

cat >"$MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "ps" ] || exit 92
echo fake-container-id
EOF

cat >"$MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN"/*

write_env() {
  local auth_line="$1"
  cat >"$PROJECT_DIR/.env.dspark" <<EOF
WORKER_HOST=worker-test
SERVED_MODEL_NAME=deepseek-v4-flash-0731
$auth_line
EOF
  chmod 600 "$PROJECT_DIR/.env.dspark"
}

run_healthcheck() {
  : >"$ARGS_LOG"
  : >"$CONFIG_LOG"
  env -u VLLM_API_KEY -u DSPARK_API_KEYS \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_ARGS_LOG="$ARGS_LOG" \
    MOCK_CONFIG_LOG="$CONFIG_LOG" \
    MOCK_ANON_CODE="${MOCK_ANON_CODE:-401}" \
    bash "$OPS_DIR/healthcheck.sh"
}

single_key="single-key-not-for-production"
write_env "VLLM_API_KEY=$single_key"
run_healthcheck >/dev/null
grep -Fq "Authorization: Bearer $single_key" "$CONFIG_LOG"
if grep -Fq "$single_key" "$ARGS_LOG"; then
  echo "single API key leaked into curl argv" >&2
  exit 1
fi

first_key="first-multi-key-not-for-production"
second_key="second-multi-key-not-for-production"
write_env "DSPARK_API_KEYS=\"$first_key $second_key\""
run_healthcheck >/dev/null
grep -Fq "Authorization: Bearer $first_key" "$CONFIG_LOG"
if grep -Fq "$first_key" "$ARGS_LOG" || grep -Fq "$second_key" "$CONFIG_LOG"; then
  echo "multi-key health probe did not use only the first key securely" >&2
  exit 1
fi

grep -Fxq -- '--connect-timeout' "$ARGS_LOG"
grep -Fxq -- '--max-time' "$ARGS_LOG"
grep -Fxq -- 'http://127.0.0.1:8000/v1/chat/completions' "$ARGS_LOG"

write_env ""
if run_healthcheck >/dev/null 2>&1; then
  echo "healthcheck accepted a deployment without API credentials" >&2
  exit 1
fi

write_env "VLLM_API_KEY=$single_key"
MOCK_ANON_CODE=200
export MOCK_ANON_CODE
if run_healthcheck >/dev/null 2>&1; then
  echo "healthcheck accepted anonymous API access" >&2
  exit 1
fi
unset MOCK_ANON_CODE

chmod 644 "$PROJECT_DIR/.env.dspark"
if run_healthcheck >/dev/null 2>&1; then
  echo "healthcheck accepted an environment file readable by group/other" >&2
  exit 1
fi

chmod 700 "$PROJECT_DIR/.env.dspark"
if run_healthcheck >/dev/null 2>&1; then
  echo "healthcheck accepted an executable environment file" >&2
  exit 1
fi

echo "ops healthcheck regression tests passed"
