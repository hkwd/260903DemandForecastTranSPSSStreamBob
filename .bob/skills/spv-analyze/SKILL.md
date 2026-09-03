---
name: spv-analyze
description: Use when the user wants to analyze, explain, or interpret an SPSS Modeler .spv output file. Handles time-series model info, fit statistics, and parameter estimates for all target series.
---

# SPV ファイル解析スキル

IBM SPSS Modeler が出力する `.spv` モデルナゲットファイルを解析し、モデル構造・適合度・パラメーター推定値を日本語で解説する。

## ファイル形式の前提知識

- `.spv` は ZIP アーカイブ（拡張子を `.zip` にリネームすれば展開できる）
- 内部の `.bin` ファイルは **圧縮なしの UTF-8 JSON**（先頭が `{"cells":` で始まる）
- `outputViewer0000000000_heading.xml` に各ブロックの構造と `.bin` ファイルへの参照が入っている
- `.bin` のデータ配列は **列優先（column-major）** で格納されている
  - 例：6行×4列の場合、`vals[0..5]` = 係数列、`vals[6..11]` = SE列、`vals[12..17]` = t値列、`vals[18..23]` = 有意確率列

## ステップ 1 — ファイルを展開する

`execute_command` で ZIP として展開する。

```powershell
$spv  = "<対象ファイルパス>"
$out  = ".bob/tmp/spv_extract"
New-Item -ItemType Directory -Force -Path $out | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory(
    (Resolve-Path $spv), (Resolve-Path $out))
Get-ChildItem $out -Recurse | Select-Object Name, Length
```

## ステップ 2 — 構造マップを取得する（heading XML）

`execute_command` で heading XML をパースし、対象系列ごとの `.bin` ファイル名を列挙する。

```powershell
[xml]$xml = Get-Content ".bob/tmp/spv_extract/outputViewer0000000000_heading.xml" -Raw -Encoding UTF8
function Get-AllText($node) {
    if ($node.NodeType -eq "Text") { $node.Value }
    foreach ($child in $node.ChildNodes) { Get-AllText $child }
}
Get-AllText $xml.DocumentElement | Where-Object { $_ -match '\S' }
```

出力から「系列名（店舗名など）→ モデル情報 .bin → パラメーター .bin」の対応を把握する。

## ステップ 3 — Python スクリプトで数値を解析する

以下のスクリプトを `.bob/skills/spv-analyze/analyze_spv.py` として同梱している。
`execute_command` で呼び出す。

```powershell
python .bob/skills/spv-analyze/analyze_spv.py `
    --extract-dir ".bob/tmp/spv_extract" `
    --model-bins "<モデル情報.bin1>,<モデル情報.bin2>,..." `
    --param-bins "<パラメーター.bin1>,<パラメーター.bin2>,..." `
    --labels "<系列名1>,<系列名2>,..."
```

スクリプトは標準出力に以下を JSON で返す：
- `model_info`: 各系列の適合度指標（ARIMA次数・MSE/RMSE/MAPE/R²/AIC/BIC/LjungBox）
- `params`: 各系列のパラメーター推定値（係数・SE・t値・有意確率・行ラベルキー）

## ステップ 4 — 結果を解釈して日本語で報告する

スクリプト出力をもとに以下の順で解説する。

### 4-1. モデル概要

- 各系列に選ばれた ARIMA 次数（非季節 p,d,q と季節 P,D,Q）
- 次数の意味（AR/MA/差分、季節）を簡潔に説明

### 4-2. 適合度の比較表

全系列を横に並べた比較表を作成する。

| 指標 | 意味 | 判断基準 |
|---|---|---|
| R² | 分散の説明率 | 1に近いほど良い |
| MAPE | 平均絶対誤差率(%) | 小さいほど良い（10%以下が目安） |
| RMSE | 二乗平均平方根誤差 | 小さいほど良い（単位は目的変数と同じ） |
| AIC/BIC | モデル複雑さのペナルティ付き適合度 | 小さいほど良い（系列間比較に使う） |
| Ljung-Box p値 | 残差の自己相関検定 | 0.05 超が理想（残差に構造が残っていない） |

### 4-3. パラメーター推定値の解釈

各パラメーターについて以下を説明する。

**時系列構造パラメーター（MA/AR/季節MA/季節AR）:**
- MA(q): 過去 q 期の予測誤差が現在値に与える影響。係数が 0〜1 の正値が標準的
- AR(p): 過去 p 期の実績値からの自己回帰。係数の絶対値が 1 未満で安定
- 季節MA/AR: 上記の週次・月次など季節周期版

**外部変数（予測変数）:**
- 係数の符号（正/負）と大きさで「どの変数が需要を押し上げ/押し下げるか」を説明
- 有意確率（p値）で統計的有意性を判定（0.05 未満 → 有意、以上 → 有意差なし）
- 系列間で同じ変数の係数方向が逆転する場合は立地・業態の違いとして解釈

### 4-4. 総合コメント

- 最も精度の高い系列・低い系列とその理由
- Ljung-Box が有意（p < 0.05）な系列はモデル改善余地ありとコメント
- 実務上の示唆（どの外部変数が施策として有効か）

## 注意事項

- `.bin` の行ラベルは文字化けすることがあるが、`key` フィールド（英語）で種別を識別できる
  （例: `"MA"`, `"AR"`, `"MA_Seasonal"`, `"Constant"`, `"降水量"` など）
- 値配列の長さが `n_rows × n_cols` にならない場合は列数（`dimensions[0].numberOfCategories`）と行数（`dimensions[1].numberOfCategories`）を実際の JSON から取得して再計算する
- 店舗名などの系列ラベルは heading XML の `<label>` テキストノードから取得する
