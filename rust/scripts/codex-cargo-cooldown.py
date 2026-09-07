#!/usr/bin/env python3
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
"""Check Cargo's effective cooldown without changing the project or its policy."""

import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import tomllib

DEPENDENCY = "codex-cooldown-probe-dependency"
OLD_VERSION = "1.0.0"
NEW_VERSION = "1.0.1"


def create_probe(root: Path) -> Path:
    registry = root / "registry"
    index = registry / "index" / DEPENDENCY[:2] / DEPENDENCY[2:4] / DEPENDENCY
    index.parent.mkdir(parents=True)
    entries = []
    for version, published in (
        (OLD_VERSION, "2000-01-01T00:00:00Z"),
        (
            NEW_VERSION,
            datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        ),
    ):
        archive = registry / f"{DEPENDENCY}-{version}.crate"
        with tarfile.open(archive, "w:gz") as tar:
            files = {
                "Cargo.toml": (
                    f'[package]\nname = "{DEPENDENCY}"\n'
                    f'version = "{version}"\nedition = "2021"\n'
                ),
                "src/lib.rs": "",
            }
            for filename, content in files.items():
                data = content.encode()
                entry = tarfile.TarInfo(f"{DEPENDENCY}-{version}/{filename}")
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
        entries.append(
            json.dumps(
                {
                    "name": DEPENDENCY,
                    "vers": version,
                    "deps": [],
                    "cksum": hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "features": {},
                    "yanked": False,
                    "pubtime": published,
                }
            )
        )
    index.write_text("\n".join(entries) + "\n")
    (root / "Cargo.toml").write_text(
        '[package]\nname = "codex-cooldown-probe"\nversion = "0.0.0"\n'
        'edition = "2021"\n[workspace]\n[dependencies]\n'
        f'{DEPENDENCY} = "1"\n'
    )
    (root / "src").mkdir()
    (root / "src/lib.rs").touch()
    return registry


def check_cooldown() -> None:
    with tempfile.TemporaryDirectory(prefix="codex-cargo-cooldown-") as directory:
        root = Path(directory)
        registry = create_probe(root)
        # Keep the session cwd: Cargo loads its configuration from cwd, even
        # when --manifest-path points elsewhere. Only the registry source is
        # replaced; no cooldown flag, config, environment, or Cargo version is set.
        result = subprocess.run(
            [
                "cargo",
                "generate-lockfile",
                "--offline",
                "--manifest-path",
                str(root / "Cargo.toml"),
                "--config",
                'source.crates-io.replace-with="codex-cooldown-probe"',
                "--config",
                f"source.codex-cooldown-probe.local-registry={json.dumps(str(registry))}",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if result.returncode:
            # Do not forward arbitrary Cargo config/credential diagnostics into
            # model context. A failed command is never counted as a passing probe.
            raise RuntimeError(
                f"Cargo の cooldown 検証用の依存解決に失敗しました (exit {result.returncode})。"
            )
        with (root / "Cargo.lock").open("rb") as lockfile:
            packages = tomllib.load(lockfile)["package"]
        selected = [p["version"] for p in packages if p["name"] == DEPENDENCY]
        if selected != [OLD_VERSION]:
            raise RuntimeError(
                "Cargo が公開直後の検証用パッケージを除外しませんでした。"
                "ログイン後の PATH と Cargo の cooldown 設定を確認してください。"
            )


def session_start() -> dict:
    event = json.load(sys.stdin)
    cwd = Path(event["cwd"])
    if not cwd.is_absolute() or not cwd.is_dir():
        raise ValueError("SessionStart の cwd が有効な絶対パスではありません。")
    shell = os.environ["SHELL"]
    if not Path(shell).is_absolute() or Path(shell).name != "bash":
        raise ValueError("この cooldown 検証は Bash ログインシェルを対象としています。")
    result = subprocess.run(
        [
            shell,
            "-lc",
            'cd -- "$1" && exec "$2" "$3" --probe',
            "codex-cargo-cooldown",
            str(cwd),
            sys.executable,
            str(Path(__file__).resolve()),
        ],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(
            "ログインシェルで Cargo の cooldown の有効性を確認できませんでした。"
            "PATH と cooldown 設定を修正するまで依存追加・更新を実行しないでください。"
        )
    return {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": (
                "Bash ログイン後の Cargo で、公開直後の検証用パッケージが"
                "新しい依存解決から除外されることを確認しました。"
                "これは起動時の crates.io 用 cooldown の動作確認です。"
            ),
        }
    }


def main() -> int:
    if sys.argv[1:] == ["--probe"]:
        try:
            check_cooldown()
        except (
            OSError,
            ValueError,
            KeyError,
            RuntimeError,
            subprocess.SubprocessError,
        ) as error:
            print(f"Cargo cooldown: {error}", file=sys.stderr)
            return 1
        return 0
    try:
        if sys.argv[1:]:
            raise ValueError(
                "引数は不要です。単独の動作確認には --probe を使ってください。"
            )
        output = session_start()
    except (
        OSError,
        ValueError,
        KeyError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        message = f"Cargo cooldown: {error}"
        output = {
            "continue": False,
            "stopReason": message,
            "systemMessage": message,
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": message,
            },
        }
    # SessionStart uses structured output on success to communicate a stop;
    # a bare nonzero exit is merely a failed hook, not a reliable stop request.
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
