---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: rust-project-setup
description: RustプロジェクトまたはCargo workspaceを新規作成・初期化し、共通のCargo manifestポリシーを適用するときに使用する。cargo new、cargo init、新規crate/workspace作成、workspace member追加時に適用する。
---

# Rustプロジェクト初期設定

## 作成手順

1. 要求からbinary crate、library crate、単一package、workspaceのどれを作るか判断する。
2. crateの作成には`cargo new --vcs none`、既存directoryの初期化には`cargo init --vcs none`を使う。Git初期化は依頼された場合だけ別途行う。
3. project構成に応じ、以下のいずれかの設定を正本として`Cargo.toml`へ追加する。
4. 既存のpackage metadata、target、feature、dependencyなど無関係な設定は維持する。
5. `cargo metadata --no-deps --format-version 1`を実行し、manifestを検証する。
6. sourceが存在する各packageでlintが有効になることを`cargo clippy --workspace --all-targets --all-features -- -D warnings`で検証する。

## 単一package

`resolver`を`[package]`へ置き、lintをpackage自身に定義する。

```toml
[package]
resolver = "3"

[lints.clippy]
allow_attributes = "warn"
allow_attributes_without_reason = "warn"

[lints.rust]
unsafe_code = "forbid"
```

既存の`[package]` tableは作り直さず、`resolver`だけを同じtableへ追加する。

## Workspace

workspace rootの`Cargo.toml`へ共通設定を一度だけ定義する。

```toml
[workspace]
resolver = "3"

[workspace.lints.clippy]
allow_attributes = "warn"
allow_attributes_without_reason = "warn"

[workspace.lints.rust]
unsafe_code = "forbid"
```

workspace内のすべてのpackage（root packageを含む）で共通lintを継承する。

```toml
[lints]
workspace = true
```

新しいworkspace memberを追加するときも、memberの`Cargo.toml`へ`[lints] workspace = true`を設定する。共通lintを各memberへ複製しない。

## 制約

- `resolver = "3"`を省略しない。editionからの暗黙選択に依存しない。
- `unsafe_code`を弱めない。
- `allow_attributes`または`allow_attributes_without_reason`を`allow`にしない。
- workspace memberへ共通lintを重複定義しない。lint policyは`[workspace.lints]`へ集約する。
- 対象Cargoがこれらの設定を解釈できない場合、古いresolverやlint未設定へfallbackせず、toolchainの非対応として報告する。
