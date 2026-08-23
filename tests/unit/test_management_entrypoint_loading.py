#!/usr/bin/env python3
"""Static contracts for race-resistant production management entrypoints."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
ENTRYPOINTS = {
    name: (SCRIPTS / name).read_text(encoding="utf-8")
    for name in (
        "start-qr-login.sh",
        "status.sh",
        "stop-qr-runtime.sh",
    )
}
COMMON = (SCRIPTS / "common.sh").read_text(encoding="utf-8")
RUNTIME_COMMON = (SCRIPTS / "qr-runtime-common.sh").read_text(
    encoding="utf-8"
)
LOGIN = (SCRIPTS / "login.sh").read_text(encoding="utf-8")
BOOTSTRAP = (SCRIPTS / "bootstrap-cfserver.sh").read_text(encoding="utf-8")
METADATA_FORMAT = r"%d:%i:%u:%g:%a:%h:%F"
CONTENT_METADATA_FORMAT = r"%d:%i:%s:%y:%z"
INTERNAL_SCRIPTS_DIR = "_CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR"
EARLY_OVERRIDE_STATE = "_CF_AGENT_WECHAT_EARLY_OVERRIDES"
BOOTSTRAP_OVERRIDE_STATE = "_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES"


class ProductionEntrypointLoadingTests(unittest.TestCase):
    def test_environment_is_scrubbed_before_any_entrypoint_child(self) -> None:
        commands = {**ENTRYPOINTS, "login.sh": LOGIN}
        for name, content in commands.items():
            with self.subTest(entrypoint=name):
                reset = content.index(f"unset {EARLY_OVERRIDE_STATE}")
                capture = content.index(
                    f'{EARLY_OVERRIDE_STATE}+="${{{EARLY_OVERRIDE_STATE}:+,}}'
                )
                scrub = content.index('unset "$_management_env_name"')
                immutable = content.index(f"readonly {EARLY_OVERRIDE_STATE}")
                child_offsets = [
                    offset
                    for marker in (
                        "/usr/bin/readlink -f",
                        'dirname -- "${BASH_SOURCE[0]}"',
                        'dirname -- "$_management_entry_resolved"',
                    )
                    if (offset := content.find(marker)) >= 0
                ]
                first_child = min(child_offsets)
                fixed_path = content.index(
                    'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
                )
                self.assertLess(reset, capture)
                self.assertLess(fixed_path, first_child)
                self.assertLess(capture, scrub)
                self.assertLess(scrub, immutable)
                self.assertLess(immutable, first_child)
                for variable in (
                    "API_URL",
                    "WS_URL",
                    "AUTH_TOKEN",
                    "CF_AGENT_WECHAT_TOKEN",
                    "HTTP_PROXY",
                    "CF_AGENT_WECHAT_COMPOSE_FILE",
                    "CF_AGENT_WECHAT_MIN_FREE_BYTES",
                    "CF_AGENT_WECHAT_MIN_FREE_PERCENT",
                    "CF_AGENT_WECHAT_MIN_FREE_INODES",
                    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES",
                    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES",
                ):
                    self.assertIn(variable, content[:first_child])
                self.assertIn('export -n "$_management_env_name"', content[:first_child])
                for secret_name in (
                    "AUTH_TOKEN",
                    "CF_AGENT_WECHAT_TOKEN",
                    "CF_GATEWAY_API_TOKEN",
                    "HERMES_API_KEY",
                    "HTTP_PROXY",
                    "PROXY",
                ):
                    self.assertIn(secret_name, content[:first_child])

    def test_testing_path_is_restored_only_after_positive_isolation(self) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                restoration = content.index("restore_testing_management_path")
                isolation = content.index("runtime_validate_testing_isolation")
                self.assertLess(restoration, isolation)
        self.assertIn(
            '"$first_component" "command path directory" confined',
            COMMON,
        )
        self.assertIn(
            "Testing command path prefix must be caller-owned and not group/other writable.",
            COMMON,
        )

    def test_common_preserves_scrubbed_override_rejection(self) -> None:
        capture = COMMON.index(
            f'[[ -v {EARLY_OVERRIDE_STATE} ]]'
        )
        merge = COMMON.index(
            f'PRODUCTION_MANAGEMENT_OVERRIDES="${EARLY_OVERRIDE_STATE}"'
        )
        scrub = COMMON.index('unset "$_override_name"')
        first_production_child = COMMON.index("/usr/bin/python3 -I")
        rejection = COMMON.index(
            "Production management environment overrides are forbidden:"
        )
        self.assertLess(capture, merge)
        self.assertLess(merge, scrub)
        self.assertLess(scrub, first_production_child)
        self.assertGreater(rejection, scrub)

    def test_bootstrap_scrubs_before_paths_or_child_processes(self) -> None:
        reset = BOOTSTRAP.index(f"unset {BOOTSTRAP_OVERRIDE_STATE}")
        capture = BOOTSTRAP.index(
            f'{BOOTSTRAP_OVERRIDE_STATE}+="${{{BOOTSTRAP_OVERRIDE_STATE}:+,}}'
        )
        scrub = BOOTSTRAP.index('unset "$_bootstrap_early_override_name"')
        immutable = BOOTSTRAP.index(f"readonly {BOOTSTRAP_OVERRIDE_STATE}")
        first_child = BOOTSTRAP.index(
            'dirname -- "${BASH_SOURCE[0]}"'
        )
        rejection = BOOTSTRAP.index(
            '"${_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES%%,*}"'
        )
        self.assertLess(reset, capture)
        self.assertLess(capture, scrub)
        self.assertLess(scrub, immutable)
        self.assertLess(immutable, first_child)
        self.assertGreater(rejection, first_child)
        self.assertIn(
            'export -n "$_bootstrap_early_override_name"',
            BOOTSTRAP[:first_child],
        )
        for variable in (
            "AUTH_TOKEN",
            "CF_AGENT_WECHAT_TOKEN",
            "HTTP_PROXY",
            "API_URL",
            "CF_AGENT_WECHAT_ROOT",
            "CF_BOOTSTRAP_DOCKER_BIN",
        ):
            self.assertIn(variable, BOOTSTRAP[:first_child])

    def test_libraries_are_snapshotted_from_verified_fds(
        self,
    ) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                self.assertIn(
                    'exec {library_fd}<"$library_path"',
                    content,
                )
                self.assertIn(
                    'IFS= read -r -d \'\' library_source <&"$library_fd"',
                    content,
                )
                self.assertIn(
                    'source /dev/stdin <<< "$library_source"',
                    content,
                )
                self.assertNotIn(
                    'source "/proc/self/fd/${library_fd}"',
                    content,
                )
                self.assertIn(
                    '[ "$path_before" != "$fd_metadata" ]',
                    content,
                )
                self.assertIn(
                    '[ "$path_before" != "$path_after" ]',
                    content,
                )
                self.assertIn(CONTENT_METADATA_FORMAT, content)
                self.assertIn(
                    '[ "$content_after" != "$content_before" ]',
                    content,
                )
                self.assertIn(
                    '[ "$fd_content_after" != "$content_before" ]',
                    content,
                )
                self.assertIn("source_status=$?", content)
                self.assertIn('return "$source_status"', content)
                self.assertGreaterEqual(
                    content.count('[ -L "$library_path" ]'),
                    3,
                )
                self.assertNotIn("for _library in", content)

    def test_path_and_descriptor_attest_same_complete_metadata(self) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                self.assertGreaterEqual(
                    content.count(METADATA_FORMAT),
                    3,
                )
                self.assertIn(
                    "read -r _dev _inode owner _gid mode links file_type",
                    content,
                )
                self.assertIn("[ \"$file_type\" != 'regular file' ]", content)
                self.assertIn('[ "$mode" != 755 ]', content)
                self.assertIn('[ "$links" != 1 ]', content)

    def test_trusted_scripts_directory_is_reset_then_made_readonly(
        self,
    ) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                reset = content.index(f"unset {INTERNAL_SCRIPTS_DIR}")
                assign = content.index(
                    f'{INTERNAL_SCRIPTS_DIR}="$SCRIPT_DIR"'
                )
                immutable = content.index(
                    f"readonly {INTERNAL_SCRIPTS_DIR}"
                )
                load = content.index(
                    '_management_source_library "${SCRIPT_DIR}/common.sh"'
                )
                self.assertLess(reset, assign)
                self.assertLess(assign, immutable)
                self.assertLess(immutable, load)

    def test_entrypoint_and_scripts_directory_are_attested(self) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                self.assertIn(
                    '_management_validate_node "$SCRIPT_DIR" directory',
                    content,
                )
                self.assertIn(
                    f'_management_validate_node "${{SCRIPT_DIR}}/{name}" file',
                    content,
                )
                self.assertIn(f"!= {name} ]", content)


class SourcedLibraryLocationTests(unittest.TestCase):
    def test_production_libraries_require_readonly_injected_location(
        self,
    ) -> None:
        for name, content in (
            ("common.sh", COMMON),
            ("qr-runtime-common.sh", RUNTIME_COMMON),
        ):
            with self.subTest(library=name):
                self.assertIn(
                    f"declare -p {INTERNAL_SCRIPTS_DIR}",
                    content,
                )
                self.assertIn("'declare -r '*", content)
                self.assertIn(
                    f'="${INTERNAL_SCRIPTS_DIR}"',
                    content,
                )
                self.assertIn("scripts directory is not immutable", content)

    def test_testing_mode_keeps_bash_source_location_fallback(self) -> None:
        self.assertIn(
            'if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then',
            COMMON,
        )
        self.assertIn(
            'dirname -- "${BASH_SOURCE[0]}"',
            COMMON,
        )
        self.assertIn(
            'if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then',
            RUNTIME_COMMON,
        )
        self.assertIn(
            'dirname -- "${BASH_SOURCE[0]}"',
            RUNTIME_COMMON,
        )

    def test_testing_sources_fail_closed_and_require_complete_libraries(
        self,
    ) -> None:
        for name, content in ENTRYPOINTS.items():
            with self.subTest(entrypoint=name):
                self.assertIn(
                    'source "${SCRIPT_DIR}/common.sh" || exit 1',
                    content,
                )
                self.assertIn(
                    'source "${SCRIPT_DIR}/qr-runtime-common.sh" || exit 1',
                    content,
                )
                self.assertIn("CF_AGENT_WECHAT_COMMON_LOADED", content)
                self.assertIn(
                    "CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED",
                    content,
                )

    def test_completeness_markers_are_at_library_end(self) -> None:
        self.assertTrue(
            COMMON.rstrip().endswith(
                "readonly CF_AGENT_WECHAT_COMMON_LOADED"
            )
        )
        self.assertTrue(
            RUNTIME_COMMON.rstrip().endswith(
                "readonly CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED"
            )
        )


class CompatibilityLoginLoadingTests(unittest.TestCase):
    def test_login_binds_exact_forced_qr_target_before_exec(self) -> None:
        self.assertIn('START_QR_LOGIN="${SCRIPT_DIR}/start-qr-login.sh"', LOGIN)
        self.assertIn(
            '_management_validate_node "$START_QR_LOGIN" file',
            LOGIN,
        )
        self.assertIn(
            'exec {_management_target_fd}<"$START_QR_LOGIN"',
            LOGIN,
        )
        self.assertIn(
            "/proc/self/fd/${_management_target_fd}",
            LOGIN,
        )
        self.assertIn("exec /bin/bash -p", LOGIN)
        self.assertNotIn("\nsource ", LOGIN)

    def test_start_independently_attests_login_descriptor(self) -> None:
        start = ENTRYPOINTS["start-qr-login.sh"]
        self.assertIn("/proc/self/fd/[0-9]*)", start)
        self.assertIn(
            '/usr/bin/readlink -f -- "$_management_entry_source"',
            start,
        )
        self.assertIn(
            '"$_management_entry_path_metadata" !=',
            start,
        )
        self.assertIn(
            '"$_management_entry_fd_metadata"',
            start,
        )


if __name__ == "__main__":
    unittest.main()
