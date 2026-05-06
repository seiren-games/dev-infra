---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: rust-dependency-policy
description: Rustの依存追加・更新に関するルールと禁止事項を定義する。依存関係の追加/更新を行うときに参照する。
metadata:
  short-description: Rust dependency policy
---

# Dependency policy (Rust)

1. 依存追加は `cargo cooldown add <crate>` を使い、バージョン指定はしない
2. 依存追加後は `cargo cooldown upgrade --locked` と `cargo cooldown update --locked` を実行し、追加後の `Cargo.toml` と `Cargo.lock` が cooldown policy を満たすことを検証する
3. 依存の更新は `cargo cooldown upgrade` を基本とし、lockfile 更新も `cargo cooldown update` で行う
4. `cargo-cooldown` は Nix の `rust-ci-tools` から提供されるものを使う
5. メジャー更新が絡むときは互換性検証のタスクを起票する

## 禁止事項
- `Cargo.toml`に直接バージョン番号を指定して書き込むこと
- `cargo add <crate-name>@<old-version>` のような形でバージョン指定すること
- `cargo add` / `cargo update` / `cargo upgrade` を `cargo-cooldown` を通さず直接実行すること
- `cargo cooldown add` の実行だけで依存追加を完了扱いにすること
