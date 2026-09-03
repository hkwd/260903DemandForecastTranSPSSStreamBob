import modeler.api
import os

stream     = modeler.script.stream()
taskrunner = modeler.script.session().getTaskRunner()

base_dir     = r"c:\sample\s3"
pos_csv      = os.path.join(base_dir, "01pos.csv")
cal_csv      = os.path.join(base_dir, "02calendar.csv")
output_path  = os.path.join(base_dir, "store_forecast.str")

# --------------------------------------------------
# 1. POS データ読み込み
# --------------------------------------------------
vf_pos = stream.createAt("variablefile", u"POS読み込み", 50, 100)
vf_pos.setPropertyValue("full_filename", pos_csv)
vf_pos.setPropertyValue("encoding", "UTF-8")

# --------------------------------------------------
# 2. 日付・店舗 単位で数量を集計
# --------------------------------------------------
agg_node = stream.createAt("aggregate", u"日次集計", 200, 100)
stream.link(vf_pos, agg_node)
agg_node.setPropertyValue("inc_record_count", False)
agg_node.setPropertyValue("keys", [u"SDATE", u"店舗"])
agg_node.setKeyedPropertyValue("aggregates", u"数量", [u"Sum"])

# 数量_Sum → 売上数量 にリネーム
rename_node = stream.createAt("filter", u"フィールドリネーム", 350, 100)
stream.link(agg_node, rename_node)
rename_node.setKeyedPropertyValue("new_name", u"数量_Sum", u"売上数量")

# --------------------------------------------------
# 3. カレンダーマスタ読み込み
# --------------------------------------------------
vf_cal = stream.createAt("variablefile", u"カレンダー読み込み", 50, 250)
vf_cal.setPropertyValue("full_filename", cal_csv)
vf_cal.setPropertyValue("encoding", "UTF-8")

# --------------------------------------------------
# 4. 販売実績 × カレンダー を SDATE キーで結合
# --------------------------------------------------
merge_node = stream.createAt("merge", u"カレンダー結合", 500, 170)
stream.link(rename_node, merge_node)
stream.link(vf_cal, merge_node)
merge_node.setPropertyValue("method",      u"Keys")
merge_node.setPropertyValue("key_fields",  [u"SDATE"])
merge_node.setPropertyValue("common_keys", True)

# --------------------------------------------------
# 5. フィールド型・ロール定義
# --------------------------------------------------
type_node = stream.createAt("type", u"フィールド型定義", 650, 170)
stream.link(merge_node, type_node)

# 型定義を確定するため一時テーブルを実行
tmp = stream.createAt("table", u"_tmp", 800, 270)
stream.link(type_node, tmp)
tmp.run([])
stream.delete(tmp)

# 目的変数: 売上数量
type_node.setKeyedPropertyValue(u"direction", u"売上数量",    u"Target")
type_node.setKeyedPropertyValue(u"type",      u"売上数量",    u"Range")

# 分割（店舗別モデル）
type_node.setKeyedPropertyValue(u"direction", u"店舗",        u"Split")
type_node.setKeyedPropertyValue(u"type",      u"店舗",        u"Set")

# 日付フィールド
type_node.setKeyedPropertyValue(u"direction", u"SDATE",       u"Input")
type_node.setKeyedPropertyValue(u"type",      u"SDATE",       u"Range")

# フラグ（events として使う）
for flag in [u"祝日フラグ", u"販促フラグ", u"長期休暇フラグ", u"イベントフラグ"]:
    type_node.setKeyedPropertyValue(u"direction", flag, u"Input")
    type_node.setKeyedPropertyValue(u"type",      flag, u"Flag")

# CUSTID・商品・単価・小計 は除外
for excl in [u"CUSTID", u"商品", u"単価", u"小計"]:
    type_node.setKeyedPropertyValue(u"direction", excl, u"None")

# --------------------------------------------------
# 6. 時系列予測モデル（Expert Modeler + 店舗ごと分割）
# --------------------------------------------------
ts_node = stream.createAt("ts", u"時系列予測", 800, 170)
stream.link(type_node, ts_node)

ts_node.setPropertyValue("custom_fields",        True)
ts_node.setPropertyValue("splitFields",          [u"店舗"])
ts_node.setPropertyValue("date_time_field",      u"SDATE")
ts_node.setPropertyValue("input_interval",       u"Day")
ts_node.setPropertyValue("targets",              [u"売上数量"])
ts_node.setPropertyValue("includeTargets",       [u"売上数量"])
ts_node.setPropertyValue("targetField",          [u"売上数量"])
ts_node.setPropertyValue("candidateTargets",     [u"売上数量"])
ts_node.setPropertyValue("inputAndTargetFields", [u"売上数量"])
# フラグは events に指定（candidate_inputs と重複させない）
ts_node.setPropertyValue("events", [u"祝日フラグ", u"販促フラグ", u"長期休暇フラグ", u"イベントフラグ"])
ts_node.setPropertyValue("method",                  "ExpertModeler")
ts_node.setPropertyValue("consider_seasonal",       True)
ts_node.setPropertyValue("forecastperiods",         3)
ts_node.setPropertyValue("extend_records_into_future", True)
ts_node.setPropertyValue("isOutputIntervalControlEnabled", True)
ts_node.setPropertyValue("futureValue_type_method", u"specify")
ts_node.setPropertyValue("cal_PI",   True)
ts_node.setPropertyValue("use_weight", True)

print(u"時系列モデルを構築中（Expert Modeler + 店舗別分割）...")
ts_node.run([])
print(u"モデル構築完了")

nugget = stream.findByType("applyts", None)

# --------------------------------------------------
# 7. 2025-12-01 以降を抽出
# --------------------------------------------------
sel_node = stream.createAt("select", u"2025年12月以降", 950, 170)
stream.link(nugget, sel_node)
sel_node.setPropertyValue("mode",      "Include")
sel_node.setPropertyValue("condition", u"SDATE >= \"2025-12-01\"")

# --------------------------------------------------
# 8. 店舗別パネル折れ線グラフ（実績値 + 予測値）
# --------------------------------------------------
mp_node = stream.createAt("multiplot", u"店舗別需要予測グラフ", 1100, 170)
stream.link(sel_node, mp_node)
mp_node.setPropertyValue("panel_field", u"店舗")
mp_node.setPropertyValue("x_field",    u"SDATE")
mp_node.setPropertyValue("y_fields",   [u"売上数量", u"$TS-売上数量"])

mp_node.run([])
print(u"グラフ出力完了")

# --------------------------------------------------
# 9. ストリーム保存
# --------------------------------------------------
taskrunner.saveStreamToFile(stream, output_path)
print(u"保存完了: " + output_path)
