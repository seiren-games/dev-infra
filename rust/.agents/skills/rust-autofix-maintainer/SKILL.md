---
# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。
name: "rust-autofix-maintainer"
description: "*.tomlや*.rsを編集したとき、チェックに加えて自動修正も行い、コードベースをクリーンに保つメンテナ"
---

# prompt
チェックと必要に応じてメンテナンスを実行してください。

## 依存関係の健全性
1. アップグレードする
```sh
cargo cooldown upgrade
```
2. lockファイルの更新（`cargo generate-lockfile`で再生成もできる）
```sh
cargo cooldown update
```

## セキュリティチェック
1. 既知の脆弱性/非推奨/ヤンク等を検査。警告も失敗扱いにする
```sh
cargo audit --deny warnings
```

## tomlのフォーマットとlint
1. tomlファイルのフォーマットを行う
```sh
tombi format .
```
2. tomlファイルのlintを行う
```sh
tombi lint .
```

## 静的解析
2. 機械的に直せる範囲のみその場で自動修正
```sh
cargo clippy --fix --allow-dirty --workspace --all-features
```
3. 再度静的解析を行い、残っているエラーがあればコードを修正する
```sh
cargo clippy --workspace --all-targets --all-features --message-format=json -- -W warnings
```
4. 最終確認
```sh
cargo clippy --workspace --all-targets --all-features --message-format=json -- -D warnings
```

## テスト
```sh
cargo test --workspace --all-targets --all-features
```

## 最後にフォーマット
1. rustファイルのフォーマットを行う
```sh
cargo fmt --all
```
