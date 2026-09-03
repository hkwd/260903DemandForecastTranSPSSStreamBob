"""
analyze_spv.py  —  SPV 解析スキル用ヘルパースクリプト
Usage:
    python analyze_spv.py \
        --extract-dir  <展開済みディレクトリ> \
        --model-bins   <モデル情報.bin,...> \
        --param-bins   <パラメーター.bin,...> \
        --labels       <系列名,...>
Output:
    JSON を標準出力に出力する
"""
import argparse
import io
import json
import os
import sys

# Windows 環境で stdout が cp932 になる場合に UTF-8 で出力する
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

# --- ARG PARSE -----------------------------------------------------------
parser = argparse.ArgumentParser()
parser.add_argument("--extract-dir", required=True)
parser.add_argument("--model-bins",  required=True)
parser.add_argument("--param-bins",  required=True)
parser.add_argument("--labels",      required=True)
args = parser.parse_args()

base      = args.extract_dir
m_bins    = [b.strip() for b in args.model_bins.split(",")]
p_bins    = [b.strip() for b in args.param_bins.split(",")]
labels    = [l.strip() for l in args.labels.split(",")]

if len(m_bins) != len(p_bins) or len(m_bins) != len(labels):
    print("ERROR: --model-bins, --param-bins, --labels の個数が一致しません", file=sys.stderr)
    sys.exit(1)


# --- HELPERS -------------------------------------------------------------
def load_json(filename):
    path = os.path.join(base, filename)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_values(data):
    return data["cells"][0]["cells"]["compactCells"]["value"]


def get_dims(data):
    dims = data["dimensions"]
    n_cols = dims[0]["numberOfCategories"]
    n_rows = dims[1]["numberOfCategories"]
    return n_rows, n_cols


def column_major_table(vals, n_rows, n_cols):
    """列優先配列を {row: [col0, col1, ...]} に変換する"""
    rows = []
    for r in range(n_rows):
        rows.append([vals[c * n_rows + r] for c in range(n_cols)])
    return rows


def walk_labels(node, path=None):
    """dimensions の children を再帰展開してリーフラベルを返す"""
    if path is None:
        path = []
    txt = node.get("text", {}).get("text", {}).get("stringText", {})
    lbl = txt.get("value") or txt.get("key", "?")
    children = node.get("children", [])
    if not children:
        return ["/".join(path + [lbl])]
    result = []
    for c in children:
        result.extend(walk_labels(c, path + [lbl]))
    return result


# Model information field order (by index in compactCells for model-info table)
# index 0 = string (ARIMA label), 1 = string (order label), 2 = int (n_predictors),
# then float metrics in this order:
MODEL_METRIC_KEYS = ["MSE", "RMSE", "RMSPE", "MAE", "MAPE",
                     "MAXAE", "MAXAPE", "AIC", "BIC", "R2", "StatR2",
                     "LjungBox_Q", "LjungBox_df", "LjungBox_p"]
PARAM_COL_KEYS = ["係数", "標準誤差", "t値", "有意確率"]


# --- PARSE MODEL INFO ----------------------------------------------------
def parse_model_info(filename):
    data = load_json(filename)
    vals = get_values(data)
    cell_labels = data.get("cellLabels", {}).get("values", [])
    method  = cell_labels[0] if len(cell_labels) > 0 else "?"
    order   = cell_labels[1] if len(cell_labels) > 1 else "?"
    n_pred  = int(vals[2]) if len(vals) > 2 else None
    metrics = {}
    for i, key in enumerate(MODEL_METRIC_KEYS):
        idx = 3 + i
        metrics[key] = vals[idx] if idx < len(vals) else None
    return {
        "method": method,
        "order": order,
        "n_predictors": n_pred,
        "metrics": metrics,
    }


# --- PARSE PARAMETERS ----------------------------------------------------
def parse_params(filename):
    data = load_json(filename)
    vals   = get_values(data)
    n_rows, n_cols = get_dims(data)
    table  = column_major_table(vals, n_rows, n_cols)
    # 行ラベルを取得
    row_labels = []
    for child in data["dimensions"][1].get("children", []):
        row_labels.extend(walk_labels(child))
    rows = []
    for i, row in enumerate(table):
        entry = {"label": row_labels[i] if i < len(row_labels) else f"row{i}"}
        for j, col_key in enumerate(PARAM_COL_KEYS[:n_cols]):
            entry[col_key] = row[j] if j < len(row) else None
        rows.append(entry)
    return rows


# --- MAIN ----------------------------------------------------------------
result = {}
for label, m_bin, p_bin in zip(labels, m_bins, p_bins):
    result[label] = {
        "model_info": parse_model_info(m_bin),
        "params":     parse_params(p_bin),
    }

print(json.dumps(result, ensure_ascii=False, indent=2))
