"""Fixed-source contract for explicit message DB failure instead of HTTP200 []."""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('CF_LOGIN_SOURCE'), 'exact official source required')
class MessageReadFailureTests(unittest.TestCase):
    def test_existing_message_key_is_verified_before_query(self):
        spec = importlib.util.spec_from_file_location('active_overlay', ROOT / 'scripts/apply-active-account-reader.py')
        overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(overlay)
        output = overlay.prepare(Path(os.environ['CF_LOGIN_SOURCE']))
        helper = output['packages/agent-server-rust/src/tools/active_account.rs'].decode()
        self.assertIn('fn message_database_readable(', helper)
        self.assertIn('active_message_database_unreadable', helper)
        self.assertIn('ReadKind::Messages', helper[helper.index('if required.iter().any(|name| !keys.contains_key(name)) {', helper.index('keys.extend(verified)')):])
        self.assertIn('?mode=ro', helper)
        self.assertIn('PRAGMA query_only = ON', helper)


if __name__ == '__main__':
    unittest.main()
