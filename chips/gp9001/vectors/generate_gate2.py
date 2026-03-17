#!/usr/bin/env python3
"""
generate_gate2.py — GP9001 Gate 2 test vector generator.

Produces gate2_vectors.jsonl covering:

  1. Single visible sprite (forward scan, scan_max=64)
  2. Three visible sprites mixed with null sprites (scan_max=64)
  3. Null sentinel (y==0x100) → invisible, not in display list
  4. scan_max limits: code=3 (32 slots), code>=4 (16 slots)
  5. Reverse scan order (SPRITE_CTRL[6]=1) — back-to-front ordering
  6. All 16 slots visible (scan_max=16, code=4)
  7. irq_sprite and display_list_ready pulse after scan
  8. Gate 1 scroll registers unchanged after scanner runs

Notes on addressing:
  The RTL's CPU decode maps addr[9:8]==2'b01 to sprite RAM.
  The testbench write_sram uses addr = 0x100 | (flat_word_index & 0xFF).
  The scanner reads from sram[{2'b01, slot[5:0], 2'b00..11}].
  These agree for slots 0..63 (flat word indices 0..255):
    slot s, word w → flat index s*4+w → sram[0x100 + s*4+w]
  Therefore all test scenarios use sprite slots 0..63 only.

  scan_max caps at 64 regardless of sprite_list_len_code 0..2.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate2_model import GP9001ScannerModel, SpriteEntry, Y_NULL_SENTINEL

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate2_vectors.jsonl')

# SPRITE_CTRL bit fields
# bits [15:12] = sprite_list_len_code
# bit  [6]     = reverse scan (sprite_sort_mode bit 0)
def make_sprite_ctrl(len_code: int, reverse: bool = False) -> int:
    return ((len_code & 0xF) << 12) | (int(reverse) << 6)


def generate():
    recs = []
    check_count = 0

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ──────────────────────────────────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────────────────────────────────

    def reset_and_setup(sprite_ctrl_val: int):
        """Reset DUT, write SPRITE_CTRL to shadow, pulse vsync to stage it."""
        add({"op": "reset"})
        add({"op": "write_reg", "addr": 0x0A, "data": sprite_ctrl_val})
        add({"op": "vsync_pulse"})

    def write_sprite(slot: int, y: int, tile: int,
                     flip_x: int, flip_y: int, priority: int,
                     x: int, palette: int, size: int):
        """Emit write_sram ops for one sprite slot's 4 words (slots 0..63)."""
        assert 0 <= slot <= 63, f"slot {slot} out of range 0..63"
        assert y != Y_NULL_SENTINEL or True, "use write_null_sprite for invisible"
        w0 = y & 0x1FF
        w1 = (tile & 0x3FF) | ((flip_x & 1) << 10) | ((flip_y & 1) << 11) | ((priority & 1) << 15)
        w2 = x & 0x1FF
        w3 = (palette & 0xF) | ((size & 0x3) << 4)
        base = slot * 4   # flat word index 0..255 for slot 0..63
        for wi, wv in enumerate([w0, w1, w2, w3]):
            add({"op": "write_sram", "addr": base + wi, "data": wv})

    def write_null_sprite(slot: int):
        """Mark a sprite slot as invisible (y = 0x100)."""
        assert 0 <= slot <= 63
        base = slot * 4
        add({"op": "write_sram", "addr": base + 0, "data": Y_NULL_SENTINEL})
        add({"op": "write_sram", "addr": base + 1, "data": 0x0000})
        add({"op": "write_sram", "addr": base + 2, "data": 0x0000})
        add({"op": "write_sram", "addr": base + 3, "data": 0x0000})

    def null_all(n_slots: int):
        """Null out slots 0..n_slots-1."""
        for si in range(n_slots):
            write_null_sprite(si)

    def model_write_sprite(m: GP9001ScannerModel, slot: int,
                           y: int, tile: int,
                           flip_x: int, flip_y: int, priority: int,
                           x: int, palette: int, size: int):
        """Write sprite data into model (flat word indices)."""
        w0 = y & 0x1FF
        w1 = (tile & 0x3FF) | ((flip_x & 1) << 10) | ((flip_y & 1) << 11) | ((priority & 1) << 15)
        w2 = x & 0x1FF
        w3 = (palette & 0xF) | ((size & 0x3) << 4)
        base = slot * 4
        m.write_sprite_raw(base + 0, w0)
        m.write_sprite_raw(base + 1, w1)
        m.write_sprite_raw(base + 2, w2)
        m.write_sprite_raw(base + 3, w3)

    def model_null(m: GP9001ScannerModel, slot: int):
        base = slot * 4
        m.write_sprite_raw(base + 0, Y_NULL_SENTINEL)
        m.write_sprite_raw(base + 1, 0)
        m.write_sprite_raw(base + 2, 0)
        m.write_sprite_raw(base + 3, 0)

    def check_dl_entry(dl_list, idx: int):
        """Emit a check_dl_entry op for display_list[idx]."""
        e = dl_list[idx]
        chk({
            "op":       "check_dl_entry",
            "idx":      idx,
            "x":        e.x,
            "y":        e.y,
            "tile_num": e.tile_num,
            "flip_x":   int(e.flip_x),
            "flip_y":   int(e.flip_y),
            "priority": int(e.priority),
            "palette":  e.palette,
            "size":     e.size,
            "valid":    int(e.valid),
        })

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: Single visible sprite at slot 0, scan_max=64 (code=0)
    # Expected: display_list[0] has the sprite; count=1; irq and ready pulse
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=0)   # scan_max=64, forward
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    # Null all 64 slots
    null_all(64)
    for si in range(64): model_null(m, si)

    # Write sprite 0 as visible
    write_sprite(0, y=50, tile=0x123, flip_x=1, flip_y=0, priority=1, x=100, palette=0xA, size=1)
    model_write_sprite(m, 0, y=50, tile=0x123, flip_x=1, flip_y=0, priority=1, x=100, palette=0xA, size=1)

    # Trigger scan
    add({"op": "vblank_pulse", "scan_max": 64})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    check_dl_entry(dl, 0)
    chk({"op": "check_dl_entry_valid", "idx": 1, "exp": 0})   # entry 1 not valid

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Three visible sprites in slots 0, 5, 10; rest null; scan_max=64
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=0)
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(64)
    for si in range(64): model_null(m, si)

    write_sprite(0,  y=10, tile=0x001, flip_x=0, flip_y=0, priority=0, x=20,  palette=1, size=0)
    write_sprite(5,  y=30, tile=0x055, flip_x=1, flip_y=1, priority=1, x=60,  palette=3, size=2)
    write_sprite(10, y=50, tile=0x0AA, flip_x=0, flip_y=1, priority=0, x=100, palette=7, size=3)
    model_write_sprite(m, 0,  y=10, tile=0x001, flip_x=0, flip_y=0, priority=0, x=20,  palette=1, size=0)
    model_write_sprite(m, 5,  y=30, tile=0x055, flip_x=1, flip_y=1, priority=1, x=60,  palette=3, size=2)
    model_write_sprite(m, 10, y=50, tile=0x0AA, flip_x=0, flip_y=1, priority=0, x=100, palette=7, size=3)

    add({"op": "vblank_pulse", "scan_max": 64})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 3
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    for i in range(count):
        check_dl_entry(dl, i)
    chk({"op": "check_dl_entry_valid", "idx": count, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: Null sentinel boundary test
    # Slot 0: y=0x100 → invisible
    # Slot 1: y=0x0FF → visible (just below sentinel)
    # Slot 2: y=0x101 → visible (above sentinel, 9-bit != 0x100)
    # scan_max=16 (code=4)
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=4)   # scan_max=16
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(16)
    for si in range(16): model_null(m, si)

    # Slot 0: invisible (y = sentinel)
    write_null_sprite(0)
    model_null(m, 0)

    # Slot 1: visible (y = 0xFF)
    write_sprite(1, y=0xFF, tile=0x00A, flip_x=0, flip_y=0, priority=0, x=5, palette=0, size=0)
    model_write_sprite(m, 1, y=0xFF, tile=0x00A, flip_x=0, flip_y=0, priority=0, x=5, palette=0, size=0)

    # Slot 2: visible (y = 0x101, which is 257 in 9-bit ≠ 0x100=256)
    write_sprite(2, y=0x101 & 0x1FF, tile=0x020, flip_x=0, flip_y=0, priority=0, x=10, palette=0, size=0)
    model_write_sprite(m, 2, y=0x101 & 0x1FF, tile=0x020, flip_x=0, flip_y=0, priority=0, x=10, palette=0, size=0)

    add({"op": "vblank_pulse", "scan_max": 16})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 2
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    check_dl_entry(dl, 0)   # slot 1's data
    check_dl_entry(dl, 1)   # slot 2's data
    chk({"op": "check_dl_entry_valid", "idx": 2, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: scan_max=32 (len_code=3) — only first 32 slots scanned
    # Place a visible sprite at slot 31 (last in range) and slot 32 (out of range)
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=3)   # scan_max=32
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(64)
    for si in range(64): model_null(m, si)

    # Sprite at slot 31 (within range)
    write_sprite(31, y=42, tile=0x100, flip_x=0, flip_y=0, priority=0, x=80, palette=5, size=1)
    model_write_sprite(m, 31, y=42, tile=0x100, flip_x=0, flip_y=0, priority=0, x=80, palette=5, size=1)

    # Sprite at slot 32 (OUTSIDE scan range — should not appear in display list)
    write_sprite(32, y=99, tile=0x200, flip_x=0, flip_y=0, priority=0, x=200, palette=7, size=0)
    # Do NOT add to model (model only scans 32 slots for code=3)

    add({"op": "vblank_pulse", "scan_max": 32})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 1 (only slot 31)
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    check_dl_entry(dl, 0)
    chk({"op": "check_dl_entry_valid", "idx": 1, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: scan_max=16 (len_code=4) — 2 sprites in range, 1 outside
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=4)
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(64)
    for si in range(64): model_null(m, si)

    write_sprite(0,  y=5,   tile=0x005, flip_x=1, flip_y=0, priority=1, x=10, palette=2, size=1)
    write_sprite(15, y=150, tile=0x015, flip_x=0, flip_y=1, priority=0, x=20, palette=4, size=2)
    write_sprite(16, y=200, tile=0x016, flip_x=0, flip_y=0, priority=0, x=30, palette=6, size=0)  # out of range
    model_write_sprite(m, 0,  y=5,   tile=0x005, flip_x=1, flip_y=0, priority=1, x=10, palette=2, size=1)
    model_write_sprite(m, 15, y=150, tile=0x015, flip_x=0, flip_y=1, priority=0, x=20, palette=4, size=2)
    # slot 16 not in model (out of scan range)

    add({"op": "vblank_pulse", "scan_max": 16})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 2
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    check_dl_entry(dl, 0)
    check_dl_entry(dl, 1)
    chk({"op": "check_dl_entry_valid", "idx": 2, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: Reverse scan order (SPRITE_CTRL[6]=1), scan_max=32
    # Sprites at slots 0 and 31.
    # In reverse order: slot 31 is scanned first → appears as dl[0].
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=3, reverse=True)   # scan_max=32, reverse
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(32)
    for si in range(32): model_null(m, si)

    write_sprite(0,  y=10, tile=0x010, flip_x=0, flip_y=0, priority=0, x=10, palette=1, size=0)
    write_sprite(31, y=20, tile=0x031, flip_x=1, flip_y=0, priority=1, x=20, palette=2, size=1)
    model_write_sprite(m, 0,  y=10, tile=0x010, flip_x=0, flip_y=0, priority=0, x=10, palette=1, size=0)
    model_write_sprite(m, 31, y=20, tile=0x031, flip_x=1, flip_y=0, priority=1, x=20, palette=2, size=1)

    add({"op": "vblank_pulse", "scan_max": 32})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 2
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    # Reverse scan: slot 31 appears first in display list
    check_dl_entry(dl, 0)   # dl[0] = slot 31's data
    check_dl_entry(dl, 1)   # dl[1] = slot 0's data
    chk({"op": "check_dl_entry_valid", "idx": 2, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: All 16 slots visible (scan_max=16, code=4)
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=4)
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(64)
    for si in range(64): model_null(m, si)

    for si in range(16):
        # y values chosen to avoid 0x100 (256): use si*13 & 0x1FE + 1
        y_v = (si * 13 + 1) & 0x1FF
        if y_v == Y_NULL_SENTINEL:
            y_v = 1
        x_v  = (si * 19) & 0x1FF
        t_v  = (si * 7 + 1) & 0x3FF
        p_v  = si & 0xF
        s_v  = si & 0x3
        fx   = (si & 1)
        fy   = ((si >> 1) & 1)
        pri  = ((si >> 2) & 1)
        write_sprite(si, y=y_v, tile=t_v, flip_x=fx, flip_y=fy, priority=pri, x=x_v, palette=p_v, size=s_v)
        model_write_sprite(m, si, y=y_v, tile=t_v, flip_x=fx, flip_y=fy, priority=pri, x=x_v, palette=p_v, size=s_v)

    add({"op": "vblank_pulse", "scan_max": 16})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 16
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    for i in range(count):
        check_dl_entry(dl, i)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: No vblank — scanner stays in IDLE; display_list_ready = 0
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "reset"})
    add({"op": "write_reg", "addr": 0x0A, "data": make_sprite_ctrl(len_code=4)})
    add({"op": "vsync_pulse"})
    # Do NOT pulse vblank — only vsync (Gate 1 staging)
    add({"op": "vsync_pulse"})
    # display_list_count should still be 0 (reset value, no vblank triggered)
    chk({"op": "check_dl_count", "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: Gate 1 registers intact after scanner ran
    # Write a scroll register, run scanner, verify scroll unchanged
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=3)   # 32 slots
    reset_and_setup(sc_val)
    # Also set a scroll register
    add({"op": "write_reg", "addr": 0x00, "data": 0xABCD})   # SCROLL0_X
    add({"op": "vsync_pulse"})

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(32)
    for si in range(32): model_null(m, si)

    # 3 visible sprites in slots 0, 10, 20
    for si_idx, (slot, y_v, tile_v, x_v) in enumerate([
        (0,  5,  0x005, 5),
        (10, 50, 0x050, 50),
        (20, 99, 0x099, 99),
    ]):
        write_sprite(slot, y=y_v, tile=tile_v, flip_x=0, flip_y=0, priority=0, x=x_v, palette=si_idx, size=0)
        model_write_sprite(m, slot, y=y_v, tile=tile_v, flip_x=0, flip_y=0, priority=0, x=x_v, palette=si_idx, size=0)

    add({"op": "vblank_pulse", "scan_max": 32})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 3
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    for i in range(count):
        check_dl_entry(dl, i)

    # Verify Gate 1 scroll register still intact after scanner ran
    chk({"op": "check_scroll", "layer": 0, "axis": "x", "exp": 0xABCD})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: All fields decoded correctly — palette, size, flip combinations
    # ══════════════════════════════════════════════════════════════════════════
    sc_val = make_sprite_ctrl(len_code=4)   # 16 slots
    reset_and_setup(sc_val)

    m = GP9001ScannerModel()
    m.sprite_ctrl = sc_val

    null_all(16)
    for si in range(16): model_null(m, si)

    # One sprite with all field combinations
    write_sprite(0, y=0x0FF, tile=0x3FF, flip_x=1, flip_y=1, priority=1, x=0x1FF, palette=0xF, size=3)
    model_write_sprite(m, 0, y=0x0FF, tile=0x3FF, flip_x=1, flip_y=1, priority=1, x=0x1FF, palette=0xF, size=3)

    write_sprite(1, y=0x001, tile=0x000, flip_x=0, flip_y=0, priority=0, x=0x000, palette=0x0, size=0)
    model_write_sprite(m, 1, y=0x001, tile=0x000, flip_x=0, flip_y=0, priority=0, x=0x000, palette=0x0, size=0)

    add({"op": "vblank_pulse", "scan_max": 16})
    dl, count = m.run_scan()

    chk({"op": "check_dl_count", "exp": count})   # 2
    chk({"op": "check_dl_ready_pulse"})
    chk({"op": "check_irq_pulse"})
    check_dl_entry(dl, 0)   # max values
    check_dl_entry(dl, 1)   # min values

    # ──────────────────────────────────────────────────────────────────────────
    # Write output
    # ──────────────────────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate2: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
