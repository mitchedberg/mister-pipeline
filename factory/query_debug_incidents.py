#!/usr/bin/env python3
"""Query .shared/debug_incidents.jsonl with simple core/tag/status filters."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / ".shared" / "debug_incidents.jsonl"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Query structured debug incidents")
    p.add_argument("--db", type=pathlib.Path, default=DEFAULT_DB)
    p.add_argument("--core")
    p.add_argument("--chip")
    p.add_argument("--stage")
    p.add_argument("--status")
    p.add_argument("--tag", action="append", default=[])
    p.add_argument("--limit", type=int, default=20)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if not args.db.exists():
        print(f"no incident database at {args.db}", file=sys.stderr)
        return 1

    rows = []
    with args.db.open("r", encoding="utf-8") as fp:
        for line in fp:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            rows.append(row)

    def keep(row: dict) -> bool:
        if args.core and row.get("core") != args.core:
            return False
        if args.chip and row.get("chip") != args.chip:
            return False
        if args.stage and row.get("stage") != args.stage:
            return False
        if args.status and row.get("status") != args.status:
            return False
        if args.tag and not all(tag in row.get("tags", []) for tag in args.tag):
            return False
        return True

    rows = [row for row in rows if keep(row)]
    rows = rows[-args.limit :]
    for row in rows:
        print(f"[{row.get('ts')}] {row.get('core')} / {row.get('chip') or '-'} / {row.get('stage')} / {row.get('status')}")
        print(f"  {row.get('summary')}")
        if row.get("assumptions"):
            print(f"  assumptions: { ' | '.join(row['assumptions']) }")
        if row.get("attempts"):
            print(f"  attempts:    { ' | '.join(row['attempts']) }")
        if row.get("evidence"):
            print(f"  evidence:    { ' | '.join(row['evidence'][:3]) }")
        if row.get("next_step"):
            print(f"  next:        {row['next_step']}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
