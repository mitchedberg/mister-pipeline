#!/usr/bin/env python3
"""
gate5_model.py — NMK16 Gate 5 behavioral model: priority mixer / color compositor.

Combines sprite pixels (from Gate 3 scanline buffer) and BG layer pixels
(from Gate 4 pipeline) for each screen position using the NMK16 priority rules.

Priority algorithm (painter's algorithm, lowest → highest):
  BG1 (background, always active)          — bottom of stack
  Sprite with priority=0                   — below BG0, above BG1
  BG0 (foreground, always active)          — highest BG priority
  Sprite with priority=1                   — above all layers

A pixel is opaque (participates) if its valid bit is 1.
Transparent pixels (valid=0) fall through to the layer below.

NMK16 has exactly 2 BG layers (BG0=foreground, BG1=background).
There is no layer_ctrl gating — both layers are always active.

References:
  GATE_PLAN.md §4.1 — compositing pipeline
  nmk16.sv Gate 5 always_comb block
"""

from dataclasses import dataclass
from typing import List


# ─────────────────────────────────────────────────────────────────────────────
# Data types
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class SprPixel:
    """Sprite pixel from Gate 3 scanline buffer read-back."""
    valid:    bool = False
    color:    int  = 0    # 8-bit: {palette[3:0], index[3:0]}
    priority: bool = False  # False=below BG0, True=above all


@dataclass
class BgPixel:
    """BG layer pixel from Gate 4 pipeline."""
    valid:    bool = False
    color:    int  = 0    # 8-bit: {palette[3:0], index[3:0]}


@dataclass
class MixResult:
    """Output of the priority mixer for one pixel position."""
    color: int  = 0      # 8-bit palette index of winning pixel
    valid: bool = False  # True if any layer contributed an opaque pixel


# ─────────────────────────────────────────────────────────────────────────────
# Priority mixer model
# ─────────────────────────────────────────────────────────────────────────────

class NMK16ColMix:
    """
    Behavioral model of the NMK16 Gate 5 priority mixer.

    Usage:
        mixer = NMK16ColMix()
        result = mixer.mix(spr, bg0, bg1)

    bg[0] = BG0 (foreground / higher priority)
    bg[1] = BG1 (background / lower priority)
    """

    @staticmethod
    def mix(spr: SprPixel,
            bg0: BgPixel,
            bg1: BgPixel) -> MixResult:
        """
        Combine sprite and BG pixels using the NMK16 priority algorithm.

        Painter's algorithm: start transparent; each higher-priority opaque
        pixel overwrites the current winner.

        Order (lowest → highest):
          1. BG1  (bottom)
          2. Sprite with priority=0
          3. BG0  (foreground)
          4. Sprite with priority=1
        """
        winner_color = 0
        winner_valid = False

        # BG1 — background (bottom of stack)
        if bg1.valid:
            winner_color = bg1.color
            winner_valid = True

        # Sprite priority=0: below BG0, above BG1
        if not spr.priority and spr.valid:
            winner_color = spr.color
            winner_valid = True

        # BG0 — foreground (highest BG priority)
        if bg0.valid:
            winner_color = bg0.color
            winner_valid = True

        # Sprite priority=1: above all BG layers
        if spr.priority and spr.valid:
            winner_color = spr.color
            winner_valid = True

        return MixResult(color=winner_color, valid=winner_valid)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    mixer = NMK16ColMix()

    # T1: all transparent → invalid output
    r = mixer.mix(SprPixel(), BgPixel(), BgPixel())
    assert not r.valid, "T1: all transparent → valid should be False"
    assert r.color == 0, "T1: color should be 0"
    print("T1 PASS: all transparent")

    # T2: only BG1 opaque → BG1 wins
    r = mixer.mix(SprPixel(), BgPixel(), BgPixel(valid=True, color=0x12))
    assert r.valid,         "T2: BG1 should produce valid output"
    assert r.color == 0x12, f"T2: expected 0x12, got {r.color:#x}"
    print("T2 PASS: BG1 only")

    # T3: BG0 + BG1 opaque → BG0 wins (higher priority)
    r = mixer.mix(SprPixel(),
                  BgPixel(valid=True, color=0xAB),
                  BgPixel(valid=True, color=0x12))
    assert r.color == 0xAB, f"T3: BG0 should win over BG1, got {r.color:#x}"
    print("T3 PASS: BG0 over BG1")

    # T4: sprite prio=1 above BG0
    r = mixer.mix(SprPixel(valid=True, color=0xFF, priority=True),
                  BgPixel(valid=True, color=0xAB),
                  BgPixel(valid=True, color=0x12))
    assert r.color == 0xFF, f"T4: sprite(prio=1) should win over BG0, got {r.color:#x}"
    print("T4 PASS: sprite prio=1 above BG0")

    # T5: sprite prio=0 below BG0, above BG1
    # BG0=0xAB opaque → BG0 should win
    r = mixer.mix(SprPixel(valid=True, color=0x55, priority=False),
                  BgPixel(valid=True, color=0xAB),
                  BgPixel(valid=True, color=0x12))
    assert r.color == 0xAB, f"T5: BG0 should beat sprite(prio=0), got {r.color:#x}"
    print("T5 PASS: BG0 beats sprite prio=0")

    # T6: sprite prio=0, BG0 transparent, BG1 opaque → sprite wins over BG1
    r = mixer.mix(SprPixel(valid=True, color=0x55, priority=False),
                  BgPixel(),
                  BgPixel(valid=True, color=0x22))
    assert r.color == 0x55, f"T6: sprite(prio=0) should beat BG1 when BG0 transparent, got {r.color:#x}"
    print("T6 PASS: sprite prio=0 beats BG1 when BG0 transparent")

    # T7: sprite prio=1 transparent → BG0 shows
    r = mixer.mix(SprPixel(valid=False, priority=True),
                  BgPixel(valid=True, color=0xCC),
                  BgPixel(valid=True, color=0xDD))
    assert r.color == 0xCC, f"T7: transparent sprite → BG0 shows, got {r.color:#x}"
    print("T7 PASS: transparent sprite falls through to BG0")

    # T8: only sprite prio=1, all BG transparent → sprite wins
    r = mixer.mix(SprPixel(valid=True, color=0xEE, priority=True),
                  BgPixel(),
                  BgPixel())
    assert r.valid,         "T8: sprite alone should produce valid output"
    assert r.color == 0xEE, f"T8: expected 0xEE, got {r.color:#x}"
    print("T8 PASS: sprite prio=1 alone, all BG transparent")

    # T9: all layers transparent → invalid
    r = mixer.mix(SprPixel(), BgPixel(), BgPixel())
    assert not r.valid, "T9: all transparent → invalid"
    print("T9 PASS: all transparent → invalid (re-check)")

    # T10: only BG0 opaque
    r = mixer.mix(SprPixel(),
                  BgPixel(valid=True, color=0x7F),
                  BgPixel())
    assert r.valid,         "T10: BG0 alone should produce valid output"
    assert r.color == 0x7F, f"T10: expected 0x7F, got {r.color:#x}"
    print("T10 PASS: only BG0 opaque")

    print("\ngate5_model self-test PASS")
