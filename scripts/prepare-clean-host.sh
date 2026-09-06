#!/usr/bin/env bash
set -Eeuo pipefail
set +x
set +a
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Initial installation only. Bootstrap remains the Token/network preparation
# owner; start-qr-login.sh remains the only Agent and fresh-session entry point.
REPOSITORY=https://github.com/Tangbohu09527/CF_agent-wechat.git
INSTALL_ROOT=/opt/cf-agent-wechat
STATE_ROOT=/var/lib/cf-agent-wechat-install
STAGE=${1:-}
MANAGER=
REVISION=
IMAGE=
RUNTIME_UID=
RUNTIME_GID=
TEMP_FILE=
IMAGE_PROBE_ID=

usage() {
  cat <<'EOF'
Usage:
  sudo bash scripts/prepare-clean-host.sh system --manager USER
  sudo bash scripts/prepare-clean-host.sh system-packages --manager USER
  bash scripts/prepare-clean-host.sh checkout --manager USER --commit FULL_SHA
  /opt/cf-agent-wechat/scripts/prepare-clean-host.sh configure --manager USER \
    --commit FULL_SHA --image REGISTRY/IMAGE@sha256:DIGEST \
    --runtime-uid UID --runtime-gid GID

Baseline: Debian 13 (trixie), amd64, systemd, local rootful Docker Engine.
system installs OS tools, Docker CE and Compose v2, and creates a locked manager
account when missing. Set that new account's password/access separately.
system-packages does only package/account preparation; it also works in a real
Debian 13 container but does NOT validate Docker daemon, systemd or reboot.
checkout and configure MUST run as the named non-root manager with sudo access.
Existing checkout/configuration is validated, never overwritten or upgraded.
configure pulls the supplied immutable image and prepares the manager's venv.
It validates the image service UID/GID with an isolated id-only container.
It does not generate Tokens, create Runtime/Session, call Gateway, or start any
Agent/worker services. Complete the Gateway installation gate, then run
bootstrap-cfserver.sh as the manager. See docs/deployment/clean-device.md.
EOF
}

die() { printf '[FAIL:%s] %s\n' "${STAGE:-arguments}" "$*" >&2; exit 1; }
log() { printf '[INFO:%s] %s\n' "$STAGE" "$*"; }
cleanup() {
  if [[ "$IMAGE_PROBE_ID" =~ ^[0-9a-f]{64}$ ]]; then
    sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=2s 20s \
      /usr/bin/docker --context default rm --force --volumes "$IMAGE_PROBE_ID" >/dev/null 2>&1 || true
  fi
  [ -z "$TEMP_FILE" ] || rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT
trap 'die "command failed; existing deployment data was retained; retry this stage after correcting the reported dependency"' ERR

case "$STAGE" in -h|--help) usage; exit 0 ;; system|system-packages|checkout|configure) shift ;; *) usage >&2; exit 2 ;; esac
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "option requires a value"
  case "$1" in
    --manager) MANAGER=$2 ;;
    --commit) REVISION=$2 ;;
    --image) IMAGE=$2 ;;
    --runtime-uid) RUNTIME_UID=$2 ;;
    --runtime-gid) RUNTIME_GID=$2 ;;
    *) die "unsupported option" ;;
  esac
  shift 2
done
[[ "$MANAGER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--manager must name a non-root Unix account"
[ "$MANAGER" != root ] || die "root cannot be the management user"
if [ "$STAGE" != system ] && [ "$STAGE" != system-packages ]; then
  [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "--commit must be a full lowercase Git SHA"
fi
if [ "$STAGE" = configure ]; then
  [[ "$IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]] ||
    die "--image must be an immutable registry reference"
  [[ "$RUNTIME_UID" =~ ^[1-9][0-9]*$ && "$RUNTIME_GID" =~ ^[1-9][0-9]*$ ]] ||
    die "explicit positive --runtime-uid and --runtime-gid are required"
  [ "${#RUNTIME_UID}" -le 10 ] && [ "${#RUNTIME_GID}" -le 10 ] &&
    [ "$RUNTIME_UID" -le 2147483647 ] && [ "$RUNTIME_GID" -le 2147483647 ] ||
    die "Runtime UID/GID must not exceed 2147483647"
fi

platform() {
  [ -f /etc/os-release ] || die "os-release is missing"
  [ "$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)" = debian ] &&
    [ "$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)" = 13 ] &&
    [ "$(dpkg --print-architecture)" = amd64 ] ||
    die "only Debian 13 amd64 is an installation baseline"
  if [ "$STAGE" = system ]; then
    [ -d /run/systemd/system ] || die "a booted systemd host is required (a plain container is insufficient; system-packages is partial preparation)"
  fi
}

safe_path() {
  local current=$1 owner mode
  while [ "$current" != / ]; do
    [ ! -L "$current" ] || die "installation path has a symlink"
    if [ -e "$current" ]; then
      owner=$(stat -c %u -- "$current")
      mode=$(stat -c %a -- "$current")
      [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ] || die "installation path has an unexpected owner"
      (( (8#$mode & 8#022) == 0 )) || die "installation path is group/other writable"
    fi
    current=$(dirname -- "$current")
  done
}

manager_identity() {
  id "$MANAGER" >/dev/null 2>&1 || die "manager does not exist; run system first"
  [ "$(id -u "$MANAGER")" != 0 ] || die "manager UID must not be root"
  case " $(id -nG "$MANAGER") " in *' root '*|*' docker '*) die "manager must not belong to root or docker groups" ;; esac
}

manager_session() {
  manager_identity
  [ "$(id -un)" = "$MANAGER" ] && [ "$(id -u)" != 0 ] ||
    die "run this stage directly as the named non-root manager"
  [ "${HOME:-}" = "$(getent passwd "$MANAGER" | cut -d: -f6)" ] || die "HOME must match the manager account"
  safe_path "$HOME"
  log "authorize sudo for the protected installation and local Docker operations"
  sudo -v || die "sudo authorization denied"
  sudo -n -- true || die "sudo authorization does not allow the required follow-up operations"
}

create_once() {
  local source=$1 destination=$2 mode=$3
  safe_path "$destination"
  if [ -e "$destination" ]; then
    [ -f "$destination" ] && [ "$(stat -c %h -- "$destination")" = 1 ] || die "existing installation asset is not a regular single-link file"
    cmp -s -- "$source" "$destination" || die "existing installation asset differs; review it without overwriting"
  else
    # Hard-link creation is atomic and fails if another installer won the race.
    install -m "$mode" -- "$source" "${destination}.new.$$"
    ln -- "${destination}.new.$$" "$destination" || die "installation asset appeared concurrently"
    rm -f -- "${destination}.new.$$"
  fi
}

install_missing_packages() {
  local package
  local -a missing=()
  for package in "$@"; do
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ]; then
      missing+=("$package")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${missing[@]}"
  fi
}

system_stage() {
  local package compose_package
  [ "$(id -u)" = 0 ] || die "system stage requires explicit root installation"
  for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ] ||
      die "conflicting Docker package exists; installer will not remove existing host packages"
  done
  install_missing_packages ca-certificates curl git openssl python3 python3-venv sudo util-linux gawk gnupg
  if ! id "$MANAGER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group "$MANAGER"
    usermod --append --groups sudo "$MANAGER"
    log "created a locked manager account; root must provision its password and SSH access before checkout"
  fi
  manager_identity
  safe_path /etc/apt/keyrings
  safe_path /etc/apt/sources.list.d
  install -d -m 755 /etc/apt/keyrings
  TEMP_FILE=$(mktemp)
  curl --fail --silent --show-error --location --connect-timeout 15 --max-time 90 \
    https://download.docker.com/linux/debian/gpg -o "$TEMP_FILE"
  gpg --batch --show-keys --with-colons "$TEMP_FILE" 2>/dev/null | \
    awk -F: '$1 == "fpr" && $10 == "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" {found=1} END {exit !found}' ||
    die "Docker repository signing key fingerprint does not match"
  create_once "$TEMP_FILE" /etc/apt/keyrings/cf-agent-docker.asc 644
  cat > "$TEMP_FILE" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/cf-agent-docker.asc
EOF
  create_once "$TEMP_FILE" /etc/apt/sources.list.d/cf-agent-docker.sources 644
  # Compose v2 is the existing management contract. A future major version must
  # undergo acceptance instead of being silently selected by apt's latest.
  if [ "$(dpkg-query -W -f='${db:Status-Status}' docker-compose-plugin 2>/dev/null || true)" != installed ]; then
    apt-get update
    compose_package=$(apt-cache madison docker-compose-plugin | awk '$3 ~ /^(([0-9]+):)?2\./ && !found {print $3; found=1}')
    [ -n "$compose_package" ] || die "official repository has no Compose v2 package; baseline needs revalidation"
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "docker-compose-plugin=$compose_package"
  fi
  install_missing_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  /usr/bin/docker compose version --short | grep -Eq '^v?2\.' || die "Docker Compose v2 is required"
  if [ "$STAGE" = system ]; then
    /usr/bin/systemctl enable --now docker.service
    /usr/bin/docker --context default info --format '{{.LiveRestoreEnabled}}' | grep -qx false || die "Docker live-restore must be disabled"
  fi
  safe_path "$STATE_ROOT"
  install -d -m 755 "$STATE_ROOT"
  dpkg-query -W -f='${Package}=${Version}\n' ca-certificates curl git openssl python3 python3-venv sudo \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > "$TEMP_FILE"
  create_once "$TEMP_FILE" "$STATE_ROOT/system-packages.txt" 644
  log "package/account preparation complete; dependency versions recorded; no Agent service enabled"
  if [ "$STAGE" = system-packages ]; then
    log "Docker daemon, systemd and host reboot have NOT been verified"
  fi
}

validate_checkout() {
  safe_path "$INSTALL_ROOT"
  [ -d "$INSTALL_ROOT/.git" ] && [ ! -L "$INSTALL_ROOT/.git" ] || die "installation must be a standalone Git checkout"
  [ "$(git -C "$INSTALL_ROOT" remote get-url origin)" = "$REPOSITORY" ] || die "unexpected checkout origin"
  [ "$(git -C "$INSTALL_ROOT" rev-parse HEAD)" = "$REVISION" ] || die "existing checkout is at another commit; review a separate upgrade"
  [ -z "$(git -C "$INSTALL_ROOT" status --porcelain --untracked-files=normal)" ] || die "checkout contains modifications; nothing will be overwritten"
}

checkout_stage() {
  manager_session
  safe_path /opt
  if [ ! -e "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ]; then
    # Clone into a fresh sibling so failed fetch never leaves a partial final
    # checkout. Failed staging directories are retained for diagnosis.
    local staging
    staging=$(sudo -n -- mktemp -d /opt/cf-agent-wechat-install.XXXXXXXX)
    sudo -n -- chown "$(id -u):$(id -g)" "$staging"
    git -c core.hooksPath=/dev/null init "$staging"
    git -C "$staging" remote add origin "$REPOSITORY"
    git -C "$staging" -c core.hooksPath=/dev/null fetch --depth 1 origin "$REVISION"
    git -C "$staging" -c core.hooksPath=/dev/null checkout --detach FETCH_HEAD
    [ "$(git -C "$staging" rev-parse HEAD)" = "$REVISION" ] || die "fetched commit differs from requested SHA"
    chmod 755 "$staging"
    sudo -n -- mv -T -n -- "$staging" "$INSTALL_ROOT"
    [ ! -e "$staging" ] || die "installation path appeared concurrently; staged checkout retained"
  fi
  validate_checkout
  log "fixed GitHub commit installed and verified"
}

validate_image_service_identity() {
  local identity
  # Create only our own disposable probe, bypassing the upstream entrypoint.
  # No host paths, credentials, network, session or Gateway are available.
  IMAGE_PROBE_ID=$(sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=2s 30s \
    /usr/bin/docker --context default create --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges --restart no \
    --entrypoint /usr/bin/id "$IMAGE" wechat) || die "image identity probe could not be created"
  [[ "$IMAGE_PROBE_ID" =~ ^[0-9a-f]{64}$ ]] || die "invalid image identity probe ID"
  identity=$(sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=2s 30s \
    /usr/bin/docker --context default start --attach "$IMAGE_PROBE_ID" 2>/dev/null) ||
    die "image service identity probe failed or timed out"
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=2s 20s \
    /usr/bin/docker --context default rm --volumes "$IMAGE_PROBE_ID" >/dev/null ||
    die "image identity probe cleanup failed"
  IMAGE_PROBE_ID=
  [[ "$identity" =~ ^uid=([0-9]+)\(wechat\)[[:space:]]gid=([0-9]+)\( ]] ||
    die "image does not expose the expected wechat service account"
  [ "${BASH_REMATCH[1]}" = "$RUNTIME_UID" ] && [ "${BASH_REMATCH[2]}" = "$RUNTIME_GID" ] ||
    die "requested Runtime UID/GID differs from the actual immutable image service account"
}

configure_stage() {
  local image_info state_dir variable daemon_info
  manager_session
  validate_checkout
  for variable in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    [[ ! -v $variable ]] || die "Docker endpoint overrides are not accepted"
  done
  safe_path "$INSTALL_ROOT/docker/.env"
  [ ! -e "$INSTALL_ROOT/docker/.env" ] || {
    [ -f "$INSTALL_ROOT/docker/.env" ] && [ "$(stat -c %h "$INSTALL_ROOT/docker/.env")" = 1 ] || die ".env must be a single-link regular file"
    case "$(stat -c %a "$INSTALL_ROOT/docker/.env")" in 600|640) ;; *) die ".env must have mode 600 or 640" ;; esac
  }
  # Validate all existing configuration before pulling or creating any asset.
  TEMP_FILE=$(mktemp)
  python3 - "$INSTALL_ROOT/docker/.env" "$IMAGE" "$RUNTIME_UID" "$RUNTIME_GID" > "$TEMP_FILE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
expected = {
    'COMPOSE_PROJECT_NAME': 'cf-agent-wechat',
    'AGENT_WECHAT_IMAGE': sys.argv[2],
    'AGENT_WECHAT_CONTAINER_NAME': 'cf-agent-wechat',
    'CF_AGENT_WECHAT_STORAGE_ROOT': '/srv/storage/cf-agent-wechat',
    'CF_AGENT_WECHAT_RUNTIME_ROOT': '/srv/storage/cf-agent-wechat/runtime',
    'CF_AGENT_WECHAT_ARCHIVE_ROOT': '/srv/storage/cf-agent-wechat/session-archive',
    'CF_AGENT_WECHAT_RUNTIME_UID': sys.argv[3],
    'CF_AGENT_WECHAT_RUNTIME_GID': sys.argv[4],
    'CF_AGENT_WECHAT_RUNTIME_MODE': '700',
    'AGENT_WECHAT_BIND_IP': '127.0.0.1',
    'AGENT_WECHAT_PORT': '6174', 'PROXY': '', 'RUST_LOG': 'info',
}
if path.exists():
    actual = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or key in actual or key not in expected:
            raise SystemExit('Existing .env is not the approved literal configuration; retained unchanged')
        actual[key] = value
    if actual != expected:
        raise SystemExit('Existing .env differs from requested inputs; retained unchanged; review configuration explicitly')
for key, value in expected.items():
    print(f'{key}={value}')
PY
  [ "$(sudo -n -- /usr/bin/docker context inspect default --format '{{.Endpoints.docker.Host}}')" = unix:///var/run/docker.sock ] ||
    die "the default Docker context must select the local Unix socket"
  daemon_info=$(sudo -n -- /usr/bin/docker --context default info --format '{{.LiveRestoreEnabled}}|{{json .SecurityOptions}}')
  case "$daemon_info" in false\|*) ;; *) die "Docker live-restore must be disabled" ;; esac
  case "$daemon_info" in *rootless*) die "rootless Docker is outside the production contract" ;; esac
  sudo -n -- /usr/bin/timeout --signal=TERM --kill-after=10s 900s \
    /usr/bin/docker --context default pull --platform linux/amd64 "$IMAGE" >/dev/null ||
    die "immutable image cannot be pulled from its registry; no local tag fallback is allowed"
  image_info=$(sudo -n -- /usr/bin/docker --context default image inspect --format '{{.Os}}|{{.Architecture}}|{{.Id}}' "$IMAGE")
  [[ "$image_info" =~ ^linux\|amd64\|sha256:[0-9a-f]{64}$ ]] || die "pulled image platform or Image ID is invalid"
  validate_image_service_identity
  if [ ! -e "$INSTALL_ROOT/docker/.env" ]; then
    create_once "$TEMP_FILE" "$INSTALL_ROOT/docker/.env" 600
  fi
  # Reuse the same pinned requirements and stamp as daily login, as manager.
  safe_path "$HOME/.local/share/cf-agent-wechat/venv"
  unset XDG_DATA_HOME CF_AGENT_WECHAT_VENV PYTHON_BIN REQUIREMENTS_FILE
  # shellcheck source=scripts/common.sh
  source "$INSTALL_ROOT/scripts/common.sh"
  ensure_login_environment || die "$LAST_ERROR"
  state_dir="$HOME/.local/share/cf-agent-wechat/install"
  safe_path "$state_dir"
  install -d -m 700 "$state_dir"
  printf 'configuration_version=1\nmanagement_git_commit=%s\nupstream_image_reference=%s\nactual_image=%s\nruntime_uid=%s\nruntime_gid=%s\nruntime_mode=700\ngateway_git_commit=NOT_INSTALLED_BY_WECHAT\n' \
    "$REVISION" "$IMAGE" "$image_info" "$RUNTIME_UID" "$RUNTIME_GID" > "$TEMP_FILE"
  create_once "$TEMP_FILE" "$state_dir/sources.txt" 600
  "$LOGIN_PYTHON" -m pip freeze > "$TEMP_FILE"
  create_once "$TEMP_FILE" "$state_dir/python-packages.txt" 600
  log "WeChat inputs prepared; Runtime UID/GID verified against the approved upstream image service account"
  log "Gateway installation/network/configuration gate remains separate; see docs/deployment/clean-device.md before Bootstrap"
}

platform
case "$STAGE" in
  system|system-packages) system_stage ;;
  checkout) checkout_stage ;;
  configure) configure_stage ;;
esac
