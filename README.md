# dev-infra
開発用の共有ファイル群

## Rust 開発環境

Rust 開発ツールは Nix 経由でパッケージ化されています。依存解決には
`min-publish-age` を利用できる固定 revision の nightly Cargo を使い、Rust compiler、
Clippy、rustfmt は各プロジェクトが選択した toolchain をそのまま使います。

### 共有ファイルの同期

初回導入時は [`rust/sync.py`](rust/sync.py) を Rust リポジトリのルートへ同じ
`sync.py` という名前でコピーし、Python 3.7 以降で実行します。以後はこのスクリプト
自身も同期対象です。

```sh
python3 sync.py
```

このスクリプトの対応実行環境は、WSL を含む Linux のみです。ネイティブ Windows
など、その他の OS では実行できません。同期先には POSIX 実行権限を保持できる
ファイルシステムが必要であり、同期開始時に検証します。WSL では Linux
ファイルシステム上（`/home/...`）へのリポジトリ配置を推奨します。

スクリプトは `dev-infra` の `main` ブランチから、`rust/` 以下およびルートの
`.editorconfig` と `.gitattributes` を取得します。先頭 5 行以内に管理元ヘッダーが
あるファイルを、Rust リポジトリの同じ相対パスへ同期します。`rust/` 自体は同期先の
パスに含めません。未配置のファイルは作成し、前回同期後に変更されていない旧版は更新
します。最新版と一致するファイルは書き換えません。

同期結果はルートの `.dev-infra-rust-sync.json` に記録されます。この状態ファイルは
共有ファイルと一緒にリポジトリへ commit してください。利用側で内容または実行権限を
変更したファイルは上書きせず、そのファイルだけ同期エラーにして他のファイルの同期を
続けます。初回実行時にすでに存在し、最新版と異なるファイルも、安全のため変更済み
として扱います。

`dev-infra` でファイルが削除された場合や管理元ヘッダーが外された場合、そのファイルが
前回同期後に変更されていなければ自動削除します。変更されていれば削除せず同期エラーに
します。いずれかのファイルで同期エラーが発生した場合、終了 status は非ゼロです。

各 Rust リポジトリでは、`inputs.dev-infra.lib.rustDevEnvironmentModule` を評価し、
module が提供する dev shell をそのリポジトリの default dev shell として公開します。
`dev-infra` input は flake として読み込み、`flake = false` は設定しません。
次の部分を各 system の flake output に組み込みます。

```nix
let
  rustDevEnvironment = nixpkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ inputs.dev-infra.lib.rustDevEnvironmentModule ];
  };
in
{
  devShells.default = rustDevEnvironment.config.devInfra.rust.devEnvironment.devShell;
}
```

ツール一覧は `devInfra.rust.devEnvironment.packages` を module 評価時に override して
カスタマイズできます。依存ポリシーを強制する nightly Cargo は、この一覧を
override しても dev shell から除外されません。

Cargo を使うときはリポジトリの dev shell を使用します。`nix profile install` は
使用しないため、dev shell の解除後もホスト環境の Cargo は変更されません。

### direnv による自動ロード

共有する `rust/.envrc` を各 Rust リポジトリのルート `.envrc` へ、
`rust/.cargo/config.toml` をルート `.cargo/config.toml` へ同期します。`.envrc` は
リポジトリへ移動したときに default dev shell を自動ロードします。default dev shell
から固定 Cargo と cooldown 設定を確認できなければ、設定ミスを見逃さないためロードに
失敗します。

自動ロードを行うホストには `direnv` と `nix-direnv` が必要です。dev shell 自体からは
導入できないため、事前に shell integration とともに有効化します。Home Manager では
次のように設定できます。

```nix
programs.direnv = {
  enable = true;
  nix-direnv.enable = true;
};
```

設定を反映して shell を再起動した後、初回および `.envrc` が更新されたときに内容を
確認して許可します。

```sh
direnv allow
```

以降はリポジトリへ入ると Nightly Cargo が自動的に有効になり、外へ出ると解除されます。
nix-direnv の cached dev shell への fallback は無効化しています。dev shell の評価、
固定した Cargo、または cooldown 設定の検証に失敗した場合は `.envrc` のロードを失敗
させます。`flake.lock` も暗黙に更新しません。direnv がエラーを表示した shell では
Cargo を実行しません。

direnv を利用できない非対話環境では、明示的に dev shell を使用します。

```sh
nix develop --no-update-lock-file
```

この `dev-infra` リポジトリの default dev shell は Rust 用ではありません。管理元で
Rust dev shell を検証するときは次の named dev shell を使用し、`rust/.envrc` は
consumer 用の共有原本として扱います。

```sh
nix develop --no-update-lock-file .#rust-dev-environment
```

### VS Code の Cargo 固定

共有する `rust/.vscode/settings.json`、`rust/.vscode/tasks.json`、および
`rust/.vscode/rust-analyzer-cargo-home/bin/cargo` も、各 Rust リポジトリの同じ位置へ
同期します。

rust-analyzer は Cargo の探索時に `PATH` より `$CARGO_HOME/bin/cargo` を優先する経路が
あるため、dev shell から VS Code を起動するだけでは固定 Cargo の利用を保証できません。
共有設定は `CARGO_HOME` と `CARGO` の両方をリポジトリ内の Cargo wrapper へ固定します。
wrapper は `direnv exec` でルート `.envrc` をロードしてから Cargo を実行するため、VS Code
を GUI など別の経路から起動しても、rust-analyzer の metadata、check、build script、
proc macro の build、および runnable には検証済みの Cargo が使われます。`.envrc` が存在
しない、未許可、または検証に失敗した場合は Cargo の実行も失敗します。

未保護の Cargo task を誤って選べないよう task の自動検出は無効化し、共有する明示的な
task は Nix dev shell 内で実行します。この設定は単一ルートで開いた VS Code workspace を
前提とします。統合 terminal や他の拡張機能から Cargo を直接実行する場合は、通常どおり
direnv がロード済みであることを確認します。

shell 内の Cargo を次のコマンドで確認できます。

```sh
command -v cargo
cargo --version --verbose
cargo -Z help | grep -F -- "-Z min-publish-age"
```

stable Cargo は publish-age policy を適用しないため、Cargo コマンド、Cargo を呼ぶ
エディタ、および自動化はすべて dev shell 内で実行します。

### 依存パッケージの cooldown

共有する `rust/.cargo/config.toml` は、すべての対応 registry に対して公開から
7 日未満のバージョンを新しい依存解決の候補から除外します。dev shell 内では
`cargo add`、`cargo update`、build、test など、すべての Cargo コマンドに固定した
nightly Cargo を使うため、どのコマンドから依存解決が発生してもこのポリシーが
適用されます。

すでに `Cargo.lock` に記録されたバージョンは保持されるため、導入時に既存の lock
file が自動で downgrade されることはありません。CI では別の lock file をゼロから
生成して比較するため、既存 lock file 経由の例外を含め、7 日のポリシーを満たさない
解決は失敗します。CI の Clippy と test では、再現性のため `--locked` も使用します。

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
