from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class TimezoneDefaultsTests(unittest.TestCase):
    def test_both_compose_profiles_use_shanghai_without_broad_env_override(self):
        for name in ("docker/compose.cfserver.yaml", "docker/docker-compose.yml"):
            service = yaml.safe_load((ROOT / name).read_text())["services"]["agent-wechat"]
            self.assertEqual(service["environment"]["TZ"], "Asia/Shanghai")
            self.assertEqual(service["restart"], "no")
            self.assertNotIn("env_file", service)
        # Fixed default needs no new production .env parser/secret-bearing key.
        self.assertNotIn("TZ=", (ROOT / "docker/.env.example").read_text())


if __name__ == "__main__":
    unittest.main()
