#!/usr/bin/env python3
"""
TC0480SCP — Vector generator for Steps 1–4.

Generates:
  step1_vectors.jsonl — Control registers + video timing (50 tests)
  step2_vectors.jsonl — VRAM read/write (20 tests)
  step3_vectors.jsonl — FG0 text layer render (30 tests)
  step4_vectors.jsonl — BG0/BG1 global scroll (35 tests)
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from scp_model import TC0480SCPModel, H_TOTAL, H_END, V_TOTAL, V_START, V_END, ACTIVE_PIXELS

OUTDIR = os.path.dirname(__file__)

H_SYNC_S = 336
H_SYNC_E = 368
V_SYNC_S = 0
V_SYNC_E = 4


def write_vectors(filename, records):
    path = os.path.join(OUTDIR, filename)
    print(f"Generating {len(records)} test vectors → {path}")
    with open(path, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


# =============================================================================
# STEP 1 — Control registers + video timing
# =============================================================================
def gen_step1():
    records = []
    m = TC0480SCPModel()

    def rec(**kw):
        records.append(kw)

    # 0. Reset
    rec(op="reset", note="power-on reset")

    # 1. BG X scroll with stagger (non-flip)
    stagger = [0, 4, 8, 12]
    for layer in range(4):
        raw_val = 0x0010
        m.write_ctrl(layer, raw_val)
        rec(op="write", addr=layer, data=raw_val, be=3,
            note=f"BG{layer}_XSCROLL write 0x{raw_val:04X}")
        exp = m.bgscrollx(layer)
        rec(op="check_bgscrollx", layer=layer, exp=exp,
            note=f"BG{layer} bgscrollx stagger check: expect 0x{exp:04X}")

    # 2. BG Y scroll pass-through (non-flip)
    for layer in range(4):
        raw_val = 0x0020 + layer
        m.write_ctrl(4 + layer, raw_val)
        rec(op="write", addr=4 + layer, data=raw_val, be=3,
            note=f"BG{layer}_YSCROLL write 0x{raw_val:04X}")
        exp = m.bgscrolly(layer)
        rec(op="check_bgscrolly", layer=layer, exp=exp,
            note=f"BG{layer} bgscrolly pass-through: expect 0x{exp:04X}")

    # 3. LAYER_CTRL dblwidth
    m.write_ctrl(15, 0x0080)
    rec(op="write", addr=15, data=0x0080, be=3, note="LAYER_CTRL=0x0080: dblwidth=1")
    rec(op="check_dblwidth", exp=1, note="dblwidth=1 after writing 0x0080")
    rec(op="check_flipscreen", exp=0, note="flipscreen=0 after writing 0x0080")

    # 4. LAYER_CTRL flipscreen
    m.write_ctrl(15, 0x0040)
    rec(op="write", addr=15, data=0x0040, be=3, note="LAYER_CTRL=0x0040: flipscreen=1")
    rec(op="check_dblwidth",  exp=0, note="dblwidth=0 after writing 0x0040")
    rec(op="check_flipscreen", exp=1, note="flipscreen=1 after writing 0x0040")

    # 5. X scroll sign inversion under flipscreen
    for layer in range(4):
        raw_val = 0x0010
        m.write_ctrl(layer, raw_val)
        exp = m.bgscrollx(layer)
        rec(op="check_bgscrollx", layer=layer, exp=exp,
            note=f"BG{layer} bgscrollx (flipscreen=1): expect 0x{exp:04X} (positive)")

    # 6. Y scroll sign inversion under flipscreen
    for layer in range(4):
        exp = m.bgscrolly(layer)
        rec(op="check_bgscrolly", layer=layer, exp=exp,
            note=f"BG{layer} bgscrolly (flipscreen=1): expect 0x{exp:04X} (negated)")

    # 7. bg_priority LUT: all 8 indices
    m.write_ctrl(15, 0x0000)
    rec(op="write", addr=15, data=0x0000, be=3, note="LAYER_CTRL=0x0000: clear all flags")
    pri_lut = [0x0123, 0x1230, 0x2301, 0x3012, 0x3210, 0x2103, 0x1032, 0x0321]
    for idx in range(8):
        layer_ctrl = (idx << 2) & 0x1C
        m.write_ctrl(15, layer_ctrl)
        rec(op="write", addr=15, data=layer_ctrl, be=3, note=f"LAYER_CTRL priority_order={idx}")
        exp_pri = m.bg_priority()
        rec(op="check_bg_priority", exp=exp_pri, note=f"bg_priority idx={idx}: expect 0x{exp_pri:04X}")
        assert exp_pri == pri_lut[idx]

    # 8. rowzoom_en bits
    m.write_ctrl(15, 0x0001)
    rec(op="write", addr=15, data=0x0001, be=3, note="LAYER_CTRL=0x0001: rowzoom_en[2]=1")
    rec(op="check_rowzoom_en", layer=2, exp=1, note="rowzoom_en[2]=1")
    rec(op="check_rowzoom_en", layer=3, exp=0, note="rowzoom_en[3]=0")
    m.write_ctrl(15, 0x0002)
    rec(op="write", addr=15, data=0x0002, be=3, note="LAYER_CTRL=0x0002: rowzoom_en[3]=1")
    rec(op="check_rowzoom_en", layer=2, exp=0, note="rowzoom_en[2]=0 after bit0 clear")
    rec(op="check_rowzoom_en", layer=3, exp=1, note="rowzoom_en[3]=1")
    m.write_ctrl(15, 0x0003)
    rec(op="write", addr=15, data=0x0003, be=3, note="LAYER_CTRL=0x0003: both set")
    rec(op="check_rowzoom_en", layer=2, exp=1, note="rowzoom_en[2]=1 (both set)")
    rec(op="check_rowzoom_en", layer=3, exp=1, note="rowzoom_en[3]=1 (both set)")
    m.write_ctrl(15, 0x0000)
    rec(op="write", addr=15, data=0x0000, be=3, note="LAYER_CTRL=0x0000: reset for timing")

    # 9. Video timing frame
    rec(op="timing_frame", exp_pv=ACTIVE_PIXELS,
        note=f"timing: pixel_active count = {ACTIVE_PIXELS} (320×240)")

    # 10. hblank/pixel_active boundary checks
    rec(op="timing_check", hpos=0, vpos=V_START,
        exp_hblank=0, exp_vblank=0, exp_pixel_active=1,
        note="timing: hpos=0 vpos=16 → active")
    rec(op="timing_check", hpos=0, vpos=V_START - 1,
        exp_hblank=0, exp_vblank=1, exp_pixel_active=0,
        note="timing: hpos=0 vpos=15 → vblank")
    rec(op="timing_check", hpos=H_END, vpos=V_START,
        exp_hblank=1, exp_vblank=0, exp_pixel_active=0,
        note=f"timing: hpos={H_END} vpos={V_START} → hblank start")
    rec(op="timing_check", hpos=H_END - 1, vpos=V_START,
        exp_hblank=0, exp_vblank=0, exp_pixel_active=1,
        note=f"timing: hpos={H_END - 1} vpos={V_START} → last active pixel")
    rec(op="timing_check", hpos=H_END, vpos=V_START,
        exp_hblank=1, exp_vblank=0, exp_pixel_active=0,
        note=f"timing: hpos={H_END} vpos={V_START} → hblank asserted")

    # 11. Zoom register round-trip
    zoom_vals = [0x8040, 0x0080, 0xFF7F, 0x1234]
    for layer in range(4):
        m.write_ctrl(8 + layer, zoom_vals[layer])
        rec(op="write", addr=8 + layer, data=zoom_vals[layer], be=3,
            note=f"BG{layer}_ZOOM write 0x{zoom_vals[layer]:04X}")
        rec(op="read", addr=8 + layer, exp_dout=zoom_vals[layer],
            note=f"BG{layer}_ZOOM readback 0x{zoom_vals[layer]:04X}")

    # 12. DX/DY sub-pixel byte extraction
    dx_vals = [0x12, 0x34, 0x56, 0x78]
    dy_vals = [0xAB, 0xCD, 0xEF, 0x01]
    for layer in range(4):
        m.write_ctrl(16 + layer, 0xBE00 | dx_vals[layer])
        rec(op="write", addr=16 + layer, data=0xBE00 | dx_vals[layer], be=3,
            note=f"BG{layer}_DX write (low byte=0x{dx_vals[layer]:02X})")
        rec(op="check_bg_dx", layer=layer, exp=dx_vals[layer],
            note=f"BG{layer} bg_dx=0x{dx_vals[layer]:02X}")
        m.write_ctrl(20 + layer, 0xBE00 | dy_vals[layer])
        rec(op="write", addr=20 + layer, data=0xBE00 | dy_vals[layer], be=3,
            note=f"BG{layer}_DY write (low byte=0x{dy_vals[layer]:02X})")
        rec(op="check_bg_dy", layer=layer, exp=dy_vals[layer],
            note=f"BG{layer} bg_dy=0x{dy_vals[layer]:02X}")

    # 13. Text scroll round-trip
    m.write_ctrl(12, 0x0100)
    rec(op="write", addr=12, data=0x0100, be=3, note="TEXT_XSCROLL write 0x0100")
    rec(op="read",  addr=12, exp_dout=0x0100, note="TEXT_XSCROLL readback")
    m.write_ctrl(13, 0x0200)
    rec(op="write", addr=13, data=0x0200, be=3, note="TEXT_YSCROLL write 0x0200")
    rec(op="read",  addr=13, exp_dout=0x0200, note="TEXT_YSCROLL readback")

    # 14. Byte-enable partial writes
    m.write_ctrl(0, 0x0000)
    rec(op="write", addr=0, data=0x0000, be=3, note="BG0_XSCROLL clear to 0")
    m.write_ctrl(0, 0x00AB, be=0x1)
    rec(op="write", addr=0, data=0x00AB, be=1, note="BG0_XSCROLL write low byte 0xAB only (be=1)")
    rec(op="read",  addr=0, exp_dout=m.read_ctrl(0),
        note=f"BG0_XSCROLL readback after low-byte-only write: expect 0x{m.read_ctrl(0):04X}")
    m.write_ctrl(0, 0xCD00, be=0x2)
    rec(op="write", addr=0, data=0xCD00, be=2, note="BG0_XSCROLL write high byte 0xCD only (be=2)")
    rec(op="read",  addr=0, exp_dout=m.read_ctrl(0),
        note=f"BG0_XSCROLL readback after high-byte-only write: expect 0x{m.read_ctrl(0):04X}")

    # 15. Register readback after reset
    rec(op="reset", note="reset before register-zero check")
    rec(op="read", addr=0,  exp_dout=0x0000, note="ctrl[0]=0 after reset")
    rec(op="read", addr=15, exp_dout=0x0000, note="ctrl[15]=0 after reset")
    rec(op="read", addr=23, exp_dout=0x0000, note="ctrl[23]=0 after reset")

    # 16. Unknown word 14
    rec(op="write", addr=14, data=0xDEAD, be=3, note="ctrl[14] (unused) write 0xDEAD")
    rec(op="read",  addr=14, exp_dout=0xDEAD, note="ctrl[14] (unused) readback 0xDEAD")

    write_vectors("step1_vectors.jsonl", records)
    return len(records)


# =============================================================================
# STEP 2 — VRAM read/write
# =============================================================================
def gen_step2():
    records = []
    m = TC0480SCPModel()

    def rec(**kw):
        records.append(kw)

    # Reset to clear control regs
    rec(op="reset", note="step2 reset")

    # --- Group 1: Basic round-trip at key addresses ---
    # Zero out first to avoid BRAM persistence issues
    rec(op="vram_zero", base=0x0000, count=4, note="zero VRAM group1 area")

    # BG0 tilemap base (byte 0x0000 = word 0x0000)
    m.write_ram(0x0000, 0xABCD)
    rec(op="vram_write", addr=0x0000, data=0xABCD, be=3,
        note="VRAM[0x0000]=0xABCD (BG0 tilemap base)")
    rec(op="vram_read", addr=0x0000, exp_data=0xABCD,
        note="VRAM[0x0000] readback 0xABCD")

    # BG0 rowscroll hi base (byte 0x4000 = word 0x2000)
    rec(op="vram_zero", base=0x2000, count=2, note="zero rowscroll area")
    m.write_ram(0x2000, 0x1234)
    rec(op="vram_write", addr=0x2000, data=0x1234, be=3,
        note="VRAM[0x2000]=0x1234 (BG0 rowscroll hi base)")
    rec(op="vram_read", addr=0x2000, exp_data=0x1234,
        note="VRAM[0x2000] readback 0x1234")

    # FG0 tile map base (byte 0xC000 = word 0x6000)
    rec(op="vram_zero", base=0x6000, count=2, note="zero FG tilemap area")
    m.write_ram(0x6000, 0x5678)
    rec(op="vram_write", addr=0x6000, data=0x5678, be=3,
        note="VRAM[0x6000]=0x5678 (FG0 tilemap base)")
    rec(op="vram_read", addr=0x6000, exp_data=0x5678,
        note="VRAM[0x6000] readback 0x5678")

    # FG0 gfx data (byte 0xE010 = word 0x7008)
    rec(op="vram_zero", base=0x7008, count=2, note="zero FG gfx area")
    m.write_ram(0x7008, 0x9ABC)
    rec(op="vram_write", addr=0x7008, data=0x9ABC, be=3,
        note="VRAM[0x7008]=0x9ABC (FG0 gfx data)")
    rec(op="vram_read", addr=0x7008, exp_data=0x9ABC,
        note="VRAM[0x7008] readback 0x9ABC")

    # --- Group 2: Byte-enable writes ---
    rec(op="vram_zero", base=0x0100, count=1, note="zero byte-enable test word")

    # Write full word first
    m.write_ram(0x0100, 0x0000)
    rec(op="vram_write", addr=0x0100, data=0x0000, be=3, note="VRAM[0x0100] clear")

    # Write low byte only (be=1 → bits[7:0])
    m.write_ram(0x0100, 0x00CD, be=0x1)
    rec(op="vram_write", addr=0x0100, data=0x00CD, be=1,
        note="VRAM[0x0100] write low byte 0xCD (be=1)")
    rec(op="vram_read", addr=0x0100, exp_data=m.read_ram(0x0100),
        note=f"VRAM[0x0100] after low-byte write: expect 0x{m.read_ram(0x0100):04X}")

    # Write high byte only (be=2 → bits[15:8])
    m.write_ram(0x0100, 0xAB00, be=0x2)
    rec(op="vram_write", addr=0x0100, data=0xAB00, be=2,
        note="VRAM[0x0100] write high byte 0xAB (be=2)")
    rec(op="vram_read", addr=0x0100, exp_data=m.read_ram(0x0100),
        note=f"VRAM[0x0100] after high-byte write: expect 0x{m.read_ram(0x0100):04X}")

    # Expected: 0xABCD (high byte 0xAB, low byte 0xCD)
    assert m.read_ram(0x0100) == 0xABCD, f"model byte-enable check failed: {m.read_ram(0x0100):04X}"

    # --- Group 3: Multiple addresses, verify no aliasing ---
    rec(op="vram_zero", base=0x0200, count=4, note="zero aliasing test area")

    test_vals = [0x1111, 0x2222, 0x3333, 0x4444]
    for i, val in enumerate(test_vals):
        m.write_ram(0x0200 + i, val)
        rec(op="vram_write", addr=0x0200 + i, data=val, be=3,
            note=f"VRAM[0x{0x0200+i:04X}]=0x{val:04X}")

    for i, val in enumerate(test_vals):
        rec(op="vram_read", addr=0x0200 + i, exp_data=val,
            note=f"VRAM[0x{0x0200+i:04X}] readback 0x{val:04X} (no aliasing)")

    # --- Group 4: Top and bottom of VRAM ---
    rec(op="vram_zero", base=0x0000, count=1, note="zero word 0")
    rec(op="vram_zero", base=0x7FFF, count=1, note="zero last word")

    m.write_ram(0x0000, 0xAAAA)
    rec(op="vram_write", addr=0x0000, data=0xAAAA, be=3, note="VRAM[0x0000]=0xAAAA")
    rec(op="vram_read",  addr=0x0000, exp_data=0xAAAA, note="VRAM[0x0000] readback 0xAAAA")

    m.write_ram(0x7FFF, 0x5555)
    rec(op="vram_write", addr=0x7FFF, data=0x5555, be=3, note="VRAM[0x7FFF]=0x5555 (top of VRAM)")
    rec(op="vram_read",  addr=0x7FFF, exp_data=0x5555, note="VRAM[0x7FFF] readback 0x5555")

    write_vectors("step2_vectors.jsonl", records)
    return len(records)


# =============================================================================
# STEP 3 — FG0 text layer render
# =============================================================================
def gen_step3():
    records = []
    m = TC0480SCPModel()

    def rec(**kw):
        records.append(kw)

    rec(op="reset", note="step3 reset")

    # Clear text scroll registers (word 12, 13) = 0
    m.write_ctrl(12, 0x0000)
    m.write_ctrl(13, 0x0000)
    rec(op="write", addr=12, data=0x0000, be=3, note="TEXT_XSCROLL=0")
    rec(op="write", addr=13, data=0x0000, be=3, note="TEXT_YSCROLL=0")

    # Clear priority order (word 15 = 0 → default 0x0123 bottom-to-top)
    m.write_ctrl(15, 0x0000)
    rec(op="write", addr=15, data=0x0000, be=3, note="LAYER_CTRL=0")

    # ── Zero VRAM areas we'll use (BRAM persistence) ──────────────────────
    # FG0 tilemap: word 0x6000–0x6FFF (4096 words)
    rec(op="vram_zero", base=0x6000, count=4096, note="zero FG0 tilemap")
    # FG0 gfx data: word 0x7000–0x7FFF (4096 words, = 256 tiles × 16 words each)
    rec(op="vram_zero", base=0x7000, count=4096, note="zero FG0 gfx data")
    # BG tilemaps: word 0x0000–0x1FFF (8192 words, all 4 layers)
    rec(op="vram_zero", base=0x0000, count=8192, note="zero all BG tilemaps (transparent)")

    def set_fg_tile(tile_idx, pixels_16x4bpp):
        """Write an 8×8 4bpp tile into FG0 gfx data (256 tiles × 16 words each).

        pixels_16x4bpp: list of 8 rows, each row is list of 8 × 4-bit pen values.
        Layout (section1 §4.3):
          row32 = {word1, word0}
          px0=row32[15:12], px1=row32[11:8], px2=row32[7:4], px3=row32[3:0]
          px4=row32[31:28], px5=row32[27:24], px6=row32[23:20], px7=row32[19:16]
        """
        gfx_base_word = 0x7000 + tile_idx * 16
        for row_idx, row in enumerate(pixels_16x4bpp):
            # pack into row32
            row32 = (
                ((row[0] & 0xF) << 12) |
                ((row[1] & 0xF) <<  8) |
                ((row[2] & 0xF) <<  4) |
                ((row[3] & 0xF) <<  0) |
                ((row[4] & 0xF) << 28) |
                ((row[5] & 0xF) << 24) |
                ((row[6] & 0xF) << 20) |
                ((row[7] & 0xF) << 16)
            )
            word0 = row32 & 0xFFFF
            word1 = (row32 >> 16) & 0xFFFF
            waddr0 = gfx_base_word + row_idx * 2
            waddr1 = waddr0 + 1
            m.write_ram(waddr0, word0)
            m.write_ram(waddr1, word1)
            rec(op="gfx_write", word_addr=tile_idx * 16 + row_idx * 2,     data=word0,
                note=f"tile{tile_idx} row{row_idx} word0=0x{word0:04X}")
            rec(op="gfx_write", word_addr=tile_idx * 16 + row_idx * 2 + 1, data=word1,
                note=f"tile{tile_idx} row{row_idx} word1=0x{word1:04X}")

    def set_fg_map(tile_x, tile_y, color, tile_idx, flipx=0, flipy=0):
        """Write FG0 tile map entry."""
        word = ((flipy & 1) << 15) | ((flipx & 1) << 14) | ((color & 0x3F) << 8) | (tile_idx & 0xFF)
        m.write_ram(0x6000 + tile_y * 64 + tile_x, word)
        rec(op="map_write_fg", tile_x=tile_x, tile_y=tile_y, data=word,
            note=f"FG map({tile_x},{tile_y})=tile{tile_idx} color={color} flipx={flipx} flipy={flipy}")

    # ── Test 1: Solid-fill tile at (0,0), pen=5, color=3 ─────────────────
    # All 8 rows filled with pen 5
    solid_5 = [[5]*8 for _ in range(8)]
    set_fg_tile(0, solid_5)
    set_fg_map(0, 0, color=3, tile_idx=0)

    # Expected: pixel at screen (0,0) → (3 << 4) | 5 = 0x35
    expected_px = (3 << 4) | 5
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=expected_px,
        note=f"solid tile pen=5 color=3 at (0,0): expect 0x{expected_px:04X}")

    # Also check pixel (7,0) and (0,7) — should be same solid color
    rec(op="check_pixel", screen_x=7, screen_y=0, exp=expected_px,
        note=f"solid tile pen=5 color=3 at (7,0): expect 0x{expected_px:04X}")
    rec(op="check_pixel", screen_x=0, screen_y=7, exp=expected_px,
        note=f"solid tile pen=5 color=3 at (0,7): expect 0x{expected_px:04X}")

    # ── Test 2: Transparent pen=0 means background ────────────────────────
    # Tile 1: all pen=0
    transparent_tile = [[0]*8 for _ in range(8)]
    set_fg_tile(1, transparent_tile)
    set_fg_map(1, 0, color=7, tile_idx=1)

    # Tile at map (1,0) → screen pixels (8..15, 0): all transparent → output = 0
    rec(op="check_pixel", screen_x=8, screen_y=0, exp=0x0000,
        note="transparent tile at (1,0): pixel (8,0) = 0 (background)")

    # ── Test 3: horizontally-striped tile at (5,3) ────────────────────────
    # Tile 2: alternating rows pen=1 and pen=2
    striped = [[1 if row % 2 == 0 else 2]*8 for row in range(8)]
    set_fg_tile(2, striped)
    set_fg_map(5, 3, color=1, tile_idx=2)

    # screen_x=40 (=5*8), screen_y=24 (=3*8): row 0 → pen=1
    exp_stripe_even = (1 << 4) | 1
    exp_stripe_odd  = (1 << 4) | 2
    rec(op="check_pixel", screen_x=40, screen_y=24, exp=exp_stripe_even,
        note=f"striped tile row0 pen=1 at screen(40,24): expect 0x{exp_stripe_even:04X}")
    rec(op="check_pixel", screen_x=40, screen_y=25, exp=exp_stripe_odd,
        note=f"striped tile row1 pen=2 at screen(40,25): expect 0x{exp_stripe_odd:04X}")

    # ── Test 4: FlipX tile at (2,0) ───────────────────────────────────────
    # Tile 3: columns 0..7 have distinct pens 1..7,0
    flipx_tile = [[p & 0xF for p in range(1, 9)] for _ in range(8)]  # pens 1,2,3,4,5,6,7,0 per row
    set_fg_tile(3, flipx_tile)
    set_fg_map(2, 0, color=0, tile_idx=3, flipx=1)

    # With flipX, pixel at screen_x=16 (=2*8+0 within tile) should get pen=7 (was px7=0→wrap)
    # Actually: pens 1..8 → mod16: 1,2,3,4,5,6,7,0
    # flipX reverses: px0←px7=0, px1←px6=7, px2←px5=6, ...
    # screen_x=16 → px0 in tile → pen=0 (transparent, flipX gives last px=0)
    # screen_x=17 → px1 in tile → pen=7 (flipX gives px6=7 from original)
    exp_flipx_px1 = (0 << 4) | 7
    rec(op="check_pixel", screen_x=17, screen_y=0, exp=exp_flipx_px1,
        note=f"flipX tile: screen_x=17 → pen=7: expect 0x{exp_flipx_px1:04X}")

    # ── Test 5: FlipY tile at (2,1) ───────────────────────────────────────
    # Tile 4: rows have distinct pens (row 0 → pen=1, row 7 → pen=8→0xF overflows → 8 mod16 = 8)
    flipy_tile = [[(row + 1) & 0xF]*8 for row in range(8)]  # row 0 all pen=1, row 7 all pen=8→0
    flipy_tile[7] = [8 & 0xF]*8  # pen=8 for last row
    set_fg_tile(4, flipy_tile)
    set_fg_map(2, 1, color=0, tile_idx=4, flipy=1)

    # With flipY: row 0 of screen (screen_y=8) → fetches tile row 7 → pen=8
    exp_flipy_row0 = (0 << 4) | 8
    rec(op="check_pixel", screen_x=16, screen_y=8, exp=exp_flipy_row0,
        note=f"flipY tile at (2,1): screen_y=8 → tile_row=7 → pen=8: expect 0x{exp_flipy_row0:04X}")
    # screen_y=15 → tile row 0 → pen=1
    exp_flipy_row7 = (0 << 4) | 1
    rec(op="check_pixel", screen_x=16, screen_y=15, exp=exp_flipy_row7,
        note=f"flipY tile at (2,1): screen_y=15 → tile_row=0 → pen=1: expect 0x{exp_flipy_row7:04X}")

    # ── Test 6: Text scroll X=8 shifts tiles ─────────────────────────────
    # With TEXT_XSCROLL=8 (1 tile), tile (0,0) should appear at screen_x=0 as tile (1,0)
    # Tile (0,0) = solid pen=5 color=3 (from test 1)
    # Tile (1,0) = transparent (from test 2)
    # After scrolling X by 8: canvas_x=8 at screen_x=0 → tile col=1 → tile (1,0) = transparent
    m.write_ctrl(12, 0x0008)
    rec(op="write", addr=12, data=0x0008, be=3, note="TEXT_XSCROLL=8 (shift left 1 tile)")
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=0x0000,
        note="X scroll=8: screen_x=0 → canvas_x=8 → tile(1,0) = transparent → 0x0000")

    # Tile (0,0) solid should now appear at screen_x = 512-8 = 504 (wraps around)
    # That's off screen (>319), so instead check screen_x=312 (= 320-8):
    # canvas_x at screen_x=312 = 312+8 = 320 → tile col=320/8=40 → tile at map(40,0)
    # We haven't set tile(40,0), so it's transparent. Let's check screen_x=8-8=0 gives tile(1,0)
    # and screen_x=320-8=312 gives canvas_x=320 → tile col=40, tile(40,0)=transparent(0)
    # Let's just confirm the scrolled position for tile(0,0) at screen_x < 0 (invisible):
    # screen_x where tile(0,0) appears: canvas_x < 8, so screen_x < 8-8=0 → not visible.
    # screen_x=319: canvas_x=319+8=327 → tile col=327/8=40 → untouched → 0
    # Reset scroll
    m.write_ctrl(12, 0x0000)
    rec(op="write", addr=12, data=0x0000, be=3, note="TEXT_XSCROLL=0 (restore)")

    # ── Test 7: Text scroll Y=8 shifts tiles ─────────────────────────────
    m.write_ctrl(13, 0x0008)
    rec(op="write", addr=13, data=0x0008, be=3, note="TEXT_YSCROLL=8 (shift up 1 tile)")
    # screen_y=0 → canvas_y=0+8=8 → tile row=1 → tile at map(0,1)=untouched → transparent
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=0x0000,
        note="Y scroll=8: screen_y=0 → canvas_y=8 → tile(0,1)=untouched → transparent")
    # screen_y=232 → canvas_y=232+8=240 → tile row=30 → untouched → transparent (should be visible)
    rec(op="check_pixel", screen_x=0, screen_y=232, exp=0x0000,
        note="Y scroll=8: screen_y=232 → canvas_y=240 → tile(0,30)=untouched → transparent")
    m.write_ctrl(13, 0x0000)
    rec(op="write", addr=13, data=0x0000, be=3, note="TEXT_YSCROLL=0 (restore)")

    # ── Test 8: Exact pixel layout verification (section1 §4.3) ──────────
    # Tile 5: specific per-pixel pattern to verify nibble decode
    # Row 0: pens [1,2,3,4,5,6,7,8]
    # This tests the column reversal in the packed format
    layout_test_row = [1, 2, 3, 4, 5, 6, 7, 8]
    layout_tile = [layout_test_row] + [[0]*8 for _ in range(7)]
    set_fg_tile(5, layout_tile)
    set_fg_map(10, 0, color=2, tile_idx=5)

    # screen_x = 80 (= 10*8 + 0), screen_y=0 → pen=1
    rec(op="check_pixel", screen_x=80, screen_y=0, exp=(2 << 4) | 1,
        note="pixel layout: (80,0) → pen=1, expect 0x21")
    rec(op="check_pixel", screen_x=81, screen_y=0, exp=(2 << 4) | 2,
        note="pixel layout: (81,0) → pen=2, expect 0x22")
    rec(op="check_pixel", screen_x=82, screen_y=0, exp=(2 << 4) | 3,
        note="pixel layout: (82,0) → pen=3, expect 0x23")
    rec(op="check_pixel", screen_x=83, screen_y=0, exp=(2 << 4) | 4,
        note="pixel layout: (83,0) → pen=4, expect 0x24")
    rec(op="check_pixel", screen_x=84, screen_y=0, exp=(2 << 4) | 5,
        note="pixel layout: (84,0) → pen=5, expect 0x25")
    rec(op="check_pixel", screen_x=85, screen_y=0, exp=(2 << 4) | 6,
        note="pixel layout: (85,0) → pen=6, expect 0x26")
    rec(op="check_pixel", screen_x=86, screen_y=0, exp=(2 << 4) | 7,
        note="pixel layout: (86,0) → pen=7, expect 0x27")
    # pen=8 → (2<<4)|8 = 0x28
    rec(op="check_pixel", screen_x=87, screen_y=0, exp=(2 << 4) | 8,
        note="pixel layout: (87,0) → pen=8, expect 0x28")

    write_vectors("step3_vectors.jsonl", records)
    return len(records)


# =============================================================================
# STEP 4 — BG0/BG1 global scroll, no zoom
# =============================================================================
def gen_step4():
    records = []
    m = TC0480SCPModel()

    def rec(**kw):
        records.append(kw)

    rec(op="reset", note="step4 reset")

    # Reset all scroll/layer ctrl registers
    for i in range(24):
        m.write_ctrl(i, 0x0000)
        rec(op="write", addr=i, data=0x0000, be=3, note=f"ctrl[{i}]=0")

    # Zero all BG tilemaps and FG0 tilemap (BRAM persistence)
    rec(op="vram_zero", base=0x0000, count=8192,  note="zero all BG tilemaps")
    rec(op="vram_zero", base=0x6000, count=4096,  note="zero FG0 tilemap")
    rec(op="vram_zero", base=0x7000, count=4096,  note="zero FG0 gfx data")

    def make_bg_gfx_solid(tile_code, pen, color_byte):
        """Write a solid-color 16×16 BG tile to GFX ROM and return setup records.

        GFX ROM format: 32 × 32-bit words per tile.
        Left 8 pixels row r:  word = tile_code*32 + r*2
        Right 8 pixels row r: word = tile_code*32 + r*2 + 1
        bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7
        Solid: all nibbles = pen value.
        """
        nibble = pen & 0xF
        solid_word = 0
        for i in range(8):
            solid_word |= (nibble << (28 - i*4))

        base = tile_code * 32
        for row in range(16):
            for half in range(2):
                waddr = base + row * 2 + half
                rec(op="gfx_rom_write", word_addr=waddr,
                    data_hi=(solid_word >> 16) & 0xFFFF,
                    data_lo=solid_word & 0xFFFF,
                    note=f"GFX ROM tile{tile_code} row{row} half{half}: solid pen={pen}")
                m.write_gfx_rom_word(waddr, solid_word)

    def make_bg_gfx_row_pattern(tile_code, row_pens):
        """Write a BG tile where each row has a specific pen value.

        row_pens: list of 16 values (one per row).
        """
        base = tile_code * 32
        for row in range(16):
            nibble = row_pens[row] & 0xF
            row_word = 0
            for i in range(8):
                row_word |= (nibble << (28 - i*4))
            for half in range(2):
                waddr = base + row * 2 + half
                rec(op="gfx_rom_write", word_addr=waddr,
                    data_hi=(row_word >> 16) & 0xFFFF,
                    data_lo=row_word & 0xFFFF,
                    note=f"GFX ROM tile{tile_code} row{row} half{half}: pen={row_pens[row]}")
                m.write_gfx_rom_word(waddr, row_word)

    def write_bg_map_tile(layer, tile_x, tile_y, color, tile_code, flipx=0, flipy=0):
        """Write BG tile map entry (attr + code words)."""
        attr = ((flipy & 1) << 15) | ((flipx & 1) << 14) | (color & 0xFF)
        code = tile_code & 0x7FFF
        rec(op="map_write_bg", layer=layer, tile_x=tile_x, tile_y=tile_y,
            attr=attr, code=code,
            note=f"BG{layer} map({tile_x},{tile_y}) tile={tile_code} color={color}")
        # Also update model
        dw = m.dblwidth()
        map_width = 64 if dw else 32
        layer_base = (layer * 0x0800) if dw else (layer * 0x0400)
        tile_idx = tile_y * map_width + tile_x
        word_base = layer_base + tile_idx * 2
        m.write_ram(word_base, attr)
        m.write_ram(word_base + 1, code)

    # ── Test 1: Solid tile at BG0 (0,0), pen=7, color=0x5A ───────────────
    make_bg_gfx_solid(tile_code=0, pen=7, color_byte=0x5A)
    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x5A, tile_code=0)

    expected = (0x5A << 4) | 7  # = 0x5A7
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=expected,
        note=f"BG0 solid tile pen=7 color=0x5A at (0,0): expect 0x{expected:04X}")
    rec(op="check_pixel", screen_x=15, screen_y=0, exp=expected,
        note=f"BG0 solid tile pen=7 color=0x5A at (15,0): expect 0x{expected:04X}")
    rec(op="check_pixel", screen_x=0, screen_y=15, exp=expected,
        note=f"BG0 solid tile pen=7 color=0x5A at (0,15): expect 0x{expected:04X}")

    # ── Test 2: BG0_XSCROLL=16 → tiles shift left 16 pixels ──────────────
    # After scrolling by 16, screen_x=0 should show tile (1,0) not tile (0,0)
    # Tile (1,0) is empty (pen=0) → transparent → output=0
    m.write_ctrl(0, 0x0010)  # raw scroll 16; bgscrollx[0] = -(16 + 0) = -16 = 0xFFF0
    rec(op="write", addr=0, data=0x0010, be=3, note="BG0_XSCROLL=0x0010 (raw=16)")
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=0x0000,
        note="BG0 scroll=16: screen_x=0 → canvas_x=16 → tile(1,0)=empty → 0")
    # screen_x=0-16 mod512 = 496 → off screen. Tile(0,0) not visible.
    # screen_x=16-16=0... wait: canvas_x = screen_x + bgscrollx applied inside engine.
    # In model: canvas_x = (screen_x + bgscrollx) & mask
    # bgscrollx = (-0x10) & 0xFFFF = 0xFFF0 = 65520
    # canvas_x at screen_x=0: (0 + 65520) & 0x1FF = 65520 & 511 = 65520 mod 512 = 65520 - 128*512 = 65520-65536 = -16 → 496
    # tile col = 496/16 = 31
    # That's tile(31,0) which is empty → transparent
    # Let's verify: screen_x=16: canvas_x=(16+65520)&511 = 65536&511 = 0 → tile(0,0) = solid!
    rec(op="check_pixel", screen_x=16, screen_y=0, exp=expected,
        note=f"BG0 scroll=16: screen_x=16 → canvas_x=0 → tile(0,0) solid: expect 0x{expected:04X}")

    # Reset BG0_XSCROLL
    m.write_ctrl(0, 0x0000)
    rec(op="write", addr=0, data=0x0000, be=3, note="BG0_XSCROLL=0 (restore)")

    # ── Test 3: BG0_YSCROLL=16 → tiles shift up 16 pixels ────────────────
    m.write_ctrl(4, 0x0010)  # raw yscroll=16; bgscrolly[0]=16
    rec(op="write", addr=4, data=0x0010, be=3, note="BG0_YSCROLL=0x0010 (raw=16)")
    # screen_y=0: canvas_y = (0 + 16) & 0x1FF = 16 → tile row=1, not row=0
    # tile(0,1) is empty → transparent
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=0x0000,
        note="BG0 yscroll=16: screen_y=0 → canvas_y=16 → tile(0,1)=empty → 0")
    # screen_y=16: canvas_y=(16+16)&0x1FF=32 → tile row 2 → tile(0,2)=empty → 0
    # screen_y back at 0-16 = -16 → 496 (row 31): We need screen_y where canvas_y=0
    # canvas_y=0 when screen_y+16=0 mod512 → screen_y = 512-16=496 → off screen (max 239)
    # So tile(0,0) is not visible. Let's just leave yscroll=16 confirmed.
    m.write_ctrl(4, 0x0000)
    rec(op="write", addr=4, data=0x0000, be=3, note="BG0_YSCROLL=0 (restore)")

    # ── Test 4: FlipX tile at BG0 (0,0) ──────────────────────────────────
    # Tile 1: column gradient pens 1..8 then 0..0 for 16px (using row_pattern per column)
    # Actually simpler: define a tile with pens 1,0,0,...,0 in px0 and 2 in px8
    # For a clean test: tile with px0=1, px1=2, px8=3, px9=4, rest=0
    # Use solid approaches: make a tile where left half (px0-7) = pen 5, right half (px8-15)=pen 6
    # Then with flipX: left half → pen 6, right half → pen 5
    # Solid left/right different:
    # Left word: all nibbles = 5
    solid_left  = sum(5 << (28 - 4*i) for i in range(8))
    solid_right = sum(6 << (28 - 4*i) for i in range(8))
    base_t1 = 1 * 32  # tile code 1
    for row in range(16):
        waddr_l = base_t1 + row * 2
        waddr_r = base_t1 + row * 2 + 1
        rec(op="gfx_rom_write", word_addr=waddr_l,
            data_hi=(solid_left >> 16) & 0xFFFF, data_lo=solid_left & 0xFFFF,
            note=f"tile1 row{row} left: pen=5")
        rec(op="gfx_rom_write", word_addr=waddr_r,
            data_hi=(solid_right >> 16) & 0xFFFF, data_lo=solid_right & 0xFFFF,
            note=f"tile1 row{row} right: pen=6")
        m.write_gfx_rom_word(waddr_l, solid_left)
        m.write_gfx_rom_word(waddr_r, solid_right)

    # Write tile1 at (0,0) WITHOUT flipX: px0-7 should be pen=5
    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x01, tile_code=1, flipx=0, flipy=0)
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=(0x01 << 4) | 5,
        note="BG0 tile1 noflip: px0=pen=5, expect 0x15")
    rec(op="check_pixel", screen_x=8, screen_y=0, exp=(0x01 << 4) | 6,
        note="BG0 tile1 noflip: px8=pen=6, expect 0x16")

    # With flipX: right becomes left
    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x01, tile_code=1, flipx=1, flipy=0)
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=(0x01 << 4) | 6,
        note="BG0 tile1 flipX: px0=pen=6, expect 0x16")
    rec(op="check_pixel", screen_x=8, screen_y=0, exp=(0x01 << 4) | 5,
        note="BG0 tile1 flipX: px8=pen=5, expect 0x15")

    # ── Test 5: FlipY tile at BG0 (0,0) ──────────────────────────────────
    # Tile 2: row 0 = pen 3, rows 1-15 = pen 4, all pixels
    row_pens_t2 = [3] + [4]*15
    make_bg_gfx_row_pattern(tile_code=2, row_pens=row_pens_t2)

    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x02, tile_code=2, flipx=0, flipy=0)
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=(0x02 << 4) | 3,
        note="BG0 tile2 noflipY: screen_y=0 → tile_row=0 → pen=3, expect 0x23")

    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x02, tile_code=2, flipx=0, flipy=1)
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=(0x02 << 4) | 4,
        note="BG0 tile2 flipY: screen_y=0 → tile_row=15 → pen=4, expect 0x24")
    rec(op="check_pixel", screen_x=0, screen_y=15, exp=(0x02 << 4) | 3,
        note="BG0 tile2 flipY: screen_y=15 → tile_row=0 → pen=3, expect 0x23")

    # ── Test 6: BG layer transparency (BG0 transparent, BG1 shows through) ─
    # Write a different solid tile to BG1 at (0,0)
    make_bg_gfx_solid(tile_code=3, pen=9, color_byte=0x0A)
    write_bg_map_tile(layer=1, tile_x=0, tile_y=0, color=0x0A, tile_code=3)
    # BG0 at (0,0): use transparent tile (tile 0xFF: all pen=0)
    # Zero tile code 0xFF GFX ROM
    base_transparent = 0xFF * 32
    for row in range(16):
        for half in range(2):
            waddr = base_transparent + row * 2 + half
            rec(op="gfx_rom_write", word_addr=waddr,
                data_hi=0, data_lo=0, note=f"clear tile 0xFF row{row} half{half}")
            m.write_gfx_rom_word(waddr, 0)

    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x00, tile_code=0xFF)
    exp_bg1 = (0x0A << 4) | 9
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=exp_bg1,
        note=f"BG0 transparent (pen=0), BG1 shows through: expect 0x{exp_bg1:04X}")

    # Restore BG0 solid tile (tile0)
    write_bg_map_tile(layer=0, tile_x=0, tile_y=0, color=0x5A, tile_code=0)
    exp_bg0 = (0x5A << 4) | 7
    rec(op="check_pixel", screen_x=0, screen_y=0, exp=exp_bg0,
        note=f"BG0 opaque again: expect 0x{exp_bg0:04X}")

    write_vectors("step4_vectors.jsonl", records)
    return len(records)


# =============================================================================
# Main
# =============================================================================
if __name__ == "__main__":
    n1 = gen_step1()
    n2 = gen_step2()
    n3 = gen_step3()
    n4 = gen_step4()
    print(f"Total vectors: step1={n1}, step2={n2}, step3={n3}, step4={n4}, total={n1+n2+n3+n4}")
