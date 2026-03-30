# ルール
## Operation
### Git
- 許可なく何かを変更するGit操作を行ってはならない。リモートはもちろん、ローカルのワークツリーを変更する一切のgit操作を禁止する。（許可があればOK）
  - 何かを変更するGit操作の例: `git commit`, `git add`/`git reset` (stage/unstage), `git push`, `git stash`,
  `git switch`/`git checkout` (branch switch), `git merge`, `git rebase`
- 読み取り専用のGitコマンド（副作用がなく何も変更しないもの）は許可なく実行して構わない。
  - 読み取り専用の例: `git diff`, `git log`, `git fsck`, `git show`, `git status`
