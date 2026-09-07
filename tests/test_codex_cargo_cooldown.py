"""Test SessionStart handling and cooldown detection with real Cargo."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import tomllib
import unittest

TEST_ROOT = Path(os.environ["DEV_INFRA_TEST_ROOT"])
HOOK = TEST_ROOT / "rust/scripts/codex-cargo-cooldown.py"
CONFIG = TEST_ROOT / "rust/.codex/config.toml"
POLICY_PATH = TEST_ROOT / "rust/.cargo/config.toml"
BASH = os.environ["DEV_INFRA_TEST_BASH"]
CARGO = os.environ["DEV_INFRA_TEST_CARGO"]
POLICY_CARGO = os.environ["DEV_INFRA_TEST_POLICY_CARGO"]


class SessionStartTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cooldown-hook-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.project = self.root / "rust project"
        self.project.mkdir()
        (self.project / "Cargo.toml").write_text("[workspace]\nmembers = []\n")
        self.original_files = list(self.project.iterdir())
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.call_log = self.root / "cargo-call.json"
        # The fake resolver supplies outcomes only; the real resolver is checked
        # separately. It never reports a version or implements cooldown logic.
        cargo = self.bin / "cargo"
        cargo.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "pathlib.Path(os.environ['PROBE_TEST_CALL_LOG']).write_text(json.dumps(args))\n"
            "if os.environ.get('PROBE_TEST_FAIL'):\n"
            "    print('private diagnostic must not leak', file=sys.stderr)\n"
            "    sys.exit(101)\n"
            "root = pathlib.Path(args[args.index('--manifest-path') + 1]).parent\n"
            "version = os.environ.get('PROBE_TEST_VERSION', '1.0.0')\n"
            "(root / 'Cargo.lock').write_text('version = 4\\n[[package]]\\n'\n"
            "    'name = \"codex-cooldown-probe-dependency\"\\nversion = \"' + version + '\"\\n')\n"
        )
        cargo.chmod(0o755)
        shell = self.bin / "bash"
        shell.write_text(
            f"#!{BASH}\n"
            "if [[ -n ${PROBE_TEST_LOGIN_VERSION:-} ]]; then\n"
            '  export PROBE_TEST_VERSION="$PROBE_TEST_LOGIN_VERSION"\n'
            "fi\n"
            f'exec {shlex.quote(BASH)} --noprofile --norc "$@"\n'
        )
        shell.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=str(self.bin),
            SHELL=str(shell),
            PROBE_TEST_CALL_LOG=str(self.call_log),
        )

    def hook(self, cwd=None, **env):
        result = subprocess.run(
            [sys.executable, HOOK],
            input=json.dumps(
                {"hook_event_name": "SessionStart", "cwd": str(cwd or self.project)}
            ),
            env=self.env | env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stderr, "")
        self.assertNotIn("private diagnostic", result.stdout)
        return json.loads(result.stdout)

    def test_success_does_not_depend_on_cargo_version(self):
        output = self.hook()
        self.assertNotIn("continue", output)
        self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "SessionStart")
        arguments = json.loads(self.call_log.read_text())
        self.assertIn("--offline", arguments)
        self.assertFalse(
            any("min-publish-age" in arg or arg.startswith("-Z") for arg in arguments)
        )
        manifest = Path(arguments[arguments.index("--manifest-path") + 1])
        self.assertFalse(manifest.exists(), "probe files should be cleaned up")
        self.assertEqual(list(self.project.iterdir()), self.original_files)

    def test_recent_version_is_an_explicit_stop_request(self):
        output = self.hook(PROBE_TEST_VERSION="1.0.1")
        self.assertIs(output["continue"], False)
        self.assertIn("cooldown", output["systemMessage"])
        self.assertTrue(output["stopReason"])

    def test_environment_after_login_is_checked(self):
        output = self.hook(PROBE_TEST_LOGIN_VERSION="1.0.1")
        self.assertIs(output["continue"], False)

    def test_resolver_failure_cannot_pass_as_cooldown(self):
        self.assertIs(self.hook(PROBE_TEST_FAIL="1")["continue"], False)

    def test_missing_cargo_cannot_pass(self):
        (self.bin / "cargo").unlink()
        self.assertIs(self.hook()["continue"], False)

    def test_subdirectory_of_rust_project_is_checked(self):
        subdirectory = self.project / "src"
        subdirectory.mkdir()
        self.assertIs(
            self.hook(subdirectory, PROBE_TEST_VERSION="1.0.1")["continue"], False
        )

    def test_shared_hook_checks_even_before_a_manifest_is_created(self):
        self.assertIs(
            self.hook(self.root, PROBE_TEST_VERSION="1.0.1")["continue"], False
        )

    def test_shared_command_finds_script_from_a_subdirectory_with_spaces(self):
        with Path(CONFIG).open("rb") as config:
            command = tomllib.load(config)["hooks"]["SessionStart"][0]["hooks"][0][
                "command"
            ]
        scripts = self.project / "scripts"
        scripts.mkdir()
        (scripts / "codex-cargo-cooldown.py").write_bytes(Path(HOOK).read_bytes())
        (self.bin / "python3").symlink_to(sys.executable)
        git = self.bin / "git"
        git.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "assert sys.argv[1:] == ['rev-parse', '--show-toplevel']\n"
            "print(os.environ['PROBE_TEST_PROJECT_ROOT'])\n"
        )
        git.chmod(0o755)
        subdirectory = self.project / "nested directory"
        subdirectory.mkdir()
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-c", command],
            cwd=subdirectory,
            env=self.env | {"PROBE_TEST_PROJECT_ROOT": str(self.project)},
            input=json.dumps(
                {"cwd": str(subdirectory), "hook_event_name": "SessionStart"}
            ),
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stderr, "")
        self.assertNotIn("continue", json.loads(result.stdout))
        self.assertTrue(self.call_log.exists())

    def test_missing_working_directory_is_reported(self):
        self.assertIs(self.hook(self.root / "missing")["continue"], False)


class CooldownIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cooldown-integration-")
        self.addCleanup(self.directory.cleanup)
        self.project = Path(self.directory.name)

    def test_real_cargo_selects_recent_fixture_when_cooldown_is_disabled(self):
        # A malformed recent index entry could otherwise make the probe falsely
        # pass. Resolve the actual fixtures with a real Cargo and no cooldown.
        config = self.project / ".cargo"
        config.mkdir()
        (config / "config.toml").write_text(
            '[registry]\nglobal-min-publish-age = "0"\n'
            '[resolver]\nincompatible-publish-age = "allow"\n'
        )
        result = subprocess.run(
            [sys.executable, HOOK, "--probe"],
            cwd=self.project,
            env=dict(
                os.environ, PATH=str(Path(CARGO).parent) + ":" + os.environ["PATH"]
            ),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("公開直後の検証用パッケージを除外しませんでした", result.stderr)

    def test_effective_cooldown_policy(self):
        policy = Path(POLICY_PATH).read_text()
        environment = dict(
            os.environ, PATH=str(Path(POLICY_CARGO).parent) + ":" + os.environ["PATH"]
        )
        (self.project / ".cargo").mkdir()
        config = self.project / ".cargo/config.toml"
        cases = [
            ("shared policy", policy, {}, 0),
            (
                "another positive duration",
                policy.replace('"7 days"', '"1 hours"'),
                {},
                0,
            ),
            (
                "feature disabled",
                policy.replace("min-publish-age = true", "min-publish-age = false"),
                {},
                1,
            ),
            ("zero duration", policy.replace('"7 days"', '"0"'), {}, 1),
            ("allow policy", policy.replace('"deny"', '"allow"'), {}, 1),
            ("no policy", "", {}, 1),
            (
                "environment allow",
                policy,
                {"CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE": "allow"},
                1,
            ),
            (
                "environment zero",
                policy,
                {"CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE": "0"},
                1,
            ),
            ("crates.io override", policy, {"CARGO_REGISTRY_MIN_PUBLISH_AGE": "0"}, 1),
        ]
        for label, content, overrides, expected_status in cases:
            with self.subTest(policy=label):
                config.write_text(content)
                result = subprocess.run(
                    [sys.executable, HOOK, "--probe"],
                    cwd=self.project,
                    env=environment | overrides,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, expected_status, result.stderr)
                if expected_status:
                    # A resolver error is not proof that a disabled policy was detected.
                    self.assertIn(
                        "公開直後の検証用パッケージを除外しませんでした", result.stderr
                    )
                self.assertFalse((self.project / "Cargo.lock").exists())


if __name__ == "__main__":
    unittest.main()
