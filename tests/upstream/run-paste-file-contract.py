#!/usr/bin/env python3
"""Synthetic clipboard + real Qt file URI decoding; never contacts WeChat."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import unquote_to_bytes, urlsplit

def check(path: Path) -> None:
    helper = Path(os.environ["CF_PASTE_FILE"])
    qt = Path(os.environ["CF_QT_FILE_URI"])
    before = path.read_bytes()
    sha = hashlib.sha256(before).hexdigest()
    with tempfile.TemporaryDirectory(prefix="cf-filename-test-") as temp:
        root = Path(temp)
        clipboard = root / "clipboard"
        # Deterministic clipboard/keystroke stand-ins. Qt below is real; no GUI
        # session or production credentials, services, files or clipboard used.
        (root / "xclip").write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\nPath(os.environ['CF_TEST_CLIPBOARD']).write_bytes(sys.stdin.buffer.read())\n")
        (root / "xdotool").write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\nassert sys.argv[1:]==['key','ctrl+v']\nassert Path(os.environ['CF_TEST_CLIPBOARD']).is_file()\nsys.exit(int(os.environ.get('CF_TEST_PASTE_FAILURE','0')))\n")
        for name in ("xclip", "xdotool"):
            (root / name).chmod(0o755)
        env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                   CF_TEST_CLIPBOARD=str(clipboard), LC_ALL="C", LANG="C")
        passed = subprocess.run(["bash", str(helper), str(path)], env=env, capture_output=True, timeout=10)
        assert passed.returncode == 0, "synthetic paste failed"
        assert passed.stdout == b"pasted file\n"
        raw = clipboard.read_bytes()
        assert raw.endswith(b"\r\n") and raw.isascii()
        uri = raw[:-2].decode("ascii")
        assert unquote_to_bytes(urlsplit(uri).path) == os.fsencode(path.resolve())
        assert "%25" in uri and "%23" in uri and "%20" in uri
        for prefix in ([], ["sudo", "-n", "-u", "nobody", "--"]):
            result = subprocess.run([*prefix, str(qt), uri, path.name, sha], env=env, capture_output=True, timeout=10)
            assert result.returncode == 0, f"Qt read failed, cross_uid={bool(prefix)}, exit={result.returncode}"
            assert result.stdout == b"qt_uri_exact_basename_and_bytes=true\n"
        assert path.read_bytes() == before
        failed = subprocess.run(["bash", str(helper), str(path)], env=dict(env, CF_TEST_PASTE_FAILURE="7"), capture_output=True, timeout=10)
        assert failed.returncode == 7 and not failed.stdout
        assert path.read_bytes() == before
        missing = subprocess.run(["bash", str(helper), str(path) + ".missing"], env=env, capture_output=True, timeout=10)
        assert missing.returncode != 0
    print("paste_contract_unicode_bytes_cross_uid_and_failure=true")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing", type=Path, required=True)
    check(parser.parse_args().existing)
