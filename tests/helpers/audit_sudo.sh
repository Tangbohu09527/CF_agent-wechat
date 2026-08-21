#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_SUDO:?}"
: "${CF_AUDIT_REAL_DOCKER:?}"

docker_seen=0
docker_inspect=0
python_or_pip=0
token_reader=0
sudo_validate=0
noninteractive=0
docker_host=default
expect_docker_host=0
sudo_arguments=("$@")
for argument in "$@"; do
  if [ "$expect_docker_host" -eq 1 ]; then docker_host="$argument"; expect_docker_host=0; fi
  case "$argument" in
    -v) sudo_validate=1 ;;
    -n) noninteractive=1 ;;
    --host) expect_docker_host=1 ;;
    docker) docker_seen=1 ;;
    inspect)
      if [ "$docker_seen" -eq 1 ]; then
        docker_inspect=1
      fi
      ;;
    cf-agent-wechat-token-reader) token_reader=1 ;;
    python|python[0-9]*|*/python|*/python[0-9]*|pip|pip[0-9]*|*/pip|*/pip[0-9]*)
      python_or_pip=1
      ;;
  esac
done

if [ "$sudo_validate" -eq 1 ]; then
  kind="authorization"
elif [ "$python_or_pip" -eq 1 ]; then
  kind="python-pip"
elif [ "$token_reader" -eq 1 ]; then
  kind="token-reader"
elif [ "$docker_inspect" -eq 1 ]; then
  kind="docker-inspect"
else
  kind="other"
fi
printf 'sudo\t%s\thost=%s\tnoninteractive=%s\n' "$kind" "$docker_host" "$noninteractive" >> "$CF_AUDIT_LOG"

if [ "$kind" = "python-pip" ]; then
  exit 97
fi
if [ "$kind" = "docker-inspect" ] &&
  [ "${CF_AUDIT_SUDO_MODE:-}" = "hang-docker-inspect" ]; then
  if [ -n "${CF_AUDIT_SUDO_HANG_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$CF_AUDIT_SUDO_HANG_PID_FILE"
  fi
  trap '' TERM
  while :; do
    sleep 1
  done
fi
if [ "$docker_inspect" -eq 1 ]; then
  for argument_index in "${!sudo_arguments[@]}"; do
    if [ "${sudo_arguments[$argument_index]}" = docker ]; then
      sudo_arguments[$argument_index]="$CF_AUDIT_REAL_DOCKER"
      break
    fi
  done
fi
exec "$CF_AUDIT_REAL_SUDO" "${sudo_arguments[@]}"
