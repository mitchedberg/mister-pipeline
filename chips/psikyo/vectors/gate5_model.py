#!/usr/bin/env python3
"""
gate5_model.py — Psikyo Gate 5 behavioral model: priority mixer / color compositor.

Combines sprite pixels (from Gate 3) and BG layer pixels (from Gate 4) for
each screen position using Psikyo priority rules.

Priority algorithm (painter's algorithm, lowest → highest):
  BG1      (background, always active)
  Sprite with priority=0  (above BG1, below BG0)
  BG0      (foreground, always active)
  Sprite with priority=1  (above BG0)
  Sprite with priority=2  (above all BG, below prio=3)
  Sprite with priority=3  (topmost)

A pixel is opaque if valid=1 AND color != 0.
Transparent pixels (valid=0 or color=0) fall through to the layer below.

References:
  psikyo GATE_PLAN.md §Gate 5 — Priority Mixer specification
  psikyo_gate5.sv     — RTL implementation
"""

from dataclasses import dataclass, field
from typing import Optional


# ─────────────────────────────────────────────────────────────────────────────
# Data types
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class SprPixel:
    """Sprite pixel from Gate 3 scanline buffer."""
    valid:    bool = False
    color:    int  = 0      # 8-bit: {palette[3:0], index[3:0]}
    priority: int  = 0      # 2-bit priority field (0–3)


@dataclass
class BgPixel:
    """BG layer pixel from Gate 4 pipeline."""
    valid:    bool = False
    color:    int  = 0      # 8-bit: {palette[3:0], index[3:0]}
    priority: int  = 0      # 2-bit priority attribute (carried through, not used for ordering)


@dataclass
class MixResult:
    """Output of the Psikyo priority mixer for one pixel position."""
    color: int  = 0      # 8-bit palette index of winning pixel
    valid: bool = False  # True if any layer contributed an opaque pixel


# ─────────────────────────────────────────────────────────────────────────────
# Priority mixer model
# ─────────────────────────────────────────────────────────────────────────────

class PsikyoColMix:
    """
    Behavioral model of the Psikyo Gate 5 priority mixer.

    Usage:
        mixer = PsikyoColMix()
        result = mixer.mix(spr, bg0, bg1)
    """

    @staticmethod
    def is_opaque(color: int, valid: bool) -> bool:
        """A pixel is opaque if valid=1 AND color != 0."""
        return valid and (color != 0)

    def mix(self, spr: SprPixel, bg0: BgPixel, bg1: BgPixel) -> MixResult:
        """
        Combine sprite and BG pixels using the Psikyo priority algorithm.

        Parameters:
            spr  — sprite pixel (from Gate 3 read-back)
            bg0  — BG0 (foreground layer) pixel from Gate 4
            bg1  — BG1 (background layer) pixel from Gate 4

        Returns MixResult with the winning pixel's color and valid flag.
        """
        winner_color = 0
        winner_valid = False

        # Step 1: BG1 (bottom background, always active)
        if self.is_opaque(bg1.color, bg1.valid):
            winner_color = bg1.color
            winner_valid = True

        # Step 2: Sprites with priority=0 (above BG1, below BG0)
        if self.is_opaque(spr.color, spr.valid) and spr.priority == 0:
            winner_color = spr.color
            winner_valid = True

        # Step 3: BG0 (foreground, always active)
        if self.is_opaque(bg0.color, bg0.valid):
            winner_color = bg0.color
            winner_valid = True

        # Step 4: Sprites with priority=1 (above BG0)
        if self.is_opaque(spr.color, spr.valid) and spr.priority == 1:
            winner_color = spr.color
            winner_valid = True

        # Step 5: Sprites with priority=2 (above all BG, below prio=3)
        if self.is_opaque(spr.color, spr.valid) and spr.priority == 2:
            winner_color = spr.color
            winner_valid = True

        # Step 6: Sprites with priority=3 (topmost)
        if self.is_opaque(spr.color, spr.valid) and spr.priority == 3:
            winner_color = spr.color
            winner_valid = True

        return MixResult(color=winner_color, valid=winner_valid)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    mixer = PsikyoColMix()

    # T1: All transparent → invalid output
    r = mixer.mix(SprPixel(), BgPixel(), BgPixel())
    assert not r.valid, "T1: all transparent → valid should be False"
    assert r.color == 0, "T1: color should be 0"
    print("T1 PASS: all transparent")

    # T2: BG1 only opaque → BG1 wins
    r = mixer.mix(SprPixel(), BgPixel(), BgPixel(valid=True, color=0x12))
    assert r.valid,         "T2: BG1 should produce valid output"
    assert r.color == 0x12, f"T2: expected 0x12, got {r.color:#x}"
    print("T2 PASS: BG1 only")

    # T3: BG0 + BG1 both opaque → BG0 wins (higher priority)
    r = mixer.mix(SprPixel(), BgPixel(valid=True, color=0xAB), BgPixel(valid=True, color=0x12))
    assert r.color == 0xAB, f"T3: BG0 should win over BG1, got {r.color:#x}"
    print("T3 PASS: BG0 over BG1")

    # T4: Sprite prio=0 above BG1, below BG0
    bg0 = BgPixel(valid=True, color=0xAB)
    bg1 = BgPixel(valid=True, color=0x12)
    spr = SprPixel(valid=True, color=0x55, priority=0)
    r = mixer.mix(spr, bg0, bg1)
    assert r.color == 0xAB, f"T4: BG0 should beat spr(prio=0), got {r.color:#x}"
    print("T4 PASS: BG0 beats sprite prio=0")

    # T5: Sprite prio=0, BG0 transparent → sprite wins over BG1
    spr = SprPixel(valid=True, color=0x55, priority=0)
    r = mixer.mix(spr, BgPixel(), BgPixel(valid=True, color=0x22))
    assert r.color == 0x55, f"T5: spr(prio=0) should beat BG1 when BG0 transparent, got {r.color:#x}"
    print("T5 PASS: sprite prio=0 beats BG1 when BG0 transparent")

    # T6: Sprite prio=1 above BG0
    spr = SprPixel(valid=True, color=0xFF, priority=1)
    r = mixer.mix(spr, BgPixel(valid=True, color=0xAB), BgPixel(valid=True, color=0x12))
    assert r.color == 0xFF, f"T6: spr(prio=1) should beat BG0, got {r.color:#x}"
    print("T6 PASS: sprite prio=1 beats BG0")

    # T7: Sprite prio=2 above BG0
    spr = SprPixel(valid=True, color=0xCC, priority=2)
    r = mixer.mix(spr, BgPixel(valid=True, color=0xAB), BgPixel(valid=True, color=0x12))
    assert r.color == 0xCC, f"T7: spr(prio=2) should beat BG0, got {r.color:#x}"
    print("T7 PASS: sprite prio=2 beats BG0")

    # T8: Sprite prio=3 (topmost) beats everything
    spr = SprPixel(valid=True, color=0xEE, priority=3)
    r = mixer.mix(spr, BgPixel(valid=True, color=0xAB), BgPixel(valid=True, color=0x12))
    assert r.color == 0xEE, f"T8: spr(prio=3) should beat all, got {r.color:#x}"
    print("T8 PASS: sprite prio=3 topmost")

    # T9: Sprite color=0 → treated as transparent even if valid=1
    spr = SprPixel(valid=True, color=0x00, priority=3)
    r = mixer.mix(spr, BgPixel(), BgPixel(valid=True, color=0x22))
    assert r.color == 0x22, f"T9: spr(color=0) should be transparent, BG1 wins, got {r.color:#x}"
    print("T9 PASS: sprite color=0 transparent")

    # T10: Sprite valid=0 → transparent regardless of priority
    spr = SprPixel(valid=False, color=0xAA, priority=3)
    r = mixer.mix(spr, BgPixel(valid=True, color=0xBB), BgPixel())
    assert r.color == 0xBB, f"T10: spr(valid=0) falls through, BG0 wins, got {r.color:#x}"
    print("T10 PASS: sprite valid=0 transparent")

    # T11: All sprite priorities present simultaneously — only active one wins
    # Exactly one sprite pixel exists at each position (only one spr_rd_priority value matters)
    spr = SprPixel(valid=True, color=0x77, priority=1)
    r = mixer.mix(spr, BgPixel(valid=True, color=0x33), BgPixel(valid=True, color=0x44))
    assert r.color == 0x77, f"T11: spr(prio=1) beats BG0, got {r.color:#x}"
    print("T11 PASS: prio=1 wins over BG0")

    # T12: Only BG0 opaque, no sprite, no BG1 → BG0 wins
    r = mixer.mix(SprPixel(), BgPixel(valid=True, color=0xBB), BgPixel())
    assert r.color == 0xBB, f"T12: BG0 only, got {r.color:#x}"
    print("T12 PASS: BG0 only")

    print("\ngate5_model self-test PASS")
