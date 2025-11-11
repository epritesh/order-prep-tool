#!/usr/bin/env python3
"""
Merge qt_sales_24m_clean into qt_item_snapshot_sales_enriched_v5_final_flat by (Product_ID, Month_Year).
- Prefer cleaned Total_Quantity/Net_Sales when present.
- Carry Item_ID from clean sales into output when available.
- Preserve all existing snapshot columns.

Usage:
  python tools/transform/merge_clean_sales_into_snapshot.py \
    --snapshot data/qt_item_snapshot_sales_enriched_v5_final_flat.csv \
    --sales data/qt_sales_24m_clean.csv \
    --out data/qt_item_snapshot_sales_enriched_v6_merged.csv
"""
from __future__ import annotations
import argparse
import os
import sys
from typing import Tuple

import pandas as pd

# --- Helpers ---------------------------------------------------------------

def read_csv_smart(path: str) -> pd.DataFrame:
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}", file=sys.stderr)
        sys.exit(1)
    # Force IDs as strings to avoid scientific notation or truncation
    dtype = {
        "Product_ID": "string",
        "Product ID": "string",
        "Item_ID": "string",
        "Item ID": "string",
        "SKU": "string",
        "Item_SKU": "string",
    }
    df = pd.read_csv(path, dtype=dtype, keep_default_na=True, na_values=["", "NA", "N/A"], low_memory=False)
    return df


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    # Strip and unify column names
    df = df.rename(columns={c: c.strip() for c in df.columns})
    rename_map = {
        # IDs
        "Product ID": "Product_ID",
        "Item ID": "Item_ID",
        # Dates
        "Month Year": "Month_Year",
        "Month-Year": "Month_Year",
        # Metrics
        "Total Quantity": "Total_Quantity",
        "Net Sales": "Net_Sales",
        # SKU variants
        "Item_SKU": "SKU",
        "Item SKU": "SKU",
    }
    df = df.rename(columns=rename_map)
    return df


def ensure_month_year_str(df: pd.DataFrame) -> pd.DataFrame:
    if "Month_Year" not in df.columns:
        return df
    # Try to coerce into YYYY-MM
    # Handles strings like YYYY-MM or datetimes
    def to_yyyymm(s):
        if pd.isna(s):
            return pd.NA
        # Fast path: already looks like YYYY-MM
        s_str = str(s).strip()
        if len(s_str) == 7 and s_str[4] == "-":
            return s_str
        try:
            dt = pd.to_datetime(s_str, errors="coerce")
            if pd.isna(dt):
                return pd.NA
            return f"{dt.year:04d}-{dt.month:02d}"
        except Exception:
            return pd.NA

    df["Month_Year"] = df["Month_Year"].map(to_yyyymm).astype("string")
    return df


def clean_ids(df: pd.DataFrame) -> pd.DataFrame:
    for col in ["Product_ID", "Item_ID", "SKU"]:
        if col in df.columns:
            df[col] = df[col].astype("string").str.strip()
    return df


def aggregate_sales_monthly(sales: pd.DataFrame) -> pd.DataFrame:
    """Collapse potentially multiple line-level rows per (Product_ID, Month_Year)
    into a single monthly record, summing quantities & Net_Sales; picking a representative Item_ID (MAX)."""
    agg_cols = {}
    if "Total_Quantity" in sales.columns:
        agg_cols["Total_Quantity"] = "sum"
    if "Net_Sales" in sales.columns:
        agg_cols["Net_Sales"] = "sum"
    if "Item_ID" in sales.columns:
        agg_cols["Item_ID"] = "max"
    if not agg_cols:
        raise ValueError("Sales data missing required metric columns to aggregate.")
    grouped = sales.groupby(["Product_ID", "Month_Year"], dropna=False).agg(agg_cols).reset_index()
    return grouped


def merge_sales(snapshot: pd.DataFrame, sales: pd.DataFrame) -> Tuple[pd.DataFrame, dict]:
    # Normalize & unify columns
    snapshot = normalize_columns(snapshot)
    sales = normalize_columns(sales)

    snapshot = ensure_month_year_str(snapshot)
    sales = ensure_month_year_str(sales)

    snapshot = clean_ids(snapshot)
    sales = clean_ids(sales)

    # Guard required columns
    for col in ["Product_ID", "Month_Year"]:
        if col not in snapshot.columns:
            raise KeyError(f"Snapshot missing required column: {col}")
        if col not in sales.columns:
            raise KeyError(f"Sales missing required column: {col}")

    # Aggregate sales to monthly single-row per key to avoid multiplication
    sales_monthly = aggregate_sales_monthly(sales)

    cols_from_sales = [c for c in ["Total_Quantity", "Net_Sales", "Item_ID"] if c in sales_monthly.columns]
    sales_sub = sales_monthly[["Product_ID", "Month_Year"] + cols_from_sales].copy()

    merged = snapshot.merge(
        sales_sub,
        on=["Product_ID", "Month_Year"],
        how="left",
        suffixes=("", "_clean"),
    )

    stats = {"row_count_pre": len(snapshot), "row_count_post": len(merged), "sales_monthly_rows": len(sales_monthly)}

    overrides = 0
    for col in ["Total_Quantity", "Net_Sales"]:
        clean_col = f"{col}_clean" if f"{col}_clean" in merged.columns else None
        if clean_col:
            before_na = merged[col].isna().sum() if col in merged.columns else "n/a"
            if col not in merged.columns:
                merged[col] = pd.NA
            mask = merged[clean_col].notna()
            overrides += int(mask.sum())
            merged.loc[mask, col] = merged.loc[mask, clean_col]
            merged.drop(columns=[clean_col], inplace=True)
            stats[f"{col}_overrides"] = int(mask.sum())
            stats[f"{col}_base_na_before"] = before_na

    if "Item_ID_clean" in merged.columns:
        if "Item_ID" not in merged.columns:
            merged["Item_ID"] = pd.NA
        mask = merged["Item_ID"].isna() & merged["Item_ID_clean"].notna()
        merged.loc[mask, "Item_ID"] = merged.loc[mask, "Item_ID_clean"]
        merged.drop(columns=["Item_ID_clean"], inplace=True)
        stats["Item_ID_filled_from_clean"] = int(mask.sum())

    stats["total_metric_overrides"] = overrides
    stats["duplication_detected"] = stats["row_count_post"] != stats["row_count_pre"]
    return merged, stats


# --- CLI ------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(description="Merge clean 24m sales into snapshot")
    p.add_argument("--snapshot", default=os.path.join("data", "qt_item_snapshot_sales_enriched_v5_final_flat.csv"))
    p.add_argument("--sales", default=os.path.join("data", "qt_sales_24m_clean.csv"))
    p.add_argument("--out", default=os.path.join("data", "qt_item_snapshot_sales_enriched_v6_merged.csv"))
    args = p.parse_args(argv)

    snap_df = read_csv_smart(args.snapshot)
    sales_df = read_csv_smart(args.sales)

    merged_df, stats = merge_sales(snap_df, sales_df)

    # Write output
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    merged_df.to_csv(args.out, index=False)

    # Print summary
    print("Merge complete:")
    print(f"  rows: {stats.get('row_count')}")
    for k in [
        "Total_Quantity_overrides",
        "Net_Sales_overrides",
        "Item_ID_filled_from_clean",
        "total_overrides",
    ]:
        if k in stats:
            print(f"  {k}: {stats[k]}")
    print(f"Output written to: {args.out}")


if __name__ == "__main__":
    main()
