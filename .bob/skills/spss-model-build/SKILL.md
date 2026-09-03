---
name: spss-model-build
description: SPSS Modeler で予測モデルのストリームを Jython スクリプトで作って実行して、と依頼されたときに使う。「需要予測ストリームを作って」「分類モデルを作りたい」「回帰分析のストリームを生成して」「Expert Modelerで時系列予測して」「クラスタリングのモデルをSPSSで作って」「CSVからモデルを構築して」など。CSV を入力に、目的に応じたモデルノードでストリームを構築し、実行・保存まで行う。
---

# SPSS Modeler 予測モデルストリーム生成スキル

CSV データを入力に、ユーザーの目的に合ったモデルノードを選定し、Jython スクリプトでストリームを構築して実行・保存まで行う。

---

## Step 1 — CSV 構造を把握する

`read_file` で CSV の先頭 10〜20 行を読む。以下を把握する：

- フィールド名の一覧
- 日付・時刻フィールドの有無と形式
- 数値フィールドと文字列フィールドの区別
- 大まかなレコード数（行数）

---

## Step 2 — モデル種別を決定する

ユーザーの依頼内容と CSV 構造から、以下の表でモデル種別とノードを選ぶ。  
不明な場合は `ask_followup_question` で確認する。

| 目的 | ノード名（スクリプト名）| ナゲット名 | Target の型 |
|------|------------------------|------------|-------------|
| **時系列予測**（需要予測・売上予測など）| `ts` | `applyts` | Range（連続） |
| **回帰**（数値を予測）| `linearregression` | `applylinearregression` | Range |
| **ランダムフォレスト回帰/分類** | `randomtrees` | `applyrandomtrees` | Range / Flag / Set |
| **ニューラルネット回帰/分類** | `neuralnet` | `applyneuralnet` | Range / Flag / Set |
| **二値分類** | `logistic` | `applylogistic` | Flag |
| **多値分類（決定木）** | `c50` | `applyc50` | Flag / Set |
| **決定木 CHAID** | `chaid` | `applychaid` | Flag / Set |
| **勾配ブースティング** | `gbm` | `applygbm` | Range / Flag / Set |
| **SVM** | `svm` | `applysvm` | Range / Flag / Set |
| **k-means クラスタリング** | `kmeans` | `applykmeans` | （Target なし）|
| **2 段階クラスタリング** | `twostep` | `applytwostep` | （Target なし）|

> **時系列データの判定基準**: 日付フィールドが存在し、予測対象が時間軸上の将来値 → `ts` ノードを選ぶ。

---

## Step 3 — 入力情報を確定する

CSV 読み取りで不明な項目のみ `ask_followup_question` で確認する。

**全モデル共通**
- CSV ファイルの絶対パス
- Target フィールド名（クラスタリングは不要）
- Input フィールド名（省略時: Target 以外の全数値フィールド）
- 出力 `.str` ファイルパス（デフォルト: CSV 同ディレクトリの `model.str`）

**時系列専用**
- 日付フィールド名 と フォーマット（例: `YYYY-MM-DD`）
- データ間隔（Day / Week / Month / Quarter / Year）
- 予測期間（デフォルト: 30）

---

## Step 4 — Jython スクリプトを生成する

`write_file` でスクリプトを CSV と同ディレクトリに保存する。

### 共通ヘッダー

> ⚠️ **`# -*- coding: utf-8 -*-` を先頭に書いてはいけない。** Jython は Unicode 文字列内のエンコーディング宣言を構文エラーとして扱う（`SyntaxError: encoding declaration in Unicode string`）。

```python
import modeler.api
import os

stream     = modeler.script.stream()
taskrunner = modeler.script.session().getTaskRunner()

# ⚠️ __file__ はバッチモード（clemb.exe -script）では未定義。絶対パスを直接指定すること。
base_dir    = r"<絶対パス>"
csv_path    = os.path.join(base_dir, "<ファイル名>.csv")
output_path = os.path.join(base_dir, "<ファイル名>.str")
```

---

### データ入力・操作ノード

#### A. データ入力（`variablefile`）

```python
vf_node = stream.createAt("variablefile", u"CSVインポート", 50, 100)
vf_node.setPropertyValue("full_filename", csv_path)
vf_node.setPropertyValue("encoding", "UTF-8")
# タブ区切り: vf_node.setPropertyValue("delimit_tab", True)
```

#### B. 集計（`aggregate`）

```python
agg_node = stream.createAt("aggregate", u"日次集計", 200, 100)
stream.link(vf_node, agg_node)
agg_node.setPropertyValue("inc_record_count", False)
agg_node.setPropertyValue("keys", [u"<KEY1>", u"<KEY2>"])
# フィールドごとにキー付きで指定。出力フィールド名は「フィールド名_Sum」等になる
agg_node.setKeyedPropertyValue("aggregates", u"<FIELD>",  [u"Sum"])
agg_node.setKeyedPropertyValue("aggregates", u"<FIELD2>", [u"Mean"])
# 使える集計関数: Sum / Mean / Min / Max / SDev / Median / Count / Variance / First / Last
```

#### C. 結合（`merge`）

```python
merge_node = stream.createAt("merge", u"マスタ結合", 350, 100)
stream.link(agg_node, merge_node)
stream.link(master_node, merge_node)
merge_node.setPropertyValue("method",      u"Keys")
merge_node.setPropertyValue("key_fields",  [u"<KEY_FIELD>"])  # keys ではなく key_fields
merge_node.setPropertyValue("common_keys", True)              # True = Inner join 相当
# 外部結合: merge_node.setPropertyValue("join", "FullOuter")
```

#### D. フィールド型・ロール定義（`type`）

```python
type_node = stream.createAt("type", u"フィールド型定義", 500, 100)
stream.link(merge_node, type_node)

# フィールドをインスタンス化（一時テーブルを実行して削除）
tmp = stream.createAt("table", u"_tmp", 650, 200)
stream.link(type_node, tmp)
tmp.run([])
stream.delete(tmp)

type_node.setKeyedPropertyValue(u"direction", u"<TARGET>", u"Target")
type_node.setKeyedPropertyValue(u"type",      u"<TARGET>", u"Range")

for f in [<INPUT_FIELDS_LIST>]:
    type_node.setKeyedPropertyValue(u"direction", f, u"Input")
    type_node.setKeyedPropertyValue(u"type",      f, u"Range")

for f in [<FLAG_FIELDS_LIST>]:
    type_node.setKeyedPropertyValue(u"direction", f, u"Input")
    type_node.setKeyedPropertyValue(u"type",      f, u"Flag")

# 日付フィールド（ts ノード用）
type_node.setKeyedPropertyValue(u"direction", u"<DATE_FIELD>", u"Input")
type_node.setKeyedPropertyValue(u"type",      u"<DATE_FIELD>", u"Range")

# splitFields のグループ分割フィールド: direction="Split" に設定する
type_node.setKeyedPropertyValue(u"direction", u"<SPLIT_FIELD>", u"Split")
type_node.setKeyedPropertyValue(u"type",      u"<SPLIT_FIELD>", u"Set")
```

#### E. フィールド派生（`derive`）

```python
derive_node = stream.createAt("derive", u"フィールド派生", 300, 100)
stream.link(prev_node, derive_node)
derive_node.setPropertyValue("new_name",     u"新フィールド名")
derive_node.setPropertyValue("formula_expr", u"<CLEM式>")   # formula は無効
derive_node.setPropertyValue("result_type",  "Continuous")  # Flag / Nominal / Continuous のみ有効。文字列返しは省略
```

#### F. 縦結合（`append`）

```python
append_node = stream.createAt("append", u"縦結合", 500, 100)
stream.link(node_a, append_node)
stream.link(node_b, append_node)
append_node.setPropertyValue("match_by",            "Name")  # match は無効
append_node.setPropertyValue("include_fields_from", "All")
```

#### G. CSV エクスポート（`outputfile`）

```python
# スクリプト名は "outputfile"（"variablefileexport" / "flat_file_export" は存在しない）
export_node = stream.createAt("outputfile", u"CSV出力", 600, 100)
stream.link(prev_node, export_node)
export_node.setPropertyValue("full_filename",   output_csv)
export_node.setPropertyValue("inc_field_names", True)           # write_field_names は無効
export_node.setPropertyValue("write_mode",      "Overwrite")    # Overwrite / Append
# encoding の選択:
#   "SystemDefault" → Windows の場合 Shift-JIS。Excel で直接開ける（推奨）
#   "UTF-8"         → UTF-8。テキストエディタ・Python での後処理向き。Excel では文字化けする
export_node.setPropertyValue("encoding",        "SystemDefault")
```

#### H-2. フィールドリネーム（`filter` ノード）

`aggregate` 後の `"フィールド名_Sum"` など自動生成された名前を変更する場合は `filter` ノードの `setKeyedPropertyValue("new_name", ...)` を使う。
> ⚠️ `setPropertyValue("renamed_fields", [...])` というプロパティは存在しない。

```python
rename_node = stream.createAt("filter", u"フィールドリネーム", 500, 100)
stream.link(prev_node, rename_node)
# setKeyedPropertyValue("new_name", 元のフィールド名, 新しいフィールド名)
rename_node.setKeyedPropertyValue("new_name", u"小計_Sum",   u"全店舗売上")
rename_node.setKeyedPropertyValue("new_name", u"小計_Sum_1", u"店舗1売上")
```

#### H. 条件抽出（`select`）

```python
select_node = stream.createAt("select", u"対象期間抽出", 800, 100)
stream.link(nugget, select_node)
select_node.setPropertyValue("mode",      "Include")
# 文字列型フィールドの場合: 文字列比較
select_node.setPropertyValue("condition", u"SDATE >= \"2025-12-01\"")
# Date 型フィールドの場合: to_date() でリテラルを Date 型に変換して比較
# select_node.setPropertyValue("condition", u"SDATE >= to_date(\"2025-12-01\")")
```

#### I. ソート（`sort`）

```python
sort_node = stream.createAt("sort", u"ソート", 700, 100)
stream.link(prev_node, sort_node)
# keys: [[フィールド名, "Ascending" or "Descending"], ...]
sort_node.setPropertyValue("keys", [[u"店舗", "Ascending"], [u"年月", "Ascending"]])
```

---

### モデルノード別テンプレート

#### A. 時系列予測（`ts` / Expert Modeler）

##### A-1. splitFields 方式（推奨）— 1 ノードで全グループ同時予測

> **前提条件**: TSノードで `splitFields` を指定してグループ分割予測を行う場合、事前にTypeノードにおいて、対象の分割フィールドのロール（`direction` プロパティ）を `"Split"` に設定しておく必要があります。
> ```python
> type_node.setKeyedPropertyValue(u"direction", u"<SPLIT_FIELD>", u"Split")
> ```

```python
model_node = stream.createAt("ts", u"時系列", 400, 100)
stream.link(type_node, model_node)

model_node.setPropertyValue("custom_fields",   True)
model_node.setPropertyValue("splitFields",     [u"<SPLIT_FIELD>"])
model_node.setPropertyValue("date_time_field", u"<DATE_FIELD>")
model_node.setPropertyValue("input_interval",  u"<INTERVAL>")
model_node.setPropertyValue("targets",              [u"<TARGET>"])
model_node.setPropertyValue("includeTargets",       [u"<TARGET>"])
model_node.setPropertyValue("targetField",          [u"<TARGET>"])
model_node.setPropertyValue("candidateTargets",     [u"<TARGET>"])
model_node.setPropertyValue("inputAndTargetFields", [u"<TARGET>"])
# フラグ類は events に指定。candidate_inputs と重複させると AEQTD0041W 警告が多発する
model_node.setPropertyValue("events",               [u"<FLAG1>", u"<FLAG2>"])
model_node.setPropertyValue("extend_records_into_future", True)
model_node.setPropertyValue("cal_PI",   True)
model_node.setPropertyValue("use_weight", True)
model_node.setPropertyValue("isOutputIntervalControlEnabled", True)
model_node.setPropertyValue("futureValue_type_method", u"specify")

print(u"時系列モデルを構築中...")
model_node.run([])
print(u"モデル構築完了")

nugget = stream.findByType("applyts", None)
```

##### A-2. select 分割 + ts 複数回方式

```python
model_node = stream.createAt("ts", u"時系列予測モデル", 400, 100)
stream.link(type_node, model_node)

model_node.setPropertyValue("custom_fields",   True)
model_node.setPropertyValue("use_period",      False)
model_node.setPropertyValue("date_time_field", u"<DATE_FIELD>")
model_node.setPropertyValue("input_interval",  "<INTERVAL>")
model_node.setPropertyValue("targets",              [u"<TARGET>"])
model_node.setPropertyValue("includeTargets",       [u"<TARGET>"])
model_node.setPropertyValue("targetField",          [u"<TARGET>"])
model_node.setPropertyValue("candidateTargets",     [u"<TARGET>"])
model_node.setPropertyValue("inputAndTargetFields", [u"<TARGET>"])
model_node.setPropertyValue("candidate_inputs", [u"<INPUT1>", u"<INPUT2>"])  # events と重複不可
model_node.setPropertyValue("events",           [u"<FLAG1>", u"<FLAG2>"])
model_node.setPropertyValue("method",            "ExpertModeler")
model_node.setPropertyValue("consider_seasonal", True)
model_node.setPropertyValue("detect_outliers",   True)
model_node.setPropertyValue("forecastperiods",   <FORECAST_PERIODS>)
model_node.setPropertyValue("extend_records_into_future", True)
model_node.setPropertyValue("conf_limits",    True)
model_node.setPropertyValue("conf_limit_pct", 95.0)

# 1 回目実行後: ナゲット ID を記録
results1 = []
model_node.run(results1)
nugget1 = stream.findByType("applyts", None)
nugget1_ids = set([id(nugget1)]) if nugget1 else set()

# 2 回目実行後: id() 差分で新ナゲットを識別
results2 = []
model_node2.run(results2)
nugget2 = None
cur = stream.findByType("applyts", None)
if cur and id(cur) not in nugget1_ids:
    nugget2 = cur
if nugget2 is None:
    nugget2 = nugget1  # 同一ノードが再利用された場合のフォールバック
```

---

#### B. 線形回帰（`linearregression`）

```python
model_node = stream.createAt("linearregression", u"線形回帰モデル", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("include_constant", True)

results = []
model_node.run(results)

nugget = stream.findByType("applylinearregression", None)
```

---

#### C. ランダムフォレスト（`randomtrees`）

```python
model_node = stream.createAt("randomtrees", u"ランダムフォレスト", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("num_trees", 100)

results = []
model_node.run(results)

nugget = stream.findByType("applyrandomtrees", None)
```

---

#### D. ニューラルネット（`neuralnet`）

```python
model_node = stream.createAt("neuralnet", u"ニューラルネット", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("hidden_layers",  [[10]])  # 隠れ層: 1層 10ユニット
model_node.setPropertyValue("max_iterations", 250)

results = []
model_node.run(results)

nugget = stream.findByType("applyneuralnet", None)
```

---

#### E. 決定木 C5.0（`c50`）

```python
model_node = stream.createAt("c50", u"C5.0 決定木", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("output_type", "DecisionTree")  # or "RuleSet"

results = []
model_node.run(results)

nugget = stream.findByType("applyc50", None)
```

---

#### F. ロジスティック回帰（`logistic`）

```python
model_node = stream.createAt("logistic", u"ロジスティック回帰", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("procedure", "Multinomial")  # or "Binomial"

results = []
model_node.run(results)

nugget = stream.findByType("applylogistic", None)
```

---

#### G. k-means クラスタリング（`kmeans`）

```python
# クラスタリング: Target 不要。全特徴フィールドを Input に設定する
model_node = stream.createAt("kmeans", u"k-meansクラスタ", 400, 100)
stream.link(type_node, model_node)
model_node.setPropertyValue("k", 4)

results = []
model_node.run(results)

nugget = stream.findByType("applykmeans", None)
```

---

### モデルナゲット — SPV ファイル出力

`taskrunner.exportModelSummaryToFile` にナゲットノード自体を渡すと、モデルサマリーを SPV ファイルとして保存できる。

```python
spv_path = os.path.join(base_dir, "model_output.spv")

if nugget:
    taskrunner.exportModelSummaryToFile(nugget, spv_path, modeler.api.FileFormat.SPV)
    print(u"SPV保存完了: " + spv_path)
```

> - 第1引数は **ナゲットノード自体**（`applyts` 等）。`run()` で取り出した `DocumentOutput` ではない
> - `nugget.run(results)` → `results[0]` で `DocumentOutput` を取得して `exportDocumentToFile` に渡す方法では `results` が空になり 0 バイトの空ファイルになる
> - `modeler.api.FileFormat.SPV` を使う（文字列 `"SPV"` ではない）
> - `applyts` に限らず `exportModelSummaryToFile` が受け付けるナゲット全般に適用可能
> - SPV は SPSS Statistics ビューワーまたは Modeler のモデルビューワーで開ける
> - `FileFormat` には他に `HTML` / `PDF` / `RTF` / `MS_EXCEL2007` / `PNG` 等も利用可能

---

### グラフ出力テンプレート

#### `multiplot`（推奨）— グループ別パネル表示対応

```python
sel_node = stream.createAt("select", u"期間フィルタ", 700, 100)
stream.link(nugget, sel_node)
sel_node.setPropertyValue("condition",       u"SDATE >= \"<DATE>\"")
sel_node.setPropertyValue("use_custom_name", True)
sel_node.setPropertyValue("custom_name",     u"SDATE >= \"<DATE>\"")

mp_node = stream.createAt("multiplot", u"線グラフ", 850, 100)
stream.link(sel_node, mp_node)
mp_node.setPropertyValue("panel_field", u"<SPLIT_FIELD>")
mp_node.setPropertyValue("x_field",    u"<DATE_FIELD>")
mp_node.setPropertyValue("y_fields",   [u"<TARGET>", u"$TS-<TARGET>"])

mp_node.run([])
```

#### `timeplot`（単一系列）

```python
sel_node = stream.createAt("select", u"期間フィルタ", 800, 100)
stream.link(nugget, sel_node)
sel_node.setPropertyValue("condition", u"date_before(<DATE_FIELD>, DATE(\"YYYY-MM-DD\")) = 0")
sel_node.setPropertyValue("mode", "Include")

tp_node = stream.createAt("timeplot", u"需要予測グラフ", 950, 100)
stream.link(sel_node, tp_node)
tp_node.setPropertyValue("y_fields", [u"<TARGET>", u"$TS-<TARGET>"])
tp_node.setPropertyValue("line",     True)
```

> `$TS-<TARGET>` = 予測値、`$TSLCI-<TARGET>` = 95% 信頼区間下限、`$TSUCI-<TARGET>` = 上限

---

### 共通フッター

```python
if nugget:
    table_node = stream.createAt("table", u"予測結果テーブル", 600, 100)
    stream.link(nugget, table_node)
else:
    print(u"警告: ナゲットが見つかりません")

taskrunner.saveStreamToFile(stream, output_path)
print(u"保存完了: " + output_path)
```

---

### エラー発生時の API ドキュメント照会

`mcp__ibm-docs-mcp__search_ibm_docs` で正確なプロパティ名・値を確認してから修正する。

```
product_id: "spss-modeler"
keyword:    "<ノード名> property"  # 例: "ts node property" / "variablefile encoding"
```

---

## Step 5 — スクリプトを実行する

`mcp__spss-clemb-mcp_996b__execute_clemb` ツールを使って実行する。MCP サーバーが JAVA_TOOL_OPTIONS を自動設定するため、`.bat` ファイルや `cmd.exe` の準備は不要。

```
mcp__spss-clemb-mcp_996b__execute_clemb
  script_file: "<SCRIPT_PATH>"
  log_file:    "<LOG_PATH>"
```

実行後は返却された `=== LOG FILE ===` セクションを確認する（別途 `read_file` は不要）。

---

## Step 6 — ログを確認して結果を報告する

`read_file` でログを読み、以下を確認する：

| 確認ポイント | OK の目安 |
|---|---|
| エラーなし | ログに `AEQMJ` エラーがない |
| モデル構築完了 | `ストリーム実行の成功` が 2 回以上（型定義実行 + モデル実行）|
| 時系列の場合 | `モデル '...' の構築に、X 分 Y 秒かかりました`（Expert Modeler は全候補評価のため数分かかる）|

---

## よくあるエラーと対処

| エラーメッセージ | 原因 | 対処 |
|---|---|---|
| `プロパティー 'delimiters' が定義されていません` | プロパティ名誤り | `delimit_other=True, other=","` を使う |
| `不明なノード タイプ 'streamingtimeseries'` | ノード名誤り | 時系列ノードのスクリプト名は `ts` |
| `'module' に、属性 'taskrunner' がありません` | taskrunner 取得方法誤り | `modeler.script.session().getTaskRunner()` を使う |
| `String incompatible with Measure` | type 値誤り | `"Continuous"` ではなく `"Range"` を使う |
| `ノードを作成できません: 不明なノード タイプ` | ノード名誤り | モデルノード対応表のスクリプト名を使う |
| `String incompatible with DateFormat` | `custom_date_format` 使用 | `stream.setPropertyValue("date_format", "YYYY-MM-DD")` + `custom_storage="Date"` を使う |
| `プロパティー 'agg_fields' が定義されていません` | aggregate プロパティ名誤り | `setKeyedPropertyValue("aggregates", field, ["Sum"])` を使う |
| `プロパティー 'keys' が定義されていません`（merge） | merge プロパティ名誤り | `setPropertyValue("key_fields", [...])` を使う（`keys` ではない） |
| `プロパティー 'join_type' が定義されていません` | merge プロパティ名誤り | `setPropertyValue("common_keys", True)` を使う |
| フラグ変数が時系列モデルで無視される | `custom_fields` 未設定 | `ts_node.setPropertyValue("custom_fields", True)` を指定する |
| 店舗・カテゴリ別のモデルが作られない | splitFields 未設定 / Type ノードで direction が Split 以外になっている | A-1 の方式: Type ノードで `direction="Split"` + ts ノードで `splitFields=[u"<SPLIT_FIELD>"]` |
| `findByType(): 2nd arg can't be coerced to String` | `findByType` 第2引数誤り | 第2引数は常に `None`。複数ナゲット取得は `id()` 差分で識別する |
| `'ExtensionBuildM' has no attribute 'getOutputLinks'` | ts ノードに `getOutputLinks()` 呼び出し | `results` リストか `id()` 差分で取得する |
| CLEM 式の日本語が文字化け（`蠎苓` など） | JVM が UTF-8 でない | `.bat` に `JAVA_TOOL_OPTIONS` を設定して `cmd.exe` 経由で実行 |
| `AEQTD0041W: metricFieldList のフィールドが重複` | `candidate_inputs` と `events` に同じフィールド | フラグ類は `events` のみに指定し `candidate_inputs` と重複させない |
| `プロパティー 'formula' が定義されていません` | derive プロパティ名誤り | `formula_expr` を使う（`formula` は無効）|
| `値 'String' はプロパティー 'result_type' に対して有効ではありません` | derive の result_type 誤り | 有効値は `"Flag"` / `"Nominal"` / `"Continuous"` のみ。文字列を返す場合は省略する |
| `引数の型に演算子または関数を適用できませんでした: substring(日付, 整数, 整数)` | 日付型フィールドに文字列関数を適用 | `datetime_year()` / `datetime_month()` を使い `to_string()` で変換する |
| `関数 'year' は定義されていません` / `関数 'month' は定義されていません` | CLEM 日付関数名誤り | `year()` / `month()` は存在しない。正しくは `datetime_year()` / `datetime_month()` |
| `関数 'round' の引数数が誤っています` | `round(x, n)` は無効 | CLEM の `round` は1引数のみ（整数に丸める）。小数桁指定は不可 |
| `次の式に空の '()' があります` | `undef()` と書いた | `undef` はキーワード。括弧不要。`else undef endif` と書く |
| `プロパティー 'match' が定義されていません`（append） | append プロパティ名誤り | `match_by` を使う（`match` は無効）|
| `プロパティー 'write_field_names' が定義されていません` | outputfile プロパティ名誤り | `inc_field_names` を使う |
| CSV 出力が Shift-JIS になる / Excel で文字化け | outputfile のエンコーディング選択 | Excel で開くなら `"SystemDefault"`、UTF-8 テキスト処理なら `"UTF-8"` を指定する |
| `プロパティー 'renamed_fields' が定義されていません` | filter ノードのリネームプロパティ名誤り | `setKeyedPropertyValue("new_name", 元名, 新名)` を使う |
| `NameError: name '__file__' is not defined` | バッチモードで `__file__` を使用 | `base_dir = r"<絶対パス>"` を直接指定する（`__file__` はバッチモードで未定義）|
| `SyntaxError: encoding declaration in Unicode string` | スクリプト先頭に `# -*- coding: utf-8 -*-` を記述 | この行は Jython では書いてはいけない。削除する |
---

## CLEM 式 リファレンス

CLEM 式は `derive` の `formula_expr`、`select` の `condition`、`filler` の置換条件など複数ノードで使用する。

### 文字列演算

| 演算・関数 | 説明 | 例 |
|---|---|---|
| `ITEM1 >< ITEM2` | 文字列連結 | `"prefix" >< to_string(num)` |
| `substring(STR, start, len)` | 部分文字列（文字列型のみ） | `substring(code, 1, 3)` |
| `to_string(ITEM)` | 数値→文字列変換 | `to_string(123)` → `"123"` |

> `substring` は**文字列型フィールドにしか使えない**。日付型フィールドに適用するとエラー。

### 日付関数

`variablefile` が日付と自動認識したフィールドは Date 型になる。文字列関数は使えないため、以下の専用関数を使う。

| 関数 | 返り値 | 説明 |
|---|---|---|
| `datetime_year(DATE)` | 整数 | 年を返す（`year()` は存在しない）|
| `datetime_month(DATE)` | 整数 | 月を返す（`month()` は存在しない）|
| `datetime_day(DATE)` | 整数 | 日を返す |
| `datetime_weekday(DATE)` | 整数 | 曜日を返す |
| `date_months_difference(D1, D2)` | 実数 | D1 から D2 までの月数差 |
| `to_date(STRING)` | Date | 文字列 `"YYYY-MM-DD"` を Date 型に変換。select の condition で Date 型フィールドと日付リテラルを比較するときに使う（例: `SDATE >= to_date("2025-12-01")`）|

**YYYY-MM 文字列を生成する例**（`select` の condition や `derive` の `formula_expr` で使用）:

```python
# 月が1桁のとき "0" を前置して 2 桁に揃える
u"to_string(datetime_year(SDATE)) >< \"-\" >< "
u"(if datetime_month(SDATE) < 10 "
u"then \"0\" >< to_string(datetime_month(SDATE)) "
u"else to_string(datetime_month(SDATE)) endif)"
```

### 条件式

```
if <条件> then <真の値> else <偽の値> endif
```

> `end` ではなく **`endif`** で閉じる。

### NULL・欠損値

| 記法 | 説明 |
|---|---|
| `undef` | NULL 値リテラル（キーワード）。`undef()` と括弧を付けるとエラー |
| `@NULL(FIELD)` | フィールドが NULL なら true を返す述語 |
| `@BLANK(FIELD)` | フィールドが空白（ユーザー欠損値）なら true |

### 前レコード参照（`@OFFSET`）

ソート済みデータで n 行前の値を参照する。主に `derive` で前月比・前日比の算出に使用。

```
@OFFSET(FIELD, n)   # n 行前の FIELD の値
@INDEX              # 現在の行番号（1 始まり）
```

**前月比（%）を整数で算出する例**（グループキー＝店舗、集計フィールド＝売上_Sum）:

```python
u"if @INDEX > 1 and @OFFSET(店舗, 1) = 店舗 and @OFFSET(売上_Sum, 1) > 0 "
u"then round((売上_Sum / @OFFSET(売上_Sum, 1)) * 100) "
u"else undef endif"
```

### 数値関数

| 関数 | 説明 |
|---|---|
| `round(x)` | 最近接整数に丸める（**1引数のみ**。`round(x, n)` は無効）|
| `int(x)` | 小数点以下を切り捨て |
| `abs(x)` | 絶対値 |

---

## クイックリファレンス

### 日付フィールドの読み込み

**パターン 1（推奨）**: type ノードで `direction="Input"` + `type="Range"` に設定するだけ。variablefile 側の設定は不要。

**パターン 2（必要な場合のみ）**:

```python
stream.setPropertyValue("date_format", "YYYY-MM-DD")
vf_node.setKeyedPropertyValue("use_custom_values", u"<DATE_FIELD>", True)
vf_node.setKeyedPropertyValue("custom_storage",    u"<DATE_FIELD>", "Date")
```

### `type` ノード プロパティ値

| `type` 値 | 意味 | `direction` 値 | 意味 |
|---|---|---|---|
| `"Range"` | 連続型（数値）| `"Target"` | 目的変数 |
| `"Flag"` | フラグ（2 値）| `"Input"` | 説明変数 |
| `"Set"` | 名義型（カテゴリ）| `"None"` | 除外 |
| `"OrderedSet"` | 順序型 | `"Partition"` | データ分割 |

### `ts` ノード `input_interval` 値

| 値 | データ間隔 |
|---|---|
| `"Day"` | 日次 |
| `"Week"` | 週次 |
| `"Month"` | 月次 |
| `"Quarter"` | 四半期 |
| `"Year"` | 年次 |

### `ts` ナゲットが生成するフィールド名

| フィールド名 | 内容 |
|---|---|
| `$TS-<TARGET>` | 予測値 |
| `$TSLCI-<TARGET>` | 信頼区間 下限（95%）|
| `$TSUCI-<TARGET>` | 信頼区間 上限（95%）|
