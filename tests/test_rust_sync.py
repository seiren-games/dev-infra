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
        version=sync_module.FileVersion(
            sha256=sync_module.sha256(content),
            executable=executable,
        ),
    )


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

    def test_notice_after_first_five_lines_does_not_mark_a_file(self) -> None:
        content = b"\n".join([b"line"] * 5 + [sync_module.MANAGED_NOTICE])
        archive = self.make_archive({"rust/not-shared.txt": (content, 0o644)})

        with self.assertRaises(sync_module.SyncError):
            sync_module.read_source_files(archive)


if __name__ == "__main__":
    unittest.main()
