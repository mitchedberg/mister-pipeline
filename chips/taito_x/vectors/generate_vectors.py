#!/usr/bin/env python3
"""
generate_vectors.py — X1-001A Phase 1 + Phase 2 test vector generator.

Produces:
  gate1_vectors.jsonl  — Sprite Y RAM read/write
  gate4_vectors.jsonl  — All RAMs + control register decode + frame_bank
  gate5_vectors.jsonl  — Sprite scanner + renderer + pixel output

Gate 1: Sprite Y RAM read/write (byte-enables, address range, scanner port)
Gate 4: All three RAMs + control register decode + frame_bank computation
Gate 5: Phase 2 sprite rendering — tile fetch, flip, priority, clipping

Naming follows the gate1/gate4 convention from tc0370mso vectors.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from x1001a_model import (
    X1001APhase1, X1001APhase2, GfxROM,
    SCREEN_H, SCREEN_W, SPRITE_LIMIT, FG_NOFLIP_YOFFS, FG_NOFLIP_XOFFS
)

VEC_DIR = os.path.dirname(os.path.abspath(__file__))


def w(f, obj):
    f.write(json.dumps(obj) + '\n')


# ─── Gate 1: Y RAM read/write ─────────────────────────────────────────────────

def gen_gate1():
    """
    Gate 1 checks the sprite Y-coordinate RAM (spriteylow):
      - Basic 16-bit read/write
      - Byte-enable: write only high byte, only low byte
      - Internal scanner port reads same data as CPU write
      - Last-address boundary write
    """
    m = X1001APhase1()
    recs = []

    # Zero YRAM (model + DUT)
    recs.append({"op": "zero_yram"})
    m.yram.clear()

    # Basic word write/read
    m.cpu_yram_write(0, 0xBEEF, be=3)
    recs.append({"op": "yram_write", "addr": 0, "data": 0xBEEF, "be": 3})
    recs.append({"op": "yram_read",  "addr": 0, "exp": m.cpu_yram_read(0)})

    m.cpu_yram_write(1, 0x1234, be=3)
    recs.append({"op": "yram_write", "addr": 1, "data": 0x1234, "be": 3})
    recs.append({"op": "yram_read",  "addr": 1, "exp": m.cpu_yram_read(1)})

    # Byte-enable: write only high byte then only low byte
    m.cpu_yram_write(2, 0xFF00, be=2)
    recs.append({"op": "yram_write", "addr": 2, "data": 0xFF00, "be": 2})
    recs.append({"op": "yram_read",  "addr": 2, "exp": m.cpu_yram_read(2)})  # should be 0xFF00 (lo was 0)

    m.cpu_yram_write(2, 0x00AB, be=1)
    recs.append({"op": "yram_write", "addr": 2, "data": 0x00AB, "be": 1})
    recs.append({"op": "yram_read",  "addr": 2, "exp": m.cpu_yram_read(2)})  # should be 0xFFAB

    # Last valid word address (0x17F = 383)
    m.cpu_yram_write(0x17F, 0xA5A5, be=3)
    recs.append({"op": "yram_write", "addr": 0x17F, "data": 0xA5A5, "be": 3})
    recs.append({"op": "yram_read",  "addr": 0x17F, "exp": m.cpu_yram_read(0x17F)})

    # Scanner port reads same physical RAM
    m.cpu_yram_write(0x10, 0x5A5A, be=3)
    recs.append({"op": "yram_write",  "addr": 0x10, "data": 0x5A5A, "be": 3})
    recs.append({"op": "yram_scan_rd", "addr": 0x10, "exp": m.scan_yram_read(0x10)})

    # Overwrite with low byte only, then check both ports
    m.cpu_yram_write(0x10, 0x00CC, be=1)
    recs.append({"op": "yram_write",  "addr": 0x10, "data": 0x00CC, "be": 1})
    recs.append({"op": "yram_read",   "addr": 0x10, "exp": m.cpu_yram_read(0x10)})
    recs.append({"op": "yram_scan_rd", "addr": 0x10, "exp": m.scan_yram_read(0x10)})

    path = os.path.join(VEC_DIR, 'gate1_vectors.jsonl')
    with open(path, 'w') as f:
        for r in recs:
            w(f, r)
    checks = sum(1 for r in recs if r['op'] in ('yram_read', 'yram_scan_rd'))
    print(f"gate1: {checks} read checks → {path}")


# ─── Gate 4: Full RAM + control registers ────────────────────────────────────

def gen_gate4():
    """
    Gate 4 checks all three memories plus control register decoding:
      - Y RAM (spot checks + byte-enable)
      - Code RAM (spot checks + byte-enable + last address)
      - Control registers 0–3 (individual byte writes + read-back)
      - Decoded outputs: flip_screen, bg_startcol, bg_numcol, col_upper_mask, frame_bank
    """
    m = X1001APhase1()
    recs = []

    # ── Reset state ──────────────────────────────────────────────────────────
    recs.append({"op": "reset"})
    m.reset()

    # ── Y RAM: spot check ────────────────────────────────────────────────────
    m.cpu_yram_write(0x00, 0xCAFE, be=3)
    recs.append({"op": "yram_write", "addr": 0x00, "data": 0xCAFE, "be": 3})
    recs.append({"op": "yram_read",  "addr": 0x00, "exp": m.cpu_yram_read(0x00)})

    # High-byte-only write
    m.cpu_yram_write(0x20, 0xDE00, be=2)
    recs.append({"op": "yram_write", "addr": 0x20, "data": 0xDE00, "be": 2})
    recs.append({"op": "yram_read",  "addr": 0x20, "exp": m.cpu_yram_read(0x20)})

    # BG scroll area (word addr 0x100 = byte addr 0x200)
    m.cpu_yram_write(0x100, 0x0080, be=3)  # scrollY=0x80 for column 0
    recs.append({"op": "yram_write", "addr": 0x100, "data": 0x0080, "be": 3})
    recs.append({"op": "yram_read",  "addr": 0x100, "exp": m.cpu_yram_read(0x100)})

    # ── Code RAM: spot check ─────────────────────────────────────────────────
    m.cpu_cram_write(0x0000, 0x1234, be=3)
    recs.append({"op": "cram_write", "addr": 0x0000, "data": 0x1234, "be": 3})
    recs.append({"op": "cram_read",  "addr": 0x0000, "exp": m.cpu_cram_read(0x0000)})

    # FlipX + FlipY + tile code: 0xC000 | 0x03FF = 0xC3FF
    m.cpu_cram_write(0x00FF, 0xC3FF, be=3)
    recs.append({"op": "cram_write", "addr": 0x00FF, "data": 0xC3FF, "be": 3})
    recs.append({"op": "cram_read",  "addr": 0x00FF, "exp": m.cpu_cram_read(0x00FF)})

    # X pointer with color=31 (0xF800) and signed X=0x1E2 (=−30)
    # 0xF800 | 0x01E2 = 0xF9E2
    m.cpu_cram_write(0x0200, 0xF9E2, be=3)
    recs.append({"op": "cram_write", "addr": 0x0200, "data": 0xF9E2, "be": 3})
    recs.append({"op": "cram_read",  "addr": 0x0200, "exp": m.cpu_cram_read(0x0200)})

    # Bank B char_pointer (addr 0x1000)
    m.cpu_cram_write(0x1000, 0x8055, be=3)   # flipX=1, tile=0x55
    recs.append({"op": "cram_write", "addr": 0x1000, "data": 0x8055, "be": 3})
    recs.append({"op": "cram_read",  "addr": 0x1000, "exp": m.cpu_cram_read(0x1000)})

    # Byte-enable: write low byte only
    m.cpu_cram_write(0x0010, 0xAB00, be=2)  # hi byte = 0xAB
    m.cpu_cram_write(0x0010, 0x00CD, be=1)  # lo byte = 0xCD
    recs.append({"op": "cram_write", "addr": 0x0010, "data": 0xAB00, "be": 2})
    recs.append({"op": "cram_write", "addr": 0x0010, "data": 0x00CD, "be": 1})
    recs.append({"op": "cram_read",  "addr": 0x0010, "exp": m.cpu_cram_read(0x0010)})

    # Last code RAM word
    m.cpu_cram_write(0x1FFF, 0xDEAD, be=3)
    recs.append({"op": "cram_write", "addr": 0x1FFF, "data": 0xDEAD, "be": 3})
    recs.append({"op": "cram_read",  "addr": 0x1FFF, "exp": m.cpu_cram_read(0x1FFF)})

    # Scanner reads same code RAM
    m.cpu_cram_write(0x100, 0x9876, be=3)
    recs.append({"op": "cram_write",  "addr": 0x100, "data": 0x9876, "be": 3})
    recs.append({"op": "cram_scan_rd", "addr": 0x100, "exp": m.scan_cram_read(0x100)})

    # ── Control registers ─────────────────────────────────────────────────────

    # ctrl[0] = 0x40 → flip_screen=1, bg_startcol=0
    m.cpu_ctrl_write(0, 0x40, be=1)
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x40, "be": 1})
    recs.append({"op": "ctrl_read",  "addr": 0, "exp": m.cpu_ctrl_read(0)})
    recs.append({"op": "check_flip_screen",   "exp": m.ctrl.flip_screen})
    recs.append({"op": "check_bg_startcol",   "exp": m.ctrl.bg_startcol})

    # ctrl[0] = 0x43 → flip_screen=1, bg_startcol=3
    m.cpu_ctrl_write(0, 0x43, be=1)
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x43, "be": 1})
    recs.append({"op": "check_flip_screen",   "exp": m.ctrl.flip_screen})
    recs.append({"op": "check_bg_startcol",   "exp": m.ctrl.bg_startcol})

    # ctrl[0] = 0x00 → flip_screen=0, bg_startcol=0
    m.cpu_ctrl_write(0, 0x00, be=1)
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "check_flip_screen",   "exp": m.ctrl.flip_screen})

    # ctrl[1] = 0x01 → bg_numcol=1 (16 columns)
    m.cpu_ctrl_write(1, 0x01, be=1)
    recs.append({"op": "ctrl_write",   "addr": 1, "data": 0x01, "be": 1})
    recs.append({"op": "check_bg_numcol", "exp": m.ctrl.bg_numcol})

    # ctrl[1] = 0x00 → bg_numcol=0 (disabled), frame_bank=1
    m.cpu_ctrl_write(1, 0x00, be=1)
    recs.append({"op": "ctrl_write",      "addr": 1, "data": 0x00, "be": 1})
    recs.append({"op": "check_bg_numcol", "exp": m.ctrl.bg_numcol})
    recs.append({"op": "check_frame_bank", "exp": m.ctrl.frame_bank})

    # ctrl[1] = 0x40 → frame_bank formula result
    m.cpu_ctrl_write(1, 0x40, be=1)
    recs.append({"op": "ctrl_write",       "addr": 1, "data": 0x40, "be": 1})
    recs.append({"op": "check_frame_bank", "exp": m.ctrl.frame_bank})

    # ctrl[1] = 0xFF → frame_bank
    m.cpu_ctrl_write(1, 0xFF, be=1)
    recs.append({"op": "ctrl_write",       "addr": 1, "data": 0xFF, "be": 1})
    recs.append({"op": "check_frame_bank", "exp": m.ctrl.frame_bank})

    # ctrl[2] and ctrl[3] → col_upper_mask
    m.cpu_ctrl_write(2, 0xAB, be=1)
    m.cpu_ctrl_write(3, 0xCD, be=1)
    recs.append({"op": "ctrl_write", "addr": 2, "data": 0xAB, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 3, "data": 0xCD, "be": 1})
    recs.append({"op": "check_col_upper_mask", "exp": m.ctrl.col_upper_mask})

    # Zero all ctrl regs
    for i in range(4):
        m.cpu_ctrl_write(i, 0x00, be=1)
        recs.append({"op": "ctrl_write", "addr": i, "data": 0x00, "be": 1})
    recs.append({"op": "check_col_upper_mask", "exp": m.ctrl.col_upper_mask})
    recs.append({"op": "check_frame_bank",     "exp": m.ctrl.frame_bank})

    path = os.path.join(VEC_DIR, 'gate4_vectors.jsonl')
    with open(path, 'w') as f:
        for r in recs:
            w(f, r)
    checks = sum(1 for r in recs if r['op'].startswith('check_') or
                 r['op'] in ('yram_read', 'cram_read', 'yram_scan_rd', 'cram_scan_rd', 'ctrl_read'))
    print(f"gate4: {checks} checks → {path}")


# ─── Gate 5: Phase 2 sprite rendering ─────────────────────────────────────────

def make_solid_tile(gfx_rom, tile_code, color_idx):
    """Load a 16×16 solid-color tile (all pixels = color_idx) into the GFX ROM."""
    base = tile_code * 64
    nibble = color_idx & 0xF
    word = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
    for row in range(16):
        for wrd in range(4):
            gfx_rom[base + row * 4 + wrd] = word
    return word


def make_striped_tile(gfx_rom, tile_code, colors):
    """
    Load a tile with a different color per column (for testing flipx).
    colors[px] = 4-bit color for pixel px (0..15).
    """
    base = tile_code * 64
    for row in range(16):
        for wrd in range(4):
            word = 0
            for n in range(4):
                px = wrd * 4 + n
                word = (word << 4) | (colors[px] & 0xF)
            gfx_rom[base + row * 4 + wrd] = word
    return gfx_rom


def make_gradient_tile(gfx_rom, tile_code):
    """
    Load a tile where pixel (row, col) has color = (row + 1) so rows are
    distinguishable (for testing flipy).
    Row 0 → all pixels = 1, row 1 → 2, ..., row 15 → 0 (wrap).
    """
    base = tile_code * 64
    for row in range(16):
        nibble = (row + 1) & 0xF
        word = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
        for wrd in range(4):
            gfx_rom[base + row * 4 + wrd] = word


def sprite_screen_y(sy_raw, yoffs=FG_NOFLIP_YOFFS, screen_h=SCREEN_H):
    """Compute sprite top-row screen Y from raw Y byte."""
    sy_eff = (sy_raw + yoffs) & 0xFF
    return screen_h - sy_eff


def raw_y_for_screen_y(screen_y_top, yoffs=FG_NOFLIP_YOFFS, screen_h=SCREEN_H):
    """Compute raw Y byte so that sprite top row is at screen_y_top."""
    # screen_y_top = SCREEN_H - ((sy + yoffs) & 0xFF)
    # (sy + yoffs) & 0xFF = SCREEN_H - screen_y_top
    # sy = (SCREEN_H - screen_y_top - yoffs) & 0xFF
    return (screen_h - screen_y_top - yoffs) & 0xFF


def gen_gate5():
    """
    Gate 5: Phase 2 sprite renderer tests.

    Test cases:
      5a. Single sprite at known position — verify 16×16 pixel block
      5b. Sprite with flipx=1 — verify pixel order reversed
      5c. Sprite with flipy=1 — verify row order reversed
      5d. Two overlapping sprites — verify priority (lower index wins)
      5e. Sprite at screen edge (left clipping)
      5f. Transparent pixels not drawn (pen 0)
    """
    m = X1001APhase2()
    recs = []
    gfx_words = {}   # addr → word value, for load_gfx_word ops

    # Helper to flush gfx ROM loads to recs
    def load_gfx(tile_code, word_val, row=None, col=None):
        """Load all 64 words for a tile (or specific row/word if specified)."""
        if row is not None and col is not None:
            addr = tile_code * 64 + row * 4 + col
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word_val})
        else:
            # Load entire tile (all rows × 4 words)
            nibble = word_val & 0xF
            word = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
            base = tile_code * 64
            for r in range(16):
                for wrd in range(4):
                    addr = base + r * 4 + wrd
                    if addr not in gfx_words or gfx_words[addr] != word:
                        gfx_words[addr] = word
                        recs.append({"op": "load_gfx_word", "addr": addr, "data": word})

    # Helper to set a sprite
    def set_sprite(idx, tile, color, sx, sy_raw, flipx=False, flipy=False):
        """Write sprite idx's entries to CRAM and YRAM."""
        char_word = (tile & 0x3FFF) | (0x8000 if flipx else 0) | (0x4000 if flipy else 0)
        x_word    = ((color & 0x1F) << 11) | (sx & 0x1FF)
        # sy byte: word address = idx // 2, lo byte if even, hi byte if odd
        word_addr = idx >> 1
        recs.append({"op": "cram_write", "addr": idx,       "data": char_word, "be": 3})
        recs.append({"op": "cram_write", "addr": 0x200+idx, "data": x_word,    "be": 3})
        if idx & 1:
            # odd sprite: high byte of word
            recs.append({"op": "yram_write", "addr": word_addr,
                         "data": (sy_raw & 0xFF) << 8, "be": 2})
        else:
            # even sprite: low byte of word
            recs.append({"op": "yram_write", "addr": word_addr,
                         "data": sy_raw & 0xFF, "be": 1})

    # Helper to make sprite invisible (tile 0 = transparent, color 0)
    def hide_sprite(idx):
        char_word = 0x0000   # tile 0, no flip
        x_word    = 0x0000   # color 0, sx 0
        word_addr = idx >> 1
        recs.append({"op": "cram_write", "addr": idx,       "data": char_word, "be": 3})
        recs.append({"op": "cram_write", "addr": 0x200+idx, "data": x_word,    "be": 3})
        if idx & 1:
            recs.append({"op": "yram_write", "addr": word_addr,
                         "data": 0xFF00, "be": 2})
        else:
            recs.append({"op": "yram_write", "addr": word_addr,
                         "data": 0x00FF, "be": 1})

    # ── Reset DUT ────────────────────────────────────────────────────────────
    recs.append({"op": "reset"})
    m.reset()

    # ── Set ctrl: flip_screen=0, frame_bank=0 ────────────────────────────────
    # ctrl[0] = 0x00: flip_screen=0
    # ctrl[1] = 0x40: frame_bank=0
    m.cpu_ctrl_write(0, 0x00, be=1)
    m.cpu_ctrl_write(1, 0x40, be=1)
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})

    # ── Tile 0: transparent (all nibbles = 0, already the default) ───────────
    # Tile 1: solid color 7
    # Tile 2: striped (each column has its color index = column number + 1)
    # Tile 3: gradient by row

    TILE_TRANSPARENT = 0
    TILE_SOLID_7     = 1
    TILE_STRIPED     = 2
    TILE_GRADIENT    = 3
    TILE_SOLID_11    = 4   # color index 11 (for priority test)

    # Load tile 1: solid color 7
    for row in range(16):
        for wrd in range(4):
            addr = TILE_SOLID_7 * 64 + row * 4 + wrd
            data = 0x7777  # all nibbles = 7
            recs.append({"op": "load_gfx_word", "addr": addr, "data": data})
            m.gfx.write_word(addr, data)

    # Load tile 2: striped — pixel p has color (p % 15) + 1 (1..15, non-transparent)
    stripe_colors = [(p % 15) + 1 for p in range(16)]
    for row in range(16):
        for wrd in range(4):
            word = 0
            for n in range(4):
                word = (word << 4) | stripe_colors[wrd * 4 + n]
            addr = TILE_STRIPED * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.gfx.write_word(addr, word)

    # Load tile 3: gradient by row (row r → color r+1, wraps)
    for row in range(16):
        nibble = (row + 1) & 0xF
        word   = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
        for wrd in range(4):
            addr = TILE_GRADIENT * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.gfx.write_word(addr, word)

    # Load tile 4: solid color 11
    for row in range(16):
        for wrd in range(4):
            addr = TILE_SOLID_11 * 64 + row * 4 + wrd
            data = 0xBBBB  # all nibbles = 11
            recs.append({"op": "load_gfx_word", "addr": addr, "data": data})
            m.gfx.write_word(addr, data)

    # Hide all sprites
    for i in range(512):
        hide_sprite(i)
        # Also update model
        word_addr = i >> 1
        if i & 1:
            m.yram.write(word_addr, 0xFF00, be=2)
        else:
            m.yram.write(word_addr, 0x00FF, be=1)
        m.cram.write(i, 0x0000, be=3)
        m.cram.write(0x200 + i, 0x0000, be=3)
    m.cpu_ctrl_write(0, 0x00, be=1)
    m.cpu_ctrl_write(1, 0x40, be=1)

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5a: Single sprite at known position
    # ═══════════════════════════════════════════════════════════════════════════
    # Place sprite 0 (highest priority) using TILE_SOLID_7, color=7, at sx=50, screen_y_top=100
    sx_5a     = 50
    sy_top_5a = 100
    sy_raw_5a = raw_y_for_screen_y(sy_top_5a)

    set_sprite(0, TILE_SOLID_7, 7, sx_5a, sy_raw_5a)
    m.cram.write(0, TILE_SOLID_7, be=3)
    m.cram.write(0x200, (7 << 11) | (sx_5a & 0x1FF), be=3)
    m.yram.write(0, sy_raw_5a, be=1)

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # Check top-left pixel of sprite
    v, c = m.get_pixel(sx_5a, sy_top_5a)
    recs.append({"op": "check_pixel", "x": sx_5a, "y": sy_top_5a,
                 "exp_color": c, "exp_valid": int(v)})

    # Check bottom-right pixel (last pixel of tile = sx+15, sy_top+15)
    v, c = m.get_pixel(sx_5a + 15, sy_top_5a + 15)
    recs.append({"op": "check_pixel", "x": sx_5a + 15, "y": sy_top_5a + 15,
                 "exp_color": c, "exp_valid": int(v)})

    # Check pixel just outside (right edge + 1) — should be transparent
    v_out, _ = m.get_pixel(sx_5a + 16, sy_top_5a)
    assert not v_out, "pixel just outside sprite should be transparent"
    recs.append({"op": "check_pixel", "x": sx_5a + 16, "y": sy_top_5a,
                 "exp_color": 0, "exp_valid": 0})

    # Check pixel just outside (above) — should be transparent
    v_out, _ = m.get_pixel(sx_5a, sy_top_5a - 1)
    assert not v_out, "pixel above sprite should be transparent"
    recs.append({"op": "check_pixel", "x": sx_5a, "y": sy_top_5a - 1,
                 "exp_color": 0, "exp_valid": 0})

    print(f"  5a: sprite at ({sx_5a},{sy_top_5a}) color=7 verified")

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5b: Sprite with flipx=1 — TILE_STRIPED, verify pixel order reversed
    # ═══════════════════════════════════════════════════════════════════════════
    # Hide sprite 0 and place a new one with flipx
    hide_sprite(0)
    m.cram.write(0, 0x0000, be=3)
    m.cram.write(0x200, 0x0000, be=3)

    sx_5b     = 80
    sy_top_5b = 60
    sy_raw_5b = raw_y_for_screen_y(sy_top_5b)

    # flipx=1: set sprite 0 with TILE_STRIPED, color=1, flipx=True
    set_sprite(0, TILE_STRIPED, 1, sx_5b, sy_raw_5b, flipx=True)
    m.cram.write(0, TILE_STRIPED | 0x8000, be=3)   # flipx
    m.cram.write(0x200, (1 << 11) | (sx_5b & 0xFF), be=3)
    m.yram.write(0, sy_raw_5b, be=1)

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # With flipx, pixel 0 should show the color from position 15 of the tile
    # stripe_colors[15] = (15 % 15) + 1 = 1
    # stripe_colors[14] = (14 % 15) + 1 = 15
    # With flipx: screen pixel 0 = tile pixel 15 = stripe_colors[15] = 1
    # screen pixel 1 = tile pixel 14 = 15
    v0, c0 = m.get_pixel(sx_5b, sy_top_5b)
    v1, c1 = m.get_pixel(sx_5b + 1, sy_top_5b)
    recs.append({"op": "check_pixel", "x": sx_5b, "y": sy_top_5b,
                 "exp_color": c0, "exp_valid": int(v0)})
    recs.append({"op": "check_pixel", "x": sx_5b + 1, "y": sy_top_5b,
                 "exp_color": c1, "exp_valid": int(v1)})

    # Verify that the colors are in reversed order compared to the stripe
    # (model guarantees this; we just check the DUT matches the model)
    print(f"  5b: flipx sprite: screen_px0=color{c0}, screen_px1=color{c1}")

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5c: Sprite with flipy=1 — TILE_GRADIENT, verify row order reversed
    # ═══════════════════════════════════════════════════════════════════════════
    hide_sprite(0)
    m.cram.write(0, 0x0000, be=3)
    m.cram.write(0x200, 0x0000, be=3)

    sx_5c     = 120
    sy_top_5c = 80
    sy_raw_5c = raw_y_for_screen_y(sy_top_5c)

    set_sprite(0, TILE_GRADIENT, 2, sx_5c, sy_raw_5c, flipy=True)
    m.cram.write(0, TILE_GRADIENT | 0x4000, be=3)   # flipy
    m.cram.write(0x200, (2 << 11) | (sx_5c & 0xFF), be=3)
    m.yram.write(0, sy_raw_5c, be=1)

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # With flipy: row 0 on screen = tile row 15 = color 0 (wraps: (15+1)&0xF = 0)
    # But color 0 is transparent! So top row should be transparent.
    # Row 1 on screen = tile row 14 = color 15
    # Row 2 on screen = tile row 13 = color 14
    v_r0, c_r0 = m.get_pixel(sx_5c, sy_top_5c)       # row 0
    v_r1, c_r1 = m.get_pixel(sx_5c, sy_top_5c + 1)   # row 1
    recs.append({"op": "check_pixel", "x": sx_5c, "y": sy_top_5c,
                 "exp_color": c_r0, "exp_valid": int(v_r0)})
    recs.append({"op": "check_pixel", "x": sx_5c, "y": sy_top_5c + 1,
                 "exp_color": c_r1, "exp_valid": int(v_r1)})
    print(f"  5c: flipy sprite: row0=color{c_r0 if v_r0 else 'transparent'}, row1=color{c_r1}")

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5d: Two overlapping sprites — priority (lower index wins)
    # ═══════════════════════════════════════════════════════════════════════════
    hide_sprite(0)
    m.cram.write(0, 0x0000, be=3)
    m.cram.write(0x200, 0x0000, be=3)

    sx_5d     = 160
    sy_top_5d = 120

    # Sprite 1 (lower priority): TILE_SOLID_11, color=11
    sy_raw_5d_1 = raw_y_for_screen_y(sy_top_5d)
    set_sprite(1, TILE_SOLID_11, 11, sx_5d, sy_raw_5d_1)
    m.cram.write(1, TILE_SOLID_11, be=3)
    m.cram.write(0x201, (11 << 11) | (sx_5d & 0xFF), be=3)
    m.yram.write(0, sy_raw_5d_1, be=2)   # odd index 1 → hi byte of word 0

    # Sprite 0 (higher priority): TILE_SOLID_7, color=7, same position
    set_sprite(0, TILE_SOLID_7, 7, sx_5d, sy_raw_5d_1)
    m.cram.write(0, TILE_SOLID_7, be=3)
    m.cram.write(0x200, (7 << 11) | (sx_5d & 0xFF), be=3)
    m.yram.write(0, sy_raw_5d_1, be=1)   # even index 0 → lo byte of word 0

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # At the overlap area, sprite 0 (higher priority) should win → color=7
    v, c = m.get_pixel(sx_5d, sy_top_5d)
    recs.append({"op": "check_pixel", "x": sx_5d, "y": sy_top_5d,
                 "exp_color": c, "exp_valid": int(v)})
    assert v and c == 7, f"Priority test: expected color=7 (sprite 0 wins), got valid={v} color={c}"
    print(f"  5d: priority test: overlapping sprites → color={c} (expected 7)")

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5e: Sprite at left screen edge (clipping)
    # ═══════════════════════════════════════════════════════════════════════════
    hide_sprite(0)
    hide_sprite(1)
    m.cram.write(0, 0x0000, be=3)
    m.cram.write(0x200, 0x0000, be=3)
    m.cram.write(1, 0x0000, be=3)
    m.cram.write(0x201, 0x0000, be=3)

    # Place sprite 0 with sx=-8 (so left half is off-screen, right half visible)
    # sx = -8 means x_word & 0x0100 is set (negative), x_word & 0x00FF = 0xF8
    # sx = (0xF8) - (0x100) = 248 - 256 = -8
    sx_raw_5e  = 0x1F8   # bit8=1, bits7:0=0xF8 → sx = 0xF8 - 0x100 = -8
    sx_5e      = -8
    sy_top_5e  = 140
    sy_raw_5e  = raw_y_for_screen_y(sy_top_5e)

    # Encode in x_word: [8]=sign, [7:0]=low
    x_word_5e = (5 << 11) | (sx_raw_5e & 0x1FF)  # color=5, sx=-8

    set_sprite(0, TILE_SOLID_7, 5, sx_raw_5e & 0x1FF, sy_raw_5e)
    recs[-4:]  # undo the last hide_sprite writes for sprite 0
    # Actually just write directly:
    recs.append({"op": "cram_write", "addr": 0,     "data": TILE_SOLID_7, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": x_word_5e,    "be": 3})
    recs.append({"op": "yram_write", "addr": 0,     "data": sy_raw_5e,    "be": 1})

    m.cram.write(0, TILE_SOLID_7, be=3)
    m.cram.write(0x200, x_word_5e, be=3)
    m.yram.write(0, sy_raw_5e, be=1)

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # Pixel at x=0 should be visible (sx=-8, so screen_x = -8+8 = 0)
    v_x0, c_x0 = m.get_pixel(0, sy_top_5e)
    recs.append({"op": "check_pixel", "x": 0, "y": sy_top_5e,
                 "exp_color": c_x0, "exp_valid": int(v_x0)})

    # Pixel at x=-1 would be off-screen (can't check, should be clipped)
    # Pixel at x=7 (last visible pixel of right half): screen_x = -8+15 = 7
    v_x7, c_x7 = m.get_pixel(7, sy_top_5e)
    recs.append({"op": "check_pixel", "x": 7, "y": sy_top_5e,
                 "exp_color": c_x7, "exp_valid": int(v_x7)})

    print(f"  5e: clipped sprite: x=0 valid={v_x0} color={c_x0}, x=7 valid={v_x7}")

    # ═══════════════════════════════════════════════════════════════════════════
    # Test 5f: Transparent pixels (tile 0 = all nibbles 0) not drawn
    # ═══════════════════════════════════════════════════════════════════════════
    # Make tile 5 have a mix: first 8 pixels transparent (0), last 8 = color 6
    TILE_HALF_TRANS = 5
    for row in range(16):
        for wrd in range(4):
            word = 0x6666 if wrd >= 2 else 0x0000   # first 2 words = transparent, last 2 = color 6
            addr = TILE_HALF_TRANS * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.gfx.write_word(addr, word)

    hide_sprite(0)
    m.cram.write(0, 0x0000, be=3)
    m.cram.write(0x200, 0x0000, be=3)

    sx_5f     = 200
    sy_top_5f = 50
    sy_raw_5f = raw_y_for_screen_y(sy_top_5f)

    recs.append({"op": "cram_write", "addr": 0,     "data": TILE_HALF_TRANS, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (6 << 11) | (sx_5f & 0xFF), "be": 3})
    recs.append({"op": "yram_write", "addr": 0,     "data": sy_raw_5f, "be": 1})

    m.cram.write(0, TILE_HALF_TRANS, be=3)
    m.cram.write(0x200, (6 << 11) | (sx_5f & 0xFF), be=3)
    m.yram.write(0, sy_raw_5f, be=1)

    recs.append({"op": "run_frame"})
    m.render_frame()
    m.swap_banks()

    # Pixels 0..7 should be transparent (nibble=0)
    v_t, _ = m.get_pixel(sx_5f, sy_top_5f)
    recs.append({"op": "check_pixel", "x": sx_5f, "y": sy_top_5f,
                 "exp_color": 0, "exp_valid": 0})

    # Pixel 8 should be visible (color=6)
    v_v, c_v = m.get_pixel(sx_5f + 8, sy_top_5f)
    recs.append({"op": "check_pixel", "x": sx_5f + 8, "y": sy_top_5f,
                 "exp_color": c_v, "exp_valid": int(v_v)})

    print(f"  5f: transparent pixels: px0 valid={v_t} (expected 0), px8 valid={v_v} color={c_v}")

    # Write vectors
    path = os.path.join(VEC_DIR, 'gate5_vectors.jsonl')
    with open(path, 'w') as f:
        for r in recs:
            w(f, r)
    checks = sum(1 for r in recs if r['op'] == 'check_pixel')
    print(f"gate5: {checks} pixel checks → {path}")
    return checks


if __name__ == '__main__':
    gen_gate1()
    gen_gate4()
    n5 = gen_gate5()
    print(f"All vector files generated. Phase 2: {n5} pixel checks.")
