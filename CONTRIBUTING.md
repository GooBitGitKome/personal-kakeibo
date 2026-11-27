# 開発ガイド

Personal Kakeibo の変更は、Issue から始めて、受け入れ条件を満たしたことを確認してから閉じます。要件・設計・テスト方針の決定と、レビュー・リリースの最終判断は人が行います。AI は課題整理、代替案の提示、共同実装、レビュー指摘を担当し、その扱いを記録します。

## バージョン計画

| バージョン | 内容 | 状態 |
|---|---|---|
| v0.1.0 | 現在のプロトタイプ最終版（基準点） | [CHANGELOG](CHANGELOG.md) を参照 |
| v0.2.0 | 分割払い機能 | 計画 |
| v0.3.0 | ボーナス払い機能 | 計画 |
| v0.4.0 | 簡易登録の高速化 | 計画 |
| v1.0.0 | 品質検証・正式リリース | 計画 |

Git タグは特定のコミットを指す目印です。`vX.Y.Z` のタグは、検証して人が承認したコミットにだけ付けます。タグが付いたことは、署名・実機・CloudKit の検証や正式配布の完了を意味しません。検証した範囲と残課題は [検証記録](docs/validation.md) と [CHANGELOG](CHANGELOG.md) に書きます。

## 開発ライフサイクル

| # | 工程 | 残す記録 |
|---|---|---|
| 1 | Issue 作成。背景・目的・解決する問題を書く | Issue |
| 2 | 要件定義。機能要件・非機能要件・受け入れ条件を決める | Issue、`openspec/changes/<name>/` の proposal と specs |
| 3 | 設計。データベース・API・UI・技術選定を決める | `openspec/changes/<name>/design.md`。重要な判断は ADR |
| 4 | ブランチ作成・実装。Issue と対応させる | ブランチ名、コミット |
| 5 | テスト。単体・結合・手動検証 | `Tests/`、[検証記録](docs/validation.md) |
| 6 | Pull Request 作成 | PR テンプレートの各欄 |
| 7 | コードレビュー・修正。品質・セキュリティ・保守性を確認 | PR のレビューコメント |
| 8 | マージ・リリース。バージョン、タグ、変更履歴を更新 | [CHANGELOG](CHANGELOG.md)、タグ |
| 9 | 動作検証・Issue 完了。受け入れ条件を確認して閉じる | Issue のコメント |

機能ごとの要件・設計は OpenSpec の変更（`openspec/changes/`）に書き、仕様の全体像は [開発仕様](docs/development-specification.md) を参照します。同じ内容を別の場所へ複製しません。

## 役割分担

| 作業 | 人 | AI |
|---|---|---|
| 課題の発見 | 主担当 | 補助 |
| 要件定義 | 主担当 | レビュー |
| アーキテクチャ設計 | 主担当 | 代替案の提示 |
| 実装 | 共同 | 共同 |
| テスト設計 | 主担当 | 補助 |
| コードレビュー | 最終判断 | 問題点の指摘 |
| リリース判断 | 主担当 | 補助 |

### AI 利用の記録

AI の関与を隠しません。PR には次を書きます。

- AI が提案・生成した主な内容（設計案、コード、テスト、レビュー指摘）
- 人が採用・修正・却下したものと、その理由
- 品質をどう確認したか（実行したテスト、手動確認、レビュー）

重要な設計判断では、採用した案と検討した代替案を [ADR](docs/decisions/) に残します。

## ブランチ・コミット・PR

- ブランチ名は `feature/<Issue番号>-<短い説明>`、`fix/<Issue番号>-<短い説明>`、`docs/<短い説明>` とします。
- PR は Issue を通常のリンク（`関連: #12`）で参照します。`Closes` や `Fixes` などの自動クローズ用キーワードは使いません。Issue はリリース後に受け入れ条件を確認して人が閉じます。
- コミットは 1 つの目的ごとに分け、件名で何を変えたかが分かるようにします。
- 署名用の秘密情報、プロビジョニングプロファイル、実際の家計データ、個人の Xcode 状態は Git に入れません（`.gitignore` を参照）。

## テストと検証

Xcode 26.3 / Swift 6.2.4 を使います。パッケージテストは次で実行します。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/kakeibo-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kakeibo-swift-cache swift test --scratch-path /tmp/personal-kakeibo-build --disable-sandbox
```

アプリと Widget は、署名なしの iOS Simulator ビルドで確認します。

```sh
xcodegen generate
xcodebuild build -project PersonalKakeibo.xcodeproj -scheme PersonalKakeibo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions（[`ci.yml`](.github/workflows/ci.yml)）も同じコマンドを実行します。CI の成功は、署名・実機・CloudKit・UI テストの合格を意味しません。これらは [実機確認手順](docs/device-validation.md) で別に確認し、結果を [検証記録](docs/validation.md) に書きます。

## リリース手順

リリースの判断とタグの作成は人が行い、CI は自動で行いません。

1. 対象の Issue の受け入れ条件と、リリース候補のコミットを確認します。
2. 候補のコミットをクリーンな環境にチェックアウトし、パッケージテストと署名なしの Simulator ビルドを実行して、結果と未検証項目を [検証記録](docs/validation.md) に書きます。
3. [CHANGELOG](CHANGELOG.md) に変更内容、検証した範囲、残課題を書きます。アプリに表示するバージョンを変える場合は、同じ PR で `project.yml` を更新します。
4. 検証済みのコミットを人が承認したら、ローカルと GitHub に同名のタグがないことを確認し、そのコミットに注釈付きタグ `vX.Y.Z` を作ります。既存のタグは動かしません。
5. タグを push し、リリースしたバージョンで動作を確認します。
6. 受け入れ条件を満たしたことを Issue に記録して閉じます。満たしていない場合は閉じず、理由を書きます。

## 記入例（v0.2.0 分割払い）

Issue、設計、PR、リリース、完了の対応を示す例です。番号と名前は説明用です。

1. **Issue #10「分割払いを登録したい」**
   - 背景・目的: 高額な購入を分割で払っており、月ごとの支払いを記録したい。
   - 受け入れ条件: 3 回以上の分割を登録でき、各回の支払いが月別集計に出る。元本を支出に二重計上しない。
2. **要件と設計**: `openspec/changes/add-installment-payments/` に proposal・specs・design を書く。計上方法の判断は ADR 0004 に残す。
3. **実装**: ブランチ `feature/10-installment-payments`。
4. **PR**: 関連: #10。設計意図は design.md へのリンク、テスト結果は実行したコマンドと結果、未検証項目は「実機での入力確認」。AI は計上ロジックの代替案とテスト案を出し、人は代替案の 1 つを採用して端末ごとの丸め処理を修正した、と書く。
5. **リリース**: CHANGELOG の `[0.2.0]` に変更と検証範囲を書き、検証済みのコミットに `v0.2.0` を付ける。
6. **Issue 完了**: v0.2.0 で受け入れ条件を確認した結果を Issue #10 にコメントし、人が閉じる。
