#!/usr/bin/env bash

dspark_require_secure_env_file() {
  local env_file="$1"
  local expected_owner="$2"
  local actual_owner mode mode_value

  if [ ! -f "$env_file" ] || [ -L "$env_file" ]; then
    echo "Expected a regular, non-symlink environment file: $env_file" >&2
    return 1
  fi

  actual_owner="$(stat -c '%U' -- "$env_file")"
  mode="$(stat -c '%a' -- "$env_file")"
  mode_value=$((8#$mode))

  if [ "$actual_owner" != "$expected_owner" ]; then
    echo "$env_file must be owned by $expected_owner (current owner: $actual_owner)." >&2
    echo "Fix with: sudo chown $expected_owner '$env_file'" >&2
    return 1
  fi
  if (( (mode_value & 0400) == 0 || (mode_value & 0177) != 0 )); then
    echo "$env_file must have mode 400 or 600 (current mode: $mode)." >&2
    echo "Fix with: chmod 600 '$env_file'" >&2
    return 1
  fi
}
