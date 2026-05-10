# dev-infra
開発用の共有ファイル群

## Rust 開発環境

Rust 開発ツールは Nix 経由でパッケージ化されています。

```sh
nix profile install github:seiren-games/dev-infra#rust-dev-environment
```

このパッケージは `rust/nix/modules/dev-environment.nix` からビルドされます。
ツール一覧のカスタマイズが必要なリポジトリでは、
`inputs.dev-infra.lib.rustDevEnvironmentModule` を import し、
`devInfra.rust.devEnvironment.packages` を override できます。

共有環境は `cargo` wrapper を提供します。`cargo update`、`cargo add`、
`cargo remove`、`cargo upgrade` など、manifest や lockfile を更新する
コマンドは、固定された `cargo-cooldown` 経由で実行されます。
`cargo generate-lockfile` や `cargo fetch` のように lockfile 解決を明示する
コマンドも同じ経路を通ります。それ以外の Cargo コマンドはすべて、Cargo の
グローバルな `--locked` flag 付きで実行されます。共有 cooldown policy file は
`rust/cooldown.toml` です。

## シークレットスキャン

このリポジトリは Git hook を提供し、gitleaks がシークレット、個人情報の
パターン、または機密情報を示す marker を検出した場合に commit と push を
ブロックします。commit 時には staged changes に対して `review-public-ok`
skill を使った Codex CLI review も実行され、公開すべきでない情報が review で
見つかった場合は失敗します。

gitleaks scanner は Nix 経由で宣言的に提供されます。

```sh
nix develop
```

Codex review には、`codex` がインストール済みで `PATH` から利用できることが
必要です。デフォルトでは
`$HOME/dotfiles/home/.agents/skills/review-public-ok/SKILL.md` を使用します。
特定の Codex executable を使う場合は `CODEX_BIN` を、skill path を上書きする
場合は `PUBLIC_OK_SKILL_PATH` を設定してください。

clone ごとに一度だけ、version 管理された hook を有効化してください。

```sh
git config core.hooksPath .githooks
```

以降は、`git commit` が staged changes をスキャンし、`git push` が outgoing
commits をスキャンします。commit 時のスキャンを手動で実行するには、次の
コマンドを使います。

```sh
scripts/secret-scan pre-commit
```

gitleaks による全履歴スキャンを手動で実行するには、次のコマンドを使います。

```sh
scripts/secret-scan all
```
