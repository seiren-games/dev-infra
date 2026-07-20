# dev-infra
開発用の共有ファイル群

## Rust 開発環境

Rust 開発ツールは Nix 経由でパッケージ化されています。依存解決には
`min-publish-age` を利用できる固定 revision の nightly Cargo を使い、Rust compiler、
Clippy、rustfmt は各プロジェクトが選択した toolchain をそのまま使います。

```sh
nix profile install github:seiren-games/dev-infra#rust-dev-environment
```

このパッケージは `rust/nix/modules/dev-environment.nix` からビルドされます。
ツール一覧のカスタマイズが必要なリポジトリでは、
`inputs.dev-infra.lib.rustDevEnvironmentModule` を import し、
`devInfra.rust.devEnvironment.packages` を override できます。依存ポリシーを強制する
nightly Cargo は、この一覧を override しても開発環境から除外されません。

インストール後は、Nix profile の `bin` が rustup などより先に解決されることを
次のコマンドで確認してください。feature が表示されない場合は、シェルの `PATH` で
`$HOME/.nix-profile/bin` をほかの Cargo より前に置きます。

```sh
command -v cargo
cargo --version --verbose
cargo -Z help | grep -F -- "-Z min-publish-age"
```

### 依存パッケージの cooldown

共有する `rust/.cargo/config.toml` は、すべての対応 registry に対して公開から
7 日未満のバージョンを新しい依存解決の候補から除外します。`cargo add` と
`cargo update` はこのポリシーを適用します。すでに `Cargo.lock` に記録された
バージョンは保持されるため、導入時に既存の lock file が自動で downgrade される
ことはありません。CI では別の lock file をゼロから生成して比較するため、既存
lock file 経由の例外を含め、7 日のポリシーを満たさない解決は失敗します。

`cargo upgrade` と `cargo update --breaking` は現時点でこのポリシーを適用しないため、
依存更新には使用しません。ポリシー全体を無効にする
`CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow` も使用しません。registry からの
`cargo install`、git dependency、path dependency、および publish time を提供しない
registry は Cargo の min-publish-age の対象外です。

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
