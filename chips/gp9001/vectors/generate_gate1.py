#!/usr/bin/env python3
"""
generate_gate1.py — GP9001 Gate 1 test vector generator.

Produces gate1_vectors.jsonl with 25+ checks covering:
  - Write/read each control register (scroll, layer_ctrl, sprite_ctrl, etc.)
  - Write/read sprite RAM entries
  - Decoded output verification (scroll values, enable bits)
  - vsync staging (shadow → active transfer)
  - Register isolation (writes to one register don't affect neighbors)
  - Sprite RAM address boundary (first and last entries)
  - STATUS register read (read-only, writes ignored)

Vector format (one JSON object per line):
  {"op": "write_reg",   "addr": <word_offset>, "data": <16-bit value>}
  {"op": "read_reg",    "addr": <word_offset>, "exp":  <expected 16-bit>}
  {"op": "write_sram",  "addr": <word_index>,  "data": <16-bit value>}
  {"op": "read_sram",   "addr": <word_index>,  "exp":  <expected 16-bit>}
  {"op": "vsync_pulse"}
  {"op": "check_scroll",   "layer": <0-3>, "axis": <"x"|"y">, "exp": <16-bit>}
  {"op": "check_layer_ctrl", "exp": <16-bit>}
  {"op": "check_sprite_ctrl", "exp": <16-bit>}
  {"op": "check_num_layers",  "exp": <0-2>}
  {"op": "check_bg0_priority","exp": <0-3>}
  {"op": "check_sprite_list_len_code", "exp": <0-15>}
  {"op": "check_sprite_sort_mode",     "exp": <0-3>}
  {"op": "check_color_key",  "exp": <16-bit>}
  {"op": "check_blend_ctrl", "exp": <16-bit>}
  {"op": "check_sprite_en",  "exp": <0|1>}
  {"op": "reset"}
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate1_model import (
    GP9001Model,
    REG_SCROLL0_X, REG_SCROLL0_Y,
    REG_SCROLL1_X, REG_SCROLL1_Y,
    REG_SCROLL2_X, REG_SCROLL2_Y,
    REG_SCROLL3_X, REG_SCROLL3_Y,
    REG_ROWSCROLL,
    REG_LAYER_CTRL, REG_SPRITE_CTRL,
    REG_LAYER_SIZE, REG_COLOR_KEY, REG_BLEND_CTRL,
    REG_STATUS, REG_RESERVED,
    SPRITE_RAM_WORDS,
)

VEC_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate1_vectors.jsonl')


def w(f, obj):
    f.write(json.dumps(obj) + '\n')


def generate():
    m = GP9001Model()
    recs = []
    check_count = 0

    def add(rec):
        recs.append(rec)

    def check(rec):
        nonlocal check_count
        recs.append(rec)
        check_count += 1

    # ─── Reset ────────────────────────────────────────────────────────────────
    add({"op": "reset"})
    m = GP9001Model()  # fresh model

    # ─────────────────────────────────────────────────────────────────────────
    # Section 1: Write and read back every control register
    # ─────────────────────────────────────────────────────────────────────────

    # SCROLL0_X  (reg 0x00)
    m.write_reg(REG_SCROLL0_X, 0x1234)
    add({"op": "write_reg", "addr": REG_SCROLL0_X, "data": 0x1234})
    check({"op": "read_reg", "addr": REG_SCROLL0_X, "exp": m.read_reg(REG_SCROLL0_X)})

    # SCROLL0_Y  (reg 0x01)
    m.write_reg(REG_SCROLL0_Y, 0x5678)
    add({"op": "write_reg", "addr": REG_SCROLL0_Y, "data": 0x5678})
    check({"op": "read_reg", "addr": REG_SCROLL0_Y, "exp": m.read_reg(REG_SCROLL0_Y)})

    # SCROLL1_X  (reg 0x02)
    m.write_reg(REG_SCROLL1_X, 0xAAAA)
    add({"op": "write_reg", "addr": REG_SCROLL1_X, "data": 0xAAAA})
    check({"op": "read_reg", "addr": REG_SCROLL1_X, "exp": m.read_reg(REG_SCROLL1_X)})

    # SCROLL1_Y  (reg 0x03)
    m.write_reg(REG_SCROLL1_Y, 0x5555)
    add({"op": "write_reg", "addr": REG_SCROLL1_Y, "data": 0x5555})
    check({"op": "read_reg", "addr": REG_SCROLL1_Y, "exp": m.read_reg(REG_SCROLL1_Y)})

    # SCROLL2_X/Y  (regs 0x04, 0x05)
    m.write_reg(REG_SCROLL2_X, 0x00FF)
    m.write_reg(REG_SCROLL2_Y, 0xFF00)
    add({"op": "write_reg", "addr": REG_SCROLL2_X, "data": 0x00FF})
    add({"op": "write_reg", "addr": REG_SCROLL2_Y, "data": 0xFF00})
    check({"op": "read_reg", "addr": REG_SCROLL2_X, "exp": m.read_reg(REG_SCROLL2_X)})
    check({"op": "read_reg", "addr": REG_SCROLL2_Y, "exp": m.read_reg(REG_SCROLL2_Y)})

    # SCROLL3_X/Y  (regs 0x06, 0x07)
    m.write_reg(REG_SCROLL3_X, 0xDEAD)
    m.write_reg(REG_SCROLL3_Y, 0xBEEF)
    add({"op": "write_reg", "addr": REG_SCROLL3_X, "data": 0xDEAD})
    add({"op": "write_reg", "addr": REG_SCROLL3_Y, "data": 0xBEEF})
    check({"op": "read_reg", "addr": REG_SCROLL3_X, "exp": m.read_reg(REG_SCROLL3_X)})
    check({"op": "read_reg", "addr": REG_SCROLL3_Y, "exp": m.read_reg(REG_SCROLL3_Y)})

    # ROWSCROLL  (reg 0x08)
    m.write_reg(REG_ROWSCROLL, 0x0003)
    add({"op": "write_reg", "addr": REG_ROWSCROLL, "data": 0x0003})
    check({"op": "read_reg", "addr": REG_ROWSCROLL, "exp": m.read_reg(REG_ROWSCROLL)})

    # LAYER_CTRL  (reg 0x09)
    # Set: num_layers=3-layer (bits[7:6]=01), bg0_priority=3 (bits[5:4]=11)
    lc_val = 0x0040 | 0x0030  # bits[7:6]=01, bits[5:4]=11
    m.write_reg(REG_LAYER_CTRL, lc_val)
    add({"op": "write_reg", "addr": REG_LAYER_CTRL, "data": lc_val})
    check({"op": "read_reg", "addr": REG_LAYER_CTRL, "exp": m.read_reg(REG_LAYER_CTRL)})

    # SPRITE_CTRL  (reg 0x0A)
    # Set: list_len_code=4 (256 sprites, bits[15:12]=0100), sort=sortX (bits[7:6]=01)
    sc_val = (4 << 12) | (1 << 6)
    m.write_reg(REG_SPRITE_CTRL, sc_val)
    add({"op": "write_reg", "addr": REG_SPRITE_CTRL, "data": sc_val})
    check({"op": "read_reg", "addr": REG_SPRITE_CTRL, "exp": m.read_reg(REG_SPRITE_CTRL)})

    # LAYER_SIZE  (reg 0x0B)
    m.write_reg(REG_LAYER_SIZE, 0x0001)
    add({"op": "write_reg", "addr": REG_LAYER_SIZE, "data": 0x0001})
    check({"op": "read_reg", "addr": REG_LAYER_SIZE, "exp": m.read_reg(REG_LAYER_SIZE)})

    # COLOR_KEY  (reg 0x0C)
    m.write_reg(REG_COLOR_KEY, 0x0000)
    add({"op": "write_reg", "addr": REG_COLOR_KEY, "data": 0x0000})
    check({"op": "read_reg", "addr": REG_COLOR_KEY, "exp": m.read_reg(REG_COLOR_KEY)})

    # BLEND_CTRL  (reg 0x0D)
    m.write_reg(REG_BLEND_CTRL, 0x0100)
    add({"op": "write_reg", "addr": REG_BLEND_CTRL, "data": 0x0100})
    check({"op": "read_reg", "addr": REG_BLEND_CTRL, "exp": m.read_reg(REG_BLEND_CTRL)})

    # STATUS  (reg 0x0E) — read-only, must return 0 (no vblank)
    # Write attempt should be silently ignored
    add({"op": "write_reg", "addr": REG_STATUS, "data": 0xFFFF})  # should be ignored
    check({"op": "read_reg", "addr": REG_STATUS, "exp": 0})        # still 0

    # RESERVED  (reg 0x0F) — reads 0, writes ignored
    add({"op": "write_reg", "addr": REG_RESERVED, "data": 0x1234})
    check({"op": "read_reg", "addr": REG_RESERVED, "exp": 0})

    # ─────────────────────────────────────────────────────────────────────────
    # Section 2: vsync staging — shadow → active transfer
    # Before vsync: active values should be 0 (from reset)
    # After vsync: active values should match shadow (what we wrote above)
    # ─────────────────────────────────────────────────────────────────────────

    # Check active values before vsync — should still be reset values
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": 0})
    check({"op": "check_scroll", "layer": 0, "axis": "y", "exp": 0})
    check({"op": "check_layer_ctrl",  "exp": 0})
    check({"op": "check_sprite_ctrl", "exp": 0})
    check({"op": "check_sprite_en",   "exp": 0})  # sprite_ctrl=0 → not enabled

    # Assert vsync — triggers shadow → active copy
    add({"op": "vsync_pulse"})
    m.vsync_pulse()

    # Check active values after vsync — should match what we wrote to shadow
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": m.scroll0_x})
    check({"op": "check_scroll", "layer": 0, "axis": "y", "exp": m.scroll0_y})
    check({"op": "check_scroll", "layer": 1, "axis": "x", "exp": m.scroll1_x})
    check({"op": "check_scroll", "layer": 1, "axis": "y", "exp": m.scroll1_y})
    check({"op": "check_scroll", "layer": 2, "axis": "x", "exp": m.scroll2_x})
    check({"op": "check_scroll", "layer": 2, "axis": "y", "exp": m.scroll2_y})
    check({"op": "check_scroll", "layer": 3, "axis": "x", "exp": m.scroll3_x})
    check({"op": "check_scroll", "layer": 3, "axis": "y", "exp": m.scroll3_y})
    check({"op": "check_layer_ctrl",    "exp": m.layer_ctrl})
    check({"op": "check_sprite_ctrl",   "exp": m.sprite_ctrl})
    check({"op": "check_num_layers",    "exp": m.num_layers_active})
    check({"op": "check_bg0_priority",  "exp": m.bg0_priority})
    check({"op": "check_sprite_list_len_code", "exp": m.sprite_list_len_code})
    check({"op": "check_sprite_sort_mode",     "exp": m.sprite_sort_mode})
    check({"op": "check_color_key",   "exp": m.color_key})
    check({"op": "check_blend_ctrl",  "exp": m.blend_ctrl})
    check({"op": "check_sprite_en",   "exp": int(m.sprite_en)})

    # ─────────────────────────────────────────────────────────────────────────
    # Section 3: Overwrite scroll registers, verify active does NOT change
    # until the next vsync (register staging holds old values)
    # ─────────────────────────────────────────────────────────────────────────

    old_scroll0_x = m.scroll0_x  # active value after first vsync

    m.write_reg(REG_SCROLL0_X, 0x9999)
    add({"op": "write_reg", "addr": REG_SCROLL0_X, "data": 0x9999})

    # Active value should still be old_scroll0_x (no vsync yet)
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": old_scroll0_x})

    # Now vsync — active should update to new shadow value
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": m.scroll0_x})

    # ─────────────────────────────────────────────────────────────────────────
    # Section 4: Sprite RAM write / read
    # ─────────────────────────────────────────────────────────────────────────

    # Write all 4 words of sprite 0
    m.write_sprite(0, 0, 0xC080)   # flipY=1, flipX=1, color_bank=2, code_lo=0x80
    m.write_sprite(0, 1, 0x1234)   # code_hi=0x12, y_pos=0x34
    m.write_sprite(0, 2, 0x4064)   # width=32px, height=32px, x=0x064
    m.write_sprite(0, 3, 0x8000)   # priority=1, blend=0

    for wd in range(4):
        raw_idx = 0 * 4 + wd
        val = m.read_sprite_raw(raw_idx)
        add({"op": "write_sram", "addr": raw_idx, "data": val})

    for wd in range(4):
        raw_idx = 0 * 4 + wd
        check({"op": "read_sram", "addr": raw_idx, "exp": m.read_sprite_raw(raw_idx)})

    # Write sprite 127 (mid-range)
    m.write_sprite(127, 0, 0x0F0A)
    m.write_sprite(127, 1, 0x0050)
    m.write_sprite(127, 2, 0x80A0)   # width=128px, x=0xA0
    m.write_sprite(127, 3, 0x0000)

    for wd in range(4):
        raw_idx = 127 * 4 + wd
        val = m.read_sprite_raw(raw_idx)
        add({"op": "write_sram", "addr": raw_idx, "data": val})

    for wd in range(4):
        raw_idx = 127 * 4 + wd
        check({"op": "read_sram", "addr": raw_idx, "exp": m.read_sprite_raw(raw_idx)})

    # Write sprite 255 (last sprite, last word = index 1023)
    m.write_sprite(255, 0, 0xFFFF)
    m.write_sprite(255, 1, 0xABCD)
    m.write_sprite(255, 2, 0x1234)
    m.write_sprite(255, 3, 0x5678)

    for wd in range(4):
        raw_idx = 255 * 4 + wd
        val = m.read_sprite_raw(raw_idx)
        add({"op": "write_sram", "addr": raw_idx, "data": val})

    for wd in range(4):
        raw_idx = 255 * 4 + wd
        check({"op": "read_sram", "addr": raw_idx, "exp": m.read_sprite_raw(raw_idx)})

    # Verify sprite 0 words unchanged after writing sprite 255
    for wd in range(4):
        check({"op": "read_sram", "addr": 0 * 4 + wd,
               "exp": m.read_sprite_raw(0 * 4 + wd)})

    # ─────────────────────────────────────────────────────────────────────────
    # Section 5: Overwrite with alternating patterns to check bit stability
    # ─────────────────────────────────────────────────────────────────────────

    m.write_reg(REG_SCROLL0_X, 0x0000)
    add({"op": "write_reg", "addr": REG_SCROLL0_X, "data": 0x0000})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": 0})

    m.write_reg(REG_SCROLL0_X, 0xFFFF)
    add({"op": "write_reg", "addr": REG_SCROLL0_X, "data": 0xFFFF})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_scroll", "layer": 0, "axis": "x", "exp": 0xFFFF})

    # SPRITE_CTRL: list_len_code=0 → sprite_en=0
    m.write_reg(REG_SPRITE_CTRL, 0x0000)
    add({"op": "write_reg", "addr": REG_SPRITE_CTRL, "data": 0x0000})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_sprite_en", "exp": 0})

    # SPRITE_CTRL: list_len_code=4 → sprite_en=1
    m.write_reg(REG_SPRITE_CTRL, (4 << 12))
    add({"op": "write_reg", "addr": REG_SPRITE_CTRL, "data": (4 << 12)})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_sprite_en", "exp": 1})

    # ─────────────────────────────────────────────────────────────────────────
    # Section 6: LAYER_CTRL decoded field verification
    # ─────────────────────────────────────────────────────────────────────────

    # 4-layer mode: bits[7:6] = 10 = 2
    m.write_reg(REG_LAYER_CTRL, 0x00C0)  # bits[7:6]=11 → reserved, but tests the field
    add({"op": "write_reg", "addr": REG_LAYER_CTRL, "data": 0x00C0})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_num_layers", "exp": m.num_layers_active})   # 3 (=0b11)

    # BG0 priority = 2 (bits[5:4]=10)
    m.write_reg(REG_LAYER_CTRL, 0x0020)
    add({"op": "write_reg", "addr": REG_LAYER_CTRL, "data": 0x0020})
    add({"op": "vsync_pulse"})
    m.vsync_pulse()
    check({"op": "check_bg0_priority", "exp": m.bg0_priority})       # 2

    # ─────────────────────────────────────────────────────────────────────────
    # Section 7: Sprite RAM isolation — writing sprite 1 doesn't corrupt sprite 0
    # ─────────────────────────────────────────────────────────────────────────

    # Save current sprite 0 word 0
    sp0_w0 = m.read_sprite_raw(0)

    m.write_sprite(1, 0, 0xF00D)
    add({"op": "write_sram", "addr": 1 * 4 + 0, "data": 0xF00D})

    # Sprite 0 word 0 should be unchanged
    check({"op": "read_sram", "addr": 0, "exp": sp0_w0})

    # ─────────────────────────────────────────────────────────────────────────
    # Write output file
    # ─────────────────────────────────────────────────────────────────────────

    with open(OUT_PATH, 'w') as f:
        for r in recs:
            w(f, r)

    print(f"gate1: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
