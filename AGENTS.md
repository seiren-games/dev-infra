# ルール
## Operation
### Git
- 許可なく何かを変更するGit操作を行ってはならない。リモートはもちろん、ローカルのワークツリーを変更する一切のgit操作を禁止する。（許可があればOK）
  - 何かを変更するGit操作の例: `git commit`, `git add`/`git reset` (stage/unstage), `git push`, `git stash`,
  `git switch`/`git checkout` (branch switch), `git merge`, `git rebase`
- 読み取り専用のGitコマンド（副作用がなく何も変更しないもの）は許可なく実行して構わない。
  - 読み取り専用の例: `git diff`, `git log`, `git fsck`, `git show`, `git status`

## 実装
- 型安全な実装を心がける。
- 後方互換は一切考慮しなくてよい。必要であれば既存のAPI・データ構造・挙動は整理してよい。
- フォールバックは問題を見えなくすることが多いため、原則として実装しない。必要な場合のみ、必要性と影響範囲を明確にしたうえで採用する。
- 設定値・ルール・型定義はSSOTを保ち、正本を1か所に集約する。
- 同じ知識やロジックの重複実装は避ける（DRY原則）。ただし、無理な共通化で可読性や変更容易性を下げない。

## dev-infra の共有境界
- ルート直下の `flake.nix` はこのリポジトリ独自の検証・公開用エントリポイントであり、各リポジトリへ共有する正本ではない。
- `rust/` 配下の共有ファイル、特に `rust/nix/modules/ci-tools.nix` は複数の Rust リポジトリで使う前提の正本として扱う。共有 Rust ツールの固定 revision やポリシーは、ルートの `flake.nix` ではなく共有 module 側に集約する。
- `rust/cooldown.toml` は共有先リポジトリのルートへ同期される前提の共有ファイルである。共有 CI で `cargo cooldown` が `dev-infra/rust/cooldown.toml` を直接読まないことだけを理由に、ポリシー未適用とは判断しない。
- `flake.lock` は自動生成される解決結果であり、SSOT にはしない。固定したい意図は人間が管理する Nix module や設定ファイルに書く。
