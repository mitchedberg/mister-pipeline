#!/usr/bin/env python3
"""Append a structured debug incident entry to .shared/debug_incidents.jsonl."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import socket
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / ".shared" / "debug_incidents.jsonl"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Append a structured debug incident entry")
    p.add_argument("--db", type=pathlib.Path, default=DEFAULT_DB)
    p.add_argument("--agent", default=os.environ.get("CODEX_AGENT", "codex"))
    p.add_argument("--core", required=True)
    p.add_argument("--chip")
    p.add_argument("--stage", required=True, choices=["sim", "standalone_synth", "quartus", "hardware", "docs", "infra"])
    p.add_argument("--status", required=True, choices=["open", "partial", "resolved", "dead_end"])
    p.add_argument("--summary", required=True)
    p.add_argument("--assumption", action="append", default=[])
    p.add_argument("--attempt", action="append", default=[])
    p.add_argument("--evidence", action="append", default=[])
    p.add_argument("--next-step", default="")
    p.add_argument("--commit", action="append", default=[])
    p.add_argument("--run", action="append", default=[])
    p.add_argument("--tag", action="append", default=[])
    return p.parse_args()


def main() -> int:
    args = parse_args()
    entry = {
        "id": str(uuid.uuid4()),
        "ts": dt.datetime.now(dt.timezone.utc).isoformat(),
        "agent": args.agent,
        "host": socket.gethostname(),
        "core": args.core,
        "chip": args.chip,
        "stage": args.stage,
        "status": args.status,
        "summary": args.summary,
        "assumptions": args.assumption,
        "attempts": args.attempt,
        "evidence": args.evidence,
        "next_step": args.next_step,
        "commits": args.commit,
        "runs": args.run,
        "tags": args.tag,
    }
    args.db.parent.mkdir(parents=True, exist_ok=True)
    with args.db.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(entry, sort_keys=True) + "\n")
    print(f"logged incident {entry['id']} -> {args.db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
