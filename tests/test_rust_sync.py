from __future__ import annotations

import importlib.util
import io
import json
import os
import stat
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from types import ModuleType
from unittest import mock


def load_sync_module() -> ModuleType:
    repository_root = Path(
        os.environ.get("DEV_INFRA_TEST_ROOT", Path(__file__).parents[1])
    )
    script_path = repository_root / "rust" / "sync.py"
    spec = importlib.util.spec_from_file_location("rust_sync", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {script_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sync_module = load_sync_module()


def source_file(content: bytes, *, executable: bool = False):
    return sync_module.SourceFile(
        content=content,
        version=sync_module.file_version(content, executable=executable),
    )


class ExecutionEnvironmentTests(unittest.TestCase):
    def test_native_windows_is_rejected_before_download(self) -> None:
        stderr = io.StringIO()
        with (
            mock.patch.object(sync_module.sys, "platform", "win32"),
            mock.patch.object(sync_module.sys, "stderr", stderr),
            mock.patch.object(sync_module, "download_source_archive") as download,
        ):
            self.assertEqual(sync_module.main(), 1)

        download.assert_not_called()
        self.assertIn("Linux（WSL を含む）専用", stderr.getvalue())

    def test_filesystem_without_executable_mode_support_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            with mock.patch.object(Path, "chmod", autospec=True):
                with self.assertRaisesRegex(
                    sync_module.SyncError,
                    "POSIX 実行権限を保持できません",
                ):
                    sync_module.ensure_executable_mode_support(project_root)

            self.assertEqual(list(project_root.iterdir()), [])


class FlakeInputTests(unittest.TestCase):
    REVISION = "0123456789abcdef0123456789abcdef01234567"

    def write_lock(
        self,
        project_root: Path,
        *,
        original: dict[str, str] | None = None,
        revision: str = REVISION,
    ) -> None:
        dev_infra_original = original or {
            "type": "github",
            "owner": "seiren-games",
            "repo": "dev-infra",
            "ref": "main",
        }
        lock = {
            "nodes": {
                "dev-infra": {
                    "locked": {
                        "type": "github",
                        "owner": "seiren-games",
                        "repo": "dev-infra",
                        "rev": revision,
                    },
                    "original": dev_infra_original,
                },
                "root": {"inputs": {"dev-infra": "dev-infra"}},
            },
            "root": "root",
            "version": 7,
        }
        (project_root / sync_module.FLAKE_LOCK_FILE_NAME).write_text(
            json.dumps(lock),
            encoding="utf-8",
        )

    def test_update_targets_only_dev_infra_and_accepts_explicit_main(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            self.write_lock(project_root)
            completed = mock.Mock(returncode=0)
            stdout = io.StringIO()

            with (
                mock.patch.object(
                    sync_module.subprocess,
                    "run",
                    return_value=completed,
                ) as run,
                mock.patch.object(sync_module.sys, "stdout", stdout),
            ):
                sync_module.update_dev_infra_input(project_root)

            run.assert_called_once_with(
                ["nix", "flake", "update", "dev-infra"],
                cwd=project_root,
                check=False,
            )
            self.assertEqual(
                sync_module.read_locked_dev_infra_revision(project_root),
                self.REVISION,
            )
            self.assertEqual(
                stdout.getvalue(),
                f"確認  dev-infra input ({self.REVISION}, 変更なし)\n",
            )

    def test_update_reports_changed_lock(self) -> None:
        updated_revision = "89abcdef0123456789abcdef0123456789abcdef"
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            self.write_lock(project_root)
            stdout = io.StringIO()

            def update_lock(*_args, **_kwargs):
                self.write_lock(project_root, revision=updated_revision)
                return mock.Mock(returncode=0)

            with (
                mock.patch.object(
                    sync_module.subprocess,
                    "run",
                    side_effect=update_lock,
                ),
                mock.patch.object(sync_module.sys, "stdout", stdout),
            ):
                sync_module.update_dev_infra_input(project_root)

            self.assertEqual(
                stdout.getvalue(),
                f"更新  dev-infra input ({updated_revision})\n",
            )

    def test_update_rejects_commit_pinned_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            self.write_lock(
                project_root,
                original={
                    "type": "github",
                    "owner": "seiren-games",
                    "repo": "dev-infra",
                    "rev": self.REVISION,
                },
            )

            with (
                mock.patch.object(
                    sync_module.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=0),
                ),
                self.assertRaisesRegex(
                    sync_module.SyncError,
                    "github:seiren-games/dev-infra/main",
                ),
            ):
                sync_module.update_dev_infra_input(project_root)

    def test_update_propagates_nix_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            with (
                mock.patch.object(
                    sync_module.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=42),
                ),
                self.assertRaisesRegex(sync_module.SyncError, "status 42"),
            ):
                sync_module.update_dev_infra_input(project_root)

    def test_main_does_not_update_input_after_sync_conflict(self) -> None:
        with (
            mock.patch.object(sync_module, "download_source_archive"),
            mock.patch.object(sync_module, "read_source_files"),
            mock.patch.object(sync_module, "sync", return_value=1),
            mock.patch.object(sync_module, "update_dev_infra_input") as update,
        ):
            self.assertEqual(sync_module.main(), 1)

        update.assert_not_called()

    def test_main_updates_input_after_successful_sync(self) -> None:
        with (
            mock.patch.object(sync_module, "download_source_archive"),
            mock.patch.object(sync_module, "read_source_files"),
            mock.patch.object(sync_module, "sync", return_value=0),
            mock.patch.object(sync_module, "update_dev_infra_input") as update,
        ):
            self.assertEqual(sync_module.main(), 0)

        update.assert_called_once_with(Path(sync_module.__file__).resolve().parent)


class SyncTests(unittest.TestCase):
    def test_initial_sync_creates_missing_files_and_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            files = {
                PurePosixPath(".config/settings.toml"): source_file(
                    b"setting = true\n"
                ),
                PurePosixPath("tool"): source_file(b"#!/bin/sh\n", executable=True),
            }

            self.assertEqual(sync_module.sync(project_root, files), 0)
            self.assertEqual(
                (project_root / ".config/settings.toml").read_bytes(),
                b"setting = true\n",
            )
            tool_mode = (project_root / "tool").stat().st_mode
            self.assertTrue(tool_mode & stat.S_IXUSR)

            state = sync_module.load_state(project_root)
            self.assertEqual(
                state.files, {path: file.version for path, file in files.items()}
            )

    def test_latest_files_are_not_rewritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            path = PurePosixPath("shared.txt")
            files = {path: source_file(b"current\n")}
            self.assertEqual(sync_module.sync(project_root, files), 0)

            destination = project_root / "shared.txt"
            state_path = project_root / sync_module.STATE_FILE_NAME
            file_mtime = destination.stat().st_mtime_ns
            state_mtime = state_path.stat().st_mtime_ns

            self.assertEqual(sync_module.sync(project_root, files), 0)
            self.assertEqual(destination.stat().st_mtime_ns, file_mtime)
            self.assertEqual(state_path.stat().st_mtime_ns, state_mtime)

    def test_clean_old_file_is_updated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            path = PurePosixPath("shared.txt")
            old_files = {path: source_file(b"old\n")}
            new_files = {path: source_file(b"new\n")}

            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertEqual((project_root / "shared.txt").read_bytes(), b"new\n")
            self.assertEqual(
                sync_module.load_state(project_root).files[path],
                new_files[path].version,
            )

    def test_checkout_crlf_conversion_remains_clean_for_update_and_removal(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            updated_path = PurePosixPath("update.bat")
            removed_path = PurePosixPath("remove.cmd")
            old_files = {
                updated_path: source_file(b"@echo old\n"),
                removed_path: source_file(b"@echo remove\n"),
            }
            new_files = {updated_path: source_file(b"@echo new\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)

            (project_root / updated_path).write_bytes(b"@echo old\r\n")
            (project_root / removed_path).write_bytes(b"@echo remove\r\n")

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertEqual(
                (project_root / updated_path).read_bytes(),
                new_files[updated_path].content,
            )
            self.assertFalse((project_root / removed_path).exists())
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {updated_path: new_files[updated_path].version},
            )

    def test_initial_existing_different_file_is_a_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            (project_root / "conflict.txt").write_bytes(b"local\n")
            files = {
                PurePosixPath("conflict.txt"): source_file(b"upstream\n"),
                PurePosixPath("missing.txt"): source_file(b"created\n"),
            }

            self.assertEqual(sync_module.sync(project_root, files), 1)
            self.assertEqual((project_root / "conflict.txt").read_bytes(), b"local\n")
            self.assertEqual((project_root / "missing.txt").read_bytes(), b"created\n")
            self.assertNotIn(
                PurePosixPath("conflict.txt"),
                sync_module.load_state(project_root).files,
            )

    def test_modified_file_is_not_overwritten_while_other_file_updates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            conflict_path = PurePosixPath("conflict.txt")
            clean_path = PurePosixPath("clean.txt")
            old_files = {
                conflict_path: source_file(b"old conflict\n"),
                clean_path: source_file(b"old clean\n"),
            }
            new_files = {
                conflict_path: source_file(b"new conflict\n"),
                clean_path: source_file(b"new clean\n"),
            }
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "conflict.txt").write_bytes(b"local change\n")

            self.assertEqual(sync_module.sync(project_root, new_files), 1)
            self.assertEqual(
                (project_root / "conflict.txt").read_bytes(),
                b"local change\n",
            )
            self.assertEqual((project_root / "clean.txt").read_bytes(), b"new clean\n")

            state = sync_module.load_state(project_root)
            self.assertEqual(
                state.files[conflict_path], old_files[conflict_path].version
            )
            self.assertEqual(state.files[clean_path], new_files[clean_path].version)

    def test_removed_clean_file_is_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            removed_path = PurePosixPath("nested/removed.txt")
            kept_path = PurePosixPath("kept.txt")
            old_files = {
                removed_path: source_file(b"remove me\n"),
                kept_path: source_file(b"keep me\n"),
            }
            new_files = {kept_path: old_files[kept_path]}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertFalse((project_root / "nested/removed.txt").exists())
            self.assertFalse((project_root / "nested").exists())
            self.assertNotIn(removed_path, sync_module.load_state(project_root).files)

    def test_removed_modified_file_is_preserved_as_a_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            removed_path = PurePosixPath("removed.txt")
            kept_path = PurePosixPath("kept.txt")
            old_files = {
                removed_path: source_file(b"remove me\n"),
                kept_path: source_file(b"keep me\n"),
            }
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "removed.txt").write_bytes(b"local change\n")

            self.assertEqual(
                sync_module.sync(project_root, {kept_path: old_files[kept_path]}), 1
            )
            self.assertEqual(
                (project_root / "removed.txt").read_bytes(),
                b"local change\n",
            )
            self.assertIn(removed_path, sync_module.load_state(project_root).files)

    def test_removed_file_below_symlinked_parent_is_not_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            project_root = temporary_root / "project"
            external_root = temporary_root / "external"
            project_root.mkdir()
            external_root.mkdir()
            removed_path = PurePosixPath(".cargo/config.toml")
            old_files = {removed_path: source_file(b"managed config\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)

            (project_root / ".cargo/config.toml").unlink()
            (project_root / ".cargo").rmdir()
            external_file = external_root / "config.toml"
            external_file.write_bytes(old_files[removed_path].content)
            (project_root / ".cargo").symlink_to(
                external_root,
                target_is_directory=True,
            )

            self.assertEqual(sync_module.sync(project_root, {}), 1)
            self.assertEqual(
                external_file.read_bytes(),
                old_files[removed_path].content,
            )
            self.assertIn(removed_path, sync_module.load_state(project_root).files)

    def test_clean_file_can_be_replaced_with_directory_in_one_sync(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared")
            new_path = PurePosixPath("shared/config.toml")
            old_files = {old_path: source_file(b"old file\n")}
            new_files = {new_path: source_file(b"new nested file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertTrue((project_root / "shared").is_dir())
            self.assertEqual(
                (project_root / "shared/config.toml").read_bytes(),
                b"new nested file\n",
            )
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_clean_directory_can_be_replaced_with_file_in_one_sync(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared/config.toml")
            new_path = PurePosixPath("shared")
            old_files = {old_path: source_file(b"old nested file\n")}
            new_files = {new_path: source_file(b"new file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertTrue((project_root / "shared").is_file())
            self.assertEqual((project_root / "shared").read_bytes(), b"new file\n")
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_adopting_directory_layout_clears_obsolete_file_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared")
            new_path = PurePosixPath("shared/config.toml")
            old_files = {old_path: source_file(b"old file\n")}
            new_files = {new_path: source_file(b"new nested file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "shared").write_bytes(b"local change\n")
            self.assertEqual(sync_module.sync(project_root, new_files), 1)

            (project_root / "shared").unlink()
            (project_root / "shared").mkdir()
            (project_root / "shared/config.toml").write_bytes(b"local nested change\n")
            self.assertEqual(sync_module.sync(project_root, new_files), 1)
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {old_path: old_files[old_path].version},
            )

            (project_root / "shared/config.toml").write_bytes(
                new_files[new_path].content
            )
            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_adopting_file_layout_clears_obsolete_nested_file_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared/config.toml")
            new_path = PurePosixPath("shared")
            old_files = {old_path: source_file(b"old nested file\n")}
            new_files = {new_path: source_file(b"new file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "shared/config.toml").write_bytes(b"local change\n")
            self.assertEqual(sync_module.sync(project_root, new_files), 1)

            (project_root / "shared/config.toml").unlink()
            (project_root / "shared").rmdir()
            (project_root / "shared").write_bytes(new_files[new_path].content)

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_empty_directory_with_missing_managed_file_can_be_replaced_with_file(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared/config.toml")
            new_path = PurePosixPath("shared")
            old_files = {old_path: source_file(b"old nested file\n")}
            new_files = {new_path: source_file(b"new file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "shared/config.toml").unlink()

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertTrue((project_root / "shared").is_file())
            self.assertEqual((project_root / "shared").read_bytes(), b"new file\n")
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_missing_nested_directory_does_not_block_replacement_with_file(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            old_path = PurePosixPath("shared/config/file")
            new_path = PurePosixPath("shared")
            old_files = {old_path: source_file(b"old nested file\n")}
            new_files = {new_path: source_file(b"new file\n")}
            self.assertEqual(sync_module.sync(project_root, old_files), 0)
            (project_root / "shared/config/file").unlink()
            (project_root / "shared/config").rmdir()

            self.assertEqual(sync_module.sync(project_root, new_files), 0)
            self.assertTrue((project_root / "shared").is_file())
            self.assertEqual((project_root / "shared").read_bytes(), b"new file\n")
            self.assertEqual(
                sync_module.load_state(project_root).files,
                {new_path: new_files[new_path].version},
            )

    def test_executable_bit_change_uses_the_same_conflict_rules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            path = PurePosixPath("tool")
            non_executable = {path: source_file(b"tool\n")}
            executable = {path: source_file(b"tool\n", executable=True)}
            self.assertEqual(sync_module.sync(project_root, non_executable), 0)

            self.assertEqual(sync_module.sync(project_root, executable), 0)
            self.assertTrue((project_root / "tool").stat().st_mode & stat.S_IXUSR)

            os.chmod(project_root / "tool", 0o644)
            self.assertEqual(sync_module.sync(project_root, executable), 1)
            self.assertFalse((project_root / "tool").stat().st_mode & stat.S_IXUSR)

    def test_version_one_state_is_migrated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory)
            path = PurePosixPath("shared.txt")
            files = {path: source_file(b"shared\n")}
            (project_root / "shared.txt").write_bytes(b"shared\n")
            version_one_state = {
                "schema_version": 1,
                "source": {
                    "repository": sync_module.SOURCE_REPOSITORY,
                    "ref": sync_module.SOURCE_REF,
                    "directory": "rust",
                },
                "files": {
                    path.as_posix(): {
                        "sha256": files[path].version.sha256,
                        "executable": False,
                    }
                },
            }
            (project_root / sync_module.STATE_FILE_NAME).write_text(
                json.dumps(version_one_state),
                encoding="utf-8",
            )

            self.assertEqual(sync_module.sync(project_root, files), 0)
            migrated_state = json.loads(
                (project_root / sync_module.STATE_FILE_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(
                migrated_state["schema_version"],
                sync_module.STATE_SCHEMA_VERSION,
            )
            self.assertEqual(migrated_state["source"], sync_module.source_identity())


class SourceArchiveTests(unittest.TestCase):
    def make_archive(self, files: dict[str, tuple[bytes, int]]) -> bytes:
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as output:
            for path, (content, mode) in files.items():
                info = tarfile.TarInfo(f"dev-infra-main/{path}")
                info.size = len(content)
                info.mode = mode
                output.addfile(info, io.BytesIO(content))
        return archive.getvalue()

    def test_only_header_marked_rust_files_are_selected(self) -> None:
        notice = sync_module.MANAGED_NOTICE
        archive = self.make_archive(
            {
                "rust/shared.txt": (b"# " + notice + b"\nshared\n", 0o644),
                "rust/bin/tool": (b"#!/bin/sh\n# " + notice + b"\n", 0o755),
                "rust/not-shared.txt": (b"local source file\n", 0o644),
                ".editorconfig": (b"# " + notice + b"\nroot = true\n", 0o644),
                ".gitattributes": (b"# " + notice + b"\n* text=auto\n", 0o644),
                ".other-root-file": (b"# " + notice + b"\n", 0o644),
                "README.md": (b"# repository\n", 0o644),
            }
        )

        files = sync_module.read_source_files(archive)

        self.assertEqual(
            set(files),
            {
                PurePosixPath("shared.txt"),
                PurePosixPath("bin/tool"),
                PurePosixPath(".editorconfig"),
                PurePosixPath(".gitattributes"),
            },
        )
        self.assertTrue(files[PurePosixPath("bin/tool")].version.executable)

    def test_cooldown_hook_and_script_are_shared_together(self) -> None:
        rust_root = Path(sync_module.__file__).parent
        paths = (".codex/config.toml", "scripts/codex-cargo-cooldown.py")
        archive = self.make_archive({
            f"rust/{path}": ((rust_root / path).read_bytes(), 0o644)
            for path in paths
        })
        files = sync_module.read_source_files(archive)
        self.assertEqual(set(files), {PurePosixPath(path) for path in paths})
        with tempfile.TemporaryDirectory() as directory:
            project_root = Path(directory)
            self.assertEqual(sync_module.sync(project_root, files), 0)
            for path in paths:
                self.assertEqual(
                    (project_root / path).read_bytes(),
                    (rust_root / path).read_bytes(),
                )

    def test_notice_after_first_five_lines_does_not_mark_a_file(self) -> None:
        content = b"\n".join([b"line"] * 5 + [sync_module.MANAGED_NOTICE])
        archive = self.make_archive({"rust/not-shared.txt": (content, 0o644)})

        with self.assertRaises(sync_module.SyncError):
            sync_module.read_source_files(archive)


if __name__ == "__main__":
    unittest.main()
