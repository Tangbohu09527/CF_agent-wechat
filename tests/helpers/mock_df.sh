#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_DOCKER_STATE_DIR:?}"

state_get() {
  local name="$1"
  local default_value="$2"

  if [ -f "${MOCK_DOCKER_STATE_DIR}/${name}" ]; then
    cat -- "${MOCK_DOCKER_STATE_DIR}/${name}"
  else
    printf '%s' "$default_value"
  fi
}

if [ "$(state_get df_fail 0)" = 1 ]; then
  exit 1
fi

df_sleep="$(state_get df_sleep 0)"
if [ "$df_sleep" != 0 ]; then
  exec sleep "$df_sleep"
fi

case "${1:-}" in
  -Pk)
    capacity_probe_count="$(state_get df_capacity_probe_count 0)"
    capacity_probe_count=$((capacity_probe_count + 1))
    printf '%s\n' "$capacity_probe_count" > \
      "${MOCK_DOCKER_STATE_DIR}/df_capacity_probe_count"
    total="$(state_get df_total_blocks 1048576)"
    available="$(state_get df_available_blocks 524288)"
    if [ "$capacity_probe_count" -gt 1 ] &&
      [ -f "${MOCK_DOCKER_STATE_DIR}/df_available_blocks_after_first" ]; then
      available="$(state_get df_available_blocks_after_first 0)"
    fi
    used=$((total - available))
    printf '%s\n' \
      'Filesystem 1024-blocks Used Available Capacity Mounted on' \
      "fixture $total $used $available 50% /fixture"
    ;;
  -Pi)
    capacity_probe_count="$(state_get df_capacity_probe_count 0)"
    total="$(state_get df_total_inodes 1000000)"
    available="$(state_get df_available_inodes 900000)"
    if [ "$capacity_probe_count" -gt 1 ] &&
      [ -f "${MOCK_DOCKER_STATE_DIR}/df_available_inodes_after_first" ]; then
      available="$(state_get df_available_inodes_after_first 0)"
    fi
    used=$((total - available))
    printf '%s\n' \
      'Filesystem Inodes IUsed IFree IUse% Mounted on' \
      "fixture $total $used $available 10% /fixture"
    ;;
  *)
    exit 2
    ;;
esac
