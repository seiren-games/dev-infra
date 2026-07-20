---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: rust-dependency-policy
description: Rustのregistry依存を追加・更新するときに使用する。publish-age policyを守り、その範囲で最新versionを採用する。
---

# Rust依存ポリシー

- registry依存には、publish-age policyを満たす最新versionを使う。
- 依存追加はversionを指定せず `cargo add <crate>`、既存requirement内の更新は `cargo update` を使う。対象を限定する場合は `-p <crate>` を指定する。
- メジャー更新だけは `cargo add <crate>@<new-major>` でrequirementを更新する。
- 明示されたversionがcooldown中の場合は変更せず、policyを満たさないことを報告する。

## 禁止事項

- `Cargo.toml`の直接編集や、メジャー更新以外のversion指定により古いversionへ固定すること。
- min-publish-ageを適用しない `cargo upgrade` または `cargo update --breaking` で依存を更新すること。
- stable Cargo、設定や環境変数のoverrideなどでpublish-age policyを無効化・弱体化すること。
