---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: rust-project-setup
description: RustプロジェクトまたはCargo workspaceを新規作成・初期化し、共通のCargo manifestポリシーを適用するときに使用する。cargo new、cargo init、新規crate/workspace作成、workspace member追加時に適用する。
---

# Rustプロジェクト初期設定

## 作成手順

1. 要求からbinary crate、library crate、単一package、workspaceのどれを作るか判断する。
2. crateの作成には`cargo new --vcs none`、既存directoryの初期化には`cargo init --vcs none`を使う。Git初期化は依頼された場合だけ別途行う。
3. Cargo公式ドキュメントを検索し、その時点で最新のresolver versionを確認する。
4. project構成に応じ、確認したresolverと以下のlint設定を正本として`Cargo.toml`へ追加する。
5. 既存のpackage metadata、target、feature、dependencyなど無関係な設定は維持する。
6. `cargo metadata --no-deps --format-version 1`を実行してmanifestを検証し、`workspace_members`に含まれる全packageの`manifest_path`を特定する。
7. workspaceでは、特定した全member（root packageを含む）の`Cargo.toml`を検査し、`[lints] workspace = true`が明示されていることを確認する。欠落または`false`をエラーとし、Clippyの成否を継承確認の代用にしない。
8. sourceが存在する各packageでlint違反がないことを`cargo clippy --workspace --all-targets --all-features -- -D warnings`で検証する。

## 単一package

`resolver`を`[package]`へ置き、検索で確認した最新versionを設定する。lintをpackage自身に定義する。

```toml
[lints.clippy]
allow_attributes = "forbid"
allow_attributes_without_reason = "forbid"

[lints.rust]
unsafe_code = "forbid"
```

既存の`[package]` tableは作り直さず、`resolver`だけを同じtableへ追加する。

## Workspace

workspace rootの`Cargo.toml`へ共通設定を一度だけ定義する。`resolver`を`[workspace]`へ置き、検索で確認した最新versionを設定する。

```toml
[workspace.lints.clippy]
allow_attributes = "forbid"
allow_attributes_without_reason = "forbid"

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

- resolver versionは記憶や固定値に頼らず、Cargo公式ドキュメントの検索結果から決定する。
- resolverを省略しない。editionからの暗黙選択に依存しない。
- `unsafe_code`を弱めない。
- `allow_attributes`または`allow_attributes_without_reason`を`forbid`から弱めない。
- workspace memberへ共通lintを重複定義しない。lint policyは`[workspace.lints]`へ集約する。
- 対象Cargoがこれらの設定を解釈できない場合、古いresolverやlint未設定へfallbackせず、toolchainの非対応として報告する。
