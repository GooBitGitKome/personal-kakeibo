# Design

## Context

動機と範囲は proposal.md、振る舞いは specs/bonus-payments/spec.md を参照。以下は、v0.2.0（`main`）の実装の事実。

- 分割払いは `FinanceContract`（`totalPayment != nil`）で、購入額は `principal`、回数は `maximumCycles`。登録時に全回の `ScheduledPayment` を、`plannedPrincipal`・`plannedInterest` 付きで作る。
- `InstallmentSchedule.make(principal:total:cycles:)` が、各回の支払額（切り捨て、余りは最終回）を作り、利息を `proportionalShare` で各回の支払額に比例して配分する。利息が支払額を超えない性質は、各回の支払額が正であれば、金額の分布によらず成り立つ（累積の比例配分の差は、その回の支払額以下）。
- 登録は `FinanceUseCases.registerInstallment`。取消、繰上返済、残りの条件の変更は、`FinanceUseCases` にある。
- バックアップは v5（`FinanceState.usesInstallmentPlans` が真のデータは v5 以降だけ）。DB は `KakeiboSchema` 5.0.0 で、`FinanceState` は JSON ペイロード。
- 検証は GitHub Actions（`swift test`、署名なしビルド）。この環境には Swift と Xcode がない。Xcode 26.6 は、長い `+` の文字列連結で型チェックがタイムアウトする。

## Goals / Non-Goals

**Goals:**

- ボーナス払いを、v0.2.0 の仕組み（予定、記帳、集計、取消、繰上返済）にそのまま乗せる。分割払いのデータと動作を変えない。
- 金額の計算を純関数にまとめ、合計と上限の性質をテストで保証する。

**Non-Goals:**

- ボーナス一括払い（1 回払い）、月ごとに違う加算額、割合での入力。
- ボーナス払いの条件変更。v0.2.0 の分割払いからの変換。

## Decisions

### 1. 契約に `bonusMonths` と `bonusAmount` を足す

`FinanceContract.bonusMonths: [Int]?`（1〜12 の重複なしの昇順）と `bonusAmount: Int64?`。両方があるものを、ボーナス払いとする。ボーナス月の回は、各 `ScheduledPayment` に印を持たず、**支払日の月が `bonusMonths` に含まれるか**で決める。支払予定の項目は増やさない。

- 代替案: `ScheduledPayment` に `isBonus` を持つ。取消・変更で状態が二重になり、検証が増えるため採用しない。

### 2. 内訳の計算を、各回の金額の配列から求める形に一般化する

`InstallmentSchedule.split(principal:amounts:)` を公開し、`make` はこれを呼ぶ形にする。`make` の入出力は変えない（既存の試験が、そのまま通る）。

- 入力: 購入額 P、各回の支払額 $a_i$（すべて 1 以上、2 件以上 1,200 件以下で、合計は P 以上）。
- 出力: 各回の (支払額, 元本, 利息)。利息は `proportionalShare` による累積の比例配分で、合計 $T=\sum a_i$ と P の差が一致する。

### 3. ボーナス月を含む金額は `BonusSchedule`（Domain、純関数）

`BonusSchedule.make(principal:total:dueDates:bonusMonths:bonusAmount:)`。

- ボーナス月の回: 支払日の月（`Month.calendar`、日本時間）が `bonusMonths` に含まれる回。その回数を k とする。
- 毎月の部分の合計 $B = T - kX$（X は加算額）。$k = 0$、$X < 1$、$B < n$ は `FinanceError.invalid`。
- 毎月の部分: $b = \lfloor B/n \rfloor$、最終回に余り $B - nb$ を足す。ボーナス月の回は、さらに X を足す。
- 内訳は、1. で一般化した `split` に渡す。

支払日は、`contract.interval.date(from: firstDue, index:)` で求める（v0.2.0 と同じ。その月にない日は月末）。

### 4. 登録の入力に `bonus` を足す

`InstallmentInput.bonus: BonusInput?`（`months: Set<Int>`、`amount: Int64`）。`registerInstallment` は、先に全回の支払日を求め、`bonus` があれば `BonusSchedule` を、なければ `InstallmentSchedule.make` を使う。契約には、`bonus` があるときだけ `bonusMonths`（昇順）と `bonusAmount` を入れる。保存は、v0.2.0 と同じ 1 回の `apply`。

### 5. 検証の追加

`validateInstallmentPlans` に足す。

- `bonusMonths` と `bonusAmount` は、両方あるか両方ないか。
- `bonusMonths` は空でなく、1〜12 の重複なし。`bonusAmount` は 1 以上で、`totalPayment` 以下。
- ボーナス払いは、分割払い（`totalPayment != nil`）でなければならない。

支払予定の金額と、ボーナス月の設定との整合（金額の再計算）は検証しない。取消・繰上返済で予定が減るため、再計算は成り立たない。

### 6. 条件変更の拒否

`changeInstallmentTerms` は、`bonusAmount != nil` の契約に対して、状態を読む前に `FinanceError.invalid` を返す。`apply` の中で投げるため、保存は起きない。画面は、ボーナス払いでは「残りの条件を変更」を出さず、取り消して登録し直す案内を出す。

- 代替案: ボーナス月の加算額を含めて、条件変更に対応する。残りのボーナス月の数の再計算、予定の作り直し、画面の入力が増える。利用者が対象外とした。

### 7. バックアップ v6、DB は変更しない

`FinanceState.usesBonusPlans`（`bonusAmount` か `bonusMonths` がある契約）を足す。`BackupFile.schemaVersion` の既定を 6 にし、読み込みは 1〜6 を受け付ける。v5 以前の形式で `usesBonusPlans` が真のものは、`StoreError.invalidData` で拒否する。

v5 の版は、v6 を `unsupported` として拒否する。新しい項目は `FinanceState` の JSON の任意の項目で、SwiftData のモデルは変わらないため、DB は変更しない。

### 8. 画面

`InstallmentRegisterView` に、「ボーナス月に加算する」のトグルを足す。オンのときだけ、12 か月のトグル（初期値は 6 月と 12 月）と加算額の入力を出す。入力検査と予定の表示は、`BonusSchedule` の結果を使う。`InstallmentDetailView` には、ボーナス月と加算額の行、各回のボーナス月の印、ボーナス払いでの案内を足す。

## Risks / Trade-offs

- [Xcode 26.6 の型チェックのタイムアウト] → 文字列は補間で作り、長い式を避ける（v0.2.0 で発生した問題と同じ）。
- [ボーナス月の判定が、日本時間の月に依存する] → 判定は `Month.calendar`（Asia/Tokyo）で統一し、月初・月末の境界を試験する。
- [一般化した `split` が、v0.2.0 の結果を変える] → `make` の既存の試験（全組み合わせの性質試験を含む）を変えずに通す。
- [新しい項目を v5 までの版が黙って落とす] → バックアップを v6 にして、明示的に拒否させる。
- [コミット済みの `project.pbxproj` の手編集] → 新規ファイル 1 件の登録だけ。CI の再生成結果との一致は、実機のビルドで確認する。

## Migration Plan

1. DB は変更しない。既存のストアは、そのまま開く。
2. バックアップ v1〜v5 の読み込みは、結果を変えない。書き出しは v6 になる。
3. ロールバックは、v6 のバックアップからボーナス払いを除いた v5 を、手で作らない限りできない。更新前に、v5 のバックアップを取るよう案内する（README）。
4. 試験: v5 のバックアップと、v0.2.0 の分割払いを含むストアを、新しい版で読み込み、内容が変わらないこと。

## Open Questions

- 画面の文言とトグルの配置（12 か月のトグルの並べ方）。仕様は変えずに、実装時に決められる。
