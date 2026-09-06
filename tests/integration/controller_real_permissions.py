#!/usr/bin/env python3
"""Real Linux permissions regression; Docker/systemd behavior is simulated.

Invoked by controller_real_permissions.sh --full after authentic old-commit
reproduction. Never run against an existing host. No uid/id/sudo/stat substitute
is installed. Bootstrap and fresh-start create their own deployment assets.
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
import pty
import select
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path("/opt/controller-real-permissions")
APP = ROOT / "candidate"
CONTROLLER = Path("/opt/cf-agent-gateway/deploy/wechat-runtime-control")
STATE = CONTROLLER.parent / ".wechat-runtime-control-test-state"
STORAGE = Path("/srv/storage/cf-agent-wechat")
TOKEN = STORAGE / "secrets/auth-token"
RUNTIME = STORAGE / "runtime"
ARCHIVE = STORAGE / "session-archive"
MANAGER = "qrmanager"
SUDOERS = Path("/etc/sudoers.d/qr-controller-test")
LOGS = ROOT / "results"
BIN = ROOT / "external-bin"
EXTERNAL_STATE = BIN / "state"
ENV = APP / "docker/.env"
COMPOSE = APP / "docker/compose.cfserver.yaml"
CONTRACT = {
    "contract_version": 1,
    "poll_worker_service": "worker",
    "delivery_worker_service": "delivery-worker",
    "dispatch_worker_service": "dispatch-worker",
    "token_mode": "file",
    "token_container_path": "/run/secrets/cf-agent-wechat-auth-token",
}
outputs: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def passed(message: str) -> None:
    print("PASS:", message, flush=True)


def write(path: Path, content: str, mode: int = 0o644) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def policy(value: str = "NOPASSWD: ALL") -> None:
    write(SUDOERS, f"{MANAGER} ALL=(root) {value}\n", 0o440)
    subprocess.run(["visudo", "-cf", str(SUDOERS)], check=True, capture_output=True)


def environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        "HOME": f"/home/{MANAGER}",
        "PATH": "/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LC_ALL": "C.UTF-8",
        "PYTHON_BIN": "/usr/bin/python3",
        "CF_AGENT_WECHAT_ROOT": str(APP),
        "CF_AGENT_WECHAT_COMPOSE_FILE": str(COMPOSE),
        "CF_AGENT_WECHAT_ENV_FILE": str(ENV),
        "COMPOSE_COMMAND_TIMEOUT": "2",
        "DOCKER_COMMAND_TIMEOUT": "2",
        "SERVER_READY_TIMEOUT": "2",
        "WECHAT_READY_TIMEOUT": "2",
        "WECHAT_STABLE_SECONDS": "1",
        "POST_LOGIN_READY_TIMEOUT": "2",
        "RUNTIME_POLL_INTERVAL": "1",
        "HTTP_CONNECT_TIMEOUT": "1",
        "HTTP_TIMEOUT": "1",
        "CF_BOOTSTRAP_TESTING": "1",
        "CF_BOOTSTRAP_DOCKER_BIN": str(BIN / "docker"),
        "CF_BOOTSTRAP_SYSTEMCTL_BIN": str(BIN / "systemctl"),
        "CF_BOOTSTRAP_DOCKER_SOCKET_PATH": str(ROOT / "docker.sock"),
        "CF_BOOTSTRAP_DOCKER_TIMEOUT": "2",
        "CF_BOOTSTRAP_COMPOSE_TIMEOUT": "2",
    }
    env.update(extra or {})
    return env


def command(args: list[str], extra: dict[str, str] | None = None) -> list[str]:
    return ["runuser", "-u", MANAGER, "--", "env", "-i",
            *[f"{key}={value}" for key, value in environment(extra).items()], *args]


def execute(label: str, args: list[str], expected: int | None = 0,
            extra: dict[str, str] | None = None, terminal: bool = False,
            cancel_password: bool = False) -> str:
    if terminal:
        master, slave = pty.openpty()
        proc = subprocess.Popen(command(args, extra), stdin=slave, stdout=slave,
                                stderr=slave, start_new_session=True)
        os.close(slave)
        chunks: list[bytes] = []
        deadline = time.monotonic() + 180
        while True:
            check(time.monotonic() < deadline, f"{label}: timed out")
            if select.select([master], [], [], 0.2)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                chunks.append(chunk)
                if cancel_password and b"password" in b"".join(chunks).lower():
                    # sudo reads an actual controlling-terminal password prompt.
                    os.write(master, b"\n\n\n")
                    cancel_password = False
            if proc.poll() is not None:
                break
        proc.wait(timeout=5)
        os.close(master)
        out = b"".join(chunks).decode("utf-8", errors="replace")
        rc = proc.returncode
    else:
        result = subprocess.run(command(args, extra), input="", text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=180, check=False)
        out, rc = result.stdout, result.returncode
    leaked = TOKEN.exists() and TOKEN.read_text() in out
    if leaked:
        out = out.replace(TOKEN.read_text(), "[REDACTED]")
    outputs.append(out)
    write(LOGS / f"{label}.log", out)
    check(not leaked, f"{label}: Token reached process output (redacted in artifact)")
    if expected == 0:
        check(rc == 0, f"{label}: exit={rc}\n{out}")
    elif expected is not None:
        check(rc != 0, f"{label}: unexpected success\n{out}")
    return out


def shell(label: str, body: str, expected: int | None = 0) -> str:
    return execute(label, ["/bin/bash", "-c",
        'source "$1/scripts/common.sh"; source "$1/scripts/qr-runtime-common.sh"; '
        + body, label, str(APP)], expected)


def validate(label: str, expected: int = 0) -> str:
    return shell(label, 'if gateway_validate_runtime_contract; then exit 0; fi; '
                 'printf "%s\\n" "$LAST_ERROR" >&2; exit 1', expected)


def install_controller(content: str | None = None) -> None:
    if CONTROLLER.exists() or CONTROLLER.is_symlink():
        CONTROLLER.unlink()
    if content is None:
        shutil.copyfile(ROOT / "authentic-controller", CONTROLLER)
        CONTROLLER.chmod(0o755)
    else:
        write(CONTROLLER, content, 0o755)
    os.chown(CONTROLLER, 0, 0)


def controller_snapshot() -> tuple[bytes, bytes]:
    return tuple((STATE / name).read_bytes() if (STATE / name).exists() else b""
                 for name in ("controller.log", "mutations.log"))


def snapshot() -> str:
    digest = hashlib.sha256()
    if not STORAGE.exists():
        return "missing"
    for path in sorted([STORAGE, *STORAGE.rglob("*")]):
        info = path.lstat()
        digest.update(str(path).encode())
        digest.update(f"{info.st_uid}:{info.st_gid}:{info.st_mode}:"
                      f"{info.st_mtime_ns}:{info.st_ino}".encode())
        if path.is_file() and not path.is_symlink():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def no_worker_start() -> None:
    for path in (STATE / "mutations.log", EXTERNAL_STATE / "mutations.log"):
        if path.exists():
            check("gateway worker start" not in path.read_text(),
                  "failure opened Gateway gate")


def main() -> None:
    check(os.getuid() == 0 and os.environ.get("CF_CONTROLLER_PERMISSION_DISPOSABLE") == "1"
          and Path("/.dockerenv").exists(), "disposable Linux setup guard")
    LOGS.mkdir()
    shutil.copytree(SOURCE / "scripts", APP / "scripts")
    shutil.copytree(SOURCE / "docker", APP / "docker")
    # Real manager-owned checkout; root-protected production configuration.
    for path in [APP, *APP.rglob("*")]:
        os.chown(path, 1101, 1101)
        if path.is_dir():
            path.chmod(0o755)
    for name in ("common.sh", "qr-runtime-common.sh", "gateway-controller-common.sh"):
        check((APP / "scripts" / name).is_file(), f"missing candidate source: {name}")
    for _ in range(2):
        validate("authentic-static-contract")
    passed("fixed candidate reads authentic static contract as real non-root UID 1101")

    # Second genuine manager identity is deliberately not a field username.
    global MANAGER
    MANAGER = "deployadmin"
    subprocess.run(["useradd", "--uid", "1102", "--user-group", "--create-home",
                    "--shell", "/bin/bash", MANAGER], check=True)
    policy()
    validate("second-manager-static-contract")
    check(subprocess.check_output(["id", "-G", MANAGER], text=True).strip() == "1102",
          "second manager unexpectedly has additional groups")
    MANAGER = "qrmanager"
    policy()
    passed("another real management username/UID works without root or docker groups")

    # No policy and password authorization failure occur before Controller or state access.
    for label, rule in (("sudo-not-authorized", None),
                        ("sudo-password-not-supplied", "PASSWD: ALL"),
                        ("sudo-explicitly-denied", "NOPASSWD: !ALL")):
        if rule is None:
            SUDOERS.unlink()
        else:
            policy(rule)
        execute(label + "-invalidate", ["/usr/bin/sudo", "-K"], None)
        validate(label, 1)
        check(not STORAGE.exists(), f"{label} created deployment state")
    policy()
    passed("real sudo missing authorization and unsupplied password fail closed")

    # Authorize successfully in the real process, then expire/revoke that grant.
    proc = subprocess.Popen(command(["/bin/bash", "-c",
        'source "$1/scripts/common.sh"; source "$1/scripts/qr-runtime-common.sh"; '
        'runtime_authorize_sudo || exit 90; echo AUTHORIZED; read -r resume; '
        'if gateway_validate_runtime_contract; then exit 0; fi; '
        'printf "%s\\n" "$LAST_ERROR"; exit 1', "expired", str(APP)]),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    assert proc.stdout is not None and proc.stdin is not None
    while True:
        line = proc.stdout.readline()
        check(bool(line), "authorization process exited before marker")
        lines.append(line)
        if line.strip() == "AUTHORIZED":
            break
    policy("PASSWD: ALL")
    subprocess.run(command(["/usr/bin/sudo", "-K"]), check=True)
    proc.stdin.write("continue\n")
    proc.stdin.flush()
    tail = proc.communicate(timeout=10)[0]
    expired = "".join(lines) + tail
    outputs.append(expired)
    write(LOGS / "sudo-expired.log", expired)
    check(proc.returncode != 0, "expired real sudo unexpectedly accepted")
    policy()
    passed("actual sudo grant expires after authorization and fails before lifecycle side effects")

    # File system rejection uses real root-only parents and actual lstat metadata.
    for kind in ("missing", "symlink", "hardlink", "not-executable",
                 "world-writable", "wrong-owner", "wrong-group",
                 "parent-writable", "parent-symlink"):
        install_controller()
        other = CONTROLLER.with_name("unsafe-controller-target")
        if kind == "missing":
            CONTROLLER.unlink()
        elif kind == "symlink":
            CONTROLLER.rename(other)
            CONTROLLER.symlink_to(other)
        elif kind == "hardlink":
            os.link(CONTROLLER, other)
        elif kind == "not-executable":
            CONTROLLER.chmod(0o644)
        elif kind == "world-writable":
            CONTROLLER.chmod(0o777)
        elif kind == "wrong-owner":
            os.chown(CONTROLLER, 1101, 0)
        elif kind == "wrong-group":
            os.chown(CONTROLLER, 0, 1101)
        elif kind == "parent-writable":
            CONTROLLER.parent.chmod(0o777)
        elif kind == "parent-symlink":
            CONTROLLER.parent.rename(CONTROLLER.parent.with_name("deploy-real"))
            CONTROLLER.parent.symlink_to("deploy-real", target_is_directory=True)
        validate("unsafe-controller-" + kind, 1)
        check(not STORAGE.exists(), f"{kind} created deployment state")
        if kind == "parent-symlink":
            CONTROLLER.parent.unlink()
            CONTROLLER.parent.with_name("deploy-real").rename(CONTROLLER.parent)
        CONTROLLER.parent.chmod(0o755)
        if other.exists():
            other.unlink()
    install_controller()
    passed("missing/symlink/hardlink/executable/owner/group/mode/parent checks fail closed")

    # Only external Controller responses are substituted from here.
    variants: dict[str, object] = {
        "malformed": "{broken", "array": [], "wrong-version": {**CONTRACT, "contract_version": 2},
        "boolean-version": {**CONTRACT, "contract_version": True},
        "string-version": {**CONTRACT, "contract_version": "1"},
        "missing-field": {k: v for k, v in CONTRACT.items() if k != "token_mode"},
        "extra-field": {**CONTRACT, "extra": "unexpected"},
        "wrong-field-type": {**CONTRACT, "poll_worker_service": ["worker"]},
        "wrong-value": {**CONTRACT, "poll_worker_service": "dispatch-worker"},
        "oversized": "x" * 65537,
    }
    for name, value in variants.items():
        payload = value if isinstance(value, str) else json.dumps(value)
        install_controller("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(payload) + "\n")
        validate("contract-" + name, 1)
    install_controller("#!/bin/sh\nprintf 'private-error\\n' >&2\nexit 70\n")
    check("private-error" not in validate("contract-nonzero", 1), "Controller stderr escaped")
    install_controller("#!/bin/sh\nexec /bin/sleep 300\n")
    started = time.monotonic()
    validate("contract-timeout", 1)
    check(time.monotonic() - started < 7, "contract timeout exceeded bound")
    install_controller()
    passed("contract exact JSON fields/types/values, nonzero exit, output bound, and real timeout")

    # Formal Bootstrap owns Token, management directory, and archive creation.
    BIN.mkdir()
    EXTERNAL_STATE.mkdir()
    os.chown(EXTERNAL_STATE, 1101, 1101)
    for source, target in (("mock_bootstrap_docker.sh", "docker"),
                           ("mock_bootstrap_systemctl.sh", "systemctl")):
        shutil.copyfile(SOURCE / "tests/helpers" / source, BIN / target)
        (BIN / target).chmod(0o755)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(ROOT / "docker.sock"))
    (ROOT / "docker.sock").chmod(0o660)
    template = (APP / "docker/.env.example").read_text()
    template = template.replace("ghcr.io/thisnick/agent-wechat@sha256:REPLACE_WITH_64_HEX_DIGEST",
                                "ghcr.io/example/agent-wechat@sha256:" + "0" * 64)
    # The image is a declared external fixture, not a publishable image assertion.
    write(ENV, template, 0o600)
    os.chown(ENV, 0, 0)
    execute("bootstrap", ["/bin/bash", str(APP / "scripts/bootstrap-cfserver.sh")])
    check(TOKEN.is_file() and not RUNTIME.exists(), "Bootstrap did not only prepare Token")
    info = TOKEN.stat()
    check((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink) ==
          (10001, 10001, 0o600, 1), "Bootstrap Token contract differs")
    token = TOKEN.read_bytes()
    before = snapshot()
    execute("bootstrap-retry", ["/bin/bash", str(APP / "scripts/bootstrap-cfserver.sh")])
    check(snapshot() == before, "Bootstrap retry changed existing valid secrets/state")
    check(not list(ARCHIVE.iterdir()), "Bootstrap generated an archive/session")
    check("up" not in (EXTERNAL_STATE / "docker.log").read_text().split(),
          "Bootstrap invoked Docker up")
    passed("ordinary-user formal Bootstrap creates protected Token/archive, retries without mutation")

    # Install behavior-only Docker wrapper at the real root-controlled command path.
    shutil.copyfile(SOURCE / "tests/helpers/mock_docker.sh", BIN / "runtime-docker")
    (BIN / "runtime-docker").chmod(0o755)
    for name, value in (("agent_exists", "0"), ("agent_running", "0"),
                        ("container_health", "unhealthy")):
        write(EXTERNAL_STATE / name, value + "\n")
        os.chown(EXTERNAL_STATE / name, 1101, 1101)
    for name in ("audit.log", "mutations.log", "auth-state"):
        write(EXTERNAL_STATE / name, "")
        os.chown(EXTERNAL_STATE / name, 1101, 1101)
    values = {
        "MOCK_DOCKER_STATE_DIR": str(EXTERNAL_STATE),
        "MOCK_DOCKER_LOG": str(EXTERNAL_STATE / "audit.log"),
        "MOCK_DOCKER_MUTATION_LOG": str(EXTERNAL_STATE / "mutations.log"),
        "MOCK_AGENT_COMPOSE_FILE": str(COMPOSE),
        "MOCK_AGENT_ENV_FILE": str(ENV),
        "MOCK_AGENT_CONTAINER_NAME": "cf-agent-wechat",
        "MOCK_RUNTIME_ROOT": str(RUNTIME),
        "MOCK_AUTH_STATE_FILE": str(EXTERNAL_STATE / "auth-state"),
        "TOKEN_FILE": str(TOKEN),
    }
    wrapper = "#!/bin/bash\n" + "".join(
        f"export {key}={shlex.quote(value)}\n" for key, value in values.items())
    wrapper += f"exec /bin/bash {shlex.quote(str(BIN / 'runtime-docker'))} \"$@\"\n"
    write(Path("/usr/local/bin/docker"), wrapper, 0o755)
    STATE.mkdir(mode=0o700)
    for name in ("controller.log", "mutations.log"):
        write(STATE / name, "")
    mock_controller = (SOURCE / "tests/helpers/mock_gateway_runtime_control.sh").read_text()
    # Shared behavior log proves order across separate Controller/Docker processes.
    mock_controller = mock_controller.replace(
        'record() {\n',
        'record() {\n  printf "%s\\n" "$1" >> ' + shlex.quote(str(EXTERNAL_STATE / "audit.log")) + '\n')
    install_controller(mock_controller)

    for name in ("start-qr-login.sh", "stop-qr-runtime.sh"):
        execute("dry-before-" + name, ["/bin/bash", str(APP / "scripts" / name), "--dry-run"])
    check(snapshot() == before, "dry-run created Session, Runtime, archive, or changed Token")
    check(not (STATE / "mutations.log").read_bytes(), "dry-run mutated Controller gate")
    check(not (EXTERNAL_STATE / "mutations.log").read_bytes(), "dry-run mutated Docker")
    passed("ordinary-user start/stop dry-runs preserve Bootstrap-only deployment state")

    entrypoints = (
        ("start", "start-qr-login.sh", ["--dry-run"]),
        ("stop", "stop-qr-runtime.sh", ["--dry-run"]),
        ("status", "status.sh", []),
        ("bootstrap", "bootstrap-cfserver.sh", []),
    )
    for denial in ("no-sudo", "sudo-denied", "invalid-contract"):
        data_before = snapshot()
        docker_before = (EXTERNAL_STATE / "audit.log").read_bytes()
        gate_before = controller_snapshot()[1]
        if denial == "no-sudo":
            SUDOERS.unlink()
        elif denial == "sudo-denied":
            policy("NOPASSWD: !ALL")
        else:
            install_controller("#!/bin/sh\n" + "printf '%s\\n' '{invalid-json'\n")
        for label, filename, args in entrypoints:
            execute(denial + "-" + label, ["/bin/bash", str(APP / "scripts" / filename), *args], 1)
            check(snapshot() == data_before, denial + "-" + label + " changed deployment state")
            check((EXTERNAL_STATE / "audit.log").read_bytes() == docker_before,
                  denial + "-" + label + " called Docker after failed authorization/contract")
            check(controller_snapshot()[1] == gate_before,
                  denial + "-" + label + " changed Controller gate")
        policy()
        install_controller(mock_controller)
    passed("all start/stop/status/Bootstrap callers fail before Docker or lifecycle side effects")

    # Environment claims may not widen the accepted owner of a protected file.
    os.chown(ENV, 1102, 1102)
    for label, filename, args in entrypoints:
        execute("spoofed-owner-" + label, ["/bin/bash", str(APP / "scripts" / filename), *args], 1,
                extra={"SUDO_UID": "1102", "SUDO_GID": "1102", "SUDO_USER": "deployadmin"})
    os.chown(ENV, 0, 0)
    check(snapshot() == data_before, "forged sudo identity changed deployment state")
    passed("caller-provided SUDO_UID/SUDO_USER do not make another owner's dotenv acceptable")

    # A real controlled terminal and real venv; deliberate unhealthy Docker ends
    # startup after official create_fresh_runtime and before QR/network login.
    execute("fresh-start-health-failure", ["/bin/bash", str(APP / "scripts/start-qr-login.sh")],
            1, terminal=True)
    check(RUNTIME.is_dir(), "formal fresh start did not reach runtime preparation")
    for path in (RUNTIME, RUNTIME / "data", RUNTIME / "wechat-home"):
        info = path.stat()
        check((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (1000, 1000, 0o700),
              "container service UID/GID was confused with manager UID/GID 1101")
    check((Path("/home/qrmanager/.local/share/cf-agent-wechat/venv/bin/python")).exists(),
          "fresh start did not build its real venv")
    mutations = (EXTERNAL_STATE / "mutations.log").read_text()
    check("agent container start" in mutations, "startup never called external Docker")
    check("gateway controller stop" in (STATE / "controller.log").read_text(),
          "fresh-start did not close gate before its runtime changes")
    no_worker_start()
    audit = (EXTERNAL_STATE / "audit.log").read_text()
    check(audit.index("gateway controller stop") < audit.index("agent container start"),
          "fresh start mutated Docker before closing both worker gates")
    before = snapshot()
    gate_before = controller_snapshot()[1]
    docker_before = (EXTERNAL_STATE / "mutations.log").read_bytes()
    for name in ("start-qr-login.sh", "stop-qr-runtime.sh"):
        execute("dry-existing-" + name, ["/bin/bash", str(APP / "scripts" / name), "--dry-run"])
    check(snapshot() == before, "existing-runtime dry-run mutated data")
    check(controller_snapshot()[1] == gate_before, "existing-runtime dry-run changed gate")
    check((EXTERNAL_STATE / "mutations.log").read_bytes() == docker_before,
          "existing-runtime dry-run changed Docker")
    passed("formal fresh start uses service UID 1000; manager UID 1101 dry-run preserves runtime")

    execute("ignored-service-identity-environment",
            ["/bin/bash", str(APP / "scripts/start-qr-login.sh"), "--dry-run"],
            extra={"CF_AGENT_WECHAT_RUNTIME_UID": "0", "CF_AGENT_WECHAT_RUNTIME_GID": "0",
                   "CF_AGENT_WECHAT_RUNTIME_MODE": "777", "SUDO_UID": "0", "SUDO_USER": "root",
                   "GATEWAY_RUNTIME_CONTROL": "/tmp/unapproved-controller"})
    check(snapshot() == before, "process environment changed approved service identity or runtime")
    passed("process UID/GID/mode, Controller-path, and sudo-owner overrides are ignored")

    for running, word in (("0", "false"), ("1", "true")):
        write(STATE / "gateway_running", running)
        result = execute("status-" + word, ["/bin/bash", str(APP / "scripts/status.sh")], None)
        check(f"Gateway Runtime Ready:\n  {word}" in result, "status omitted valid gateway gate")
        check("Gateway Runtime Contract controller is unavailable" not in result,
              "status regressed to ordinary-user precheck")
    execute("ordinary-stop", ["/bin/bash", str(APP / "scripts/stop-qr-runtime.sh")])
    no_worker_start()
    passed("ordinary status reports gated/ready; ordinary stop closes controlled workers")

    # Token content may not reach diagnostics or runtime/archive; no test prints it.
    check(TOKEN.read_bytes() == token, "lifecycle changed Token")
    for out in outputs:
        check(token not in out.encode(), "Token leaked in management output")
    for root in (RUNTIME, ARCHIVE, LOGS):
        for path in root.rglob("*"):
            if path.is_file():
                check(token not in path.read_bytes(), "Token leaked outside secrets directory")
    check(token not in ENV.read_bytes(), "Token entered dotenv")
    no_worker_start()
    passed("failures do not leak Token, restore sessions, or open Poll/Delivery gate")
    print("BOUNDARY: real Debian/user/sudo/files/Bootstrap/venv; Docker and later Controller "
          "lifecycle responses simulated. Real QR, Hermes, Docker daemon, PostgreSQL, and "
          "host reboot acceptance are not performed here.", flush=True)


if __name__ == "__main__":
    main()
