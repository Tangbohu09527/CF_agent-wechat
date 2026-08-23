#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_SUDO:?}"

sudo_arguments=("$@")

docker_subcommand=""
docker_arguments=()
python_or_pip=0
approved_management_python=0
token_reader=0
validation=0
noninteractive=0
for argument_index in "${!sudo_arguments[@]}"; do
  argument="${sudo_arguments[$argument_index]}"
  case "$argument" in
    -v) validation=1 ;;
    -n) noninteractive=1 ;;
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
  for argument in "${sudo_arguments[@]}"; do
    case "$argument" in
      */parse_management_env.py|*/verify_management_source_secrets.py|gateway-verifier-snapshot|*'base64.b64encode(b"".join(chunks))'*)
        approved_management_python=1
        ;;
    esac
  done
fi

if [ "$validation" -eq 1 ]; then
  kind="validate"
elif [ "$python_or_pip" -eq 1 ] &&
  [ "$approved_management_python" -eq 1 ]; then
  kind="management-python"
elif [ "$python_or_pip" -eq 1 ]; then
  kind="python-pip"
elif [ "$token_reader" -eq 1 ]; then
  kind="token-reader"
elif [ -n "$docker_subcommand" ]; then
  case "$docker_subcommand" in
    context|info|compose|exec|inspect) kind="docker-$docker_subcommand" ;;
    *) kind="docker-other" ;;
  esac
else
  kind="other"
fi
if [ "$noninteractive" -eq 1 ]; then
  mode="noninteractive"
else
  mode="interactive"
fi
printf 'sudo\t%s\t%s\n' "$kind" "$mode" >> "$CF_AUDIT_LOG"

if [ "$kind" = "python-pip" ]; then
  exit 97
fi
if [ "$kind" != "validate" ] && [ "$noninteractive" -ne 1 ]; then
  printf '%s\n' 'operational sudo must use -n after sudo -v' >&2
  exit 96
fi
if [ "${CF_AUDIT_DOCKER_RUNTIME_MOCK:-0}" = "1" ] &&
  [ -n "$docker_subcommand" ]; then
  mock_arguments=("${sudo_arguments[@]}")
  while [ "${#mock_arguments[@]}" -gt 0 ]; do
    case "${mock_arguments[0]}" in
      -n|-v) mock_arguments=("${mock_arguments[@]:1}") ;;
      --)
        mock_arguments=("${mock_arguments[@]:1}")
        break
        ;;
      *) break ;;
    esac
  done
  exec env CF_AUDIT_DOCKER_VIA_SUDO=1 "${mock_arguments[@]}"
fi
exec "$CF_AUDIT_REAL_SUDO" "$@"
