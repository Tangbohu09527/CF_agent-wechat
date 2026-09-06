#!/usr/bin/env bash
# Run only inside the workflow's fresh privileged Debian container. No host socket.
set -Eeuo pipefail
set +x
umask 022
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SOURCE_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
INSTALLER="$SOURCE_ROOT/scripts/prepare-clean-host.sh"
INSTALL_ROOT=/opt/cf-agent-wechat
MANAGER=deploycheck
MANAGER_HOME=/home/deploycheck
EVIDENCE=/evidence
COMMIT="${CF_CLEAN_HOST_COMMIT:-}"
IMAGE=ghcr.io/thisnick/agent-wechat@sha256:b5e92047e28ce67e34576e574d8ccf00f8619f485597109f7342a137300285c0
EXPECTED_IMAGE_ID=sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720
DAEMON_PID=
CURRENT_STAGE=preconditions

fail() { printf 'FAIL stage=%s: %s\n' "$CURRENT_STAGE" "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID"
    # The outer disposable container owns remaining daemon cleanup.
  fi
  if [ "$result" -ne 0 ]; then
    printf 'FAIL stage=%s exit=%s; no complete-host acceptance claimed\n' "$CURRENT_STAGE" "$result" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'fail "command failed at line $LINENO"' ERR

[ "${CF_CLEAN_HOST_DISPOSABLE:-}" = 1 ] || fail "explicit disposable-container opt-in required"
[ -f /.dockerenv ] && [ "$(id -u)" = 0 ] || fail "fresh root Docker container required"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "the reviewed full GitHub commit is required"
[ ! -S /var/run/docker.sock ] || fail "Docker socket already exists; host sockets are forbidden"
[ ! -e "$INSTALL_ROOT" ] && [ ! -e /opt/cf-agent-gateway ] || fail "deployment already exists"
[ ! -e /srv/storage/cf-agent-wechat ] || fail "WeChat storage already exists"
! id "$MANAGER" >/dev/null 2>&1 || fail "manager must be created by the formal installer"
[ "$(dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null || true)" != installed ] ||
  fail "Docker CE must be installed by the formal installer"
[ -d "$EVIDENCE" ] && [ ! -L "$EVIDENCE" ] || fail "dedicated evidence mount required"
exec > >(tee "$EVIDENCE/acceptance.log") 2>&1

printf 'scope=Debian13-amd64-container-package-checkout-configure\n'
printf 'management_git_commit=%s\n' "$COMMIT"
printf 'not_tested=systemd,host-reboot,Gateway-stack,PostgreSQL,Bootstrap,QR,Hermes-text\n'
printf 'simulated_external_services=none\n'
printf 'test_authorization=disposable-real-sudoers-policy-after-denial-check\n'
printf 'daemon=container-owned-vfs-no-host-socket\n'

# Standard package policy for containers: deny service autostart, not a fake
# systemctl/systemd result. The actual daemon is started explicitly below.
if [ ! -e /usr/sbin/policy-rc.d ]; then
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod 755 /usr/sbin/policy-rc.d
fi

CURRENT_STAGE=system-packages-first
bash "$INSTALLER" system-packages --manager "$MANAGER"
[ "$(id -u "$MANAGER")" != 0 ] || fail "manager is root"
case " $(id -nG "$MANAGER") " in *' root '*|*' docker '*) fail "manager joined a prohibited group" ;; esac
case " $(id -nG "$MANAGER") " in *' sudo '*) ;; *) fail "new manager has no administrative authorization group" ;; esac
[ "$(getent passwd "$MANAGER" | cut -d: -f6)" = "$MANAGER_HOME" ] || fail "wrong manager home"
[ "$(passwd --status "$MANAGER" | awk '{print $2}')" = L ] || fail "new account password is not locked"
/usr/bin/docker compose version --short | grep -Eq '^v?2\.' || fail "Compose v2 is missing"
[ ! -S /var/run/docker.sock ] || fail "package-only stage started a Docker daemon"
account_before="$(getent passwd "$MANAGER")"
groups_before="$(id -G "$MANAGER")"
home_before="$(stat -c '%u:%g:%a:%i' "$MANAGER_HOME")"
packages_before="$(sha256sum /var/lib/cf-agent-wechat-install/system-packages.txt)"
pass "formal installer installed packages and created a real locked non-root manager"

CURRENT_STAGE=system-packages-repeat
bash "$INSTALLER" system-packages --manager "$MANAGER"
[ "$(getent passwd "$MANAGER")" = "$account_before" ] || fail "repeat changed account"
[ "$(id -G "$MANAGER")" = "$groups_before" ] || fail "repeat changed groups"
[ "$(stat -c '%u:%g:%a:%i' "$MANAGER_HOME")" = "$home_before" ] || fail "repeat replaced home"
[ "$(sha256sum /var/lib/cf-agent-wechat-install/system-packages.txt)" = "$packages_before" ] ||
  fail "repeat changed package version record"
cp /var/lib/cf-agent-wechat-install/system-packages.txt "$EVIDENCE/system-packages.txt"
pass "repeat package preparation preserved account, groups, home and dependency record"

as_manager() {
  runuser -u "$MANAGER" -- env -i HOME="$MANAGER_HOME" USER="$MANAGER" LOGNAME="$MANAGER" \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}
assert_no_lifecycle_assets() {
  [ ! -e /srv/storage/cf-agent-wechat ] || fail "preparation created Token/Runtime/Archive assets"
  [ ! -e /opt/cf-agent-gateway ] || fail "preparation installed a fake Gateway"
}

CURRENT_STAGE=checkout-unauthorized
if as_manager bash "$INSTALLER" checkout --manager "$MANAGER" --commit "$COMMIT"; then
  fail "checkout succeeded before sudo authorization"
fi
[ ! -e "$INSTALL_ROOT" ] || fail "unauthorized checkout created final deployment"
[ -z "$(find /opt -maxdepth 1 -name 'cf-agent-wechat-install.*' -print -quit)" ] ||
  fail "unauthorized checkout created a staging directory"
assert_no_lifecycle_assets
pass "real sudo denial failed before checkout or lifecycle side effects"

# This is explicit test-host authorization. No sudo command or user identity is
# mocked; password-based interactive sudo belongs to manual host acceptance.
printf '%s ALL=(root) NOPASSWD: ALL\n' "$MANAGER" > /etc/sudoers.d/cf-clean-host-test
chmod 440 /etc/sudoers.d/cf-clean-host-test
visudo -cf /etc/sudoers.d/cf-clean-host-test >/dev/null

CURRENT_STAGE=checkout-first
as_manager bash "$INSTALLER" checkout --manager "$MANAGER" --commit "$COMMIT"
[ "$(as_manager git -C "$INSTALL_ROOT" rev-parse HEAD)" = "$COMMIT" ] || fail "wrong GitHub commit"
[ "$(as_manager git -C "$INSTALL_ROOT" remote get-url origin)" = https://github.com/Tangbohu09527/CF_agent-wechat.git ] ||
  fail "checkout did not use the original GitHub repository"
cmp -s "$INSTALLER" "$INSTALL_ROOT/scripts/prepare-clean-host.sh" || fail "seed installer differs from fetched commit"
[ -z "$(as_manager git -C "$INSTALL_ROOT" status --porcelain)" ] || fail "new checkout is dirty"
[ "$(stat -c %u "$INSTALL_ROOT")" = "$(id -u "$MANAGER")" ] || fail "checkout has the wrong real owner"
checkout_before="$(stat -c '%u:%g:%a:%i' "$INSTALL_ROOT")"
CURRENT_STAGE=checkout-repeat
as_manager bash "$INSTALL_ROOT/scripts/prepare-clean-host.sh" checkout --manager "$MANAGER" --commit "$COMMIT"
[ "$(stat -c '%u:%g:%a:%i' "$INSTALL_ROOT")" = "$checkout_before" ] || fail "repeat replaced checkout"
assert_no_lifecycle_assets
pass "manager fetched the exact GitHub commit; repeated checkout retained its identity"

CURRENT_STAGE=isolated-docker-daemon
[ ! -S /var/run/docker.sock ] || fail "unexpected daemon socket"
dockerd --host=unix:///var/run/docker.sock --storage-driver=vfs \
  --data-root=/var/lib/cf-clean-host-docker --exec-root=/run/cf-clean-host-docker \
  --pidfile=/run/cf-clean-host-docker.pid --iptables=false --ip6tables=false \
  --bridge=none --ip-forward=false --ip-masq=false > /tmp/cf-clean-host-dockerd.log 2>&1 &
DAEMON_PID=$!
daemon_ready=0
for _attempt in $(seq 1 60); do
  if /usr/bin/docker --context default info >/dev/null 2>&1; then
    daemon_ready=1
    break
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "isolated dockerd exited"
  sleep 1
done
[ "$daemon_ready" = 1 ] || fail "isolated dockerd readiness timeout"
[ -z "$(/usr/bin/docker --context default ps --all --quiet)" ] || fail "isolated daemon contains old containers"
[ -z "$(/usr/bin/docker --context default image ls --quiet)" ] || fail "isolated daemon contains old images"
pass "real isolated rootful Docker started with an empty local image/container store"

configure() {
  as_manager bash "$INSTALL_ROOT/scripts/prepare-clean-host.sh" configure \
    --manager "$MANAGER" --commit "$COMMIT" --image "$IMAGE" --runtime-uid 1000 --runtime-gid 1000
}
CURRENT_STAGE=configure-first
configure
ENV_FILE="$INSTALL_ROOT/docker/.env"
[ "$(stat -c '%u:%a:%h' "$ENV_FILE")" = "$(id -u "$MANAGER"):600:1" ] ||
  fail "installer did not create the protected manager-owned configuration"
[ "$(/usr/bin/docker image inspect --format '{{.Id}}' "$IMAGE")" = "$EXPECTED_IMAGE_ID" ] ||
  fail "actual pulled Image ID differs from the approved manifest configuration"
[ -z "$(/usr/bin/docker ps --all --quiet)" ] || fail "configure left a container after its isolated identity probe"
assert_no_lifecycle_assets
as_manager "$MANAGER_HOME/.local/share/cf-agent-wechat/venv/bin/python" -c 'import websocket, PIL, qrcode'
as_manager "$MANAGER_HOME/.local/share/cf-agent-wechat/venv/bin/python" -m pip check

# configure itself creates one isolated /usr/bin/id probe from the pulled
# image, verifies the real wechat UID/GID, and removes it before writing .env.
# Read its resulting provenance rather than creating duplicate vfs containers.
uid_result="$(awk -F= '$1 == "runtime_uid" {print $2}' "$MANAGER_HOME/.local/share/cf-agent-wechat/install/sources.txt")"
gid_result="$(awk -F= '$1 == "runtime_gid" {print $2}' "$MANAGER_HOME/.local/share/cf-agent-wechat/install/sources.txt")"
[ "$uid_result" = 1000 ] && [ "$gid_result" = 1000 ] || fail "verified image service identity was not recorded"
pass "formal configure pulled immutable upstream, probed its real service UID/GID, and created protected .env/venv"

CURRENT_STAGE=configure-repeat
env_before="$(sha256sum "$ENV_FILE")"
env_metadata_before="$(stat -c '%u:%g:%a:%h:%i:%Y' "$ENV_FILE")"
sources_before="$(sha256sum "$MANAGER_HOME/.local/share/cf-agent-wechat/install/sources.txt")"
configure
[ "$(sha256sum "$ENV_FILE")" = "$env_before" ] || fail "repeat changed existing configuration"
[ "$(stat -c '%u:%g:%a:%h:%i:%Y' "$ENV_FILE")" = "$env_metadata_before" ] || fail "repeat replaced .env"
[ "$(sha256sum "$MANAGER_HOME/.local/share/cf-agent-wechat/install/sources.txt")" = "$sources_before" ] ||
  fail "repeat changed source provenance"

CURRENT_STAGE=configure-conflict
if as_manager bash "$INSTALL_ROOT/scripts/prepare-clean-host.sh" configure \
    --manager "$MANAGER" --commit "$COMMIT" --image "$IMAGE" --runtime-uid 1001 --runtime-gid 1000; then
  fail "conflicting Runtime identity was silently accepted"
fi
[ "$(sha256sum "$ENV_FILE")" = "$env_before" ] || fail "failure changed existing configuration"
[ "$(stat -c '%u:%g:%a:%h:%i:%Y' "$ENV_FILE")" = "$env_metadata_before" ] || fail "failure replaced .env"
assert_no_lifecycle_assets
[ -z "$(/usr/bin/docker ps --all --quiet)" ] || fail "preparation or failed retry left an application container"
case " $(id -nG "$MANAGER") " in *' root '*|*' docker '*) fail "preparation expanded manager group access" ;; esac
pass "repeat and rejected conflicting configuration preserved existing .env and provenance"

CURRENT_STAGE=evidence
cp "$MANAGER_HOME/.local/share/cf-agent-wechat/install/sources.txt" "$EVIDENCE/sources.txt"
cp "$MANAGER_HOME/.local/share/cf-agent-wechat/install/python-packages.txt" "$EVIDENCE/python-packages.txt"
/usr/bin/docker version --format '{{json .}}' > "$EVIDENCE/docker-version.json"
printf 'upstream_service_uid=%s\nupstream_service_gid=%s\n' "$uid_result" "$gid_result" > "$EVIDENCE/service-identity.txt"
chmod 644 "$EVIDENCE"/*
pass "Debian 13 container system-packages + original GitHub checkout + configure acceptance"
printf 'LIMITATION systemd,host-reboot,Gateway/PostgreSQL,Bootstrap,dry-run,QR,Hermes-text remain unverified by this test\n'
