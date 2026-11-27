# 変更履歴

リリース済みの変更だけを記載します。今後のバージョンの計画は [開発ガイド](CONTRIBUTING.md#バージョン計画) を参照してください。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に倣います。

## [Unreleased]

- Xcode 26.6（Swift 6.3.3）で型チェックがタイムアウトする `ContentView.swift` の式を分割した（[#1](https://github.com/GooBitGitKome/personal-kakeibo/issues/1)、[PR #2](https://github.com/GooBitGitKome/personal-kakeibo/pull/2)）。表示内容は変わらない。

## [0.1.0] - 2026-11-27 プロトタイプ最終版

タグ `v0.1.0` はコミット `4ef04f3` を指す注釈付きタグです。正式な配布や署名付きリリースではなく、検証した範囲だけを示す基準点です。

### 内容

- 入力・履歴・ジャンル管理・月別集計・月間予算・CSV 出力・JSON バックアップ（v4）と復元プレビュー。
- リマインダーと予算通知。
- 口座・カード・振替、契約・サブスクリプション、所有物と実質生活コスト。サービス名の選択（14 件）。
- 支出を登録する Widget と、全画面入力。
- はじめ方の案内と、5 タブの画面構成。
- 開発ガイド、Issue・PR テンプレート、ADR 0003、GitHub Actions の設定。
- `PersistenceTests` がアプリと Widget の `PrivacyInfo.xcprivacy` を重複して検出する問題を修正。

### 検証済みの範囲

新規クローンの `4ef04f3` で、`swift test`（63 件、失敗 0）と署名なしの iOS Simulator ビルドが成功しました（macOS 27.2.1、Xcode 27.2、Swift 6.4.2）。詳細と経緯は [検証記録](docs/validation.md#v010-基準点の検証2026-11-27) を参照してください。

### 残課題

- 実機 UI、VoiceOver、iPad 分割表示、2 台の iCloud 同期、CloudKit の本番スキーマ、UI テスト、署名付きビルドは未検証。
- Xcode 26.3 での実行は未確認。Xcode 26.6 では、`swift test`（63 件）は成功するが、署名なしの Simulator ビルドが `ContentView.swift:500` の型チェックのタイムアウトで失敗する（[#1](https://github.com/GooBitGitKome/personal-kakeibo/issues/1)）。このタグのコミットは Xcode 26.6 でビルドできない。修正は [Unreleased] に記載。
- Git 管理外の `.rollback/` を持つ作業ツリーでは `swift test` が失敗する。新規クローンで実行する。
- 署名・正式配布は対象外。
