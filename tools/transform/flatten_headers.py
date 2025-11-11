#!/usr/bin/env python3
"""
Flatten CSV headers by removing known prefixes like "f." and "a6.".

Usage:
  python tools/transform/flatten_headers.py <input_csv> <output_csv>

Notes:
  - Preserves row order and values.
  - Only modifies the header row: strips leading prefixes "f." and "a6.".
  - Safe to run multiple times; re-running will keep headers unchanged.
"""

import csv
import sys
from pathlib import Path


def flatten_header(field: str) -> str:
    # Remove BOM and leading/trailing spaces
    if field:
        field = field.lstrip("\ufeff").strip()
    prefixes = ("f.", "a6.")
    for p in prefixes:
        if field.startswith(p):
            return field[len(p):]
    return field


def main():
    if len(sys.argv) != 3:
        print("Usage: python tools/transform/flatten_headers.py <input_csv> <output_csv>")
        sys.exit(1)

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    if not in_path.exists():
        print(f"Input file not found: {in_path}")
        sys.exit(1)

    # Ensure parent directory exists for output
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with in_path.open("r", newline='', encoding="utf-8") as fin, out_path.open("w", newline='', encoding="utf-8") as fout:
        reader = csv.reader(fin)
        writer = csv.writer(fout)

        try:
            header = next(reader)
        except StopIteration:
            # Empty file; write nothing
            return

        flat_header = [flatten_header(h) for h in header]
        writer.writerow(flat_header)

        for row in reader:
            writer.writerow(row)

    print(f"Wrote flattened CSV to {out_path}")


if __name__ == "__main__":
    main()
