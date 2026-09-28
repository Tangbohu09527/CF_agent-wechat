"""Offline rejection tests for the pinned media candidate identity gate."""

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "media_candidate", Path(__file__).resolve().parents[2] / "scripts/verify-media-candidate.py"
)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class CandidateVerificationTests(unittest.TestCase):
    def test_same_revision_does_not_accept_modified_media_source(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "media.rs").write_bytes(b"changed\n")
            lock = {
                "source_revision": "a" * 40,
                "source_files_sha256": {"media.rs": hashlib.sha256(b"original\n").hexdigest()},
            }
            with patch.object(candidate.subprocess, "check_output", return_value="a" * 40), \
                    patch.object(candidate.subprocess, "run"), \
                    self.assertRaisesRegex(ValueError, "checksum mismatch"):
                candidate.verify_source(source, lock)

    def test_wrong_revision_is_rejected_before_file_access(self):
        with patch.object(candidate.subprocess, "check_output", return_value="b" * 40), \
                self.assertRaisesRegex(ValueError, "revision mismatch"):
            candidate.verify_source(Path("unused"), {"source_revision": "a" * 40})

    def test_tampered_image_is_rejected_before_build_id_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "agent-server").write_bytes(b"changed")
            with patch.object(candidate.subprocess, "check_output") as readelf, \
                    self.assertRaisesRegex(ValueError, "image checksum mismatch"):
                candidate.verify_image(root, {"image_files_sha256": {"agent-server": "0" * 64}})
            readelf.assert_not_called()

    def test_unexpected_or_unsupported_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "opt/tools/media-download.py"
            helper.parent.mkdir(parents=True)
            helper.write_text("BUILDS = {'other'}\n", encoding="utf-8")
            lock = {
                "image_files_sha256": {}, "wechat_elf_path": "wechat", "wechat_build_id": "a" * 40,
            }
            with patch.object(candidate.subprocess, "check_output", return_value="Build ID: " + "b" * 40), \
                    self.assertRaisesRegex(ValueError, "build ID mismatch"):
                candidate.verify_image(root, lock)
            with patch.object(candidate.subprocess, "check_output", return_value="Build ID: " + "a" * 40), \
                    self.assertRaisesRegex(ValueError, "not supported"):
                candidate.verify_image(root, lock)


if __name__ == "__main__":
    unittest.main()
