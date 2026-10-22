"""Pinned-source checks; native behavior runs on Linux with official locked dependencies."""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "packages/agent-server-rust/src/"


@unittest.skipUnless(os.environ.get("CF_LOGIN_SOURCE"), "pinned isolated source required")
class LiveObservationOverlayTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(os.environ["CF_LOGIN_SOURCE"])
        self.baseline = os.environ.get("CF_LIVE_LOGIN_PHASE") == "baseline"
        if self.baseline:
            self.result = {PREFIX + name: (self.source / (PREFIX + name)).read_bytes()
                           for name in ("ia/states/login.rs", "ia/actions.rs",
                                        "router/status.rs", "tools/wechat_db.rs")}
        else:
            spec = importlib.util.spec_from_file_location(
                "live_overlay", ROOT / "scripts/apply-live-login-observation.py")
            self.overlay = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.overlay)
            self.result = self.overlay.prepare(self.source)

    def text(self, name):
        return self.result[PREFIX + name].decode()

    def test_saved_account_alias_and_action_include_enter_weixin(self):
        self.assertIn('push-button[name="Enter Weixin"]', self.text("ia/states/login.rs"))
        self.assertIn("Log In|Open WeChat|Enter Weixin", self.text("ia/actions.rs"))

    def test_fresh_auth_observation_must_not_reuse_stale_online_context(self):
        route = self.text("router/status.rs")
        self.assertIn('"error": "observation_unrecognized"', route)
        self.assertIn("context.state = match reduce_auth_observation(", route)

    def test_live_reader_includes_wal_and_enforces_readonly(self):
        reader = self.text("tools/wechat_db.rs")
        production = reader.split("#[cfg(test)]")[0]
        self.assertNotIn("immutable=1", production)
        self.assertIn("?mode=ro", production)
        self.assertIn("PRAGMA query_only = ON", production)
        self.assertIn("PRAGMA busy_timeout = 1000", production)

    def test_only_reviewed_files_change_and_source_drift_fails_closed(self):
        if self.baseline:
            self.skipTest("green-only composition check")
        self.assertEqual(set(self.result), set(self.overlay.EXPECTED))
        original = {name: (self.source / name).read_bytes()
                    for name in self.overlay.EXPECTED}
        original[PREFIX + "tools/wechat_db.rs"] += b"\n// upstream drift\n"
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            self.overlay.transform(original)

    def test_optional_expected_account_guard_does_not_include_filename_changes(self):
        if self.baseline:
            self.skipTest("green-only composition check")
        result = self.overlay.prepare(self.source, with_expected_account=True)
        login = result[PREFIX + "plans/login.rs"].decode()
        route = result[PREFIX + "router/status.rs"].decode()
        self.assertNotIn("clear_session_data", login)
        self.assertNotIn("click_switch_account", login)
        self.assertIn("expected_account", login)
        self.assertIn('"error": "observation_unrecognized"', route)
        self.assertNotIn(PREFIX + "router/return_file.rs", result)
        self.assertEqual(set(result) - set(self.result), {
            PREFIX + "plans/login.rs", PREFIX + "plans/mod.rs",
            PREFIX + "plans/login_guard.rs", PREFIX + "execution/mod.rs"})


if __name__ == "__main__":
    unittest.main()
