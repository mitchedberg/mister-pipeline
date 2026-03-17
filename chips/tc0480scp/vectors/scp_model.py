"""
TC0480SCP behavioral model — Step 1: Control registers + video timing.

Implements:
  TC0480SCPModel.__init__()
  write_ctrl(word_addr, data, be=0x3)   → write control register
  read_ctrl(word_addr)                   → read control register
  bgscrollx(layer)                       → decoded effective X scroll
  bgscrolly(layer)                       → decoded effective Y scroll
  bgzoom(layer)                          → raw zoom word
  bg_dx(layer)                           → sub-pixel X byte
  bg_dy(layer)                           → sub-pixel Y byte
  text_scrollx()                         → FG0 X scroll
  text_scrolly()                         → FG0 Y scroll
  dblwidth()                             → double-width flag
  flipscreen()                           → flip-screen flag
  priority_order()                       → 3-bit priority index
  rowzoom_en(layer)                      → per-row zoom enable (BG2/BG3 only)
  bg_priority()                          → decoded 4-nibble priority word

Video timing constants (MAME set_raw parameters):
  set_raw(26.686MHz/4, 424, 0, 320, 262, 16, 256)
  H_TOTAL=424  H_END=320   (active: hpos 0..319)
  V_TOTAL=262  V_START=16  V_END=256  (active: vpos 16..255)
  Active pixels per frame: 320 × 240 = 76,800
"""

# ── Video timing constants ───────────────────────────────────────────────────
H_TOTAL  = 424
H_END    = 320    # hblank starts at this hpos
V_TOTAL  = 262
V_START  = 16     # active display starts at this vpos
V_END    = 256    # vblank starts at this vpos (after active)

ACTIVE_PIXELS = (H_END) * (V_END - V_START)   # 320 × 240 = 76,800

# ── Priority LUT ─────────────────────────────────────────────────────────────
# tc0480scp_bg_pri_lookup[8] from MAME tc0480scp.cpp
_PRI_LUT = [0x0123, 0x1230, 0x2301, 0x3012, 0x3210, 0x2103, 0x1032, 0x0321]

# ── Layer stagger constants ───────────────────────────────────────────────────
_STAGGER = [0, 4, 8, 12]   # added to raw ctrl scroll before negation


class TC0480SCPModel:
    """Behavioral model of TC0480SCP chip, Step 1 (registers + timing only)."""

    def __init__(self):
        # 24 × 16-bit control registers, indexed by word address 0–23
        self._ctrl = [0] * 24

    # ── Register access ───────────────────────────────────────────────────────

    def write_ctrl(self, word_addr: int, data: int, be: int = 0x3) -> None:
        """Write one control register word.

        word_addr: 0–23
        data:      16-bit value
        be:        byte enables, bit1=upper byte, bit0=lower byte
        """
        if not (0 <= word_addr <= 23):
            raise ValueError(f"word_addr {word_addr} out of range 0–23")
        data = data & 0xFFFF
        cur  = self._ctrl[word_addr]
        if be & 0x2:
            cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1:
            cur = (cur & 0xFF00) | (data & 0x00FF)
        self._ctrl[word_addr] = cur

    def read_ctrl(self, word_addr: int) -> int:
        """Read one control register word. Returns 16-bit value."""
        if not (0 <= word_addr <= 23):
            raise ValueError(f"word_addr {word_addr} out of range 0–23")
        return self._ctrl[word_addr]

    # ── LAYER_CTRL decode ─────────────────────────────────────────────────────

    def _layer_ctrl(self) -> int:
        """Return raw LAYER_CTRL word (word 15)."""
        return self._ctrl[15]

    def dblwidth(self) -> bool:
        """LAYER_CTRL bit[7] = 0x80: double-width tilemap enable."""
        return bool(self._layer_ctrl() & 0x80)

    def flipscreen(self) -> bool:
        """LAYER_CTRL bit[6] = 0x40: screen flip enable."""
        return bool(self._layer_ctrl() & 0x40)

    def priority_order(self) -> int:
        """LAYER_CTRL bits[4:2] = 0x1C >> 2: 3-bit priority index."""
        return (self._layer_ctrl() >> 2) & 0x7

    def rowzoom_en(self, layer: int) -> bool:
        """LAYER_CTRL bit[0]=BG2 enable, bit[1]=BG3 enable.

        layer must be 2 or 3; other layers always return False.
        """
        if layer == 2:
            return bool(self._layer_ctrl() & 0x01)
        elif layer == 3:
            return bool(self._layer_ctrl() & 0x02)
        return False

    def bg_priority(self) -> int:
        """Decoded 4-nibble priority word from 8-entry LUT.

        Nibble [15:12] = bottom BG layer index, nibble [3:0] = top BG layer.
        Text layer is always topmost (above all BG).
        """
        return _PRI_LUT[self.priority_order()]

    # ── Scroll decode ─────────────────────────────────────────────────────────

    def bgscrollx(self, layer: int) -> int:
        """Effective X scroll for BG layer (0–3), 16-bit signed result.

        Applies layer stagger and sign based on flipscreen.
        Non-flip: -(ctrl[layer] + stagger)
        Flip:     +(ctrl[layer] + stagger)
        Result is masked to 16 bits (two's complement).
        """
        raw = self._ctrl[layer] & 0xFFFF
        val = (raw + _STAGGER[layer]) & 0xFFFF
        if self.flipscreen():
            return val
        else:
            return (-val) & 0xFFFF

    def bgscrolly(self, layer: int) -> int:
        """Effective Y scroll for BG layer (0–3), 16-bit signed result.

        Non-flip: ctrl[4+layer]
        Flip:     -ctrl[4+layer]
        Result is masked to 16 bits.
        """
        raw = self._ctrl[4 + layer] & 0xFFFF
        if self.flipscreen():
            return (-raw) & 0xFFFF
        else:
            return raw

    def bgzoom(self, layer: int) -> int:
        """Raw zoom word for BG layer (0–3).

        bits[15:8] = xzoom byte, bits[7:0] = yzoom byte.
        """
        return self._ctrl[8 + layer] & 0xFFFF

    def bg_dx(self, layer: int) -> int:
        """Sub-pixel X byte for BG layer (0–3). Low byte of ctrl[16+layer]."""
        return self._ctrl[16 + layer] & 0xFF

    def bg_dy(self, layer: int) -> int:
        """Sub-pixel Y byte for BG layer (0–3). Low byte of ctrl[20+layer]."""
        return self._ctrl[20 + layer] & 0xFF

    def text_scrollx(self) -> int:
        """FG0 text layer X scroll (word 12, raw)."""
        return self._ctrl[12] & 0xFFFF

    def text_scrolly(self) -> int:
        """FG0 text layer Y scroll (word 13, raw)."""
        return self._ctrl[13] & 0xFFFF
