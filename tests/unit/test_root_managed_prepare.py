"""Root-managed mode must be explicit and cannot confer privilege."""
import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/prepare-clean-host.sh"


@unittest.skipUnless(os.name == "posix", "requires the supported shell environment")
class RootManagedPrepareTests(unittest.TestCase):
    def test_unknown_mode_is_rejected_before_platform_or_installation(self):
        result = subprocess.run(["bash", str(SCRIPT), "checkout", "--manager", "deploycheck",
                                 "--commit", "a" * 40, "--execution-mode", "anything"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported execution mode", result.stderr)

    @unittest.skipIf(getattr(os, "geteuid", lambda: 0)() == 0, "run as an unprivileged CI user")
    def test_root_managed_never_prompts_or_grants_a_nonroot_caller_privilege(self):
        result = subprocess.run(["bash", str(SCRIPT), "checkout", "--manager", "deploycheck",
                                 "--commit", "a" * 40, "--execution-mode", "root-managed"],
                                input="", capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires the already authorized root installer", result.stderr)

    def test_mode_does_not_apply_to_package_installation(self):
        result = subprocess.run(["bash", str(SCRIPT), "system", "--manager", "deploycheck",
                                 "--execution-mode", "root-managed"],
                                input="", capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, "root-managed|authorized root")


if __name__ == "__main__":
    unittest.main()
