#!/usr/bin/env python3
"""
Generate a calendar months CSV with fields helpful for rolling-window analytics:
  - Month_Year (YYYY-MM)
  - YYYY (int)
  - MM (int)
  - YYYYMM (int)
  - Start6_YYYYMM (int): current month minus 5 months (year-boundary safe)

Usage:
  python tools/transform/generate_calendar_months.py [start=2018-01] [end=2030-12]
Writes to data/calendar_months.csv in the repo.
"""

import csv
import sys
from datetime import date
from pathlib import Path


def parse_ym(s: str) -> date:
    y, m = s.split("-")
    return date(int(y), int(m), 1)


def add_months(d: date, delta_months: int) -> date:
    y = d.year + (d.month - 1 + delta_months) // 12
    m = (d.month - 1 + delta_months) % 12 + 1
    return date(y, m, 1)


def yyyymm(d: date) -> int:
    return d.year * 100 + d.month


def main():
    start = parse_ym(sys.argv[1]) if len(sys.argv) > 1 else date(2018, 1, 1)
    end = parse_ym(sys.argv[2]) if len(sys.argv) > 2 else date(2030, 12, 1)

    out_path = Path("data/calendar_months.csv")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    months = []
    d = start
    while d <= end:
        months.append(d)
        d = add_months(d, 1)

    with out_path.open("w", newline='', encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Month_Year", "YYYY", "MM", "YYYYMM", "Start6_YYYYMM"])  # minus 5 months
        for d in months:
            start6 = add_months(d, -5)
            w.writerow([
                f"{d.year:04d}-{d.month:02d}",
                d.year,
                d.month,
                yyyymm(d),
                yyyymm(start6),
            ])

    print(f"Wrote {out_path} ({len(months)} rows)")


if __name__ == "__main__":
    main()
