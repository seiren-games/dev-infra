"""Check the commit gate against real Git indexes and the pinned formatter."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(os.environ["DEV_INFRA_TEST_ROOT"])
BASH = os.environ["DEV_INFRA_TEST_BASH"]


class PreCommitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pre-commit-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repo = self.directory / "repository with spaces"
        self.repo.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "nix.json"
        self.secret_log = self.directory / "secret-scan.txt"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            PRE_COMMIT_TEST_LOG=str(self.log),
            PRE_COMMIT_TEST_SECRET_LOG=str(self.secret_log),
        )
        self.git("init", "--quiet")
        self.write("flake.nix", "{}\n")
        self.write("flake.lock", "{}\n")
        self.write("rust/.codex/config.toml", "value = 1\n")
        self.git("add", ".")
        # Keep Nix's expensive execution boundary small while using real Tombi
        # on the actual exported source. Use offline mode only in these sandboxed
        # tests; the hook forwards the ordinary online formatter command.
        nix = self.bin / "nix"
        nix.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, subprocess, sys\n"
            "root = pathlib.Path.cwd()\n"
            "files = {str(p.relative_to(root)): p.read_text()\n"
            "         for p in root.rglob('*') if p.is_file()}\n"
            "record = {'args': sys.argv[1:], 'root': str(root), 'files': files,\n"
            "          'symlinks': {str(p.relative_to(root)): os.readlink(p)\n"
            "                       for p in root.rglob('*') if p.is_symlink()},\n"
            "          'executable': [str(p.relative_to(root)) for p in root.rglob('*')\n"
            "                         if p.is_file() and p.stat().st_mode & 0o111],\n"
            "          'git_env': {k: os.environ[k] for k in\n"
            "                      ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')\n"
            "                      if k in os.environ}}\n"
            "log = pathlib.Path(os.environ['PRE_COMMIT_TEST_LOG'])\n"
            "record['calls'] = json.loads(log.read_text())['calls'] if log.exists() else []\n"
            "record['calls'].append(sys.argv[1:])\n"
            "log.write_text(json.dumps(record))\n"
            "if sys.argv[1] == 'develop':\n"
            "    command = sys.argv[sys.argv.index('--command') + 1:]\n"
            "    assert command[0] == 'tombi'\n"
            "    command[0] = os.environ['DEV_INFRA_TEST_TOMBI']\n"
            "    sys.exit(subprocess.run(command + ['--offline']).returncode)\n"
            "sys.exit(int(os.environ.get('PRE_COMMIT_TEST_NIX_EXIT', '0')))\n"
        )
        nix.chmod(0o755)

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=self.env, check=True, capture_output=True
        )

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_check(self, *, hook=False, cwd=None, **env):
        self.log.unlink(missing_ok=True)
        index = self.repo / ".git/index"
        original_index = index.read_bytes()
        result = subprocess.run(
            [BASH, ROOT / (".githooks/pre-commit" if hook else "scripts/check-staged")],
            cwd=cwd or self.repo,
            env=dict(self.env, **env),
            capture_output=True,
            text=True,
        )
        self.assertEqual(index.read_bytes(), original_index)
        if self.log.exists():
            record = json.loads(self.log.read_text())
            self.assertFalse(
                Path(record["root"]).exists(), "snapshot must be cleaned up"
            )
            self.assertEqual(record["git_env"], {})
            for args in record["calls"]:
                self.assertIn("--no-update-lock-file", args)
                self.assertIn("path:" + record["root"], args)
        return result

    def test_staged_format_error_is_not_hidden_by_unstaged_fix(self):
        self.write("rust/.codex/config.toml", "value=1\n")
        self.git("add", ".")
        self.write("rust/.codex/config.toml", "value = 1\n")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config.toml", result.stderr)
        self.assertEqual(len(json.loads(self.log.read_text())["calls"]), 1)
        self.assertEqual(
            (self.repo / "rust/.codex/config.toml").read_text(), "value = 1\n"
        )

    def test_unstaged_and_untracked_errors_do_not_block_staged_contents(self):
        self.write("rust/.codex/config.toml", "value=1\n")
        self.write("untracked.toml", "invalid = [\n")
        result = self.run_check(cwd=self.repo / "rust")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json.loads(self.log.read_text())["calls"]
        self.assertEqual(calls[0][-4:], ["--command", "tombi", "format", "--check"])
        self.assertEqual(calls[1][:2], ["flake", "check"])
        files = json.loads(self.log.read_text())["files"]
        self.assertEqual(files["rust/.codex/config.toml"], "value = 1\n")
        self.assertNotIn("untracked.toml", files)
        self.assertEqual(
            (self.repo / "rust/.codex/config.toml").read_text(), "value=1\n"
        )

    def test_unstaged_encoding_attributes_do_not_change_staged_contents(self):
        self.write(".gitattributes", "* text=auto eol=lf\n")
        self.git("add", ".gitattributes")
        self.write(
            ".gitattributes",
            "* text=auto eol=lf\n*.toml working-tree-encoding=UTF-16LE\n",
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = json.loads(self.log.read_text())["files"]
        self.assertEqual(files["rust/.codex/config.toml"], "value = 1\n")
        self.assertEqual(files[".gitattributes"], "* text=auto eol=lf\n")

    def test_smudge_filter_cannot_hide_staged_format_error(self):
        self.write("rust/.codex/config.toml", "value=1\n")
        self.git("add", ".")
        self.git("config", "filter.format.smudge", 'sed "s/value=1/value = 1/"')
        self.write(".gitattributes", "*.toml filter=format\n")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config.toml", result.stderr)
        record = json.loads(self.log.read_text())
        self.assertEqual(record["files"]["rust/.codex/config.toml"], "value=1\n")
        self.assertEqual(len(record["calls"]), 1)

    def test_paths_and_symlink_targets_preserve_tabs_and_newlines(self):
        target = "directory with spaces/file\tname\n"
        self.write(target, "staged content\n")
        (self.repo / "link").symlink_to(target)
        self.git("add", ".")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.log.read_text())
        self.assertEqual(record["files"][target], "staged content\n")
        self.assertEqual(record["symlinks"]["link"], target)

    def test_parent_directory_preserves_trailing_newlines(self):
        path = "directory\n\n/file.txt"
        self.write(path, "staged content\n")
        self.git("add", ".")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = json.loads(self.log.read_text())["files"]
        self.assertEqual(files[path], "staged content\n")
        self.assertNotIn("directory/file.txt", files)

    def test_staged_additions_deletions_and_executable_files_are_exported(self):
        added = self.write("new directory/new.toml", "value = 2\n")
        executable = self.write("scripts/tool", "#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        self.git("add", ".")
        self.git("rm", "--cached", "rust/.codex/config.toml")
        added.unlink()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = json.loads(self.log.read_text())["files"]
        self.assertEqual(files["new directory/new.toml"], "value = 2\n")
        self.assertNotIn("rust/.codex/config.toml", files)
        self.assertIn("scripts/tool", json.loads(self.log.read_text())["executable"])

    def test_partial_commit_uses_the_index_supplied_by_git(self):
        alternate_index = self.directory / "partial-index"
        shutil.copyfile(self.repo / ".git/index", alternate_index)
        self.write("rust/.codex/config.toml", "value=1\n")
        self.git("add", ".")
        original_alternate = alternate_index.read_bytes()
        result = self.run_check(
            GIT_INDEX_FILE=str(alternate_index),
            GIT_DIR=str(self.repo / ".git"),
            GIT_WORK_TREE=str(self.repo),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(alternate_index.read_bytes(), original_alternate)

    def test_nix_failure_blocks_commit_and_cleans_snapshot(self):
        result = self.run_check(PRE_COMMIT_TEST_NIX_EXIT="42")
        self.assertEqual(result.returncode, 42, result.stderr)

    def test_missing_staged_flake_or_lock_fails_before_nix(self):
        for filename in ("flake.nix", "flake.lock"):
            with self.subTest(filename=filename):
                self.git("rm", "--cached", filename)
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be present in the index", result.stderr)
                self.assertFalse(self.log.exists())
                self.git("add", filename)

    def test_pre_commit_preserves_secret_scan_and_stops_on_either_failure(self):
        scripts = self.repo / "scripts"
        scripts.mkdir()
        checker = self.write(
            "scripts/check-staged",
            f"#!{BASH}\n"
            + (ROOT / "scripts/check-staged").read_text().partition("\n")[2],
        )
        checker.chmod(0o755)
        scanner = self.write(
            "scripts/secret-scan",
            f"#!{BASH}\n"
            'printf "%s\\n" "$@" > "$PRE_COMMIT_TEST_SECRET_LOG"\n'
            'exit "${PRE_COMMIT_TEST_SECRET_EXIT:-0}"\n',
        )
        scanner.chmod(0o755)
        result = self.run_check(hook=True, PRE_COMMIT_TEST_SECRET_EXIT="23")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.secret_log.read_text(), "pre-commit\n")
        self.assertFalse(self.log.exists(), "rejected contents must never reach Nix")
        self.secret_log.unlink()
        result = self.run_check(hook=True, PRE_COMMIT_TEST_NIX_EXIT="42")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.secret_log.read_text(), "pre-commit\n")
        self.assertTrue(self.log.exists())
        result = self.run_check(hook=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
