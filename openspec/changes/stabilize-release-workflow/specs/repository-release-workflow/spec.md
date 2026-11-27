# Spec Delta

## Purpose

開発者とレビュー担当者が、変更の目的・判断・検証結果からリリース対象のコミットまでを追跡し、検証済みの範囲と未検証の範囲を区別できるようにする。

## ADDED Requirements

### Requirement: Reproducible prototype baseline
`v0.1.0` は、人がレビューし、クリーンなチェックアウトから検証したプロトタイプのコミットを指さなければならない（SHALL）。

#### Scenario: Maintainer approves the baseline
- **WHEN** 管理者が現状の差分を棚卸しし、候補コミットのチェックアウトだけで既存の自動テストと署名不要の iOS ビルドが成功したことを確認して承認する
- **THEN** `v0.1.0` タグからその候補のコミット SHA を特定でき、必要なローカル Swift パッケージとビルド設定を取得できる
- **AND** 生成物、個人の Xcode 状態、署名用秘密情報、私的な家計データはその候補のツリーに含まれない

#### Scenario: Baseline is not verified or the tag points elsewhere
- **WHEN** 候補の検証が失敗もしくは未実施、または `v0.1.0` が既に別コミットを指している
- **THEN** タグを新規作成または移動せず、未解決事項を記録する

### Requirement: Traceable change review
開発手順では、Issue に記載した課題と受け入れ条件を、設計判断、実装ブランチ、PR の検証結果、人による最終判断に紐づけなければならない（SHALL）。

#### Scenario: Contributor opens a pull request
- **WHEN** 開発者が Issue に対応する PR を作成する
- **THEN** レビュー担当者は、PR から元の Issue、変更内容と設計意図、受け入れ条件に対応する検証結果、未検証項目を特定できる
- **AND** AI が重要な提案や実装に関与した場合は、人が何を評価・修正し、どう検証したかを確認できる

#### Scenario: Change is released and checked
- **WHEN** リリース済みの変更を確認する
- **THEN** Issue は対象バージョンでの動作確認と受け入れ条件の充足を記録してから完了にできる

### Requirement: Visible automated checks
GitHub Actions は PR と既定ブランチへの push で、自動テストと署名不要の iOS Simulator ビルドを実行し、失敗をチェック結果として公開しなければならない（SHALL）。

#### Scenario: A pull request fails validation
- **WHEN** PR でパッケージテストまたはアプリと Widget を含む Simulator ビルドが失敗する
- **THEN** PR から該当チェックの失敗を確認でき、自動で配布したり Git タグを作成したりしない

#### Scenario: Automated checks pass
- **WHEN** 自動テストと Simulator ビルドが成功する
- **THEN** 当該チェックの成功を確認できるが、署名・実機・CloudKit の検証済みを意味しない

### Requirement: Discoverable release evidence
リポジトリは、人が決定したリリースの参照先、変更内容、検証済み範囲および残課題を、ロードマップ上の未リリースの計画と区別して提示しなければならない（SHALL）。

#### Scenario: Reader inspects the prototype release
- **WHEN** 読者が README から変更履歴と `v0.1.0` の記録へ進む
- **THEN** プロトタイプ基準点とその検証記録を追跡でき、正式配布や未検証項目を完了済みと誤認しない
- **AND** `v0.2.0` 以降のロードマップをリリース済みの変更履歴と区別できる
