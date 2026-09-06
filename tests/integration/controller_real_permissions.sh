#!/usr/bin/env bash
# Disposable Debian 13 amd64 only. Identity, permissions, and sudo are real.
# Static contract uses the authentic fixed Gateway Controller source.
set -euo pipefail

BASELINE_SHA=69f07702b6ee16d8e9700b3a53d5ebbb8ee875f8
REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT=/opt/controller-real-permissions
CONTROLLER=/opt/cf-agent-gateway/deploy/wechat-runtime-control
MANAGER=qrmanager
MODE="${1:---baseline-only}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[ "${CF_CONTROLLER_PERMISSION_DISPOSABLE:-}" = 1 ] && [ -f /.dockerenv ] ||
  fail 'requires an explicitly authorized disposable Docker container'
[ "$(id -u)" = 0 ] || fail 'container setup requires root'
# shellcheck source=/dev/null
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 13 ] || fail 'requires Debian 13'
[ "$(dpkg --print-architecture)" = amd64 ] || fail 'requires amd64'
[ "$MODE" = --baseline-only ] || fail 'unsupported test mode'
for path in "$TEST_ROOT" /opt/cf-agent-gateway /srv/storage/cf-agent-wechat; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "test path is occupied: $path"
done
for tool in curl git python3 sudo runuser useradd visudo; do
  command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"
done

useradd --uid 1101 --user-group --create-home --shell /bin/bash "$MANAGER"
printf '%s ALL=(root) NOPASSWD: ALL\n' "$MANAGER" > /etc/sudoers.d/qr-controller-test
chmod 440 /etc/sudoers.d/qr-controller-test
visudo -cf /etc/sudoers.d/qr-controller-test
install -d -o root -g root -m 755 "$TEST_ROOT/baseline"
git -c "safe.directory=$REPO_ROOT" -C "$REPO_ROOT" archive "$BASELINE_SHA" scripts |
  tar -x -C "$TEST_ROOT/baseline"
install -d -o root -g root -m 750 /opt/cf-agent-gateway
install -d -o root -g root -m 755 /opt/cf-agent-gateway/deploy
GATEWAY_SHA=4f13039b86c60bc94340edb5468f0102d62d2dff
CONTROLLER_SHA256=c28d9a97157b7551d91b6ee8e29396fd6b7807670c85b470a0b522f7d4b0c7f6
curl --fail --silent --show-error --location --connect-timeout 20 --max-time 90 \
  "https://raw.githubusercontent.com/Tangbohu09527/CF_agent-gateway/$GATEWAY_SHA/deploy/wechat-runtime-control" \
  --output "$TEST_ROOT/authentic-controller"
printf '%s  %s\n' "$CONTROLLER_SHA256" "$TEST_ROOT/authentic-controller" | sha256sum -c -
install -o root -g root -m 755 "$TEST_ROOT/authentic-controller" "$CONTROLLER"
printf 'gateway_git_commit=%s controller_sha256=%s\n' "$GATEWAY_SHA" "$CONTROLLER_SHA256"

run_manager() {
  runuser -u "$MANAGER" -- env -i HOME="/home/$MANAGER" \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8 "$@"
}

printf 'baseline_git_commit=%s\n' "$BASELINE_SHA"
printf 'candidate_git_commit=%s\n' "$(git -c "safe.directory=$REPO_ROOT" -C "$REPO_ROOT" rev-parse HEAD)"
printf 'distribution=%s architecture=%s\n' "$PRETTY_NAME" "$(dpkg --print-architecture)"
dpkg-query -W bash coreutils python3 sudo
run_manager id
[ "$(run_manager id -u)" = 1101 ] || fail 'manager identity is not real UID 1101'
case " $(run_manager id -Gn) " in
  *' root '*|*' docker '*) fail 'manager belongs to a prohibited group' ;;
esac
[ "$(stat -c '%u:%g:%a' /opt/cf-agent-gateway)" = 0:0:750 ] || fail 'Gateway mode differs'
[ "$(stat -c '%u:%g:%a' /opt/cf-agent-gateway/deploy)" = 0:0:755 ] || fail 'deploy mode differs'
[ "$(stat -c '%u:%g:%a:%h' "$CONTROLLER")" = 0:0:755:1 ] || fail 'Controller metadata differs'
if run_manager test -f "$CONTROLLER" || run_manager test -x "$CONTROLLER"; then
  fail 'ordinary-user direct Controller inspection unexpectedly succeeded'
fi
pass 'ordinary manager cannot inspect Controller through root:root 0750 Gateway'

OUTPUT="$TEST_ROOT/baseline.out"
if run_manager /bin/bash -c '
  source "$1/scripts/common.sh"
  source "$1/scripts/qr-runtime-common.sh"
  if gateway_validate_runtime_contract; then exit 0; fi
  printf "%s\n" "$LAST_ERROR" >&2
  exit 1
' baseline "$TEST_ROOT/baseline" > "$OUTPUT" 2>&1; then
  fail 'unmodified baseline unexpectedly accepted inaccessible Controller'
fi
grep -Fq 'Gateway Runtime Contract controller is unavailable at the fixed path.' "$OUTPUT" ||
  fail 'baseline did not reproduce the reported unavailable failure'
[ ! -e /srv/storage/cf-agent-wechat ] || fail 'baseline created deployment state'
cat "$OUTPUT"
pass 'fixed original commit reproduces unavailable before any Controller invocation'

run_manager /usr/bin/sudo -v
run_manager /usr/bin/sudo -n -- test -f "$CONTROLLER"
run_manager /usr/bin/sudo -n -- test -x "$CONTROLLER"
run_manager /usr/bin/sudo -n -- "$CONTROLLER" contract |
  python3 -c 'import json,sys; p=json.load(sys.stdin); assert type(p["contract_version"]) is int and p["contract_version"] == 1'
[ ! -e /opt/cf-agent-gateway/.env ] || fail 'static contract created Gateway configuration'
[ ! -e /srv/storage/cf-agent-wechat ] || fail 'baseline proof created deployment state'
pass 'same real user can inspect file and read authentic Gateway static contract using real sudo'
pass 'baseline evidence complete; no installation, real QR, Hermes, or Gateway readiness claim'
