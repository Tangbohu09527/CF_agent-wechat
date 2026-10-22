#!/usr/bin/env python3
"""Package only a reviewed agent-server replacement over the exact current runtime.

Linux CI only. Does not start WeChat, mount login data, send, log in or deploy.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = "96c2e90c497d999bf5189a134a9b3b293731f42e"
BASE = "ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43"
CONFIG = "sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e"


def run(argv, timeout=120):
    return subprocess.check_output(argv, text=True, timeout=timeout).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def runtime_config(image):
    return {key: value for key, value in image["Config"].items() if key not in {"Labels", "Image"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--applied", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(os.name == "posix", "isolated Linux runner required")
    require(not args.output.exists(), "refuse existing output")
    revision = run(["git", "-C", str(ROOT), "rev-parse", "HEAD"])
    require(re.fullmatch("[0-9a-f]{40}", revision), "invalid overlay revision")
    require(run(["git", "-C", str(args.source), "rev-parse", "HEAD"]) == UPSTREAM, "wrong upstream")
    spec = importlib.util.spec_from_file_location("live_overlay", ROOT / "scripts/apply-live-login-observation.py")
    overlay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(overlay)
    originals = {name: subprocess.check_output(["git", "-C", str(args.source), "show", "HEAD:" + name])
                 for name in overlay.EXPECTED}
    expected = overlay.transform(originals)
    receipt = json.loads(args.applied.read_text())
    require(receipt["schema"] == "cf-live-observation-overlay/v1"
            and not receipt["regression_only"] and not receipt["expected_account_included"]
            and not receipt["filename_included"], "not the minimal observation build")
    proof = {name: hashlib.sha256(data).hexdigest() for name, data in expected.items()}
    require(receipt["files_sha256"] == proof, "source receipt mismatch")
    require(all(sha(args.source / name) == digest for name, digest in proof.items()), "modified overlay output")
    changed = set(run(["git", "-C", str(args.source), "diff", "--name-only", "HEAD"]).splitlines())
    untracked = set(run(["git", "-C", str(args.source), "ls-files", "--others", "--exclude-standard"]).splitlines())
    require(changed | untracked == set(expected), "unreviewed source changes")
    lock = "packages/agent-server-rust/Cargo.lock"
    require(sha(args.source / lock) == hashlib.sha256(subprocess.check_output(
        ["git", "-C", str(args.source), "show", "HEAD:" + lock])).hexdigest(), "dependency lock drift")
    require(run(["rustc", "--version"]).startswith("rustc 1.93.0 "), "wrong compiler")
    versions = run(["readelf", "--version-info", str(args.binary)])
    glibc = sorted(set(re.findall(r"GLIBC_([0-9]+\.[0-9]+)", versions)),
                   key=lambda version: tuple(map(int, version.split("."))))
    require(glibc and tuple(map(int, glibc[-1].split("."))) <= (2, 35), "runtime glibc incompatibility")
    run(["docker", "pull", "--platform", "linux/amd64", BASE], 600)
    base = json.loads(run(["docker", "image", "inspect", BASE]))[0]
    require(base["Id"] == CONFIG and base["Architecture"] == "amd64", "runtime identity mismatch")
    args.output.mkdir(parents=True)
    context = args.output / "context"
    context.mkdir()
    shutil.copyfile(args.binary, context / "agent-server")
    (context / "agent-server").chmod(0o755)
    (context / "Dockerfile").write_text(
        f"FROM {BASE}\nCOPY --chown=0:0 --chmod=0755 agent-server /opt/agent-server/agent-server\n"
        f'LABEL org.opencontainers.image.revision="{revision}" cf.upstream.revision="{UPSTREAM}"\n')
    tag = "cf-live-observation:" + revision
    run(["docker", "build", "--network", "none", "--pull=false", "--tag", tag, str(context)], 300)
    image = json.loads(run(["docker", "image", "inspect", tag]))[0]
    require(image["RootFS"]["Layers"][:-1] == base["RootFS"]["Layers"], "not one replacement layer")
    require(runtime_config(image) == runtime_config(base), "runtime configuration changed")
    with tempfile.TemporaryDirectory(prefix="cf-live-runtime-") as temporary:
        cid = run(["docker", "create", "--network", "none", "--entrypoint", "/bin/true", tag])
        try:
            extracted = Path(temporary) / "agent-server"
            run(["docker", "cp", cid + ":/opt/agent-server/agent-server", str(extracted)])
            require(sha(extracted) == sha(args.binary), "replacement binary mismatch")
        finally:
            run(["docker", "rm", "-v", cid])
    output = run(["docker", "run", "--rm", "--network", "none", "--read-only", "--entrypoint", "/bin/sh",
                  tag, "-c", "/lib64/ld-linux-x86-64.so.2 --verify /opt/agent-server/agent-server && "
                  "/lib64/ld-linux-x86-64.so.2 --list /opt/agent-server/agent-server && getconf GNU_LIBC_VERSION"])
    require("not found" not in output.lower() and "glibc 2.35" in output, "loader verification failed")
    (args.output / "runtime-loader.txt").write_text(output + "\n")
    hashes = {name: sha(context / name) for name in ("Dockerfile", "agent-server")}
    (context / "SHA256SUMS").write_text("".join(digest + "  " + name + "\n" for name, digest in hashes.items()))
    archive = args.output / "live-observation-overlay.tar.gz"
    with tarfile.open(archive, "w:gz") as packed:
        for name in [*hashes, "SHA256SUMS"]:
            packed.add(context / name, arcname=name, recursive=False)
    result = dict(schema="cf-live-observation-release/v1", overlay_revision=revision,
                  upstream_revision=UPSTREAM, base_image=BASE, base_config=CONFIG,
                  candidate_image_id=image["Id"], source_sha256=proof, context_sha256=hashes,
                  cargo_lock_sha256=sha(args.source / lock), archive_sha256=sha(archive),
                  required_glibc=glibc, runtime_config_preserved=True, single_replacement_layer=True,
                  expected_account_included=False, filename_included=False,
                  live_wechat_started=False, deployment_performed=False)
    (args.output / "release-proof.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
