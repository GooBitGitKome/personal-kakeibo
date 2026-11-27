# 検証記録

## テンキーWidgetのグレー表示ボタンでアプリを開かない（2026-10-27）

- 無効な登録・ページ送りボタンに `.disabled` を適用すると、タップがWidgetのアプリ起動へ渡る問題に対応。表示はグレーのまま、データを参照・変更せずアプリも起動しない `IgnoreWidgetTapIntent` でタップを受け止める。読み上げでは利用できない状態を伝える。有効な操作は既存のIntentを使用する。
- iPhone 12 mini / iOS 26.3 Simulatorで、金額ゼロ時の登録ボタンの中央・左右、先頭ページの「前へ」、末尾ページの「次へ」をタップし、アプリが前面へ出ず、金額・ページも変わらないことを確認。有効なページ送り・900円の登録・取消も成功した。
- Widget追加の自動操作が不安定だったため、テスト専用の `KAKEIBO_INLINE_WIDGET_TESTING` フラグで同じ製品用テンキー画面を既存Widget枠に表示してUIテストした。通常ビルドのWidget構成は変更しない。
- 署名付きビルド、iPhoneへの更新インストール・起動・プロセス継続を確認。変更前の全画面対応版は `.rollback/20261027-before-disabled-widget-fix/` に保存している。実機上でのタップ操作は未検証。

## Widgetからの全画面入力と復元ポイント（2026-10-27）

- 変更前に117ファイルのソースをアーカイブし、全ファイルのSHA-256を照合。直前に配備した署名済みアプリをコピーし、署名検証にも成功した。復元ポイントは `.rollback/20261027-before-fullscreen/`（Git管理対象外）。`restore-device.sh` で旧版を更新インストールできる。`restore-source.py` は既定で差分表示のみ、`--apply` で後続作業を退避して復元する。家計データやDBを巻き戻すものではない。
- 既存のWidget種別を全画面入力ランチャーへ変更し、小・中・大に対応。従来のテンキーWidgetも別種別で保持する。`personalkakeibo://quick-entry` の明示的な経路だけを受け付け、起動前に届いたURLも状態として保持する。
- 全画面入力は同じWidget下書き・保存・取消処理を使用する。入力途中を保持し、登録済みからの新規起動は次の入力を開始する。Widget側の選択画面が残っていても入力へ戻せる。失敗時は選択肢を再取得して入力を保持する。DB・バックアップ形式は変更していない。
- `swift test --disable-sandbox`: 63件成功、失敗0。URL経路の許可・拒否、下書き継続、保存・取消、登録済みからの再入力、無効化された選択肢の再取得を含む。最後の選択画面引継ぎ修正後に関連4件を再実行して成功した。
- iPhone 12 mini / iOS 26.3 SimulatorでWidgetからのコールド起動、全画面表示、64pt以上のキー寸法、金額・ジャンル・支払元の操作、保存・取消・再保存、履歴反映、ウォーム起動時の新規入力・入力途中保持をUIテストし成功した。[全画面の画像](images/quick-entry/fullscreen.png)を目視確認した。
- 通常プロジェクトの署名付きビルドとiPhoneへの更新インストールが成功。実機の画面操作・VoiceOver・他の編集シートを表示中の起動・横向きレイアウトは未検証。初回の起動要求は端末ロックで拒否されたが、解除後の再実行で全画面入力URLを指定したアプリ起動が成功した。

## アプリを開かずに支出を登録するWidget（2026-10-27）

- 大サイズのホーム画面Widgetに、テンキー・支出ジャンル・支払元のページ選択・登録・直前の取消を追加。App Intentはアプリを前面へ出さず実行し、端末認証を要求する。日付は保存時点、メモ空欄、節約可能オフ。複数配置は同じ入力状態を共有する。
- App Group内の共通SwiftDataストアへ切り替える。初回アプリ起動で旧ストアの全スナップショットをコピー・照合し、準備完了を公開する。旧ストアは端末内に保持し、失敗時に空の家計簿へ切り替えない。Widgetは準備完了まで登録しない。
- DB v4からv5へ軽量移行し、端末別のWidget状態と保存結果を保存する。JSONバックアップはv4を維持し、Widgetの操作状態を含めない。取引と口座記録・保存結果は同じSQLiteトランザクションで更新する。
- 入力セッションIDを取引IDとして固定し、再実行・連打・古いWidget操作で重複登録しない。取消後は新しいセッションへ移行する。取消は取引と口座記録が保存時と同じで、契約・返金・所有物・修理から参照されていない場合に限る。
- アプリとWidgetでプロセス間ファイルロックと新しいModelContextを使用し、古いスナップショットによる上書きを拒否する。Widgetでは全履歴をロードせず、対象取引・口座情報を読み込む。
- `swift test --disable-sandbox`: **59件成功、失敗0**（28.259秒）。Widget関連8件を含む。旧データ移行・中断後の再試行・元データ保持、現金／銀行／カード／未指定の保存と取消、保存／取消失敗時の巻き戻し、編集済み取引の取消拒否、古い操作の再実行、別プロセスによるロック排他、カテゴリ・口座のアーカイブ、端数のない整数金額の上限を確認した。
- iPhone 12 mini / iOS 26.3 Simulatorのホーム画面でUIテスト2件成功。通常文字70.016秒、アクセシビリティ最大文字56.448秒。アプリを終了してWidgetで金額入力・ジャンル選択・保存・取消・再保存し、アプリが前面に出ないことと履歴に1件だけ反映することを確認。最大文字で全数字キー・削除キーの操作可否、ジャンルのページ送り、支払元の選択、登録・取消を確認した。
- [入力画面](images/widget-entry/keypad.png)、[登録完了](images/widget-entry/registered.png)、[最大文字の入力](images/widget-entry/keypad-largest.png)、[最大文字の完了](images/widget-entry/registered-largest.png)を目視確認。長い支払元名は入力行で省略されるが、完了画面とアクセシビリティ名で識別できる。
- iPhone 12 miniへ更新インストールと起動が成功。実機の画面操作は未実施。
- 通常プロジェクトのWidget拡張を含む署名付き端末ビルド成功。アプリと拡張のInfo.plistで共通App Groupを確認。CloudKit構成生成スクリプトも一時ディレクトリ内で実行し、両ターゲットの共有領域・CloudKit設定の一致を確認した。UserDefaultsのアプリ内利用・App Group共有の利用理由を双方のPrivacy Manifestへ記載した。
- 実機でのWidget操作、VoiceOverの音声操作、ロック中の認証操作、CloudKit構成の2台同期は未検証。UIテストは同じソースの `project-localcheck.yml` を使用し、出力先が別ディレクトリのためInfo.plist・entitlementsを生成先にも配置して実行した。
- 任意の端末外バックアップは自動承認レビューに拒否されたため行っていない。元データを端末内に保持する移行方式を使用する。

## サブスクの一括確定・自動確定・履歴タグ（2026-10-26）

- 当月の未確定サブスクを予定額・支払日・契約のカテゴリ／支払元で一括記帳。件数・合計額を確認するアラートを表示する。全件を一度に保存し、予定の変更・確定済みを検知すると保存しない。
- 契約ごとの任意設定で定額サブスクを自動確定。起動・復帰・再読込時に当月の期日到来分だけを処理し、将来日・過去月・変動額・終了済み・設定オフを除外。アプリ終了中の定刻実行や送金は対象外。
- 既存の取引と支払予定・所有物・修理の関連を使い、履歴に管理タグを表示。契約は種類と契約名を併記する。設定は既存の契約JSONに任意項目として保存し、旧データの欠落値はオフとして扱う。
- `swift test --disable-sandbox`: 51件成功。タグの判定追加後に結合テスト6件を再実行し成功。一括処理の途中失敗で全件不変、再実行で重複なし、自動確定の対象期間・定額条件、設定のJSON往復・旧キー欠落時の読込を検証。
- iPhone 12 mini / iOS 26.3 SimulatorのUIテスト1件成功。一括確定のキャンセル／実行、実行後の無効化、履歴タグを確認。最初の確認ダイアログではキャンセルボタンの表示を検出できず、明示的なアラートに変更して成功した。[履歴タグの画像](images/subscription-payments/history-tag.png)を目視確認。
- 汎用iOS端末向けビルドと、修正後のiPhone向け署名付きビルドが成功。実機での画面操作は未検証。更新インストールも成功。起動要求は端末ロックにより拒否されたため、更新後の実機起動確認は未完了。

## 契約・固定費のカテゴリ別表示（2026-10-26）

- 契約の支出カテゴリごとに一覧を分け、上部に月額換算合計、カテゴリ内に小計を表示。終了済みは一覧に残し、合計対象外と明示する。解約予定は合計に含む。月額換算は既存の周期換算を使い、端数は合算後に表示時に丸める。実際の請求額とは異なる概算である旨を表示した。
- 管理タブのアイコンを `square.grid.2x2` に変更。
- `swift test --disable-sandbox`: 49件成功、失敗0。追加した計算テストで月払い・年払い・複数月払いの合算、終了済みの除外、解約予定の算入、空一覧、端数とInt64を超える合計を確認した。
- 通常プロジェクトの汎用iOS端末向けDebugビルド成功。今回の画面配置の実機目視確認は未実施。
- iPhone 12 mini向け署名付きビルド、更新インストール、起動が成功。

## add-subscription-service-picker（2026-10-26）

- 同梱カタログ14件を設計書と照合し、名称・順序・IDの一意性を確認。候補画面に通信・外部画像・保存処理の依存がないことをコードで確認した。名前へのBindingのみを渡し、保存形式は変更していない。
- `swift test --disable-sandbox`: 48件成功、失敗0（37.145秒）。保存失敗時の巻き戻し、ディスク再読込、バックアップ往復を含む。
- 通常の `PersonalKakeibo.xcodeproj` で `generic/platform=iOS`、署名なしのDebugビルド成功。
- `openspec validate add-subscription-service-picker --strict`: 成功。
- iPhone 12 mini / iOS 26.3 SimulatorのUIテスト4件が成功。初回案内・管理からの入口、14件への到達、空欄・空白・同名・別名の選択、置き換えの承認／キャンセル、一覧から戻る、手入力へのフォーカス、種類切り替え、既存契約編集での入口非表示を確認した。
- 金額・カテゴリ・支払元・周期・開始日・最初の支払日を選択前と比較し、置き換えキャンセル／承認の両方で一致。候補名と手修正した名前の保存・再起動後表示、金額未入力エラー後の入力保持、追加キャンセル後の契約・支払予定ゼロを確認した。
- 標準文字の初回案内テスト136.993秒、入力保持・保存テスト438.344秒、手修正・再起動テスト101.900秒、最大文字テスト122.089秒。別実行で計4件成功、失敗0。初回の検証で手入力への復帰時にフォーカスが反映されない問題を検出し、候補画面の終了後にフォーカスを設定するよう修正した。再実行でキーボード表示と直接入力を確認した。テストのスクロール対象・テスト間依存も修正した。
- [標準文字](images/subscription-service-picker/standard.png)、[アクセシビリティ最大文字](images/subscription-service-picker/accessibility-largest.png)、[最大文字の一覧下端](images/subscription-service-picker/accessibility-largest-bottom.png)を目視確認。長い名称は折り返され、最下部のAmazonプライムまで選択できた。
- UIテストは `project-localcheck.yml` から生成した同じアプリソースの構成で実行。実機操作・VoiceOverの音声操作は未検証。

## 設定タブの独立と管理内のリマインダー（2026-10-26）

- `swift test --disable-sandbox`: 48件成功、失敗0。通知を開いたときに管理タブが選ばれてリマインダーへの遷移状態になることと、繰り返しても同じ画面が増えないことを既存の通知テストで確認。
- 標準の `PersonalKakeibo.xcodeproj` を汎用iOS端末向け・Debug・署名なしでビルドし、`BUILD SUCCEEDED` を確認。
- iPhone 12 mini / iOS 26.3 SimulatorのUIテスト2件が成功、失敗0。タブが入力・履歴・ホーム・管理・設定の5つであること、設定が独立して開くこと、管理の5項目と戻る動作、初回契約・所有物作成のキャンセル後の管理タブ選択、保存・再起動を確認。添付画像「管理と独立した設定タブ」も目視確認した。
- UIテストは同じアプリソースを参照する `project-localcheck.yml` 構成で実行。通知の実配信と実機での通知タップは未実施。
- 管理画面の名称・説明・並び順の整理や件数・金額の表示は改善案として提案中。この検証では、承認済みのタブ構成と通知からの導線変更を対象とした。

## 管理と設定入口の分離（2026-10-26）

- `swift test --disable-sandbox`: 48件成功、失敗0。既存の保存・復元・財務計算テストを含む。
- 標準の `PersonalKakeibo.xcodeproj` を汎用iOS端末向けのDebug構成・署名なしでビルドし、`BUILD SUCCEEDED` を確認。
- iPhone 12 mini / iOS 26.3 Simulatorで、更新したUIテスト2件の成功を確認。初回の契約・所有物追加とキャンセル後の管理タブ、管理一覧の4項目、設定の歯車からの往復、5タブの維持、ホーム表示、契約・所有物の入力保持と保存、再起動後の所有物保持を確認した。
- 最初の寸法検証で標準ツールバースタイルによる高さ36ptへの縮小を検出し、表示スタイルを修正した。設定ボタンの幅・高さ44pt以上とアクセシビリティ名「設定」をUIテストで確認。座標の丸め誤差に対する寸法判定の許容差は0.01pt。
- 保存フローテストは73.095秒で成功。ナビゲーションテストは丸め誤差の判定補正後に単独で再実行し、81.311秒・失敗0で成功した。成功したテストの添付画像「管理と右上の設定」で、4項目・右上の歯車・5タブの配置を目視確認した。
- UIテストは `project-localcheck.yml` の同じアプリソースを使用する構成で実行。実機での画面操作とVoiceOverの音声操作は未実施。

## fresh-start-menu-and-product-readiness（2026-10-26）

- `swift test --disable-sandbox`: 48件成功、失敗0。初回表示判定、案内完了の再生成後保持、既存データによる案内抑止、契約・所有物の保存失敗時の巻き戻し、旧取込履歴付き v4 ストアの再読込と JSON 往復・復元プレビュー・CSV を含む。
- iOS 汎用端末向けビルド: 成功。`LifeCostIntegration` の保存形式用依存を維持した構成。
- iPhone 17 Pro / iOS 26.3 Simulator の UI テスト2件が成功。初回の収支・契約・所有物入口、キャンセル後の通常画面、5つのメニュー移動先からの復帰、既存4タブからメニューへの移動、旧取込ボタンがないことを確認。ホームの集計・口座・予定・期限表示、契約・所有物エディタの入力保持とエラーアラート、保存後の一覧、再起動後の所有物保持も確認。
- `PersonalKakeibo/` と `Package.swift` の参照検索で `SharedPaymentFile`、`previewLegacy`、`importLegacy`、旧 LifeCost の画面と Use Case への参照がないことを確認。起動時に共有ファイルを開く経路がなく、旧ファイルの存在のみでは読込・案内・データ変更は発生しない。家計簿自身の JSON 復元経路は維持。

## 統合家計簿（DB / JSON v4）

2026-10-23、通常の `PersonalKakeibo.xcodeproj` を接続済みの iPhone 12 mini 指定で署名付きDebugビルドし、`BUILD SUCCEEDED` を確認した。端末への更新インストールと起動も成功し、プロセスの継続を確認した。更新前にアプリのSwiftDataストアと設定を `/tmp/personal-kakeibo-iphone-preupdate/` へ退避した。起動後のストアは整合性検査が `ok` で、v4の `ZSTOREDFINANCESTATE` テーブルが追加されていた。更新前後で取引17件、カテゴリ9件、予定関連2件、節約フラグ8件が一致した。画面の操作・表示は未確認。

2026-10-23 に `swift test --disable-sandbox` で50件成功、失敗0。既存の家計簿テストに加え、口座・カード利用と引落、返金、予定の実額確認と二重記録防止、予定の期間延長、記録済み取引の参照保護、実質コスト配分、旧LifeCost JSON取込、v3ストアのv4移行、JSON v4往復を確認した。SwiftDataのテスト用ストアと架空データを使用した。

iPhoneOS向けのSwiftUIを含む確認用プロジェクトも署名なしでビルド成功した。`project-localcheck.yml` から `/tmp` に生成したプロジェクトで、同梱した `LocalPackages/` のソースを直接コンパイルした。制限環境では通常プロジェクトのSwiftPM診断キャッシュへ書けずパッケージ解決で停止したが、通常のMac環境からの実機ビルドでは解決した。実機UIとCloudKitの端末間同期は未確認。

検証日: 2026-10-12。環境: macOS、Xcode 26.3 (17C529)、Swift 6.2.4、iPhoneOS SDK 26.2。


## 金額全消去・00入力・項目別予算通知（2026-10-12）

- `swift test --scratch-path /tmp/personal-kakeibo-build --disable-sandbox`（既存手順のモジュールキャッシュ環境変数を使用）は32件成功、失敗0。
- 追加3件で、00入力と19桁制限、全消去後のメモ・日付・ジャンル保持、28/29/30/31日の日割り、日額優先、端数切り捨て、未設定、最大金額を検証。
- 代替通知サービスで項目別の名前・概算額・安定した識別子、月変更時の再計算、予算通知オフ・解除、アーカイブによる除外、繰り返し収支の独立した確認通知を検証。
- `/tmp/kakeibo-input-reminders-project` に `project-buildcheck.yml` から確認用プロジェクトを生成。署名なし・Asset Catalogを除外したiPhoneOSビルドは成功。通常構成のビルドは `No available simulator runtimes for platform iphonesimulator` により `CompileAssetCatalogVariant` で失敗した。
- 新旧の予約整理と項目・時刻枠ごとの繰り返し予約を実装。通知予約数を64件以内に抑えるため、超過時は対象項目または時刻枠を減らす案内を表示する。OSへの予約・取り消しと配信は実機では未検証。
- スワイプの判定範囲・方向・閾値とVoiceOverアクションを実装したが、実機UI検証は未実施。確認手順は `docs/device-validation.md` に追加。
- 月額予算からの概算は起動・復帰時に更新する。未起動で月をまたいだ場合は次回起動まで前回の概算額を繰り返し通知する。

検証ログ: `/tmp/kakeibo-input-reminders-tests.log`、`/tmp/kakeibo-input-reminders-code-ios.log`、`/tmp/kakeibo-input-reminders-ios.log`。

## 入力・予算・リマインダー追加（2026-10-12）

最終の `swift test` は29件成功、失敗0。既存15件に14件の検証を追加した。

- Core Dataの変更通知をバックグラウンドから送信し、コールバックがMainActorへ移って画面更新することを確認。
- ViewModelから30回連続保存し、入力消去・取引件数・残額を確認。save前の障害注入では入力が保持され、追加レコードがrollbackされる。
- 初期ジャンルのViewModel再生成後の保持、収支区分ごとの独立性、アーカイブ時の代替選択。
- 日額・月額予算、日本時間の開始・終了境界、予算超過、編集・削除の再計算、未設定、集計オーバーフロー。
- 毎日・毎週・毎月の期日、閏年・月末補正、未処理予定の表示、無効化、スキップ。
- 繰り返し収支と処理済み状態を一括保存し、失敗時の両方のrollbackと二重記録・二重スキップの拒否を確認。
- v1のディスクストアにカテゴリ・取引・予算を保存してv2へ移行。既存値の保持と、新しい予算・予定・処理状態の再読み込みを確認。
- v2 JSONの全項目往復・復元・再追加、従来v1 JSONの読み込み、新データを保持した追加復元。
- 通知枠の上限・重複時刻拒否・全枠停止、通知対象のアーカイブ時の停止、通知を開くコールバックによるタブ遷移を代替サービスで確認。

追加後のアプリ全体のiPhoneOSビルドも署名なし・Asset Catalogを除外した確認用構成で成功。確認用プロジェクトは `/tmp` に生成し、通常のプロジェクトはアイコンと既存の署名Teamを保持した構成にしている。

```sh
mkdir -p /tmp/kakeibo-update-project
xcodegen generate --spec project-buildcheck.yml --project /tmp/kakeibo-update-project
xcodebuild -project /tmp/kakeibo-update-project/PersonalKakeibo.xcodeproj -scheme PersonalKakeibo -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/kakeibo-update-ios CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
```

SwiftDataモデルのinitを直接代入に変更し、ローカル保存通知による余分な再取得を除去した。MainActor内で作られたCombineのsinkコールバックは、Swift 6でバックグラウンド通知を受けると実行スレッド検査で停止する可能性がある。コールバックを明示的な `@Sendable` にして、画面更新だけをMainActorへ移した。

同じ構造の最小コードを `/tmp/kakeibo-actor-notification-probe.swift` に用意し、Swift 6でコンパイルして確認した。修正前のコールバックはバックグラウンド通知でsignal 4（終了コード132）となり、`@Sendable` を付けた同じコードは終了コード0で `BACKGROUND_CALLBACK_COMPLETED` を出力した。これは元の通知経路にクラッシュ条件がある証拠であり、報告された実機のクラッシュスタックとの一致を確認したものではない。保存の各段階は `PersonalKakeibo` subsystemの `Entry` / `Persistence` categoryにログを記録する。金額・メモなどの家計情報はログに含めない。

実機のクラッシュ記録はこの環境に見つからず、終了の原因は断定していない。CoreSimulatorServiceに接続できず、CoreDeviceServiceの初期化もタイムアウトしたため、実機での終了解消、スワイプ・長押し・カレンダーUI、許可ダイアログ、OS通知配信、通知からのコールド起動は未検証。新エンティティのCloudKit同期と端末間の同時処理も未検証であり、2台での同時記帳の一意性を保証するものではない。

UserDefaultsへの初期ジャンル・時刻の保存には、[Appleの利用理由CA92.1](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc)をPrivacy Manifestに宣言した。

## 初回版（追加前）の検証

## 実行結果

`swift test`で15件成功、失敗0。Domain 4件、SwiftData・ファイル形式・Applicationの結合テスト11件。テストの家計情報は架空。

| 検証 | 結果 |
| --- | --- |
| ASCII数字、ゼロ・負数・小数・Int64範囲外の拒否 | 成功 |
| 集計のオーバーフロー、開始を含み終了を除外、空一覧 | 成功 |
| 日本時間の年月、閏年2月、不正年月の拒否 | 成功 |
| 取引の保存・編集・削除、ID・createdAt保持 | 成功 |
| アーカイブ後の既存参照保持と新規入力拒否 | 成功 |
| 予算の未設定・保存・更新、カテゴリ名とメモ制限 | 成功 |
| ディスクストアの再読み込み | 成功 |
| JSON全値・小数秒の往復、CSVの引用符と改行 | 成功 |
| JSONの未知バージョン、UUID重複、参照不正、小数金額の拒否 | 成功 |
| 同一バックアップの再追加、追加の競合拒否、上書きプレビュー | 成功 |
| プレビュー後に状態が変わった場合の拒否 | 成功 |
| save直前の障害注入で一括更新がrollbackされる | 成功 |
| 同じ論理IDの表示統合と物理レコード保持 | 成功 |
| 10,000取引のJSON出力・読込・プレビュー・一括保存 | 成功、4,049,324 bytes、約5.85秒 |

10,000件の処理は当初約26.9秒だった。日時フォーマッタの再利用とID索引によるマージにより約5.85秒に短縮した。数字はMacのテスト用メモリストアでの1回の実測であり、実機の応答性・メモリ量を保証しない。アプリではファイル読み込み・変換をバックグラウンドTaskで実行し、一括保存はMainActorで行う。

## ビルドと環境制約

iPhoneOS向けのアプリ、Domain、Applicationのコード全体は、署名なし・アイコンカタログを除外した確認用構成でビルド成功した。Privacy Manifestも含む。確認用構成は `project-buildcheck.yml`、最終のXcodeプロジェクトは通常の `project.yml` から再生成している。

```sh
xcodegen generate --spec project-buildcheck.yml
xcodebuild -project PersonalKakeibo.xcodeproj -scheme PersonalKakeibo -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/kakeibo-ios-build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
xcodegen generate
```

この環境ではCoreSimulatorServiceに接続できない。通常構成のAsset Catalogコンパイルは「No available simulator runtimes for platform iphonesimulator」で失敗した。アイコン画像とカタログは用意しているが、そのコンパイルとSimulator起動は未確認。制限環境でSwiftマクロを実行するため、検証コマンドではコンパイラの `-disable-sandbox` を指定した。これはリリース用プロジェクト設定には追加していない。

SwiftDataテスト中にOSのstore changed通知登録の権限警告が出た。ローカル保存・復元テストは成功しているが、同期通知の到達性を検証した結果としては扱わない。

## 残る確認

実際のApple Developer Team、Bundle ID、CloudKit Containerは未提供のため、iCloudを有効にした署名・接続は未実施。標準構成は端末内保存。CloudKit設定用生成スクリプトと未ログイン等の状態案内は実装している。

AC01、AC04、AC09〜AC11、AC17、AC18のUI・2台実機部分、共有UI、初期化失敗の画面、実機での保存エラー、CloudKit本番スキーマは未検証。AC15の障害注入はsave直前に例外を発生させる試験であり、ディスク障害そのものの再現ではない。AC20は初版スキーマのため未適用。

MVPの受け入れ完了・本番同期保証・配布完了とは扱わない。続きは [実機確認手順](device-validation.md) に従う。
