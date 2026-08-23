#!/usr/bin/env python3
"""Validate the deployed Gateway consumer contract without exposing secrets."""

from __future__ import annotations

import argparse
import enum
import hmac
import json
import os
import posixpath
import re
import stat
import sys
from pathlib import Path


CONTRACT_VERSION = "1"
TOKEN_FILE_KEY = "CF_AGENT_WECHAT_TOKEN_FILE"
TOKEN_KEY = "CF_AGENT_WECHAT_TOKEN"
MAX_INPUT_BYTES = 1024 * 1024
MAX_ATTESTATION_BYTES = 4 * 1024 * 1024
WORKER_TOKEN_PATH = "/run/secrets/cf-agent-wechat-auth-token"
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
CONTRACT_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
PRODUCER_REPOSITORY = re.compile(
    r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}"
)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
TOKEN_PATTERN = re.compile(rb"[0-9a-f]{64}")


class ContractError(Exception):
    """A deliberately non-sensitive contract validation failure."""


def read_regular_file(path: Path, *, max_bytes: int) -> bytes:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ContractError("input is not a single-link regular file")
    if metadata.st_size > max_bytes:
        raise ContractError("input exceeds its size limit")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino)
            != (metadata.st_dev, metadata.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
        ):
            raise ContractError("input changed while it was opened")
        if opened.st_size > max_bytes:
            raise ContractError("input exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ContractError("input exceeds its size limit")
            chunks.append(chunk)
        final = os.fstat(descriptor)
        if (
            final.st_size != opened.st_size
            or final.st_ctime_ns != opened.st_ctime_ns
        ):
            raise ContractError("input changed while it was read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_token(path: Path) -> bytes:
    value = read_regular_file(path, max_bytes=8193)
    if value.endswith(b"\n"):
        value = value[:-1]
    if TOKEN_PATTERN.fullmatch(value) is None:
        raise ContractError("Agent Token source is invalid")
    return value


def decode_gateway_environment(path: Path) -> list[str]:
    raw = read_regular_file(path, max_bytes=MAX_INPUT_BYTES)
    decode_error = False
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        decode_error = True
        text = ""
    if decode_error:
        raise ContractError("Gateway environment is not valid UTF-8") from None
    if text.startswith("\ufeff"):
        raise ContractError("Gateway environment must not contain a byte-order mark")

    lines: list[str] = []
    for physical_line in text.split("\n"):
        if physical_line.endswith("\r"):
            line = physical_line[:-1]
        else:
            line = physical_line
        if "\r" in line:
            raise ContractError("Gateway environment has invalid line endings")
        if any(
            (
                ord(character) < 0x20 and character != "\t"
            )
            or 0x7F <= ord(character) <= 0x9F
            for character in line
        ):
            raise ContractError("Gateway environment contains a control character")
        lines.append(line)
    return lines


def read_gateway_file_credential(path: Path, expected_worker_path: str) -> None:
    credential_path: str | None = None
    for line in decode_gateway_environment(path):
        stripped = line.lstrip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        if not match:
            if TOKEN_KEY in line or TOKEN_FILE_KEY in line:
                raise ContractError(
                    "Gateway Agent credential assignment uses unsupported syntax"
                )
            continue
        key, value = match.groups()
        if key == TOKEN_KEY:
            raise ContractError(
                "Gateway plaintext Agent Token credential is forbidden"
            )
        if key != TOKEN_FILE_KEY:
            continue
        if credential_path is not None:
            raise ContractError("Gateway file credential assignment is duplicated")
        if value != expected_worker_path:
            raise ContractError("Gateway file credential path is incompatible")
        credential_path = value
    if credential_path is None:
        raise ContractError("Gateway file credential assignment is missing")


def read_legacy_gateway_token(path: Path) -> bytes:
    token: bytes | None = None
    for line in decode_gateway_environment(path):
        stripped = line.lstrip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        if not match:
            if TOKEN_KEY in line or TOKEN_FILE_KEY in line:
                raise ContractError(
                    "legacy Gateway Token assignment uses unsupported syntax"
                )
            continue
        key, value = match.groups()
        if key == TOKEN_FILE_KEY:
            raise ContractError("legacy audit input mixes credential modes")
        if key != TOKEN_KEY:
            continue
        if token is not None:
            raise ContractError("legacy Gateway Token assignment is duplicated")
        encoded = value.encode("utf-8")
        if TOKEN_PATTERN.fullmatch(encoded) is None:
            raise ContractError("legacy Gateway Token assignment is invalid")
        token = encoded
    if token is None:
        raise ContractError("legacy Gateway Token assignment is missing")
    return token


class LegacyTokenAuditResult(enum.Enum):
    """A migration finding that can never authorize a production deployment."""

    MATCH_INCOMPATIBLE = "token_match_but_production_incompatible"
    MISMATCH_INCOMPATIBLE = "token_mismatch_and_production_incompatible"

    @property
    def production_compatible(self) -> bool:
        return False


def audit_legacy_token_agreement(
    token_path: Path, gateway_environment_path: Path
) -> LegacyTokenAuditResult:
    agent_token = read_token(token_path)
    gateway_token = read_legacy_gateway_token(gateway_environment_path)
    try:
        matches = hmac.compare_digest(agent_token, gateway_token)
    finally:
        agent_token = b""
        gateway_token = b""
    if matches:
        return LegacyTokenAuditResult.MATCH_INCOMPATIBLE
    return LegacyTokenAuditResult.MISMATCH_INCOMPATIBLE


def object_without_duplicate_keys(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError("JSON input has a duplicate key")
        result[key] = value
    return result


def reject_json_constant(_value: str) -> object:
    raise ContractError("JSON input contains a non-JSON value")


def parse_json_bytes(raw: bytes, *, label: str) -> object:
    parse_error = False
    try:
        result = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=object_without_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError):
        parse_error = True
        result = None
    if parse_error:
        raise ContractError(f"{label} is invalid") from None
    return result


def read_bounded_standard_input() -> bytes:
    stream = getattr(sys.stdin, "buffer", sys.stdin)
    raw = stream.read(MAX_ATTESTATION_BYTES + 1)
    if isinstance(raw, str):
        encode_error = False
        try:
            raw = raw.encode("utf-8")
        except UnicodeEncodeError:
            encode_error = True
            raw = b""
        if encode_error:
            raise ContractError("Gateway attestation input is invalid") from None
    if len(raw) > MAX_ATTESTATION_BYTES:
        raise ContractError("Gateway attestation input exceeds its size limit")
    if not raw:
        raise ContractError("Gateway attestation input is missing")
    return raw


def require_token_absent(raw: bytes, token: bytes) -> None:
    if token in raw:
        raise ContractError("Gateway attestation contains Agent Token bytes")


def require_compose_environment(
    service: dict[str, object], expected_worker_path: str
) -> None:
    environment = service.get("environment")
    if not isinstance(environment, dict) or any(
        not isinstance(key, str) for key in environment
    ):
        raise ContractError("Gateway worker environment is invalid")
    if TOKEN_KEY in environment:
        raise ContractError("Gateway worker exposes a plaintext Agent Token")
    if environment.get(TOKEN_FILE_KEY) != expected_worker_path:
        raise ContractError("Gateway worker file credential pointer is invalid")


def require_inspect_environment(
    config: dict[str, object], expected_worker_path: str
) -> None:
    entries = config.get("Env")
    if not isinstance(entries, list):
        raise ContractError("Gateway worker inspect environment is invalid")
    environment: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, str) or "=" not in entry:
            raise ContractError("Gateway worker inspect environment is invalid")
        key, value = entry.split("=", 1)
        if key in environment:
            raise ContractError("Gateway worker inspect environment is duplicated")
        environment[key] = value
    if TOKEN_KEY in environment:
        raise ContractError("Gateway worker exposes a plaintext Agent Token")
    if environment.get(TOKEN_FILE_KEY) != expected_worker_path:
        raise ContractError("Gateway worker file credential pointer is invalid")


def bind_source_exposes_path(source: object, protected_path: str) -> bool:
    """Return whether a host bind source contains the protected path."""
    if not isinstance(source, str) or not source:
        return False
    try:
        if not os.path.isabs(source) or not os.path.isabs(protected_path):
            return False
        normalized_source = os.path.normcase(os.path.realpath(source))
        normalized_protected = os.path.normcase(
            os.path.realpath(protected_path)
        )
        return (
            os.path.commonpath((normalized_source, normalized_protected))
            == normalized_source
        )
    except (OSError, ValueError):
        return False

def container_target_contains_path(target: object, protected_path: str) -> bool:
    """Return whether a container mount target contains the protected path."""
    if not isinstance(target, str) or not target:
        return False
    try:
        if not posixpath.isabs(target) or not posixpath.isabs(protected_path):
            return False
        normalized_target = posixpath.normpath(target)
        normalized_protected = posixpath.normpath(protected_path)
        return (
            posixpath.commonpath((normalized_target, normalized_protected))
            == normalized_target
        )
    except ValueError:
        return False

def require_safe_path_text(value: object, message: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        raise ContractError(message)
    return value


def normalize_container_target(
    target: object,
    *,
    message: str,
    default_root: str | None = None,
) -> str:
    value = require_safe_path_text(target, message)
    if posixpath.isabs(value):
        normalized = posixpath.normpath(value)
    elif default_root is not None:
        normalized = posixpath.normpath(posixpath.join(default_root, value))
    else:
        raise ContractError(message)
    if not posixpath.isabs(normalized):
        raise ContractError(message)
    return "/" + normalized.lstrip("/")


def require_target_does_not_overlay_token(
    target: str,
    protected_path: str,
    message: str,
) -> None:
    if container_target_contains_path(target, protected_path):
        raise ContractError(message)


def require_matching_target_keys(
    entry: dict[str, object],
    keys: tuple[str, ...],
    *,
    message: str,
    default_root: str | None = None,
) -> str:
    values = [entry[key] for key in keys if key in entry]
    if not values:
        raise ContractError(message)
    normalized = {
        normalize_container_target(
            value,
            message=message,
            default_root=default_root,
        )
        for value in values
    }
    if len(normalized) != 1:
        raise ContractError(message)
    return normalized.pop()


def require_device_permissions(value: object, message: str) -> None:
    if not isinstance(value, str) or not value:
        raise ContractError(message)
    if any(character not in "rwm" for character in value):
        raise ContractError(message)
    if len(set(value)) != len(value):
        raise ContractError(message)



def require_no_compose_token_target_overlays(
    services: dict[str, object],
    protected_path: str,
) -> None:
    overlay_error = "Gateway Compose service overlays the Agent Token target"
    invalid_error = "Gateway Compose service target inventory is invalid"

    for service_name, service in services.items():
        if not isinstance(service_name, str) or not isinstance(service, dict):
            raise ContractError("Gateway Compose service inventory is invalid")

        for collection_name, default_root in (
            ("secrets", "/run/secrets"),
            ("configs", "/"),
        ):
            entries = service.get(collection_name, [])
            if not isinstance(entries, list):
                raise ContractError(invalid_error)
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ContractError(invalid_error)
                source = require_safe_path_text(
                    entry.get("source"),
                    invalid_error,
                )
                target_value = (
                    entry["target"] if "target" in entry else source
                )
                target = normalize_container_target(
                    target_value,
                    message=invalid_error,
                    default_root=default_root,
                )
                require_target_does_not_overlay_token(
                    target,
                    protected_path,
                    overlay_error,
                )

        tmpfs_entries = service.get("tmpfs", [])
        if not isinstance(tmpfs_entries, list):
            raise ContractError(invalid_error)
        for entry in tmpfs_entries:
            if isinstance(entry, str):
                target_value, separator, options = entry.partition(":")
                if separator and (
                    not options
                    or any(
                        ord(character) < 0x20 or ord(character) == 0x7F
                        for character in options
                    )
                ):
                    raise ContractError(invalid_error)
                target = normalize_container_target(
                    target_value,
                    message=invalid_error,
                )
            elif isinstance(entry, dict):
                target = require_matching_target_keys(
                    entry,
                    ("target", "source"),
                    message=invalid_error,
                )
            else:
                raise ContractError(invalid_error)
            require_target_does_not_overlay_token(
                target,
                protected_path,
                overlay_error,
            )

        device_entries = service.get("devices", [])
        if not isinstance(device_entries, list):
            raise ContractError(invalid_error)
        for entry in device_entries:
            if isinstance(entry, str):
                parts = entry.split(":")
                if len(parts) not in (2, 3):
                    raise ContractError(invalid_error)
                normalize_container_target(
                    parts[0],
                    message=invalid_error,
                )
                target = normalize_container_target(
                    parts[1],
                    message=invalid_error,
                )
                if len(parts) == 3:
                    require_device_permissions(parts[2], invalid_error)
            elif isinstance(entry, dict):
                require_matching_target_keys(
                    entry,
                    ("path_on_host", "source"),
                    message=invalid_error,
                )
                target = require_matching_target_keys(
                    entry,
                    ("path_in_container", "target"),
                    message=invalid_error,
                )
                permission_values = [
                    entry[key]
                    for key in ("cgroup_permissions", "permissions")
                    if key in entry
                ]
                for permissions in permission_values:
                    require_device_permissions(permissions, invalid_error)
                if len(set(permission_values)) > 1:
                    raise ContractError(invalid_error)
            else:
                raise ContractError(invalid_error)
            require_target_does_not_overlay_token(
                target,
                protected_path,
                overlay_error,
            )


def require_no_inspect_token_target_overlays(
    item: dict[str, object],
    protected_path: str,
) -> None:
    overlay_error = "Gateway worker inspect overlays the Agent Token target"
    invalid_error = "Gateway worker inspect target inventory is invalid"
    host_config = item.get("HostConfig")
    if not isinstance(host_config, dict):
        raise ContractError(invalid_error)

    tmpfs_entries = host_config.get("Tmpfs")
    if tmpfs_entries is None:
        tmpfs_entries = {}
    if not isinstance(tmpfs_entries, dict):
        raise ContractError(invalid_error)
    for target_value, options in tmpfs_entries.items():
        target = normalize_container_target(
            target_value,
            message=invalid_error,
        )
        if not isinstance(options, str):
            raise ContractError(invalid_error)
        require_target_does_not_overlay_token(
            target,
            protected_path,
            overlay_error,
        )

    device_entries = host_config.get("Devices")
    if device_entries is None:
        device_entries = []
    if not isinstance(device_entries, list):
        raise ContractError(invalid_error)
    for entry in device_entries:
        if not isinstance(entry, dict):
            raise ContractError(invalid_error)
        normalize_container_target(
            entry.get("PathOnHost"),
            message=invalid_error,
        )
        target = normalize_container_target(
            entry.get("PathInContainer"),
            message=invalid_error,
        )
        require_device_permissions(
            entry.get("CgroupPermissions"),
            invalid_error,
        )
        require_target_does_not_overlay_token(
            target,
            protected_path,
            overlay_error,
        )


def require_no_compose_token_indirection(
    payload: dict[str, object],
    protected_path: str,
) -> None:
    for collection_name in ("secrets", "configs"):
        definitions = payload.get(collection_name, {})
        if not isinstance(definitions, dict):
            raise ContractError(
                "Gateway Compose Secret/config inventory is invalid"
            )
        for name, definition in definitions.items():
            if not isinstance(name, str) or not isinstance(definition, dict):
                raise ContractError(
                    "Gateway Compose Secret/config definition is invalid"
                )
            if bind_source_exposes_path(
                definition.get("file"), protected_path
            ):
                raise ContractError(
                    "Gateway Compose reuses the Agent Token authority"
                )

    volumes = payload.get("volumes", {})
    if not isinstance(volumes, dict):
        raise ContractError("Gateway Compose volume inventory is invalid")
    for name, definition in volumes.items():
        if not isinstance(name, str):
            raise ContractError("Gateway Compose volume definition is invalid")
        if definition is None:
            continue
        if not isinstance(definition, dict):
            raise ContractError("Gateway Compose volume definition is invalid")
        driver_options = definition.get("driver_opts", {})
        if not isinstance(driver_options, dict):
            raise ContractError("Gateway Compose volume driver options are invalid")
        if bind_source_exposes_path(
            driver_options.get("device"), protected_path
        ):
            raise ContractError(
                "Gateway Compose volume reuses the Agent Token authority"
            )


def require_no_cross_service_token_mounts(
    services: dict[str, object],
    allowed_service_name: str,
    protected_path: str,
) -> None:
    for name, candidate in services.items():
        if not isinstance(name, str) or not isinstance(candidate, dict):
            raise ContractError("Gateway Compose service inventory is invalid")
        volumes_from = candidate.get("volumes_from", [])
        if not isinstance(volumes_from, list):
            raise ContractError("Gateway Compose volumes_from is invalid")
        if volumes_from:
            raise ContractError("Gateway Compose volumes_from is forbidden")
        if name == allowed_service_name:
            continue
        volumes = candidate.get("volumes", [])
        if not isinstance(volumes, list):
            raise ContractError("Gateway Compose service volumes are invalid")
        for volume in volumes:
            if not isinstance(volume, dict):
                raise ContractError("Gateway Compose service volume is invalid")
            if (
                volume.get("type") == "bind"
                and bind_source_exposes_path(
                    volume.get("source"), protected_path
                )
            ):
                raise ContractError(
                    "Gateway Compose exposes the Agent Token through another service"
                )



def require_compose_token_mount(
    service: dict[str, object], host_path: str, worker_path: str
) -> None:
    volumes = service.get("volumes")
    if not isinstance(volumes, list):
        raise ContractError("Gateway worker Token mount is missing")
    relevant: list[dict[str, object]] = []
    for volume in volumes:
        if not isinstance(volume, dict):
            raise ContractError("Gateway worker volume definition is invalid")
        if (
            volume.get("source") == host_path
            or container_target_contains_path(
                volume.get("target"), worker_path
            )
            or (
                volume.get("type") == "bind"
                and bind_source_exposes_path(volume.get("source"), host_path)
            )
        ):
            relevant.append(volume)
    if len(relevant) != 1:
        raise ContractError("Gateway worker Token mount is not unique")
    mount = relevant[0]
    if (
        mount.get("type") != "bind"
        or mount.get("source") != host_path
        or mount.get("target") != worker_path
        or mount.get("read_only") is not True
    ):
        raise ContractError("Gateway worker Token mount is incompatible")


def require_inspect_token_mount(
    item: dict[str, object], host_path: str, worker_path: str
) -> None:
    mounts = item.get("Mounts")
    if not isinstance(mounts, list):
        raise ContractError("Gateway worker inspect Token mount is missing")
    relevant: list[dict[str, object]] = []
    for mount in mounts:
        if not isinstance(mount, dict):
            raise ContractError("Gateway worker inspect mount is invalid")
        if (
            mount.get("Source") == host_path
            or container_target_contains_path(
                mount.get("Destination"), worker_path
            )
            or (
                mount.get("Type") == "bind"
                and bind_source_exposes_path(mount.get("Source"), host_path)
            )
        ):
            relevant.append(mount)
    if len(relevant) != 1:
        raise ContractError("Gateway worker inspect Token mount is not unique")
    mount = relevant[0]
    if (
        mount.get("Type") != "bind"
        or mount.get("Source") != host_path
        or mount.get("Destination") != worker_path
        or mount.get("RW") is not False
    ):
        raise ContractError("Gateway worker inspect Token mount is incompatible")


def attest_gateway_compose(
    raw: bytes,
    token: bytes,
    *,
    project: str,
    service_name: str,
    token_host_path: str,
    token_worker_path: str,
) -> None:
    require_token_absent(raw, token)
    payload = parse_json_bytes(raw, label="Gateway Compose attestation")
    if not isinstance(payload, dict) or payload.get("name") != project:
        raise ContractError("Gateway Compose project identity is incompatible")
    require_no_compose_token_indirection(payload, token_host_path)
    services = payload.get("services")
    if not isinstance(services, dict):
        raise ContractError("Gateway Compose service inventory is invalid")
    require_no_compose_token_target_overlays(services, token_worker_path)
    require_no_cross_service_token_mounts(
        services,
        service_name,
        token_host_path,
    )
    service = services.get(service_name)
    if not isinstance(service, dict):
        raise ContractError("Gateway Compose worker service is missing")
    if service.get("restart") != "no":
        raise ContractError("Gateway worker restart policy is incompatible")
    require_compose_environment(service, token_worker_path)
    require_compose_token_mount(service, token_host_path, token_worker_path)


def attest_gateway_worker_inspect(
    raw: bytes,
    token: bytes,
    *,
    project: str,
    service_name: str,
    token_host_path: str,
    token_worker_path: str,
) -> None:
    require_token_absent(raw, token)
    payload = parse_json_bytes(raw, label="Gateway worker inspect attestation")
    if not isinstance(payload, list) or len(payload) != 1:
        raise ContractError("Gateway worker inspect inventory is invalid")
    item = payload[0]
    if not isinstance(item, dict):
        raise ContractError("Gateway worker inspect object is invalid")
    config = item.get("Config")
    if not isinstance(config, dict):
        raise ContractError("Gateway worker inspect config is invalid")
    labels = config.get("Labels")
    if (
        not isinstance(labels, dict)
        or labels.get("com.docker.compose.project") != project
        or labels.get("com.docker.compose.service") != service_name
    ):
        raise ContractError("Gateway worker inspect identity is incompatible")
    require_no_inspect_token_target_overlays(item, token_worker_path)
    host_config = item.get("HostConfig")
    restart_policy = (
        host_config.get("RestartPolicy")
        if isinstance(host_config, dict)
        else None
    )
    if (
        not isinstance(restart_policy, dict)
        or restart_policy.get("Name") != "no"
        or type(restart_policy.get("MaximumRetryCount")) is not int
        or restart_policy.get("MaximumRetryCount") != 0
    ):
        raise ContractError(
            "Gateway worker inspect restart policy is incompatible"
        )
    require_inspect_environment(config, token_worker_path)
    require_inspect_token_mount(item, token_host_path, token_worker_path)


def exact_json_equal(actual: object, expected: object) -> bool:
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        if actual.keys() != expected.keys():
            return False
        return all(
            exact_json_equal(actual[key], expected_value)
            for key, expected_value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            exact_json_equal(actual_value, expected_value)
            for actual_value, expected_value in zip(actual, expected)
        )
    return actual == expected


def require_exact_contract(path: Path, expected: dict[str, object]) -> None:
    raw = read_regular_file(path, max_bytes=MAX_INPUT_BYTES)
    payload = parse_json_bytes(raw, label="Gateway runtime contract")
    if not exact_json_equal(payload, expected):
        raise ContractError("Gateway runtime contract is incompatible")


def expected_contract(arguments: argparse.Namespace) -> dict[str, object]:
    identifiers = (arguments.alias, arguments.service, arguments.project)
    paths = (arguments.token_file, arguments.checker)
    if (
        not 1 <= arguments.port <= 65535
        or arguments.max_age <= 0
        or any(CONTRACT_IDENTIFIER.fullmatch(value) is None for value in identifiers)
        or PRODUCER_REPOSITORY.fullmatch(arguments.producer_repository) is None
        or SHA256_PATTERN.fullmatch(arguments.checker_sha256) is None
        or any(not Path(value).is_absolute() for value in paths)
        or any(
            any(
                ord(character) < 0x20
                or 0x7F <= ord(character) <= 0x9F
                for character in value
            )
            for value in (
                *identifiers,
                *paths,
                arguments.producer_repository,
                arguments.checker_sha256,
            )
        )
    ):
        raise ContractError("Gateway runtime contract arguments are invalid")
    return {
        "contractVersion": CONTRACT_VERSION,
        "producer": {
            "repository": arguments.producer_repository,
            "checkerSha256": arguments.checker_sha256,
        },
        "agent": {
            "networkAlias": arguments.alias,
            "port": arguments.port,
            "tokenAuthority": {
                "hostPath": str(Path(arguments.token_file)),
                "ownership": "root:root",
                "mode": "0600",
            },
        },
        "gateway": {
            "service": arguments.service,
            "composeProject": arguments.project,
            "checker": arguments.checker,
            "checkerInterfaceVersion": 1,
            "heartbeatMaxAgeSeconds": arguments.max_age,
            "requiresDockerHealth": True,
            "requiresSuccessfulPoll": True,
            "requiresLoggedIn": True,
            "silentOutput": True,
            "checkerExecution": {
                "caller": "management-user",
                "sudo": False,
                "dockerSocketAccess": False,
                "producerLinuxProof": "required",
            },
            "lifecycle": {
                "restartPolicy": "no",
                "bootPolicy": "manual-after-fresh-qr",
                "producerLinuxProof": "required",
            },
            "credential": {
                "type": "file",
                "environmentVariable": TOKEN_FILE_KEY,
                "workerPath": WORKER_TOKEN_PATH,
                "readOnly": True,
                "forbiddenEnvironmentVariable": TOKEN_KEY,
                "workerReadabilityProof": "producer-linux-integration",
            },
        },
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--contract-file", required=True)
    parser.add_argument("--gateway-env", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--checker", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--max-age", required=True, type=int)
    parser.add_argument("--producer-repository", required=True)
    parser.add_argument("--checker-sha256", required=True)
    parser.add_argument(
        "--attestation-kind",
        choices=("compose", "worker-inspect"),
        default="compose",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        require_exact_contract(
            Path(arguments.contract_file), expected_contract(arguments)
        )
        read_gateway_file_credential(
            Path(arguments.gateway_env), WORKER_TOKEN_PATH
        )
        agent_token = read_token(Path(arguments.token_file))
        attestation = read_bounded_standard_input()
        attestation_arguments = {
            "project": arguments.project,
            "service_name": arguments.service,
            "token_host_path": str(Path(arguments.token_file)),
            "token_worker_path": WORKER_TOKEN_PATH,
        }
        if arguments.attestation_kind == "compose":
            attest_gateway_compose(
                attestation, agent_token, **attestation_arguments
            )
        else:
            attest_gateway_worker_inspect(
                attestation, agent_token, **attestation_arguments
            )
    except ContractError as exc:
        print(f"Gateway contract verification failed: {exc}", file=sys.stderr)
        return 1
    except OSError:
        print(
            "Gateway contract verification failed: "
            "required input could not be read safely",
            file=sys.stderr,
        )
        return 1
    finally:
        if "agent_token" in locals():
            agent_token = b""
        if "attestation" in locals():
            attestation = b""
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
