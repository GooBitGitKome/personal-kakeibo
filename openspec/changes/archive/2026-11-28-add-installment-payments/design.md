# Design

## Context

動機と範囲は proposal.md、振る舞いは specs/installment-payments/spec.md を参照。以下は、実装に影響する現状の事実。

- 契約の種類 `ContractKind.installment`・`.loan` は既にある。`FinanceContract` に `maximumCycles`、`finalAmount`、`principal`、`liabilityAccountId`、`financedAssetId`、`paymentAccountId` がある。
- 支払確認（`FinanceUseCases.recordPayment`）は、分割・ローンで、支払元（銀行・現金）から支払額を引き、未払口座から元本を引き、利息だけを支出として記録する。元本と利息は毎回、利用者が入力する。
- `FinanceRules.effectiveMonth` は、分割・ローンの契約で、支払月の `interestAmount` だけを実質コストにする。確認前の予定は `interestAmount` が空なので、0 円になる。
- `FinanceRules.generatePayments(through:)` は、期限までの回を遅延生成し、未確認で上書きされていない予定の金額を、契約から再計算する。
- 家計簿の保存は、`StoredFinanceState` の JSON（`FinanceState`）。SwiftData のモデルは増えない。DB は `KakeiboSchema` 5.0.0。バックアップは `schemaVersion` 4。
- 記帳（`AccountPosting`）の `kind` は `transaction`、`refund`、`transfer`、`cardSettlement`、`loanSettlement`。正の値は、資産の増加か未払いの増加を表す。
- この環境には Swift も Xcode もないため、実装後の検証は GitHub Actions（`swift test` と署名なしビルド）で行う。

## Goals / Non-Goals

**Goals:**

- 金額の計算を、副作用のない純関数にまとめ、端数と合計の性質をテストで保証する。
- 既存の分割払い・ローンの契約と記録を、変更せずに動かし続ける。
- 状態の変更は、既存の `apply` と `FinanceRules.validate` を通し、不整合を保存しない。

**Non-Goals:**

- 年率による利息計算、一部の繰上返済、ボーナス払い（v0.3.0）。
- 既存の分割払い・ローン契約を、新しい形式へ自動変換すること。

## Decisions

### 1. 契約に支払総額を足し、新形式を `totalPayment != nil` で見分ける

`FinanceContract.totalPayment: Int64?` を足す。購入額は既存の `principal`、回数は `maximumCycles` を使う。`totalPayment == nil` の契約は、従来の動作のままにする。

- 代替案: 新しい型 `InstallmentPlan` を作る。`FinanceState` への配列追加、参照の検証、バックアップ項目が増える。契約・支払予定・口座の既存の仕組み（一覧、確認、通知）を再利用できなくなるため採用しない。

### 2. 金額計算は `InstallmentSchedule`（Domain、純関数）

入力: 購入額 P、支払総額 T、回数 n。出力: 各回の (支払額, 元本, 利息)。

- 支払額 $a_i = \lfloor T/n \rfloor$（$i < n$）、$a_n = T - (n-1)\lfloor T/n \rfloor$。
- 利息の総額 $I = T - P$。各回の利息は `allocatedYen(I, n, i)`（既存の累積丸め）を基本とし、$a_i$ を超える分は次回以降へ繰り越す。最終回が残りを精算する。元本は $a_i$ から利息を引く。
- 性質（テストで保証）: $\sum a_i = T$、$\sum p_i = P$、$\sum r_i = I$、すべての $i$ で $0 \le r_i \le a_i$。

代替案: 利息を最終回に寄せる。各回の利息が偏り、月別の実質コストが現実とずれるため採用しない。

### 3. 全回の予定を登録時に作り、遅延生成の対象から外す

新形式の契約は、登録時に n 件の `ScheduledPayment` を、`plannedPrincipal` と `plannedInterest` 付きで作る。`generatePayments` は、`totalPayment != nil` の契約を飛ばす。契約からの再計算で、確認前の予定が上書きされるのを防ぐため。

`ScheduledPayment` に `plannedPrincipal: Int64?` と `plannedInterest: Int64?` を足す。確認時の `principalAmount`・`interestAmount` は、従来どおり実績を表す。

### 4. 記帳

`PostingKind` に `installmentPurchase` と `installmentCancellation` を足す。

| 操作 | 記帳 | 支出 |
|---|---|---|
| 登録 | 未払口座に +P（`installmentPurchase`、`eventId` は契約の ID） | なし |
| 支払確認 | 既存どおり。支払元に −支払額、未払口座に −元本（`loanSettlement`） | 利息のみ |
| 取消 | 未払口座に −残りの元本（`installmentCancellation`） | なし |
| 一括繰上返済 | 支払元に −(残りの元本+手数料)、未払口座に −残りの元本（`loanSettlement`） | 手数料のみ |

残りの元本は、P から確認済みの元本の合計を引いた額。購入額の登録を、`Transaction` にしない理由は、元本を支出に入れない既存の方針に合わせるため。

### 5. 実質コストへの反映

`effectiveMonth` で、新形式の契約の予定は、確認前（`pending`）なら `plannedInterest`、確認済みなら実績の `interestAmount` を、支払月に加える。従来の契約は変えない。取り消した予定は含めない。

### 6. 取消・繰上返済・条件変更は `FinanceUseCases` に追加する

- 取消: `pending` の予定をすべて `cancelled` にし、契約を `ended` にする。
- 繰上返済: 手数料を受け取り、既存の `recordPayment` と同じ形で 1 つのイベントとして記録し、残りの予定を `cancelled` にする。繰上返済そのものは、`ScheduledPayment` に新しい行（`cycleIndex` は最後の次の値、支払額は残りの元本+手数料、元本は残りの元本）として残し、履歴で確認できるようにする。
- 条件変更: `pending` を `cancelled` にし、新しい `seriesId` で、残りの元本・入力された残りの支払総額と回数から、同じ規則で予定を作り直す。初回の期日は、取り消した最初の予定の期日とする。
- 3 つとも、実行前に確認を求める（UI）。ユースケースは、期待する状態（`expected`）を受け取り、変わっていれば `FinanceError.changed` にする（既存の `skipPayment` と同じ）。

### 7. 保存形式: バックアップ v5、DB は変更しない

新しい項目は、すべて `FinanceState` の JSON に入る任意の項目で、SwiftData のモデルは変わらない。そのため **DB（`KakeiboSchema` 5.0.0）は変えない**。

バックアップは v5 にする。理由は、v4 までのアプリが、新しい `PostingKind` を含むデータを、黙って落とさずに拒否するため。`BackupFormat` は v1〜v5 を読み、v5 だけが `finance` に新しい項目を持てる。v4 以前に新しい項目があれば拒否する。

> 利用者の選択（2026-11-28）は「DB v6・バックアップ v5」だった。DB のバージョンを上げる必要はないと判断した。上げる場合は、空の移行段階を足す必要があり、利点がない。異論があれば、実装前に決める。

### 8. 検証の追加

`FinanceRules.validate` に、新形式の契約の規則を足す。

- `totalPayment >= principal`、`totalPayment >= maximumCycles`、`principal >= 1`、`maximumCycles` は 2 以上 1,200 以下。
- 購入の記帳が 1 件あり、金額が `principal` と一致する。
- 確認済みの元本の合計は `principal` 以下。
- `pending` の予定は `plannedPrincipal` と `plannedInterest` を持ち、合計が `expectedAmount` に一致する。

## Risks / Trade-offs

- [利息の繰り越し規則が、一部の入力で最終回の利息を支払額より大きくする] → 性質テストを、購入額・総額・回数の小さい値の全組み合わせと、境界値（n=1,200、P=1、T=P）で実行する。成り立たなければ、規則を見直す。
- [Swift の環境がなく、手元でテストできない] → 計算の純関数と検証を先に作り、CI の `swift test` で確認する。UI は、CI の署名なしビルドで型を確認し、動作は未検証として記録する。
- [実額が予定と違うとき、残りの予定の内訳が実績とずれる] → 残りの元本は、購入額から確認済みの元本を引いた額（実績）で計算する。最終回の確認では、残りの元本を初期値にする。
- [新しい `PostingKind` を、旧アプリが読めない] → バックアップを v5 にして、旧アプリには明示的に拒否させる。
- [条件変更で、同じ契約の予定が複数の系列に分かれる] → 画面では、期日順に並べ、系列を意識させない。`validate` は、取消済みの予定に系列の一致を求めない（既存の規則）。

## Migration Plan

1. DB は変更しない。既存のストアは、そのまま開く。
2. バックアップ v1〜v4 の読み込みは、結果を変えない。v5 の書き出しは、分割払いがなくても v5 とする。
3. ロールバックは、v5 のバックアップから新形式の契約を除いた v4 を、手で作らない限りできない。リリース前に、v4 のバックアップを取るよう案内する（README）。
4. 旧ストアの試験を追加する: v4 のバックアップと、`KakeiboSchemaV4` のストアを読み込み、内容が変わらないこと。

## Open Questions

- 画面の文言と配置（登録画面を「契約・固定費」の追加に置くか、独立の入口にするか）。仕様は変えずに、実装時に決められる。
