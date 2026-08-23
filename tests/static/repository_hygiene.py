#!/usr/bin/env python3
"""Dependency-free repository text, Markdown, secret, and CI policy checks."""

from __future__ import annotations

import argparse
import html
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


BINARY_SUFFIXES = {
    ".7z",
    ".avi",
    ".bmp",
    ".bz2",
    ".class",
    ".dll",
    ".doc",
    ".docx",
    ".eot",
    ".exe",
    ".gif",
    ".gz",
    ".ico",
    ".jar",
    ".jpeg",
    ".jpg",
    ".mov",
    ".mp3",
    ".mp4",
    ".otf",
    ".pdf",
    ".png",
    ".pyc",
    ".so",
    ".tar",
    ".tgz",
    ".ttf",
    ".webm",
    ".webp",
    ".woff",
    ".woff2",
    ".xls",
    ".xlsx",
    ".xz",
    ".zip",
}

KNOWN_TEXT_SUFFIXES = {
    ".cfg",
    ".conf",
    ".css",
    ".csv",
    ".env",
    ".example",
    ".gitattributes",
    ".gitignore",
    ".html",
    ".ini",
    ".js",
    ".json",
    ".jsx",
    ".md",
    ".properties",
    ".py",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}

KNOWN_TEXT_NAMES = {
    ".dockerignore",
    ".editorconfig",
    ".gitattributes",
    ".gitignore",
    ".gitkeep",
    "Dockerfile",
    "LICENSE",
    "Makefile",
}

MARKDOWN_LINK_RE = re.compile(
    r"!?\[[^\]\n]*\]\("
    r"(?P<target><[^>\n]+>|[^\s)]+)"
    r"(?:\s+(?:\"[^\"\n]*\"|'[^'\n]*'|\([^\n)]*\)))?\)"
)
ATX_HEADING_RE = re.compile(r"^ {0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$")
EXPLICIT_ANCHOR_RE = re.compile(
    r"<(?:a\s+(?:[^>]*?\s)?(?:id|name)|[^>]+\sid)=[\"']([^\"']+)[\"']",
    re.IGNORECASE,
)

PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN[ \t]+(?:RSA[ \t]+|EC[ \t]+|DSA[ \t]+|OPENSSH[ \t]+)?"
    r"PRIVATE[ \t]+KEY-----"
)

COMMON_SECRET_PATTERNS = (
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,255}\b")),
    (
        "GitHub fine-grained token",
        re.compile(r"\bgithub_pat_[A-Za-z0-9_]{50,255}\b"),
    ),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,255}\b")),
    ("GitLab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,255}\b")),
    ("npm token", re.compile(r"\bnpm_[A-Za-z0-9]{30,255}\b")),
    ("Stripe live key", re.compile(r"\bsk_live_[A-Za-z0-9]{20,255}\b")),
    (
        "OpenAI or Anthropic key",
        re.compile(r"\bsk-(?:(?:proj|svcacct|ant)-)?[A-Za-z0-9_-]{32,255}\b"),
    ),
    (
        "JWT",
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
            r"[A-Za-z0-9_-]{8,}\b"
        ),
    ),
)

GENERIC_SECRET_ASSIGNMENT_RE = re.compile(
    r"^[ \t]*(?:export[ \t]+)?"
    r"(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)[ \t]*(?:=|:)[ \t]*"
    r"(?P<value>[^\r\n#]+)",
    re.MULTILINE,
)

SAFE_SECRET_MARKERS = {
    "changeme",
    "dummy",
    "example",
    "fake",
    "fixture",
    "mock",
    "never-printed",
    "placeholder",
    "redacted",
    "sentinel",
    "test-secret",
    "test-token",
}

SECRET_KEY_PARTS = ("TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "ACCESS_KEY")
NON_SECRET_KEY_SUFFIXES = (
    "_FILE",
    "_PATH",
    "_URL",
    "_URI",
    "_ENDPOINT",
    "_TIMEOUT",
    "_PREFIX",
    "_NAME",
    "_READER",
    "_STATUS",
    "_OUTPUT",
    "_READY",
    "_LENGTH",
    "_SOURCE",
    "_MOUNT",
    "_DIR",
    "_ROOT",
)

PRODUCTION_QR_SCRIPTS = (
    "scripts/start-qr-login.sh",
    "scripts/login.sh",
    "scripts/qr_login.py",
)

WORKFLOW_SECRET_EXPRESSION_RE = re.compile(
    r"\$\{\{[ \t]*secrets\.[^}\r\n]*(?:WECHAT|TOKEN|QR)[^}\r\n]*\}\}",
    re.IGNORECASE,
)
WORKFLOW_SENSITIVE_ENV_RE = re.compile(
    r"^[ \t]*(?:AGENT_WECHAT_(?:AUTH_)?TOKEN|WECHAT_QR(?:_DATA|_PAYLOAD|_CONTENT)?|"
    r"QR_(?:DATA|PAYLOAD|CONTENT))[ \t]*:",
    re.IGNORECASE | re.MULTILINE,
)
WORKFLOW_OUTPUT_RE = re.compile(
    r"(?im)^[ \t]*(?:sudo\s+(?:-[^\s]+\s+)*)?"
    r"(?:echo|printf|cat|tee|head|tail|printenv)\b[^\r\n]*"
    r"(?:\$\{?[^}\s]*(?:TOKEN|SECRET|PASSWORD|QR_(?:DATA|PAYLOAD|CONTENT))[^}\s]*\}?|"
    r"auth-token|qrData|qr[_-]?(?:payload|content))"
)
WORKFLOW_TRACE_RE = re.compile(
    r"(?im)(?:^|[;&|][ \t]*)[ \t]*"
    r"(?:set[ \t]+(?:-[A-Za-z]*x[A-Za-z]*|-o[ \t]+xtrace)|"
    r"bash[ \t]+-[A-Za-z]*x[A-Za-z]*)\b"
)


@dataclass(frozen=True, order=True)
class Issue:
    path: str
    line: int
    column: int
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.line}:{self.column}: {self.message}"


@dataclass(frozen=True)
class ScanResult:
    issues: tuple[Issue, ...]
    text_files: int
    markdown_files: int
    workflow_files: int


def _line_and_column(text: str, offset: int) -> tuple[int, int]:
    line = text.count("\n", 0, offset) + 1
    previous_newline = text.rfind("\n", 0, offset)
    return line, offset - previous_newline


def _issue(path: PurePosixPath, text: str, offset: int, message: str) -> Issue:
    line, column = _line_and_column(text, offset)
    return Issue(path.as_posix(), line, column, message)


def _looks_like_text(path: PurePosixPath, data: bytes) -> bool:
    suffix = path.suffix.lower()
    if suffix in BINARY_SUFFIXES:
        return False
    if suffix in KNOWN_TEXT_SUFFIXES or path.name in KNOWN_TEXT_NAMES:
        return True
    return b"\0" not in data


def _is_forbidden_control(character: str) -> bool:
    codepoint = ord(character)
    return (codepoint < 0x20 and character not in "\t\n\r") or codepoint == 0x7F


def _scan_controls(path: PurePosixPath, text: str) -> list[Issue]:
    issues: list[Issue] = []
    for offset, character in enumerate(text):
        if _is_forbidden_control(character):
            issues.append(
                _issue(
                    path,
                    text,
                    offset,
                    f"forbidden control character U+{ord(character):04X}",
                )
            )
    return issues


def _safe_secret_value(value: str) -> bool:
    candidate = value.strip().rstrip(",").strip("'\"")
    lowered = candidate.casefold()
    if not candidate or len(candidate) < 16:
        return True
    if any(marker in lowered for marker in SAFE_SECRET_MARKERS):
        return True
    if candidate.startswith(("$", "<", "/", "./", "../")):
        return True
    if "${" in candidate or "$(" in candidate or "{{" in candidate:
        return True
    if re.fullmatch(r"sha256:[0-9a-fA-F]{64}", candidate):
        return True
    if len(set(candidate)) <= 2:
        return True
    return False


def _literal_assignment_value(value: str) -> str | None:
    """Return a complete scalar literal, not a function call or expression."""
    candidate = value.strip().rstrip(",").strip()
    quoted = re.fullmatch(r"([\"'])(.*)\1", candidate)
    if quoted is not None:
        return quoted.group(2)
    if re.fullmatch(r"[A-Za-z0-9_+./:=@-]+", candidate):
        return candidate
    return None


def _is_secret_key(key: str) -> bool:
    normalized = key.upper().replace("-", "_").replace(".", "_")
    if normalized.endswith(NON_SECRET_KEY_SUFFIXES):
        return False
    return normalized == "TOKEN" or any(
        normalized.endswith(f"_{part}") or normalized == part
        for part in SECRET_KEY_PARTS
    )


def scan_secrets(path: PurePosixPath, text: str) -> list[Issue]:
    issues: list[Issue] = []
    for match in PRIVATE_KEY_RE.finditer(text):
        issues.append(_issue(path, text, match.start(), "private-key block detected"))

    for label, pattern in COMMON_SECRET_PATTERNS:
        for match in pattern.finditer(text):
            if not _safe_secret_value(match.group(0)):
                issues.append(
                    _issue(path, text, match.start(), f"possible live {label} detected")
                )

    for match in GENERIC_SECRET_ASSIGNMENT_RE.finditer(text):
        key = match.group("key")
        value = _literal_assignment_value(match.group("value"))
        if value is not None and _is_secret_key(key) and not _safe_secret_value(value):
            issues.append(
                _issue(
                    path,
                    text,
                    match.start("value"),
                    f"possible live credential assigned to {key}",
                )
            )
    return issues


def _fence_state(text: str) -> tuple[list[tuple[int, str, int]], set[int]]:
    open_fence: tuple[int, str, int] | None = None
    unmatched: list[tuple[int, str, int]] = []
    fenced_lines: set[int] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        marker_match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if open_fence is None:
            if marker_match is not None:
                marker = marker_match.group(1)
                open_fence = (line_number, marker[0], len(marker))
                fenced_lines.add(line_number)
            continue

        fenced_lines.add(line_number)
        _, character, length = open_fence
        closing = re.match(
            rf"^ {{0,3}}{re.escape(character)}{{{length},}}[ \t]*$",
            line,
        )
        if closing is not None:
            open_fence = None

    if open_fence is not None:
        unmatched.append(open_fence)
    return unmatched, fenced_lines


def _strip_inline_markdown(value: str) -> str:
    value = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", value)
    value = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", value)
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").replace("*", "").replace("~", "")
    return html.unescape(value)


def github_slug(value: str) -> str:
    """Approximate GitHub's heading slugger, including non-ASCII headings."""
    value = _strip_inline_markdown(value).strip().casefold()
    characters: list[str] = []
    for character in value:
        if character in "-_" or not unicodedata.category(character).startswith("P"):
            characters.append(character)
    return re.sub(r"\s+", "-", "".join(characters)).strip("-")


def markdown_anchors(text: str) -> set[str]:
    _, fenced_lines = _fence_state(text)
    anchors: set[str] = set()
    slug_counts: dict[str, int] = {}
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line_number in fenced_lines:
            continue
        for explicit in EXPLICIT_ANCHOR_RE.findall(line):
            anchors.add(html.unescape(explicit).casefold())
        heading = ATX_HEADING_RE.match(line)
        if heading is None:
            continue
        base = github_slug(heading.group(1))
        if not base:
            continue
        count = slug_counts.get(base, 0)
        slug_counts[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def _relative_path(root: Path, candidate: Path) -> PurePosixPath | None:
    try:
        return PurePosixPath(candidate.resolve().relative_to(root.resolve()).as_posix())
    except ValueError:
        return None


def _markdown_links(
    path: PurePosixPath,
    text: str,
    fenced_lines: set[int],
) -> list[tuple[int, int, str]]:
    links: list[tuple[int, int, str]] = []
    offset = 0
    for line_number, line in enumerate(text.splitlines(keepends=True), start=1):
        if line_number not in fenced_lines:
            searchable = re.sub(r"`[^`\n]*`", "", line)
            for match in MARKDOWN_LINK_RE.finditer(searchable):
                links.append((offset + match.start("target"), line_number, match.group("target")))
        offset += len(line)
    return links


def scan_markdown(
    root: Path,
    path: PurePosixPath,
    text: str,
    texts: dict[PurePosixPath, str],
    available_paths: set[PurePosixPath],
) -> list[Issue]:
    issues: list[Issue] = []
    unmatched, fenced_lines = _fence_state(text)
    for line_number, character, length in unmatched:
        issues.append(
            Issue(
                path.as_posix(),
                line_number,
                1,
                f"unclosed Markdown fence ({character * length})",
            )
        )

    source_file = root / Path(path.as_posix())
    for offset, _line_number, raw_target in _markdown_links(path, text, fenced_lines):
        target = raw_target[1:-1] if raw_target.startswith("<") else raw_target
        target = html.unescape(target)
        split = urlsplit(target)
        if split.scheme or split.netloc:
            continue
        decoded_path = unquote(split.path)
        fragment = unquote(split.fragment).casefold()
        if not decoded_path:
            target_path = path
        elif decoded_path.startswith("/"):
            target_path = PurePosixPath(decoded_path.lstrip("/"))
        else:
            candidate = source_file.parent / Path(decoded_path.replace("/", os.sep))
            normalized = _relative_path(root, candidate)
            if normalized is None:
                issues.append(
                    _issue(path, text, offset, f"relative link escapes repository: {target}")
                )
                continue
            target_path = normalized

        if target_path not in available_paths:
            directory_index = target_path / "README.md"
            if directory_index in available_paths:
                target_path = directory_index
            else:
                issues.append(
                    _issue(path, text, offset, f"relative link target does not exist: {target}")
                )
                continue

        if fragment and target_path.suffix.casefold() == ".md":
            target_text = texts.get(target_path)
            if target_text is None:
                issues.append(
                    _issue(path, text, offset, f"Markdown link target is not UTF-8 text: {target}")
                )
                continue
            if fragment not in markdown_anchors(target_text):
                issues.append(
                    _issue(path, text, offset, f"Markdown anchor does not exist: {target}")
                )
    return issues


def _extract_run_blocks(text: str) -> list[tuple[int, str]]:
    lines = text.splitlines()
    blocks: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(
            r"^(?P<indent>[ \t]*)(?:-[ \t]+)?run:[ \t]*(?P<body>.*)$",
            line,
        )
        if match is None:
            index += 1
            continue
        start_line = index + 1
        body = match.group("body").strip()
        if body and body[0] not in ">|":
            blocks.append((start_line, body))
            index += 1
            continue

        style = body[:1]
        parent_indent = len(match.group("indent").expandtabs(8))
        child_lines: list[str] = []
        index += 1
        while index < len(lines):
            child = lines[index]
            if child.strip():
                child_indent = len(child) - len(child.lstrip(" "))
                if child_indent <= parent_indent:
                    break
                child_lines.append(child[parent_indent + 2 :])
            else:
                child_lines.append("")
            index += 1
        separator = " " if style == ">" else "\n"
        blocks.append((start_line + 1, separator.join(child_lines)))
    return blocks


def _direct_qr_invocation(block: str) -> re.Match[str] | None:
    normalized = re.sub(r"\\\r?\n[ \t]*", " ", block)
    script_alternation = "|".join(re.escape(script) for script in PRODUCTION_QR_SCRIPTS)
    direct = re.compile(
        rf"(?im)(?:^|[;&|][ \t]*|\b(?:then|do)[ \t]+)"
        rf"[ \t]*"
        rf"(?:sudo[ \t]+(?:-[^\s]+[ \t]+)*)?"
        rf"(?:env[ \t]+(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]+[ \t]+)*)?"
        rf"(?:timeout[ \t]+[^\s]+[ \t]+)?"
        rf"(?:\./)?(?:{script_alternation})\b"
    )
    match = direct.search(normalized)
    if match is not None:
        return match

    interpreter = re.compile(
        rf"(?im)(?:^|[;&|][ \t]*|\b(?:then|do)[ \t]+)"
        rf"[ \t]*"
        rf"(?:sudo[ \t]+(?:-[^\s]+[ \t]+)*)?"
        rf"(?:(?:bash|sh)[ \t]+(?!-n\b)(?:-[^\s]+[ \t]+)*"
        rf"(?:\./)?scripts/(?:start-qr-login\.sh|login\.sh)|"
        rf"python(?:3)?[ \t]+(?:-[^\s]+[ \t]+)*(?:\./)?scripts/qr_login\.py)\b"
    )
    return interpreter.search(normalized)


def scan_workflow(path: PurePosixPath, text: str) -> list[Issue]:
    issues: list[Issue] = []
    for pattern, message in (
        (
            WORKFLOW_SECRET_EXPRESSION_RE,
            "workflow must not import a WeChat Token or QR secret",
        ),
        (
            WORKFLOW_SENSITIVE_ENV_RE,
            "workflow must not declare a Token or QR payload environment value",
        ),
    ):
        for match in pattern.finditer(text):
            issues.append(_issue(path, text, match.start(), message))

    for start_line, block in _extract_run_blocks(text):
        direct_match = _direct_qr_invocation(block)
        if direct_match is not None:
            line_offset = block.count("\n", 0, direct_match.start())
            issues.append(
                Issue(
                    path.as_posix(),
                    start_line + line_offset,
                    1,
                    "workflow directly invokes a production QR entrypoint/listener",
                )
            )
        for pattern, message in (
            (WORKFLOW_TRACE_RE, "workflow enables shell tracing, which can expose secrets"),
            (
                WORKFLOW_OUTPUT_RE,
                "workflow command may print a Token or QR payload",
            ),
        ):
            for match in pattern.finditer(block):
                line_offset = block.count("\n", 0, match.start())
                issues.append(
                    Issue(path.as_posix(), start_line + line_offset, 1, message)
                )

        if re.search(r"(?im)\bcurl\b[^\r\n]*(?:--trace(?:-ascii)?|-v|--verbose)\b", block):
            issues.append(
                Issue(
                    path.as_posix(),
                    start_line,
                    1,
                    "workflow uses verbose curl tracing, which can expose Authorization headers",
                )
            )
    return issues


def collect_repository_files(root: Path) -> list[PurePosixPath]:
    """Return tracked and not-ignored untracked files using NUL-safe Git output."""
    completed = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git ls-files failed: {detail}")
    decoded = completed.stdout.decode("utf-8")
    return sorted(
        PurePosixPath(entry)
        for entry in decoded.rstrip("\0").split("\0")
        if entry
    )


def scan_repository(
    root: Path,
    paths: list[PurePosixPath] | None = None,
) -> ScanResult:
    root = root.resolve()
    repository_paths = collect_repository_files(root) if paths is None else sorted(paths)
    available_paths = {
        path for path in repository_paths if (root / Path(path.as_posix())).is_file()
    }
    texts: dict[PurePosixPath, str] = {}
    issues: list[Issue] = []

    for path in sorted(available_paths):
        absolute = root / Path(path.as_posix())
        data = absolute.read_bytes()
        if not _looks_like_text(path, data):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            issues.append(
                Issue(
                    path.as_posix(),
                    1,
                    exc.start + 1,
                    f"text file is not valid UTF-8: {exc.reason}",
                )
            )
            continue
        texts[path] = text
        issues.extend(_scan_controls(path, text))
        issues.extend(scan_secrets(path, text))

    markdown_files = 0
    workflow_files = 0
    for path, text in sorted(texts.items()):
        if path.suffix.casefold() == ".md":
            markdown_files += 1
            issues.extend(scan_markdown(root, path, text, texts, available_paths))
        if (
            len(path.parts) >= 3
            and path.parts[0] == ".github"
            and path.parts[1] == "workflows"
            and path.suffix.casefold() in {".yml", ".yaml"}
        ):
            workflow_files += 1
            issues.extend(scan_workflow(path, text))

    return ScanResult(
        issues=tuple(sorted(set(issues))),
        text_files=len(texts),
        markdown_files=markdown_files,
        workflow_files=workflow_files,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository root (default: inferred from this script)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = scan_repository(args.repo_root)
    except (OSError, RuntimeError, UnicodeDecodeError) as exc:
        print(f"repository hygiene: ERROR: {exc}", file=sys.stderr)
        return 2

    if result.issues:
        for issue in result.issues:
            print(issue.render(), file=sys.stderr)
        print(
            f"repository hygiene: FAIL ({len(result.issues)} issue(s), "
            f"{result.text_files} text files, {result.markdown_files} Markdown files, "
            f"{result.workflow_files} workflow files)",
            file=sys.stderr,
        )
        return 1

    print(
        f"repository hygiene: PASS ({result.text_files} text files, "
        f"{result.markdown_files} Markdown files, "
        f"{result.workflow_files} workflow files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
