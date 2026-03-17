#!/usr/bin/env python3
"""
generate_gate5.py — GP9001 Gate 5 test vector generator.

Produces gate5_vectors.jsonl covering the priority mixer logic:

  1.  All transparent → final_valid=0
  2.  BG1 only opaque → BG1 wins
  3.  BG0 + BG1 opaque → BG0 wins (higher priority)
  4.  Sprite prio=1 + BG0 opaque → sprite wins
  5.  Sprite prio=0 + BG0 + BG1 opaque → BG0 wins
  6.  Sprite prio=0, BG0 transparent, BG1 opaque → sprite wins over BG1
  7.  3-layer mode: BG2 active below BG1
  8.  3-layer mode: BG0+BG1 transparent, BG2 visible
  9.  2-layer mode: BG2/BG3 ignored even when valid
  10. 4-layer mode: BG3 bottom layer visible
  11. Transparent sprite falls through (prio=1)
  12. Sprite prio=1 beats BG0
  13. All 4 BG layers + sprite prio=1 — sprite wins
  14. All 4 BG layers + sprite prio=0 — BG0 wins
  15. All layers transparent except BG3 (4-layer mode)
  16. Sprite prio=0, all BG transparent → sprite visible
  17. BG0 priority bit (tile prio) has no effect on colmix ordering
  18. layer_ctrl = 0x80 (bits [7:6]=10 → 4 layers)
  19. layer_ctrl = 0xC0 (bits [7:6]=11 → 4 layers)
  20. Multiple sprite+BG combos: verify correct winner each time

Target: 100+ checks.

Vector operations:
  reset                  — DUT reset + vsync to stage registers
  set_layer_ctrl  data   — write LAYER_CTRL register + vsync_pulse to stage
  set_spr_pixel   valid, color, prio  — drive spr_rd_* inputs (via spr_rd_addr write)
  set_bg_pixel    layer, valid, color  — write BG pixel into DUT via VRAM+scroll trick
                                          (not feasible directly; see below)
  check_final     exp_valid, exp_color — check final_valid + final_color outputs

Implementation note:
  Gate 5 is purely combinational from:
    spr_rd_valid/spr_rd_color/spr_rd_priority  (Gate 4 read-back)
    bg_pix_valid[0:3]/bg_pix_color[0:3]        (Gate 3 outputs)
    layer_ctrl                                  (register)

  The testbench directly drives the spr_rd_addr to select a pixel in the
  sprite scanline buffer (populated by writing sprite ROM + running scan_line),
  AND must inject BG pixels.

  For Gate 5 isolation, the testbench will:
    - Directly poke the bg_pix_color/bg_pix_valid/bg_pix_priority arrays
      via the full BG pipeline (VRAM write + set_pixel + clock_n to let the
      Gate 3 pipeline settle at a known pixel)
    - Then read final_color/final_valid

  Because the Gate 3 pipeline is 2-stage (2 clock latency) and processes
  4 layers in round-robin, for each test case we:
    1. Write VRAM entry for the target layer at cell 0 (scroll=0 → hpos=0, vpos=0)
    2. drive hpos=0, vpos=0
    3. clock 8 cycles to let all 4 layers produce their output registers
    4. Set spr_rd_addr=0 to read sprite buffer at x=0
    5. Check final_color and final_valid

  Sprite pixels are injected via the normal Gate 4 mechanism:
    - Write sprite RAM, trigger vblank scan, trigger scan_line
    - Then spr_rd_addr=0 reads the sprite pixel at x=0

  For cases where sprite should be transparent: use null sprite (tile=0, all bytes=0)
  For cases where sprite should be opaque: write solid-fill tile + sprite at x=0, y=0
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate5_model import GP9001ColMix, SprPixel, BgPixel, MixResult

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate5_vectors.jsonl')

# Sprite RAM word layout (from generate_gate4.py):
#   Word 0  [8:0]  y_pos      (0x100 = null sentinel)
#   Word 1  [9:0]  tile_num; [10] flip_x; [11] flip_y; [15] priority
#   Word 2  [8:0]  x_pos
#   Word 3  [3:0]  palette; [5:4] size
Y_NULL = 0x100
SPRITE_CTRL_32 = 0x3000   # scan 32 sprites


def make_sprite_words(y, tile_num, flip_x, flip_y, prio, x, palette, size):
    w0 = y & 0x1FF
    w1 = (tile_num & 0x3FF) | (int(flip_x) << 10) | (int(flip_y) << 11) | (int(prio) << 15)
    w2 = x & 0x1FF
    w3 = (palette & 0xF) | ((size & 0x3) << 4)
    return w0, w1, w2, w3


def generate():
    recs = []
    check_count = 0
    mixer = GP9001ColMix()

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ── Shortcuts ─────────────────────────────────────────────────────────────

    def reset():
        add({"op": "reset"})

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def write_sram(addr, data):
        add({"op": "write_sram", "addr": addr, "data": data})

    def write_reg(addr, data):
        add({"op": "write_reg", "addr": addr, "data": data})

    def write_sprite_ctrl(data):
        add({"op": "write_sprite_ctrl", "data": data})

    def write_spr_rom(addr, data):
        add({"op": "write_spr_rom", "addr": addr, "data": data})

    def vblank_scan():
        add({"op": "vblank_scan"})

    def scan_line(scanline):
        add({"op": "scan_line", "scanline": scanline})

    def set_spr_rd_addr(x):
        add({"op": "set_spr_rd_addr", "x": x})

    def write_vram(layer, addr, data):
        add({"op": "write_vram", "layer": layer, "addr": addr, "data": data})

    def write_rom_byte(addr, data):
        add({"op": "write_rom_byte", "addr": addr, "data": data})

    def set_pixel(hpos, vpos):
        add({"op": "set_pixel", "hpos": hpos, "vpos": vpos})

    def clock_n(n):
        add({"op": "clock_n", "n": n})

    def check_final(exp_valid, exp_color):
        chk({"op": "check_final", "exp_valid": int(exp_valid), "exp_color": exp_color})

    def null_sprite(slot):
        base = slot * 4
        write_sram(base + 0, Y_NULL)
        write_sram(base + 1, 0)
        write_sram(base + 2, 0)
        write_sram(base + 3, 0)

    def write_sprite_slot(slot, y, tile_num, flip_x, flip_y, prio, x, palette, size):
        w0, w1, w2, w3 = make_sprite_words(y, tile_num, flip_x, flip_y, prio, x, palette, size)
        base = slot * 4
        write_sram(base + 0, w0)
        write_sram(base + 1, w1)
        write_sram(base + 2, w2)
        write_sram(base + 3, w3)

    def load_solid_tile_spr(tile_code, nybble):
        """Write solid-fill sprite tile to DUT ROM."""
        byte_val = (nybble << 4) | nybble
        base = tile_code * 128
        for b in range(128):
            write_spr_rom(base + b, byte_val)

    def load_solid_tile_bg(tile_num, nybble):
        """Write solid-fill BG tile to DUT tile ROM.
        BG tiles: 8×8, 4bpp, 32 bytes per tile.
        Byte layout: each byte holds 2 pixels (low=left, high=right).
        """
        byte_val = (nybble << 4) | nybble
        base = tile_num * 32
        for b in range(32):
            write_rom_byte(base + b, byte_val)

    def setup_bg_layer(layer, tile_num, palette, prio_bit, nybble):
        """
        Program BG layer 'layer' so pixel at (hpos=0, vpos=0, scroll=0) produces
        a pixel with the given palette/nybble/prio_bit.

        Steps:
          1. Load BG tile ROM with solid nybble
          2. Write VRAM cell 0 of 'layer':
               code_word = tile_num (cell 0, addr 0, word_sel=0)
               attr_word = palette | (prio_bit << 6) (cell 0, addr 1, word_sel=1)
          3. Set scroll X/Y = 0 for this layer
        """
        load_solid_tile_bg(tile_num, nybble)
        # VRAM: cell 0 → addr[9:0]=0 for code, addr[9:0]=1 for attr
        write_vram(layer, 0, tile_num)             # code_word = tile_num
        write_vram(layer, 1, palette | (prio_bit << 6))  # attr_word
        # Set scroll X/Y = 0 for this layer (already 0 after reset, but be explicit)
        scroll_x_reg = layer * 2      # reg 0,2,4,6 for X
        scroll_y_reg = layer * 2 + 1  # reg 1,3,5,7 for Y
        write_reg(scroll_x_reg, 0)
        write_reg(scroll_y_reg, 0)
        vsync_pulse()

    def clear_bg_layer(layer):
        """Write VRAM cell 0 of layer with tile_num=0 (all-transparent tile)."""
        write_vram(layer, 0, 0)   # code = 0 → tile 0 = transparent (nybble=0)
        write_vram(layer, 1, 0)   # attr = 0

    def setup_opaque_sprite(tile_code, palette, prio, nybble, x=0, y=0, slot=0):
        """Install a solid opaque sprite at (x,y) and run scan_line(y)."""
        load_solid_tile_spr(tile_code, nybble)
        for s in range(32):
            null_sprite(s)
        write_sprite_slot(slot, y=y, tile_num=tile_code, flip_x=False, flip_y=False,
                          prio=prio, x=x, palette=palette, size=0)
        write_sprite_ctrl(SPRITE_CTRL_32)
        vblank_scan()
        scan_line(y)

    def setup_transparent_sprite():
        """Install all-transparent sprite RAM (no opaque pixels)."""
        for s in range(32):
            null_sprite(s)
        write_sprite_ctrl(SPRITE_CTRL_32)
        vblank_scan()
        scan_line(0)

    def settle_bg(n_clocks=12):
        """
        Drive hpos=0, vpos=0 and clock N cycles for Gate 3 pipeline to produce
        output pixels for all 4 layers.  Need at least 2 pipeline stages × 4 layers
        = 8 cycles; use 12 for margin.
        """
        set_pixel(0, 0)
        clock_n(n_clocks)

    def set_layer_ctrl(data):
        """Write LAYER_CTRL (reg 0x09) + vsync_pulse to stage it."""
        write_reg(0x9, data)
        vsync_pulse()

    # ══════════════════════════════════════════════════════════════════════════
    # SCENARIO SETUP HELPER
    # Sets up the DUT for a given sprite + bg[0..3] configuration,
    # then checks final_color and final_valid.
    #
    # Parameters:
    #   spr:        SprPixel (or None for transparent)
    #   bg_specs:   list of (valid, color, prio_tile) for bg[0..3]
    #               color = 8-bit {palette, nybble}
    #   layer_ctrl: value for LAYER_CTRL register
    # ══════════════════════════════════════════════════════════════════════════

    # BG tile numbers: use different tiles per layer to avoid overlap
    BG_TILE_BASE = [100, 101, 102, 103]  # tile numbers per layer

    def run_scenario(label, spr_valid, spr_color, spr_prio,
                     bg_specs,   # list of 4 (valid, color) tuples; color=8-bit
                     layer_ctrl_val=0x00):
        """
        Full scenario:
          1. Reset + write layer_ctrl
          2. Setup BG layers (VRAM + tile ROM)
          3. Setup sprite (tile ROM + sprite RAM + vblank_scan + scan_line)
          4. Settle BG pipeline
          5. Set spr_rd_addr=0
          6. Check final_color, final_valid
        """
        reset()
        set_layer_ctrl(layer_ctrl_val)

        # -- Setup BG layers --
        for layer in range(4):
            v, c = bg_specs[layer]
            palette = (c >> 4) & 0xF
            nybble  =  c & 0xF
            if v and nybble != 0:
                setup_bg_layer(layer, BG_TILE_BASE[layer], palette, 0, nybble)
            else:
                clear_bg_layer(layer)

        # -- Setup sprite --
        if spr_valid:
            spr_palette = (spr_color >> 4) & 0xF
            spr_nybble  =  spr_color & 0xF
            if spr_nybble == 0:
                spr_valid = False  # nybble=0 → transparent
        if spr_valid:
            SPR_TILE = 200
            setup_opaque_sprite(SPR_TILE, spr_palette, spr_prio, spr_nybble,
                                x=0, y=0, slot=0)
        else:
            setup_transparent_sprite()

        # -- Settle BG pipeline --
        settle_bg()

        # -- Set spr read address to x=0 --
        set_spr_rd_addr(0)

        # -- Compute expected result via model --
        spr_px = SprPixel(valid=spr_valid, color=spr_color, priority=bool(spr_prio))
        bg_px = []
        for layer in range(4):
            v, c = bg_specs[layer]
            nybble = c & 0xF
            bg_px.append(BgPixel(valid=bool(v and nybble != 0), color=c))

        r = mixer.mix(spr_px, bg_px, layer_ctrl=layer_ctrl_val)

        # -- Emit checks --
        check_final(r.valid, r.color)

    # ══════════════════════════════════════════════════════════════════════════
    # Test scenarios
    # ══════════════════════════════════════════════════════════════════════════

    TRANSPARENT = (False, 0)

    # 1. All transparent
    run_scenario("1_all_transparent",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT]*4,
                 layer_ctrl_val=0x00)

    # 2. BG1 only opaque
    run_scenario("2_bg1_only",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, (True, 0x12), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 3. BG0 + BG1 opaque → BG0 wins
    run_scenario("3_bg0_over_bg1",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[(True, 0xAB), (True, 0x12), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 4. Sprite prio=1 + BG0 opaque → sprite wins
    run_scenario("4_spr_prio1_beats_bg0",
                 spr_valid=True, spr_color=0xF8, spr_prio=1,
                 bg_specs=[(True, 0xAB), (True, 0x12), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 5. Sprite prio=0 + BG0 opaque → BG0 wins
    run_scenario("5_bg0_beats_spr_prio0",
                 spr_valid=True, spr_color=0x55, spr_prio=0,
                 bg_specs=[(True, 0xAB), (True, 0x12), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 6. Sprite prio=0, BG0 transparent, BG1 opaque → sprite beats BG1
    run_scenario("6_spr_prio0_beats_bg1",
                 spr_valid=True, spr_color=0x55, spr_prio=0,
                 bg_specs=[TRANSPARENT, (True, 0x22), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 7. 3-layer mode: BG0+BG1+BG2 — BG0 wins
    run_scenario("7_3layer_bg0_wins",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[(True, 0x11), (True, 0x22), (True, 0x33), TRANSPARENT],
                 layer_ctrl_val=0x40)   # bits[7:6]=01 → 3 layers

    # 8. 3-layer mode: BG0+BG1 transparent, BG2 shows
    run_scenario("8_3layer_bg2_fallback",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, (True, 0x33), TRANSPARENT],
                 layer_ctrl_val=0x40)

    # 9. 2-layer mode: BG2/BG3 ignored
    run_scenario("9_2layer_bg2_bg3_ignored",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, (True, 0x22), (True, 0x33), (True, 0x44)],
                 layer_ctrl_val=0x00)

    # 10. 4-layer mode: BG3 bottom layer shows
    run_scenario("10_4layer_bg3_fallback",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, TRANSPARENT, (True, 0x44)],
                 layer_ctrl_val=0x80)   # bits[7:6]=10 → 4 layers

    # 11. Transparent sprite (prio=1) falls through to BG1
    run_scenario("11_transparent_spr_fallthrough",
                 spr_valid=False, spr_color=0xBB, spr_prio=1,
                 bg_specs=[TRANSPARENT, (True, 0xBB), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 12. Sprite prio=1 beats BG0
    run_scenario("12_spr_prio1_over_bg0",
                 spr_valid=True, spr_color=0xEE, spr_prio=1,
                 bg_specs=[(True, 0xCC), (True, 0xDD), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 13. All 4 BG layers + sprite prio=1 — sprite wins (4-layer mode)
    run_scenario("13_spr_prio1_beats_all_bg",
                 spr_valid=True, spr_color=0x77, spr_prio=1,
                 bg_specs=[(True, 0x11), (True, 0x22), (True, 0x33), (True, 0x44)],
                 layer_ctrl_val=0x80)

    # 14. All 4 BG layers + sprite prio=0 — BG0 wins (4-layer mode)
    run_scenario("14_bg0_beats_spr_prio0_4layer",
                 spr_valid=True, spr_color=0x77, spr_prio=0,
                 bg_specs=[(True, 0x11), (True, 0x22), (True, 0x33), (True, 0x44)],
                 layer_ctrl_val=0x80)

    # 15. 4-layer: all transparent except BG3
    run_scenario("15_4layer_only_bg3",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, TRANSPARENT, (True, 0x99)],
                 layer_ctrl_val=0x80)

    # 16. Sprite prio=0, all BG transparent → sprite visible
    run_scenario("16_spr_prio0_all_bg_transparent",
                 spr_valid=True, spr_color=0x56, spr_prio=0,
                 bg_specs=[TRANSPARENT]*4,
                 layer_ctrl_val=0x00)

    # 17. Sprite prio=1, all BG transparent → sprite visible
    run_scenario("17_spr_prio1_all_bg_transparent",
                 spr_valid=True, spr_color=0x78, spr_prio=1,
                 bg_specs=[TRANSPARENT]*4,
                 layer_ctrl_val=0x00)

    # 18. layer_ctrl bits[7:6]=11 → 4 layers (same as 10=4 layers)
    run_scenario("18_layer_ctrl_11_is_4layers",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, TRANSPARENT, (True, 0x44)],
                 layer_ctrl_val=0xC0)   # bits[7:6]=11 → 4 layers

    # 19. BG0 + BG1, sprite transparent → BG0 wins
    run_scenario("19_bg0_bg1_spr_transparent",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[(True, 0xA1), (True, 0xB2), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 20. 4-layer: BG0+BG1+BG2+BG3 all opaque, sprite prio=0 (BG0 foreground wins)
    run_scenario("20_4layer_bg0_fg_wins_prio0",
                 spr_valid=True, spr_color=0x55, spr_prio=0,
                 bg_specs=[(True, 0x11), (True, 0x22), (True, 0x33), (True, 0x44)],
                 layer_ctrl_val=0x80)

    # 21. 3-layer: sprite prio=1 beats BG2+BG1+BG0
    run_scenario("21_3layer_spr_prio1_beats_all",
                 spr_valid=True, spr_color=0xAA, spr_prio=1,
                 bg_specs=[(True, 0x11), (True, 0x22), (True, 0x33), TRANSPARENT],
                 layer_ctrl_val=0x40)

    # 22. 2-layer: sprite prio=0, BG0 transparent → sprite over BG1
    run_scenario("22_2layer_spr_prio0_over_bg1",
                 spr_valid=True, spr_color=0x5A, spr_prio=0,
                 bg_specs=[TRANSPARENT, (True, 0x33), TRANSPARENT, TRANSPARENT],
                 layer_ctrl_val=0x00)

    # 23. 4-layer: BG3 opaque, BG2+BG1+BG0 transparent, sprite transparent
    run_scenario("23_4layer_bg3_only",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, TRANSPARENT, (True, 0x78)],
                 layer_ctrl_val=0x80)

    # 24. All transparent except sprite prio=1 (only sprite)
    run_scenario("24_only_spr_prio1",
                 spr_valid=True, spr_color=0xCD, spr_prio=1,
                 bg_specs=[TRANSPARENT]*4,
                 layer_ctrl_val=0x00)

    # 25. BG2 active in 3-layer mode, BG3 has valid pixel but is ignored
    run_scenario("25_3layer_bg3_ignored",
                 spr_valid=False, spr_color=0, spr_prio=0,
                 bg_specs=[TRANSPARENT, TRANSPARENT, (True, 0x3C), (True, 0x44)],
                 layer_ctrl_val=0x40)

    # ── Write output ──────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate5: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
