---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: rust-dependency-policy
description: Rustの依存追加・更新に関するルールと禁止事項を定義する。依存関係の追加/更新を行うときに参照する。
metadata:
  short-description: Rust dependency policy
---

# Dependency policy (Rust)

1. 依存追加は `cargo add <crate>` を使い、バージョン指定はしない（publish-age policy を満たす最新の安定版を採用する）
2. 互換性のある依存更新は `cargo update` で `Cargo.lock` を更新する
3. メジャー更新では互換性検証のタスクを起票し、`cargo add <crate>@<new-major>` で requirement を更新してから `cargo update` を実行する

## 禁止事項
- `Cargo.toml`に直接バージョン番号を指定して書き込むこと
- メジャー更新以外で `cargo add <crate>@<version>` のようにバージョン指定すること
- min-publish-age を適用しない `cargo upgrade` または `cargo update --breaking` で依存を更新すること
- `CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow` で publish-age policy を無効化すること
