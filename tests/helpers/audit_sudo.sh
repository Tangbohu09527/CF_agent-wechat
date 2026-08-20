#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_SUDO:?}"

sudo_arguments=("$@")
if [ "${sudo_arguments[0]:-}" = "--" ]; then
  sudo_arguments=("${sudo_arguments[@]:1}")
fi

docker_subcommand=""
docker_arguments=()
python_or_pip=0
token_reader=0
for argument_index in "${!sudo_arguments[@]}"; do
  argument="${sudo_arguments[$argument_index]}"
  case "$argument" in
    docker|*/docker)
      docker_offset=$((argument_index + 1))
      docker_arguments=("${sudo_arguments[@]:docker_offset}")
      docker_subcommand="${docker_arguments[0]:-}"
      break
      ;;
  esac
done

for argument in "${sudo_arguments[@]}"; do
  case "$argument" in
    cf-agent-wechat-token-reader) token_reader=1 ;;
    python|python[0-9]*|*/python|*/python[0-9]*|pip|pip[0-9]*|*/pip|*/pip[0-9]*)
      python_or_pip=1
      ;;
  esac
done

if [ "$python_or_pip" -eq 1 ]; then
  kind="python-pip"
elif [ "$token_reader" -eq 1 ]; then
  kind="token-reader"
elif [ -n "$docker_subcommand" ]; then
  case "$docker_subcommand" in
    info|compose|exec|inspect) kind="docker-$docker_subcommand" ;;
    *) kind="docker-other" ;;
  esac
else
  kind="other"
fi
printf 'sudo\t%s\n' "$kind" >> "$CF_AUDIT_LOG"

if [ "$kind" = "python-pip" ]; then
  exit 97
fi
if [ "${CF_AUDIT_DOCKER_RUNTIME_MOCK:-0}" = "1" ] &&
  [ -n "$docker_subcommand" ]; then
  exec env CF_AUDIT_DOCKER_VIA_SUDO=1 "${sudo_arguments[@]}"
fi
exec "$CF_AUDIT_REAL_SUDO" "$@"
