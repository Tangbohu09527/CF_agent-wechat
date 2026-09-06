#!/usr/bin/env bash

# Call with the caller's already-authorized privilege and timeout helpers.
# No Controller path is accepted from arguments or the process environment.
gateway_controller_check_file() {
  "$@" /bin/sh -eu -c '
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    controller=/opt/cf-agent-gateway/deploy/wechat-runtime-control

    safe_metadata() {
      metadata=$(stat -c "%u:%g:%a" -- "$1") || return 1
      owner=${metadata%%:*}
      remainder=${metadata#*:}
      group=${remainder%%:*}
      mode=${remainder#*:}
      [ "$owner:$group" = "0:0" ] || return 1
      case "$mode" in ""|*[!0-7]*) return 1 ;; esac
      [ "$((0$mode & 07022))" -eq 0 ]
    }

    for directory in / /opt /opt/cf-agent-gateway /opt/cf-agent-gateway/deploy; do
      [ ! -L "$directory" ] && [ -d "$directory" ] || exit 1
      safe_metadata "$directory" || exit 1
    done
    [ ! -L "$controller" ] && [ -f "$controller" ] && [ -x "$controller" ] || exit 1
    safe_metadata "$controller" || exit 1
    [ "$(stat -c "%h" -- "$controller")" = 1 ]
  '
}
