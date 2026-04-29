---
name: rust-dependency-policy
description: Rustの依存追加・更新に関するルールと禁止事項を定義する。依存関係の追加/更新を行うときに参照する。
metadata:
  short-description: Rust dependency policy
---

# Dependency policy (Rust)

1. 依存追加は `cargo add <crate>` を使い、バージョン指定はしない（最新の安定版を採用する）
2. 依存の更新は `cargo upgrade`（cargo-edit）を基本とし、`cargo update` だけで終わらせない
3. メジャー更新が絡むときは互換性検証のタスクを起票する

## 禁止事項
- `Cargo.toml`に直接バージョン番号を指定して書き込むこと
- `cargo add <crate-name>@<old-version>` のような形でバージョン指定すること
