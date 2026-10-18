import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("overlay", ROOT / "scripts/apply-return-filename.py")
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

class OverlayTests(unittest.TestCase):
    def setUp(self):
        import os
        self.source = Path(os.environ["CF_FILENAME_SOURCE"])
        self.inputs = {name: (self.source / name).read_bytes() for name in overlay.EXPECTED}
        self.result = overlay.transform(self.inputs, ROOT / "upstream/return-filename")

    def test_only_expected_six_outputs(self):
        self.assertEqual(set(self.result), set(overlay.EXPECTED) | {overlay.PREFIX + "router/return_file.rs"})

    def test_unknown_or_changed_upstream_rejected(self):
        for key in self.inputs:
            changed = dict(self.inputs); changed[key] += b"\n"
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                overlay.transform(changed, ROOT / "upstream/return-filename")

    def test_images_original_code_unchanged(self):
        route = overlay.PREFIX + "router/messages.rs"
        old = self.inputs[route].decode().replace("\r\n", "\n")
        new = self.result[route].decode()
        start = old.index("    // Decode base64 image")
        self.assertEqual(old[start:old.index("    // Decode base64 file")],
                         new[new.index("    // Decode base64 image"):new.index("    let mut context =", new.index("pub async fn send_message"))])
        plan = overlay.PREFIX + "plans/send_message.rs"
        old = self.inputs[plan].decode().replace("\r\n", "\n")
        new = self.result[plan].decode()
        self.assertEqual(old[old.index("                    // Image"):], new[new.index("                    // Image"):])

    def test_file_failure_does_not_press_return(self):
        plan = self.result[overlay.PREFIX + "plans/send_message.rs"].decode()
        block = plan[plan.index("                    // File"):plan.index("                    // Image")]
        self.assertLess(block.index("if pasted.exit_code != 0"), block.index('combo: "Return"'))
        self.assertIn("return None", block)

    def test_file_is_retained_by_sender_not_waiter(self):
        route = self.result[overlay.PREFIX + "router/messages.rs"].decode()
        self.assertIn("retain_for_send(file, execute).await", route)
        self.assertIn("else { execute.await }", route)
        self.assertNotIn("remove_file(p);\n    }\n\n    Json", route)

    def test_paste_does_not_copy_or_change_basename(self):
        helper = self.result["docker/tools/paste-file"].decode()
        self.assertIn("quote_from_bytes(os.fsencode(path)", helper)
        self.assertNotIn("paste_safe_", helper)
        self.assertNotIn(" cp ", helper)
        self.assertNotIn("rm ", helper)

    def test_queue_bound_is_file_only_and_execution_body_unchanged(self):
        name = overlay.PREFIX + "execution/mod.rs"
        old = self.inputs[name].decode().replace("\r\n", "\n")
        new = self.result[name].decode()
        self.assertIn("acquire_file_gui_guard(std::time::Duration::from_secs(30))", new)
        old_body = old[old.index("    let mut plan_state ="):]
        new_body = new[new.index("    let mut plan_state ="):new.index("#[cfg(test)]\nmod filename_queue_tests")]
        self.assertEqual(old_body.strip(), new_body.strip())

    def test_invalid_file_is_rejected_before_combined_image_can_create_file(self):
        route = self.result[overlay.PREFIX + "router/messages.rs"].decode()
        entry = route[route.index("pub async fn send_message"):]
        self.assertLess(entry.index("Invalid file name"), entry.index("// Decode base64 image"))
        self.assertLess(entry.index("Invalid base64 file data"), entry.index("// Decode base64 image"))
        self.assertLess(entry.index("let mut prepared_file"), entry.index("// Decode base64 image"))

if __name__ == "__main__": unittest.main()
