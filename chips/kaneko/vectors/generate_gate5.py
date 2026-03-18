#!/usr/bin/env python3
"""
generate_gate5.py — Kaneko16 Gate 5 test vector generator.

Gate 5 is purely combinational.  The testbench drives the DUT combinational
inputs (spr_rd_color, spr_rd_valid, spr_rd_priority, bg_pix_color[*],
bg_pix_valid, layer_ctrl) directly and reads back final_color / final_valid.

Vector operations (processed by tb_gate5.cpp):
  reset                      — DUT reset
  set_spr   color,valid,prio — drive sprite pixel inputs
  set_bg    layer,color,valid— drive one BG layer pixel (repeatable for all layers)
  set_layer_ctrl  data       — drive layer_ctrl input
  check_final  exp_valid, exp_color — verify final_valid and final_color

Scenarios:
  1.  All transparent → final_valid=0
  2.  BG0 only, 2-layer mode → BG0 wins
  3.  BG1 over BG0 → BG1 wins
  4.  Sprite prio=0, 2-layer mode: above BG1 (BG2 ignored) → sprite wins
  5.  BG2 beats sprite prio=0, 3-layer mode → BG2 wins
  6.  BG3 beats sprite prio=4, 4-layer mode → BG3 wins
  7.  Sprite prio=4 wins when BG3 transparent, 4-layer mode → sprite wins
  8.  Sprite prio=8 above all BG, 4-layer mode → sprite wins
  9.  Sprite prio=15 (max) above all BG → sprite wins
  10. 2-layer mode: BG2/BG3 ignored even if valid → BG1 wins
  11. 3-layer mode: BG3 ignored → BG2 wins
  12. Transparent sprite falls through to BG → BG wins
  13. Sprite prio=3 (group 0) below BG2 in 3-layer mode → BG2 wins
  14. Sprite prio=7 (group 1) below BG3 in 4-layer mode → BG3 wins
  15. Full 3-layer stack (BG0+BG1+BG2+sprite prio=0) → BG2 wins
  16. layer_ctrl 2'b10 (4-layer mode) — BG3 active
  17. layer_ctrl 2'b11 (4-layer mode alias) — BG3 active
  18. Sprite prio=0 below BG1 when BG2 transparent in 3-layer mode → sprite wins
  19. Sprite prio=12 (group 3) above all BG → sprite wins
  20. Only BG3 visible in 4-layer mode → BG3 shows

Target: 40+ checks.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate5_model import Kaneko16ColMix, SprPixel, BgPixel

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate5_vectors.jsonl')


# ─────────────────────────────────────────────────────────────────────────────
# Generator
# ─────────────────────────────────────────────────────────────────────────────

def generate():
    recs = []
    check_count = 0
    mixer = Kaneko16ColMix()

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ── Op helpers ────────────────────────────────────────────────────────────

    def reset():
        add({"op": "reset"})

    def set_spr(color: int, valid: int, prio: int):
        add({"op": "set_spr", "color": color, "valid": valid, "prio": prio})

    def set_bg(layer: int, color: int, valid: int):
        add({"op": "set_bg", "layer": layer, "color": color, "valid": valid})

    def set_layer_ctrl(data: int):
        add({"op": "set_layer_ctrl", "data": data})

    def check_final(exp_valid: int, exp_color: int):
        chk({"op": "check_final", "exp_valid": exp_valid, "exp_color": exp_color})

    # ── Model-driven query helper ─────────────────────────────────────────────

    def run_scenario(label: str,
                     spr: SprPixel,
                     bg_pixels,
                     layer_ctrl: int):
        """Set DUT inputs from model parameters, verify against model output."""
        set_layer_ctrl(layer_ctrl)
        set_spr(spr.color, int(spr.valid), spr.priority)
        for i, bp in enumerate(bg_pixels):
            set_bg(i, bp.color, int(bp.valid))
        result = mixer.mix(spr, bg_pixels, layer_ctrl)
        check_final(int(result.valid), result.color)

    def make_bg(colors=None, valids=None):
        """Create 4 BG pixels; defaults to all transparent."""
        bg = [BgPixel() for _ in range(4)]
        if colors:
            for i, c in enumerate(colors):
                bg[i].color = c
        if valids:
            for i, v in enumerate(valids):
                bg[i].valid = bool(v)
        return bg

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: All transparent → final_valid=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    run_scenario("all_transparent",
                 SprPixel(valid=False, color=0, priority=0),
                 make_bg(),
                 layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: BG0 only, 2-layer mode → BG0 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0, 0, 0], valids=[1, 0, 0, 0])
    run_scenario("bg0_only", SprPixel(), bg, layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: BG1 over BG0 → BG1 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0, 0], valids=[1, 1, 0, 0])
    run_scenario("bg1_over_bg0", SprPixel(), bg, layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: Sprite prio=0, 2-layer mode: BG2 ignored → sprite wins over BG1
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0], valids=[1, 1, 1, 0])
    spr = SprPixel(valid=True, color=0xAA, priority=0)
    run_scenario("spr_prio0_2layer", spr, bg, layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: BG2 beats sprite prio=0, 3-layer mode → BG2 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0], valids=[1, 1, 1, 0])
    spr = SprPixel(valid=True, color=0xAA, priority=0)
    run_scenario("bg2_beats_spr0_3layer", spr, bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: BG3 beats sprite prio=4, 4-layer mode → BG3 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xBB, priority=4)
    run_scenario("bg3_beats_spr4_4layer", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Sprite prio=4 wins when BG3 transparent, 4-layer mode
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 0])
    spr = SprPixel(valid=True, color=0xBB, priority=4)
    run_scenario("spr4_beats_transparent_bg3", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: Sprite prio=8 above all BG, 4-layer mode
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xCC, priority=8)
    run_scenario("spr8_above_all_4layer", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: Sprite prio=15 above all BG
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xDD, priority=15)
    run_scenario("spr15_above_all", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: 2-layer mode: BG2/BG3 ignored even if valid
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[0, 1, 1, 1])
    run_scenario("2layer_bg23_ignored", SprPixel(), bg, layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 11: 3-layer mode: BG3 ignored → BG2 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[0, 0, 1, 1])
    run_scenario("3layer_bg3_ignored", SprPixel(), bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 12: Transparent sprite falls through to BG1
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0, 0x55, 0, 0], valids=[0, 1, 0, 0])
    spr = SprPixel(valid=False, color=0xFF, priority=15)
    run_scenario("transparent_spr_fallthrough", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 13: Sprite prio=3 (group 0) below BG2 in 3-layer mode → BG2 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0, 0x33, 0], valids=[1, 0, 1, 0])
    spr = SprPixel(valid=True, color=0xEE, priority=3)
    run_scenario("spr3_below_bg2_3layer", spr, bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 14: Sprite prio=7 (group 1) below BG3 in 4-layer mode → BG3 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0, 0, 0, 0x77], valids=[0, 0, 0, 1])
    spr = SprPixel(valid=True, color=0xFF, priority=7)
    run_scenario("spr7_below_bg3_4layer", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 15: Full 3-layer stack (BG0+BG1+BG2+sprite prio=0) → BG2 wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0], valids=[1, 1, 1, 0])
    spr = SprPixel(valid=True, color=0xAA, priority=0)
    run_scenario("full_3layer_stack", spr, bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 16: layer_ctrl 2'b10 (4-layer mode) — BG3 active
    # Same as scenario 6 but with explicit layer_ctrl=0x80 check
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0, 0, 0, 0x99], valids=[0, 0, 0, 1])
    run_scenario("lc_10_bg3_active", SprPixel(), bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 17: layer_ctrl 2'b11 (4-layer mode alias) — BG3 also active
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0, 0, 0, 0x99], valids=[0, 0, 0, 1])
    run_scenario("lc_11_bg3_active", SprPixel(), bg, layer_ctrl=0xC0)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 18: Sprite prio=0 above BG1, BG2 transparent in 3-layer mode
    # Stack: BG0, BG1, spr(0), BG2(transparent) → sprite wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0, 0], valids=[1, 1, 0, 0])
    spr = SprPixel(valid=True, color=0xEE, priority=0)
    run_scenario("spr0_above_bg1_bg2_transparent", spr, bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 19: Sprite prio=12 (group 3) above all BG → sprite wins
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xAB, priority=12)
    run_scenario("spr12_group3_above_all", spr, bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 20: Only BG3 visible in 4-layer mode → BG3 shows
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0, 0, 0, 0xFE], valids=[0, 0, 0, 1])
    run_scenario("only_bg3_4layer", SprPixel(), bg, layer_ctrl=0x80)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 21: Sprite prio=1 in 2-layer mode — above BG1, BG2/BG3 invisible
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xCD, priority=1)
    run_scenario("spr1_2layer_above_bg1", spr, bg, layer_ctrl=0x00)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 22: Sprite prio=5 in 3-layer mode: above BG2? No — group=1, above BG2
    # 3-layer stack: BG0, BG1, spr(0), BG2, spr(4-7).
    # With prio=5 (group=1): sprite inserted after BG2 slot → sprite wins.
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0], valids=[1, 1, 1, 0])
    spr = SprPixel(valid=True, color=0xDE, priority=5)
    run_scenario("spr5_above_bg2_3layer", spr, bg, layer_ctrl=0x40)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 23: Multiple sprites at same priority group 2 — single sprite test
    # Sprite prio=10 (group 2) above BG3 in 4-layer mode
    # ══════════════════════════════════════════════════════════════════════════
    bg = make_bg(colors=[0x11, 0x22, 0x33, 0x44], valids=[1, 1, 1, 1])
    spr = SprPixel(valid=True, color=0xBC, priority=10)
    run_scenario("spr10_group2_above_bg3", spr, bg, layer_ctrl=0x80)

    # ── Write output ──────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate5: {check_count} checks → {OUT_PATH}", file=sys.stderr)
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
