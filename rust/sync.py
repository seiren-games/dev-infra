#!/usr/bin/env python3
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path, PurePosixPath
from typing import Final, Mapping

SOURCE_REPOSITORY: Final = "seiren-games/dev-infra"
SOURCE_REF: Final = "main"
RUST_SOURCE_DIRECTORY: Final = PurePosixPath("rust")
ROOT_SOURCE_FILES: Final = (
    PurePosixPath(".editorconfig"),
    PurePosixPath(".gitattributes"),
)
SOURCE_ARCHIVE_URL: Final = (
    f"https://codeload.github.com/{SOURCE_REPOSITORY}/tar.gz/refs/heads/{SOURCE_REF}"
)
STATE_FILE_NAME: Final = ".dev-infra-rust-sync.json"
STATE_SCHEMA_VERSION: Final = 2
MAX_ARCHIVE_SIZE: Final = 20 * 1024 * 1024
MANAGED_NOTICE: Final = (
    "このファイルは https://github.com/seiren-games/dev-infra で管理されています。"
    "様々なリポジトリで共有することが目的のファイルです。"
).encode("utf-8")


class SyncError(Exception):
    pass


@dataclass(frozen=True)
class FileVersion:
    sha256: str
    executable: bool


@dataclass(frozen=True)
class SourceFile:
    content: bytes
    version: FileVersion


@dataclass(frozen=True)
class SyncState:
    files: Mapping[PurePosixPath, FileVersion]


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def is_managed(content: bytes) -> bool:
    return any(MANAGED_NOTICE in line for line in content.splitlines()[:5])


def validate_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise SyncError(f"不正な同期対象パスです: {value!r}")
    if path.as_posix() != value:
        raise SyncError(f"正規化されていない同期対象パスです: {value!r}")
    return path


def source_identity() -> dict[str, object]:
    return {
        "repository": SOURCE_REPOSITORY,
        "ref": SOURCE_REF,
        "rust_directory": RUST_SOURCE_DIRECTORY.as_posix(),
        "root_files": [path.as_posix() for path in ROOT_SOURCE_FILES],
    }


def destination_path(repository_path: PurePosixPath) -> PurePosixPath | None:
    if repository_path in ROOT_SOURCE_FILES:
        return repository_path
    try:
        relative_path = repository_path.relative_to(RUST_SOURCE_DIRECTORY)
    except ValueError:
        return None
    if not relative_path.parts:
        return None
    return validate_relative_path(relative_path.as_posix())


def download_source_archive() -> bytes:
    request = urllib.request.Request(
        SOURCE_ARCHIVE_URL,
        headers={"User-Agent": "dev-infra-rust-sync/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > MAX_ARCHIVE_SIZE:
                raise SyncError(
                    f"取得元アーカイブが上限 {MAX_ARCHIVE_SIZE} bytes を超えています"
                )
            archive = response.read(MAX_ARCHIVE_SIZE + 1)
    except (OSError, urllib.error.URLError, ValueError) as error:
        raise SyncError(
            f"取得元アーカイブのダウンロードに失敗しました: {error}"
        ) from error

    if len(archive) > MAX_ARCHIVE_SIZE:
        raise SyncError(
            f"取得元アーカイブが上限 {MAX_ARCHIVE_SIZE} bytes を超えています"
        )
    return archive


def read_source_files(archive: bytes) -> dict[PurePosixPath, SourceFile]:
    files: dict[PurePosixPath, SourceFile] = {}
    try:
        with tarfile.open(fileobj=BytesIO(archive), mode="r:gz") as source_archive:
            members = source_archive.getmembers()
            if not members:
                raise SyncError("取得元アーカイブが空です")

            archive_root = PurePosixPath(members[0].name).parts[0]
            archive_prefix = PurePosixPath(archive_root)
            for member in members:
                member_path = PurePosixPath(member.name)
                try:
                    repository_path = member_path.relative_to(archive_prefix)
                except ValueError:
                    continue
                if not repository_path.parts or not member.isfile():
                    continue

                normalized_path = destination_path(repository_path)
                if normalized_path is None:
                    continue
                extracted = source_archive.extractfile(member)
                if extracted is None:
                    raise SyncError(
                        f"取得元ファイルを読み取れません: {normalized_path.as_posix()}"
                    )
                content = extracted.read()
                if not is_managed(content):
                    continue
                if normalized_path == PurePosixPath(STATE_FILE_NAME):
                    raise SyncError(
                        f"{STATE_FILE_NAME} は同期状態の保存用に予約されています"
                    )
                if normalized_path in files:
                    raise SyncError(
                        f"複数の取得元が同じ同期先を使用しています: "
                        f"{normalized_path.as_posix()}"
                    )

                files[normalized_path] = SourceFile(
                    content=content,
                    version=FileVersion(
                        sha256=sha256(content),
                        executable=bool(member.mode & stat.S_IXUSR),
                    ),
                )
    except (tarfile.TarError, OSError) as error:
        raise SyncError(f"取得元アーカイブの解析に失敗しました: {error}") from error

    if not files:
        raise SyncError("管理元ヘッダーを持つ共有ファイルが取得元にありません")
    return files


def parse_file_version(value: object, path: PurePosixPath) -> FileVersion:
    if not isinstance(value, dict):
        raise SyncError(f"状態ファイルの {path.as_posix()} が不正です")
    if set(value) != {"sha256", "executable"}:
        raise SyncError(f"状態ファイルの {path.as_posix()} が不正です")

    digest = value["sha256"]
    executable = value["executable"]
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
        or not isinstance(executable, bool)
    ):
        raise SyncError(f"状態ファイルの {path.as_posix()} が不正です")
    return FileVersion(sha256=digest, executable=executable)


def load_state(project_root: Path) -> SyncState:
    state_path = project_root / STATE_FILE_NAME
    if not state_path.exists():
        return SyncState(files={})
    if state_path.is_symlink() or not state_path.is_file():
        raise SyncError(f"状態ファイルが通常ファイルではありません: {state_path}")

    try:
        value = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SyncError(f"状態ファイルを読み取れません: {error}") from error

    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "source",
        "files",
    }:
        raise SyncError("状態ファイルの形式が不正です")
    schema_version = value["schema_version"]
    if schema_version not in {1, STATE_SCHEMA_VERSION}:
        raise SyncError(f"未対応の状態ファイル schema_version です: {schema_version!r}")
    version_one_source = {
        "repository": SOURCE_REPOSITORY,
        "ref": SOURCE_REF,
        "directory": RUST_SOURCE_DIRECTORY.as_posix(),
    }
    expected_source = version_one_source if schema_version == 1 else source_identity()
    if value["source"] != expected_source:
        raise SyncError("状態ファイルの取得元がこのスクリプトと一致しません")
    if not isinstance(value["files"], dict):
        raise SyncError("状態ファイルの files が不正です")

    files: dict[PurePosixPath, FileVersion] = {}
    for path_value, version_value in value["files"].items():
        if not isinstance(path_value, str):
            raise SyncError("状態ファイルに文字列ではないパスがあります")
        path = validate_relative_path(path_value)
        files[path] = parse_file_version(version_value, path)
    return SyncState(files=files)


def serialize_state(files: Mapping[PurePosixPath, FileVersion]) -> bytes:
    value = {
        "schema_version": STATE_SCHEMA_VERSION,
        "source": source_identity(),
        "files": {
            path.as_posix(): {
                "sha256": version.sha256,
                "executable": version.executable,
            }
            for path, version in sorted(files.items())
        },
    }
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def local_file_version(path: Path) -> FileVersion | None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SyncError(f"{path} の状態を確認できません: {error}") from error

    if not stat.S_ISREG(file_stat.st_mode):
        raise SyncError(f"{path} は通常ファイルではありません")
    try:
        content = path.read_bytes()
    except OSError as error:
        raise SyncError(f"{path} を読み取れません: {error}") from error
    return FileVersion(
        sha256=sha256(content),
        executable=bool(file_stat.st_mode & stat.S_IXUSR),
    )


def ensure_parent_directory(project_root: Path, relative_path: PurePosixPath) -> Path:
    parent = project_root
    for part in relative_path.parts[:-1]:
        parent /= part
        try:
            parent_stat = parent.lstat()
        except FileNotFoundError:
            try:
                parent.mkdir()
            except OSError as error:
                raise SyncError(
                    f"ディレクトリを作成できません: {parent}: {error}"
                ) from error
            continue
        except OSError as error:
            raise SyncError(
                f"ディレクトリの状態を確認できません: {parent}: {error}"
            ) from error
        if not stat.S_ISDIR(parent_stat.st_mode):
            raise SyncError(f"同期先の親がディレクトリではありません: {parent}")
    return parent / relative_path.name


def write_file_atomically(
    project_root: Path,
    relative_path: PurePosixPath,
    source_file: SourceFile,
) -> None:
    destination = ensure_parent_directory(project_root, relative_path)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as temporary_file:
            temporary_file.write(source_file.content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
            temporary_path = Path(temporary_file.name)
        temporary_path.chmod(0o755 if source_file.version.executable else 0o644)
        os.replace(temporary_path, destination)
        temporary_path = None
    except OSError as error:
        raise SyncError(f"{destination} を更新できません: {error}") from error
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def delete_file(project_root: Path, relative_path: PurePosixPath) -> None:
    destination = project_root.joinpath(*relative_path.parts)
    try:
        destination.unlink()
    except OSError as error:
        raise SyncError(f"{destination} を削除できません: {error}") from error

    parent = destination.parent
    while parent != project_root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent


def save_state(
    project_root: Path,
    files: Mapping[PurePosixPath, FileVersion],
) -> None:
    state_path = project_root / STATE_FILE_NAME
    content = serialize_state(files)
    if state_path.exists():
        try:
            if state_path.read_bytes() == content:
                return
        except OSError as error:
            raise SyncError(f"状態ファイルを読み取れません: {error}") from error

    source_file = SourceFile(
        content=content,
        version=FileVersion(sha256=sha256(content), executable=False),
    )
    write_file_atomically(project_root, PurePosixPath(STATE_FILE_NAME), source_file)


def sync(project_root: Path, source_files: Mapping[PurePosixPath, SourceFile]) -> int:
    previous_state = load_state(project_root)
    next_state = dict(previous_state.files)
    conflict_count = 0

    for relative_path, source_file in sorted(source_files.items()):
        destination = project_root.joinpath(*relative_path.parts)
        try:
            local_version = local_file_version(destination)
        except SyncError as error:
            print(f"エラー  {relative_path.as_posix()}: {error}", file=sys.stderr)
            conflict_count += 1
            continue

        previous_version = previous_state.files.get(relative_path)
        if local_version == source_file.version:
            next_state[relative_path] = source_file.version
            continue
        if local_version is not None and (
            previous_version is None or local_version != previous_version
        ):
            print(
                f"エラー  {relative_path.as_posix()}: 利用側で変更されているため上書きしません",
                file=sys.stderr,
            )
            conflict_count += 1
            continue

        action = "取得" if local_version is None else "更新"
        try:
            write_file_atomically(project_root, relative_path, source_file)
        except SyncError as error:
            print(f"エラー  {relative_path.as_posix()}: {error}", file=sys.stderr)
            conflict_count += 1
            continue
        next_state[relative_path] = source_file.version
        print(f"{action}  {relative_path.as_posix()}")

    removed_paths = previous_state.files.keys() - source_files.keys()
    for relative_path in sorted(removed_paths):
        destination = project_root.joinpath(*relative_path.parts)
        try:
            local_version = local_file_version(destination)
        except SyncError as error:
            print(f"エラー  {relative_path.as_posix()}: {error}", file=sys.stderr)
            conflict_count += 1
            continue

        previous_version = previous_state.files[relative_path]
        if local_version is None:
            next_state.pop(relative_path, None)
            continue
        if local_version != previous_version:
            print(
                f"エラー  {relative_path.as_posix()}: "
                "利用側で変更されているため配布終了ファイルを削除しません",
                file=sys.stderr,
            )
            conflict_count += 1
            continue

        try:
            delete_file(project_root, relative_path)
        except SyncError as error:
            print(f"エラー  {relative_path.as_posix()}: {error}", file=sys.stderr)
            conflict_count += 1
            continue
        next_state.pop(relative_path, None)
        print(f"削除  {relative_path.as_posix()}")

    save_state(project_root, next_state)
    if conflict_count:
        print(f"{conflict_count} 件の同期エラーがあります", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    project_root = Path(__file__).resolve().parent
    try:
        archive = download_source_archive()
        source_files = read_source_files(archive)
        return sync(project_root, source_files)
    except SyncError as error:
        print(f"同期エラー: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
