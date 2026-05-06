<!-- このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。 -->

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
- 実装項目ごとに対応するテストを追加すること。テストカバレッジは80%以上を目標とする。
- 後方互換は一切考慮しなくてよい。必要であれば既存のAPI・データ構造・挙動は整理してよい。
- フォールバックは問題を見えなくすることが多いため、原則として実装しない。必要な場合のみ、必要性と影響範囲を明確にしたうえで採用する。
- 設定値・ルール・型定義はSSOTを保ち、正本を1か所に集約する。
- 同じ知識やロジックの重複実装は避ける（DRY原則）。ただし、無理な共通化で可読性や変更容易性を下げない。

## Rust
- 依存の追加では `cargo cooldown add <crate>` を実行した後、`cargo cooldown upgrade --locked` と `cargo cooldown update --locked` で追加後の `Cargo.toml` と `Cargo.lock` を検証する。
- 依存の更新・管理では `cargo add` / `cargo update` / `cargo upgrade` を直接実行せず、`cargo cooldown update` / `cargo cooldown upgrade` のように `cargo-cooldown` 経由で実行する。
- `cargo-cooldown` は Nix の `rust-ci-tools` から提供されるものを使う。このツール自体のサプライチェーン攻撃対策として、Nix で固定された revision のものを使う。
