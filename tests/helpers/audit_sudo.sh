#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_SUDO:?}"

docker_seen=0
docker_inspect=0
python_or_pip=0
token_reader=0
for argument in "$@"; do
  case "$argument" in
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

if [ "$python_or_pip" -eq 1 ]; then
  kind="python-pip"
elif [ "$token_reader" -eq 1 ]; then
  kind="token-reader"
elif [ "$docker_inspect" -eq 1 ]; then
  kind="docker-inspect"
else
  kind="other"
fi
printf 'sudo\t%s\n' "$kind" >> "$CF_AUDIT_LOG"

if [ "$kind" = "python-pip" ]; then
  exit 97
fi
exec "$CF_AUDIT_REAL_SUDO" "$@"
