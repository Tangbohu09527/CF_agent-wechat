"""Offline identity/compatibility checks; actual Rust tests run on pinned Linux CI."""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("login_overlay",ROOT/"scripts/apply-login-expected-account.py")
overlay=importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

@unittest.skipUnless(os.environ.get("CF_LOGIN_SOURCE"),"pinned isolated upstream source required")
class OverlayTests(unittest.TestCase):
    def setUp(self):self.source=Path(os.environ["CF_LOGIN_SOURCE"])
    def test_guard_replaces_destructive_flow_and_identityless_success(self):
        result=overlay.prepare(self.source)
        login=result[overlay.PREFIX+"plans/login.rs"].decode()
        route=result[overlay.PREFIX+"router/status.rs"].decode()
        self.assertNotIn("clear_session_data",login)
        self.assertNotIn("click_switch_account",login)
        self.assertNotIn("update_session_logged_in_user",login)
        self.assertNotIn("LoginSuccess { user_id: None }",route)
        self.assertEqual(route.count('"loginCapabilities":'),6)
        self.assertIn("expected_account_ws_missing_identity_and_switch_are_rejected_before_native_tools",route)
        self.assertNotIn('format!("{:?}", s.action)',result[overlay.PREFIX+"execution/mod.rs"].decode())
    def test_fixed_filename_overlay_composes_without_losing_lifetime_control(self):
        result=overlay.prepare(self.source,True)
        self.assertIn(overlay.PREFIX+"router/return_file.rs",result)
        self.assertIn("run_file_execution_loop",result[overlay.PREFIX+"execution/mod.rs"].decode())
        self.assertIn("retain_for_send",result[overlay.PREFIX+"router/messages.rs"].decode())
        self.assertNotIn("clear_session_data",result[overlay.PREFIX+"plans/login.rs"].decode())
    def test_source_drift_fails_closed_before_any_write(self):
        inputs={name:(self.source/name).read_bytes() for name in overlay.EXPECTED}
        inputs[overlay.PREFIX+"plans/login.rs"]+=b"\n// changed upstream\n"
        with self.assertRaisesRegex(ValueError,"identity mismatch"):overlay.transform(inputs)

if __name__=="__main__":unittest.main()
