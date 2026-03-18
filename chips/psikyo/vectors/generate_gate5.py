#!/usr/bin/env python3
"""
generate_gate5.py — Psikyo Gate 5 test vector generator.

Produces gate5_vectors.jsonl consumed by tb_gate5.cpp.

Gate 5 is purely combinational: no clocks, no setup/teardown.
Each test scenario drives the inputs directly and checks the outputs.

Supported ops:
  set_inputs   — drive all compositor inputs directly
  check_final  — check final_valid and final_color

Test scenarios:
  1.  All transparent → invalid output
  2.  BG1 only opaque → BG1 wins
  3.  BG0 only opaque → BG0 wins
  4.  BG0 + BG1 both opaque → BG0 wins (foreground priority)
  5.  Sprite prio=0 above BG1, below BG0 (BG0 present → BG0 wins)
  6.  Sprite prio=0 above BG1, BG0 transparent → sprite wins
  7.  Sprite prio=1 above BG0
  8.  Sprite prio=2 above BG0
  9.  Sprite prio=3 topmost (beats everything)
  10. Sprite color=0 → treated as transparent (BG1 wins)
  11. Sprite valid=0 → transparent (BG0 wins)
  12. BG1 color=0 → transparent even though valid=1 (BG0 wins)
  13. BG0 color=0 → transparent even though valid=1 (BG1 wins)
  14. All layers present, sprite prio=1 wins
  15. All layers present, sprite prio=2 wins
  16. All layers present, sprite prio=3 wins
  17. All layers present, sprite prio=0 → BG0 wins (BG0 present)
  18. Sprite prio=0, BG0 transparent, BG1 opaque → sprite wins over BG1
  19. Sprite prio=1 only active → wins
  20. Sprite prio=2 only active → wins
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate5_model import PsikyoColMix, SprPixel, BgPixel

OUTPUT_FILE = os.path.join(os.path.dirname(__file__), "gate5_vectors.jsonl")


def emit(f, obj: dict) -> None:
    f.write(json.dumps(obj) + "\n")


def check(f, mixer: PsikyoColMix,
          spr_valid: bool, spr_color: int, spr_prio: int,
          bg0_valid: bool, bg0_color: int,
          bg1_valid: bool, bg1_color: int,
          label: str) -> None:
    """Emit set_inputs + check_final ops for one scenario."""
    spr = SprPixel(valid=spr_valid, color=spr_color, priority=spr_prio)
    bg0 = BgPixel(valid=bg0_valid, color=bg0_color)
    bg1 = BgPixel(valid=bg1_valid, color=bg1_color)
    result = mixer.mix(spr, bg0, bg1)

    emit(f, {"op": "comment", "text": label})
    emit(f, {
        "op":          "set_inputs",
        "spr_valid":   int(spr_valid),
        "spr_color":   spr_color,
        "spr_prio":    spr_prio,
        "bg0_valid":   int(bg0_valid),
        "bg0_color":   bg0_color,
        "bg1_valid":   int(bg1_valid),
        "bg1_color":   bg1_color,
    })
    emit(f, {
        "op":        "check_final",
        "exp_valid": int(result.valid),
        "exp_color": result.color,
    })


def generate() -> None:
    mixer = PsikyoColMix()

    with open(OUTPUT_FILE, "w") as f:

        # ── Scenario 1: All transparent ──────────────────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=False, bg1_color=0x00,
              label="T1: all transparent → invalid")

        # ── Scenario 2: BG1 only ─────────────────────────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=True,  bg1_color=0x12,
              label="T2: BG1 only → BG1 wins")

        # ── Scenario 3: BG0 only ─────────────────────────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=False, bg1_color=0x00,
              label="T3: BG0 only → BG0 wins")

        # ── Scenario 4: BG0 + BG1 → BG0 wins ────────────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x12,
              label="T4: BG0+BG1 → BG0 wins (foreground)")

        # ── Scenario 5: Sprite prio=0, BG0 present → BG0 wins ────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x55, spr_prio=0,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x12,
              label="T5: spr(prio=0) below BG0 — BG0 wins")

        # ── Scenario 6: Sprite prio=0, BG0 transparent → sprite wins ─────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x55, spr_prio=0,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=True,  bg1_color=0x22,
              label="T6: spr(prio=0) beats BG1 when BG0 transparent")

        # ── Scenario 7: Sprite prio=1 above BG0 ──────────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0xFF, spr_prio=1,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x12,
              label="T7: spr(prio=1) beats BG0")

        # ── Scenario 8: Sprite prio=2 above BG0 ──────────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0xCC, spr_prio=2,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x12,
              label="T8: spr(prio=2) beats BG0")

        # ── Scenario 9: Sprite prio=3 topmost ────────────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0xEE, spr_prio=3,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x12,
              label="T9: spr(prio=3) topmost")

        # ── Scenario 10: Sprite color=0 → transparent ────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x00, spr_prio=3,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=True,  bg1_color=0x22,
              label="T10: spr(color=0) transparent → BG1 wins")

        # ── Scenario 11: Sprite valid=0 → transparent ────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0xAA, spr_prio=3,
              bg0_valid=True,  bg0_color=0xBB,
              bg1_valid=False, bg1_color=0x00,
              label="T11: spr(valid=0) transparent → BG0 wins")

        # ── Scenario 12: BG1 color=0 → transparent ───────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=True,  bg0_color=0xAB,
              bg1_valid=True,  bg1_color=0x00,
              label="T12: BG1(color=0) transparent → BG0 wins")

        # ── Scenario 13: BG0 color=0 → transparent ───────────────────────────
        check(f, mixer,
              spr_valid=False, spr_color=0x00, spr_prio=0,
              bg0_valid=True,  bg0_color=0x00,
              bg1_valid=True,  bg1_color=0x33,
              label="T13: BG0(color=0) transparent → BG1 wins")

        # ── Scenario 14: All layers, spr prio=1 wins ─────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x77, spr_prio=1,
              bg0_valid=True,  bg0_color=0x33,
              bg1_valid=True,  bg1_color=0x44,
              label="T14: all layers, spr(prio=1) wins")

        # ── Scenario 15: All layers, spr prio=2 wins ─────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x88, spr_prio=2,
              bg0_valid=True,  bg0_color=0x33,
              bg1_valid=True,  bg1_color=0x44,
              label="T15: all layers, spr(prio=2) wins")

        # ── Scenario 16: All layers, spr prio=3 wins ─────────────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x99, spr_prio=3,
              bg0_valid=True,  bg0_color=0x33,
              bg1_valid=True,  bg1_color=0x44,
              label="T16: all layers, spr(prio=3) wins")

        # ── Scenario 17: All layers, spr prio=0 → BG0 wins ──────────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x55, spr_prio=0,
              bg0_valid=True,  bg0_color=0x33,
              bg1_valid=True,  bg1_color=0x44,
              label="T17: all layers, spr(prio=0) → BG0 wins")

        # ── Scenario 18: Spr prio=0, BG0 transparent, BG1 opaque → spr wins ─
        check(f, mixer,
              spr_valid=True,  spr_color=0x55, spr_prio=0,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=True,  bg1_color=0x22,
              label="T18: spr(prio=0) beats BG1, BG0 absent")

        # ── Scenario 19: Sprite prio=1 only, no BG → spr wins ───────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x66, spr_prio=1,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=False, bg1_color=0x00,
              label="T19: spr(prio=1) only → wins")

        # ── Scenario 20: Sprite prio=2 only, no BG → spr wins ───────────────
        check(f, mixer,
              spr_valid=True,  spr_color=0x77, spr_prio=2,
              bg0_valid=False, bg0_color=0x00,
              bg1_valid=False, bg1_color=0x00,
              label="T20: spr(prio=2) only → wins")

    # Count check ops
    with open(OUTPUT_FILE) as fin:
        lines = [json.loads(l) for l in fin if l.strip() and not l.startswith('#')]
    checks_count = sum(1 for l in lines if l.get("op") == "check_final")
    ops = len(lines)
    print(f"Generated {OUTPUT_FILE}")
    print(f"Total ops: {ops}, check_final ops: {checks_count}")


if __name__ == '__main__':
    generate()
