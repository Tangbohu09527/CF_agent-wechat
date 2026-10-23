"""Pinned source contracts; Rust filesystem/SQL behavior is verified in native CI."""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "packages/agent-server-rust/src/"

@unittest.skipUnless(os.environ.get("CF_LOGIN_SOURCE"), "exact official source required")
class ActiveAccountOverlayTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("active_overlay", ROOT / "scripts/apply-active-account-reader.py")
        self.overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.overlay)
        self.source = Path(os.environ["CF_LOGIN_SOURCE"])
        if os.environ.get("CF_ACTIVE_PHASE") == "baseline":
            self.output = self.overlay.prior().prepare(self.source)
            self.output.update({name: (self.source / name).read_bytes() for name in self.overlay.EXPECTED})
        else:
            self.output = self.overlay.prepare(self.source)

    def test_auth_reports_observed_account_and_never_saved_fallback(self):
        text = self.output[PREFIX + "router/status.rs"].decode()
        text = text[text.index("pub async fn auth_status()"):text.index("/// Log out")]
        self.assertIn('"loggedInUser": current_account', text)
        self.assertNotIn('"loggedInUser": session.logged_in_user', text)

    def test_all_six_read_handlers_resolve_and_recheck_actual_identity(self):
        counts = {"router/contacts.rs": 2, "router/chats.rs": 3, "router/messages.rs": 1}
        for name, count in counts.items():
            text = self.output[PREFIX + name].decode()
            self.assertEqual(text.count("active_read_keys(&session, ReadKind::"), count)
            self.assertEqual(text.count("ensure_active_account(&session, &active)"), count)

    def test_no_login_send_media_or_session_changes(self):
        if os.environ.get("CF_ACTIVE_PHASE") == "baseline": self.skipTest("green scope")
        for name, marker in [("router/status.rs", "/// Log out"), ("router/messages.rs", "#[derive(Deserialize, Default)]"), ("router/chats.rs", "/// Open a chat")]:
            original = (self.source / (PREFIX + name)).read_text(encoding="utf-8")
            changed = self.output[PREFIX + name].decode()
            if marker in original:
                self.assertEqual(changed[changed.index(marker):].split("#[cfg(test)]")[0].rstrip(),
                                 original[original.index(marker):].split("#[cfg(test)]")[0].rstrip())
        self.assertNotIn(PREFIX + "plans/login.rs", self.output)
        helper = self.output[PREFIX + "tools/active_account.rs"].decode().split("#[cfg(test)]")[0]
        for forbidden in ["clear_session_data", "update_session_logged_in_user", "DELETE FROM", "set_sync_state"]:
            self.assertNotIn(forbidden, helper)

    def test_upstream_drift_is_rejected(self):
        if os.environ.get("CF_ACTIVE_PHASE") == "baseline": self.skipTest("green drift")
        originals = {name: (self.source / name).read_bytes() for name in self.overlay.EXPECTED}
        originals[PREFIX + "router/contacts.rs"] += b"\n// drift"
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            self.overlay.transform(originals, base_outputs=self.overlay.prior().prepare(self.source))

if __name__ == "__main__":
    unittest.main()
