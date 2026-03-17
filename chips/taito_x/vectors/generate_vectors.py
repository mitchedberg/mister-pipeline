#!/usr/bin/env python3
"""
generate_vectors.py — X1-001A Phase 1 test vector generator.

Produces gate1_vectors.jsonl and gate4_vectors.jsonl.

Gate 1: Sprite Y RAM read/write (byte-enables, address range, scanner port)
Gate 4: All three RAMs + control register decode + frame_bank computation

Naming follows the gate1/gate4 convention from tc0370mso.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from x1001a_model import X1001APhase1

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


if __name__ == '__main__':
    gen_gate1()
    gen_gate4()
    print("All vector files generated.")
