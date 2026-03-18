#!/usr/bin/env python3
"""
gate5_model.py — Kaneko16 Gate 5 behavioral model: priority mixer / color compositor.

Combines sprite pixels (from Gate 3 scanline buffer) and BG layer pixels
(from Gate 4 pipeline) for each screen position using the Kaneko16 VU-001/VU-002
priority rules from GATE_PLAN.md §Gate 4 "Priority System".

Priority stack (painter's algorithm, lowest → highest):
  BG0   — back layer, always active
  BG1   — always active
  Sprite (prio group 0: prio[3:2]==2'b00, i.e., prio 0–3) — above BG1, below BG2
  BG2   — active when num_layers >= 3
  Sprite (prio group 1: prio[3:2]==2'b01, i.e., prio 4–7) — above BG2, below BG3
  BG3   — active when num_layers == 4
  Sprite (prio group 2+: prio[3:2]>=2'b10, i.e., prio 8–15) — above all BG

Transparent pixels (valid=False) are skipped; the last opaque pixel wins.
If all pixels are transparent, the output is (color=0, valid=False).

num_layers decoded from layer_ctrl[7:6]:
  2'b00 → 2 layers (BG0 + BG1)
  2'b01 → 3 layers (BG0 + BG1 + BG2)
  2'b10, 2'b11 → 4 layers (BG0–BG3)

References:
  GATE_PLAN.md §Gate 4 — Priority System
  kaneko16.sv Gate 5 — Priority Mixer / Color Compositor
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
    color:    int  = 0    # 8-bit: {palette[3:0], nybble[3:0]}
    priority: int  = 0    # 4-bit priority field from sprite descriptor (0–15)


@dataclass
class BgPixel:
    """BG layer pixel from Gate 4 pipeline."""
    valid:    bool = False
    color:    int  = 0    # 8-bit: {palette[3:0], nybble[3:0]}


@dataclass
class MixResult:
    """Output of the priority mixer for one pixel position."""
    color: int  = 0      # 8-bit palette index of winning pixel
    valid: bool = False  # True if any layer contributed an opaque pixel


# ─────────────────────────────────────────────────────────────────────────────
# Priority mixer model
# ─────────────────────────────────────────────────────────────────────────────

class Kaneko16ColMix:
    """
    Behavioral model of the Kaneko16 Gate 5 priority mixer.

    Usage:
        mixer = Kaneko16ColMix()
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

    @staticmethod
    def spr_group(priority: int) -> int:
        """
        Map 4-bit sprite priority to priority group (0, 1, 2+):
          group 0: prio  0–3   (prio[3:2] == 2'b00)
          group 1: prio  4–7   (prio[3:2] == 2'b01)
          group 2: prio  8–15  (prio[3:2] >= 2'b10)
        """
        return (priority >> 2) & 0x3

    def mix(self,
            spr: SprPixel,
            bg: List[BgPixel],
            layer_ctrl: int = 0) -> MixResult:
        """
        Combine sprite and BG pixels using the Kaneko16 priority algorithm.

        Parameters:
            spr        — sprite pixel (from Gate 3 scanline buffer)
            bg         — list of 4 BG layer pixels: bg[0]=BG0 (back), ..., bg[3]=BG3
            layer_ctrl — active layer_ctrl register value (bits [7:6] control num_layers)

        Returns MixResult with the winning pixel's color and valid flag.
        """
        assert len(bg) == 4, "bg must have exactly 4 entries (BG0..BG3)"

        num_layers = self.num_active_layers(layer_ctrl)
        group      = self.spr_group(spr.priority)

        winner_color = 0
        winner_valid = False

        # ── Painter's algorithm: higher priority overwrites lower ─────────────

        # BG0 — back layer, always active
        if bg[0].valid:
            winner_color = bg[0].color
            winner_valid = True

        # BG1 — always active
        if bg[1].valid:
            winner_color = bg[1].color
            winner_valid = True

        # Sprite group 0 (prio 0–3): above BG1, below BG2
        if spr.valid and group == 0:
            winner_color = spr.color
            winner_valid = True

        # BG2 — active when num_layers >= 3
        if num_layers >= 3 and bg[2].valid:
            winner_color = bg[2].color
            winner_valid = True

        # Sprite group 1 (prio 4–7): above BG2, below BG3
        if spr.valid and group == 1:
            winner_color = spr.color
            winner_valid = True

        # BG3 — active when num_layers == 4
        if num_layers >= 4 and bg[3].valid:
            winner_color = bg[3].color
            winner_valid = True

        # Sprite groups 2–3 (prio 8–15): above all BG
        if spr.valid and group >= 2:
            winner_color = spr.color
            winner_valid = True

        return MixResult(color=winner_color, valid=winner_valid)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

def _make_bg(n=4):
    return [BgPixel() for _ in range(n)]


if __name__ == '__main__':
    mixer = Kaneko16ColMix()

    # ── T1: all transparent → invalid ─────────────────────────────────────────
    r = mixer.mix(SprPixel(), _make_bg())
    assert not r.valid, "T1: all transparent → valid should be False"
    assert r.color == 0, "T1: color should be 0"
    print("T1 PASS: all transparent")

    # ── T2: BG0 only → BG0 wins ───────────────────────────────────────────────
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    r = mixer.mix(SprPixel(), bg)
    assert r.valid and r.color == 0x11, f"T2: {r}"
    print("T2 PASS: BG0 only")

    # ── T3: BG1 over BG0 ──────────────────────────────────────────────────────
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[1] = BgPixel(valid=True, color=0x22)
    r = mixer.mix(SprPixel(), bg)
    assert r.color == 0x22, f"T3: BG1 should beat BG0, got {r.color:#x}"
    print("T3 PASS: BG1 over BG0")

    # ── T4: sprite prio=0 above BG1, but BG2 inactive (2-layer mode) ──────────
    # layer_ctrl[7:6]=00 → 2 layers; BG2 ignored.
    # Expected: sprite(prio=0) group=0 → above BG1; BG2 skipped → sprite wins.
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)  # should be ignored
    spr = SprPixel(valid=True, color=0xAA, priority=0)
    r = mixer.mix(spr, bg, layer_ctrl=0x00)  # 2-layer mode
    assert r.color == 0xAA, f"T4: sprite(prio=0) above BG1 in 2-layer mode, got {r.color:#x}"
    print("T4 PASS: sprite prio=0 above BG1 in 2-layer mode")

    # ── T5: BG2 beats sprite prio=0 in 3-layer mode ───────────────────────────
    # layer_ctrl[7:6]=01 → 3 layers.  Stack: BG0, BG1, spr(prio=0), BG2.
    # BG2 is active and overwrites sprite → BG2 wins.
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)
    spr = SprPixel(valid=True, color=0xAA, priority=0)  # prio=0 → group 0
    r = mixer.mix(spr, bg, layer_ctrl=0x40)  # 3-layer mode
    assert r.color == 0x33, f"T5: BG2 should beat sprite(prio=0) in 3-layer mode, got {r.color:#x}"
    print("T5 PASS: BG2 beats sprite prio=0 in 3-layer mode")

    # ── T6: sprite prio=4 above BG2, below BG3 (4-layer mode) ────────────────
    # Stack: BG0, BG1, spr(0), BG2, spr(4), BG3, spr(8+).
    # prio=4 → group=1; BG3 is active → BG3 beats sprite prio=4.
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)
    bg[3] = BgPixel(valid=True, color=0x44)
    spr = SprPixel(valid=True, color=0xAA, priority=4)  # group 1
    r = mixer.mix(spr, bg, layer_ctrl=0x80)  # 4-layer mode
    assert r.color == 0x44, f"T6: BG3 should beat sprite(prio=4) in 4-layer mode, got {r.color:#x}"
    print("T6 PASS: BG3 beats sprite prio=4 in 4-layer mode")

    # ── T7: sprite prio=4 wins when BG3 transparent ───────────────────────────
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)
    bg[3] = BgPixel(valid=False)  # transparent
    spr = SprPixel(valid=True, color=0xBB, priority=4)
    r = mixer.mix(spr, bg, layer_ctrl=0x80)  # 4-layer mode
    assert r.color == 0xBB, f"T7: sprite(prio=4) wins when BG3 transparent, got {r.color:#x}"
    print("T7 PASS: sprite prio=4 wins over transparent BG3")

    # ── T8: sprite prio=8 above all BG ───────────────────────────────────────
    bg = _make_bg()
    for i in range(4):
        bg[i] = BgPixel(valid=True, color=0x10 + i)
    spr = SprPixel(valid=True, color=0xCC, priority=8)  # group 2
    r = mixer.mix(spr, bg, layer_ctrl=0x80)  # 4-layer mode
    assert r.color == 0xCC, f"T8: sprite(prio=8) above all BG, got {r.color:#x}"
    print("T8 PASS: sprite prio=8 above all BG")

    # ── T9: sprite prio=15 above all BG ──────────────────────────────────────
    bg = _make_bg()
    for i in range(4):
        bg[i] = BgPixel(valid=True, color=0x10 + i)
    spr = SprPixel(valid=True, color=0xDD, priority=15)  # group 3
    r = mixer.mix(spr, bg, layer_ctrl=0x80)
    assert r.color == 0xDD, f"T9: sprite(prio=15) above all BG, got {r.color:#x}"
    print("T9 PASS: sprite prio=15 above all BG")

    # ── T10: 2-layer mode — BG2/BG3 ignored even if valid ────────────────────
    bg = _make_bg()
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)  # should be ignored
    bg[3] = BgPixel(valid=True, color=0x44)  # should be ignored
    r = mixer.mix(SprPixel(), bg, layer_ctrl=0x00)  # 2-layer mode
    assert r.color == 0x22, f"T10: BG2/BG3 ignored in 2-layer mode, got {r.color:#x}"
    print("T10 PASS: BG2/BG3 ignored in 2-layer mode")

    # ── T11: 3-layer mode — BG3 ignored ──────────────────────────────────────
    bg = _make_bg()
    bg[1] = BgPixel(valid=True, color=0x22)
    bg[2] = BgPixel(valid=True, color=0x33)
    bg[3] = BgPixel(valid=True, color=0x44)  # should be ignored
    r = mixer.mix(SprPixel(), bg, layer_ctrl=0x40)  # 3-layer mode
    assert r.color == 0x33, f"T11: BG3 ignored in 3-layer mode, got {r.color:#x}"
    print("T11 PASS: BG3 ignored in 3-layer mode")

    # ── T12: transparent sprite falls through to BG ───────────────────────────
    bg = _make_bg()
    bg[1] = BgPixel(valid=True, color=0x55)
    spr = SprPixel(valid=False, priority=15)  # transparent even at highest prio
    r = mixer.mix(spr, bg)
    assert r.color == 0x55, f"T12: transparent sprite falls through, got {r.color:#x}"
    print("T12 PASS: transparent sprite falls through")

    # ── T13: sprite prio=3 (group 0) — below BG2 in 3-layer mode ────────────
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x11)
    bg[2] = BgPixel(valid=True, color=0x33)
    # BG1 transparent so sprite(prio=3) wins at that slot, but BG2 overwrites
    spr = SprPixel(valid=True, color=0xEE, priority=3)
    r = mixer.mix(spr, bg, layer_ctrl=0x40)  # 3-layer mode
    assert r.color == 0x33, f"T13: BG2 beats sprite(prio=3) in 3-layer mode, got {r.color:#x}"
    print("T13 PASS: sprite prio=3 below BG2")

    # ── T14: sprite prio=7 (group 1) — below BG3 in 4-layer mode, BG2 also ──
    # Stack: BG0, BG1, spr(0-3), BG2, spr(4-7), BG3.
    # Only BG3 is opaque (others transparent) → BG3 beats sprite prio=7.
    bg = _make_bg()
    bg[3] = BgPixel(valid=True, color=0x77)
    spr = SprPixel(valid=True, color=0xFF, priority=7)
    r = mixer.mix(spr, bg, layer_ctrl=0x80)  # 4-layer mode
    assert r.color == 0x77, f"T14: BG3 beats sprite(prio=7), got {r.color:#x}"
    print("T14 PASS: sprite prio=7 below BG3")

    # ── T15: all opaque, sprite prio=0 — BG2 (3-layer) is top ───────────────
    # Order verified: BG0=0x10, BG1=0x20, spr(prio=0)=0xAA, BG2=0x30.
    # Winner = BG2 (0x30).
    bg = _make_bg()
    bg[0] = BgPixel(valid=True, color=0x10)
    bg[1] = BgPixel(valid=True, color=0x20)
    bg[2] = BgPixel(valid=True, color=0x30)
    spr = SprPixel(valid=True, color=0xAA, priority=0)
    r = mixer.mix(spr, bg, layer_ctrl=0x40)  # 3-layer mode
    assert r.color == 0x30, f"T15: BG2 is top in 3-layer mode, got {r.color:#x}"
    print("T15 PASS: full 3-layer stack with sprite prio=0")

    print("\ngate5_model self-test PASS")
