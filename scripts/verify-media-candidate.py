#!/usr/bin/env python3
"""Verify an offline, pinned upstream checkout and extracted candidate image.

This never queries an account, starts WeChat, or changes deployment settings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "upstream" / "media-retrieval.lock.json"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_source(source: Path, candidate: dict) -> None:
    actual = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != candidate["source_revision"]:
        raise ValueError("upstream source revision mismatch")
    subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "--quiet", "HEAD"], check=True)
    for relative, expected in candidate["source_files_sha256"].items():
        # Git's Windows checkout may convert line endings. Image files remain
        # byte-exact below; only source text has this explicit normalization.
        data = (source / relative).read_bytes().replace(b"\r\n", b"\n")
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"source checksum mismatch: {relative}")


def verify_image(root: Path, candidate: dict) -> None:
    for relative, expected in candidate["image_files_sha256"].items():
        if digest(root / relative) != expected:
            raise ValueError(f"image checksum mismatch: {relative}")
    notes = subprocess.check_output(
        ["readelf", "-n", str(root / candidate["wechat_elf_path"])], text=True
    )
    build_ids = re.findall(r"Build ID:\s*([0-9a-f]+)", notes)
    if build_ids != [candidate["wechat_build_id"]]:
        raise ValueError("WeChat ELF build ID mismatch")
    helper = (root / "opt/tools/media-download.py").read_text(encoding="utf-8")
    if candidate["wechat_build_id"] not in helper:
        raise ValueError("WeChat build is not supported by the pinned native helper")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--image-root", type=Path)
    args = parser.parse_args()
    candidate = json.loads(LOCK.read_text(encoding="utf-8"))["candidate"]
    verify_source(args.source.resolve(), candidate)
    print("PASS: pinned source revision and media source hashes")
    if args.image_root:
        verify_image(args.image_root.resolve(), candidate)
        print("PASS: extracted image hashes and native WeChat build profile")
    print("NOT VERIFIED: logged-in native transfer, source-original bytes, or document parsing")


if __name__ == "__main__":
    main()
