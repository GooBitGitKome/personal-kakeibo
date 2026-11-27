# Proposal

## Why

資産・サブスクリプションの管理入口がホーム、設定、家計管理画面に分散し、旧 LifeCost からの移行操作が新規利用者にも表示されている。新しい家計簿として使い始める導線を明確にし、製品化に向けた未検証事項を可視化する。

## What Changes

- 独立した「メニュー」タブを設け、資産、サブスクリプションを含む契約、口座・カード、支払予定の管理入口を集約する。設定はメニュー内から開けるようにし、ホームは集計と状況確認を主とする。
- 空の利用者データで初回起動した場合、新規作成を案内する入口を表示する。収支記録、サブスクリプション登録、資産登録へ進め、後で始める選択も用意する。既存データがある場合は初回案内を出さない。
- **BREAKING**: 旧 LifeCost の JSON バックアップ取込、共有ファイルからの予定読込、関連する取込画面・自動案内を利用できなくする。移行機能の再設計は後続の変更とする。保存済みの取引・契約・所有物・取込履歴は削除しない。家計簿自身の JSON バックアップと復元は維持する。
- 製品化のための優先課題と受け入れ基準を提案する。本変更では導線変更と旧読込の停止に必要な検証を計画し、実機検証、CloudKit、プライバシー、配布準備などの独立した課題は後続変更の候補として整理する。

## Capabilities

### New Capabilities

- `app-navigation`: 独立したメニューと、家計・資産・契約の画面への一貫した移動を定義する。
- `fresh-start`: 初回起動時に空の状態から記録・資産・契約を新規作成する入口を定義する。
- `legacy-import-retirement`: 旧 LifeCost 読込の停止と保存済みデータの保護を定義する。

### Modified Capabilities

なし。現時点の `openspec/specs/` に既存仕様はない。

## Impact

- 主な対象は `ContentView`、`SettingsView`、`FinanceHubView`、`RemindersView`、資産・契約画面、関連 ViewModel／Use Case とパッケージ依存関係。
- 保存済みデータと SwiftData スキーマを消去しない。旧 LifeCost 参照を除く際は、既存データの読取・表示・バックアップ互換性を検証する。
- アプリ内の家計簿 JSON バックアップ／復元は旧アプリ移行とは別機能として維持する。旧 LifeCost 取込を使用する利用者にとっては機能削除となるため、公開済み製品への適用前に対象利用者と配布状況を確認する。

## 製品化に向けた後続提案

1. **公開前に必須**: 実機での初回起動・主要操作・保存失敗時復旧、iPhone／iPad と VoiceOver／Dynamic Type、JSON バックアップ復元を記録付きで検証する。クラッシュ調査と障害時のデータ保護も完了条件にする。[Apple のアクセシビリティ検証案内](https://developer.apple.com/documentation/Accessibility/performing-accessibility-testing-for-your-app)
2. **提供方針の確定**: iCloud 同期を提供するなら、正式な識別子と CloudKit 本番スキーマ、2台間同期・オフライン・競合を検証する。提供しない初回版なら端末内保存を明示する。[Apple の SwiftData 同期案内](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
3. **配布準備**: プライバシーポリシーと App Store のデータ取扱い申告、サポート窓口、ストア説明・画面素材、署名とリリース手順を整える。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)・[App Privacy 案内](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
4. **後続機能**: 旧アプリからの移行を必要とする場合、対象フォーマット、重複判定、プレビュー、取消し・失敗時の原状維持を別変更で設計する。
