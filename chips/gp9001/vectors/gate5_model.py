#!/usr/bin/env python3
"""
gate5_model.py — GP9001 Gate 5 behavioral model: priority mixer / color compositor.

Combines sprite pixels (from Gate 4) and BG layer pixels (from Gate 3) for
each screen position using priority rules derived from section2_behavior.md §4.1
and MAME gp9001.cpp screen_update().

Priority algorithm (painter's algorithm, lowest → highest):
  BG3 (bottom)           — active when num_layers >= 4
  BG2                    — active when num_layers >= 3
  BG1                    — always active
  Sprite (prio=0)        — below BG0, above BG1
  BG0 (foreground)       — always active
  Sprite (prio=1)        — above all BG

A pixel is opaque (participates) if its valid bit is 1.
Transparent pixels (valid=0) fall through to the layer below.

num_layers decoded from layer_ctrl[7:6]:
  2'b00 → 2 layers (BG0 + BG1)
  2'b01 → 3 layers (BG0 + BG1 + BG2)
  2'b10 → 4 layers (BG0 + BG1 + BG2 + BG3)
  2'b11 → 4 layers

References:
  section2_behavior.md §4.1 — composite_pixel() algorithm
  section3_rtl_plan.md  §5  — Gate 5 specification
  MAME src/mame/toaplan/gp9001.cpp — screen_update(), priority logic
"""

from dataclasses import dataclass
from typing import List


# ─────────────────────────────────────────────────────────────────────────────
# Data types
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class SprPixel:
    """Sprite pixel from Gate 4 scanline buffer."""
    valid:    bool = False
    color:    int  = 0    # 8-bit: {palette[3:0], index[3:0]}
    priority: bool = False


@dataclass
class BgPixel:
    """BG layer pixel from Gate 3 pipeline."""
    valid:    bool = False
    color:    int  = 0    # 8-bit: {palette[3:0], index[3:0]}
    priority: bool = False   # per-tile priority bit (not used for layer ordering here)


@dataclass
class MixResult:
    """Output of the priority mixer for one pixel position."""
    color: int  = 0      # 8-bit palette index of winning pixel
    valid: bool = False  # True if any layer contributed an opaque pixel


# ─────────────────────────────────────────────────────────────────────────────
# Priority mixer model
# ─────────────────────────────────────────────────────────────────────────────

class GP9001ColMix:
    """
    Behavioral model of the GP9001 Gate 5 priority mixer.

    Usage:
        mixer = GP9001ColMix()
        result = mixer.mix(spr, bg_pixels, layer_ctrl)
    """

    @staticmethod
    def num_active_layers(layer_ctrl: int) -> int:
        """Decode num_layers from layer_ctrl[7:6]."""
        code = (layer_ctrl >> 6) & 0x3
        if code == 0:
            return 2
        elif code == 1:
            return 3
        else:
            return 4  # 2'b10 and 2'b11 both → 4

    def mix(self,
            spr: SprPixel,
            bg: List[BgPixel],
            layer_ctrl: int = 0) -> MixResult:
        """
        Combine sprite and BG pixels using the GP9001 priority algorithm.

        Parameters:
            spr        — sprite pixel (from Gate 4 read-back)
            bg         — list of 4 BG layer pixels: bg[0]=BG0 (fg), ..., bg[3]=BG3 (bottom)
            layer_ctrl — LAYER_CTRL register value (bits [7:6] control num_layers)

        Returns MixResult with the winning pixel's color and valid flag.
        """
        num_layers = self.num_active_layers(layer_ctrl)

        # Painter's algorithm: start transparent, each higher-priority opaque
        # pixel overwrites the current winner.
        winner_color = 0
        winner_valid = False

        # BG3 — bottom of stack, active only when 4 layers
        if num_layers >= 4 and bg[3].valid:
            winner_color = bg[3].color
            winner_valid = True

        # BG2 — active when 3+ layers
        if num_layers >= 3 and bg[2].valid:
            winner_color = bg[2].color
            winner_valid = True

        # BG1 — always active
        if bg[1].valid:
            winner_color = bg[1].color
            winner_valid = True

        # Sprite with priority=0: below BG0 (foreground), above BG1
        if not spr.priority and spr.valid:
            winner_color = spr.color
            winner_valid = True

        # BG0 — foreground, always active
        if bg[0].valid:
            winner_color = bg[0].color
            winner_valid = True

        # Sprite with priority=1: above all BG layers
        if spr.priority and spr.valid:
            winner_color = spr.color
            winner_valid = True

        return MixResult(color=winner_color, valid=winner_valid)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

def _make_bg(n=4):
    return [BgPixel() for _ in range(n)]


if __name__ == '__main__':
    mixer = GP9001ColMix()

    # ── Test 1: all transparent → invalid output ───────────────────────────────
    spr = SprPixel()
    bg  = _make_bg()
    r   = mixer.mix(spr, bg)
    assert not r.valid, "T1: all transparent → valid should be False"
    assert r.color == 0, "T1: color should be 0"
    print("T1 PASS: all transparent")

    # ── Test 2: only BG1 opaque → BG1 wins ────────────────────────────────────
    bg[1] = BgPixel(valid=True, color=0x12)
    r = mixer.mix(SprPixel(), bg)
    assert r.valid,        "T2: BG1 should produce valid output"
    assert r.color == 0x12, f"T2: expected 0x12, got {r.color:#x}"
    print("T2 PASS: BG1 only")

    # ── Test 3: BG0 + BG1 opaque → BG0 wins (higher priority) ────────────────
    bg[0] = BgPixel(valid=True, color=0xAB)
    r = mixer.mix(SprPixel(), bg)
    assert r.color == 0xAB, f"T3: BG0 should win over BG1, got {r.color:#x}"
    print("T3 PASS: BG0 over BG1")

    # ── Test 4: sprite prio=1 above BG0 ──────────────────────────────────────
    spr = SprPixel(valid=True, color=0xFF, priority=True)
    r   = mixer.mix(spr, bg)
    assert r.color == 0xFF, f"T4: sprite(prio=1) should win over BG0, got {r.color:#x}"
    print("T4 PASS: sprite prio=1 above BG0")

    # ── Test 5: sprite prio=0 below BG0, above BG1 ────────────────────────────
    # BG0=0xAB, BG1=0x12, sprite=0x55 prio=0
    # Expected: BG0 wins (0xAB)
    spr = SprPixel(valid=True, color=0x55, priority=False)
    bg  = _make_bg()
    bg[0] = BgPixel(valid=True, color=0xAB)
    bg[1] = BgPixel(valid=True, color=0x12)
    r = mixer.mix(spr, bg)
    assert r.color == 0xAB, f"T5: BG0 should beat sprite(prio=0), got {r.color:#x}"
    print("T5 PASS: BG0 beats sprite prio=0")

    # ── Test 6: sprite prio=0, BG0 transparent, BG1 opaque ───────────────────
    # Sprite is between BG0 and BG1.  BG0 is transparent, so sprite wins over BG1.
    bg  = _make_bg()
    bg[1] = BgPixel(valid=True, color=0x22)
    spr = SprPixel(valid=True, color=0x55, priority=False)
    r = mixer.mix(spr, bg)
    assert r.color == 0x55, f"T6: sprite(prio=0) should beat BG1 when BG0 transparent, got {r.color:#x}"
    print("T6 PASS: sprite prio=0 beats BG1 when BG0 transparent")

    # ── Test 7: 3 layers — BG2 active ─────────────────────────────────────────
    # layer_ctrl[7:6] = 0b01 → 3 layers
    layer_ctrl = 0x40  # bits [7:6] = 01
    bg  = _make_bg()
    bg[2] = BgPixel(valid=True, color=0x33)
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[0] = BgPixel(valid=True, color=0x11)
    r = mixer.mix(SprPixel(), bg, layer_ctrl=layer_ctrl)
    assert r.color == 0x11, f"T7: BG0 should win with 3 layers, got {r.color:#x}"
    print("T7 PASS: 3-layer mode BG0 wins")

    # ── Test 8: 3 layers — BG2 active below BG1 ──────────────────────────────
    # BG0 transparent, BG1 transparent, BG2 opaque
    bg  = _make_bg()
    bg[2] = BgPixel(valid=True, color=0x33)
    r = mixer.mix(SprPixel(), bg, layer_ctrl=0x40)
    assert r.color == 0x33, f"T8: BG2 should win when BG0+BG1 transparent, got {r.color:#x}"
    print("T8 PASS: BG2 fallback in 3-layer mode")

    # ── Test 9: 2 layers — BG2/BG3 ignored even if valid ─────────────────────
    # layer_ctrl[7:6] = 0b00 → 2 layers: BG2 and BG3 should be ignored
    bg  = _make_bg()
    bg[3] = BgPixel(valid=True, color=0x44)
    bg[2] = BgPixel(valid=True, color=0x33)
    bg[1] = BgPixel(valid=True, color=0x22)
    r = mixer.mix(SprPixel(), bg, layer_ctrl=0x00)
    assert r.color == 0x22, f"T9: BG1 should win (BG2/BG3 ignored in 2-layer mode), got {r.color:#x}"
    print("T9 PASS: BG2/BG3 ignored in 2-layer mode")

    # ── Test 10: 4 layers — BG3 active (bottom) ──────────────────────────────
    # layer_ctrl[7:6] = 0b10 → 4 layers; BG3 is bottom
    bg  = _make_bg()
    bg[3] = BgPixel(valid=True, color=0x44)
    r = mixer.mix(SprPixel(), bg, layer_ctrl=0x80)
    assert r.color == 0x44, f"T10: BG3 should show when all else transparent, got {r.color:#x}"
    print("T10 PASS: BG3 bottom layer in 4-layer mode")

    # ── Test 11: sprite transparent → next layer shows ───────────────────────
    bg  = _make_bg()
    bg[1] = BgPixel(valid=True, color=0xBB)
    spr = SprPixel(valid=False, priority=True)
    r = mixer.mix(spr, bg)
    assert r.color == 0xBB, f"T11: transparent sprite → BG1 shows, got {r.color:#x}"
    print("T11 PASS: transparent sprite falls through")

    # ── Test 12: sprite prio=1 beats BG0 ─────────────────────────────────────
    bg  = _make_bg()
    bg[0] = BgPixel(valid=True, color=0xCC)
    bg[1] = BgPixel(valid=True, color=0xDD)
    spr = SprPixel(valid=True, color=0xEE, priority=True)
    r = mixer.mix(spr, bg)
    assert r.color == 0xEE, f"T12: sprite(prio=1) beats BG0, got {r.color:#x}"
    print("T12 PASS: sprite prio=1 beats BG0")

    print("\ngate5_model self-test PASS")
