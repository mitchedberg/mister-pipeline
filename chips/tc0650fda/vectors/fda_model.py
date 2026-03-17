"""
TC0650FDA behavioral model — Python reference implementation.

Steps 1–4 scope:
  - 8192-entry × 32-bit palette RAM (CPU write with byte enables)
  - Dual-index lookup: src_pal + dst_pal → RGB888 (3-stage MAC pipeline)
  - Alpha blend MAC: out = clamp((src * src_blend + dst * dst_blend) >> 3, 0, 255)
  - Opaque passthrough (do_blend=0): output = src_rgb directly
  - 12-bit legacy decode (nibble-repeat 4→8 expansion)

Format reference (section1 §2):
  Standard:  bits[23:16]=R, bits[15:8]=G, bits[7:0]=B
  12-bit:    bits[15:12]=R[3:0], bits[11:8]=G[3:0], bits[7:4]=B[3:0]

Blend formula (section1 §6):
  out_C = clamp((src_C * src_blend + dst_C * dst_blend) >> 3, 0, 255)
  Coefficient range: 0–8 (section2 §2.2 notes max is 8; but RTL accepts 0–15 4-bit)
  When do_blend=False: out = src_rgb (bypass MAC entirely)
"""


class TC0650FDA:
    PALETTE_DEPTH = 8192  # 0x2000 entries

    def __init__(self) -> None:
        # Palette RAM: 8192 entries × 32-bit (stored as Python ints)
        self.pal_ram: list[int] = [0] * self.PALETTE_DEPTH
        # Video output (after 3-cycle pipeline — modelled as instant in software)
        self.video_r: int = 0
        self.video_g: int = 0
        self.video_b: int = 0

    def reset(self) -> None:
        self.pal_ram = [0] * self.PALETTE_DEPTH
        self.video_r = 0
        self.video_g = 0
        self.video_b = 0

    # ── CPU write ─────────────────────────────────────────────────────────────

    def write(self, addr: int, data: int, be: int = 0xF) -> None:
        """Write palette entry at addr[12:0] with 32-bit data and byte enables.

        be[3] = D31:D24 (unused channel, accepted and stored)
        be[2] = D23:D16 = R
        be[1] = D15:D8  = G
        be[0] = D7:D0   = B
        """
        addr &= 0x1FFF
        data &= 0xFFFF_FFFF
        cur = self.pal_ram[addr]

        if be & 0x8:
            cur = (cur & 0x00FF_FFFF) | (data & 0xFF00_0000)
        if be & 0x4:
            cur = (cur & 0xFF00_FFFF) | (data & 0x00FF_0000)
        if be & 0x2:
            cur = (cur & 0xFFFF_00FF) | (data & 0x0000_FF00)
        if be & 0x1:
            cur = (cur & 0xFFFF_FF00) | (data & 0x0000_00FF)

        self.pal_ram[addr] = cur

    # ── CPU read-back ─────────────────────────────────────────────────────────

    def read(self, addr: int) -> int:
        """Read palette entry at addr[12:0]."""
        return self.pal_ram[addr & 0x1FFF]

    # ── Palette decode ────────────────────────────────────────────────────────

    @staticmethod
    def decode_standard(entry: int) -> tuple[int, int, int]:
        """Decode standard RGB888 entry.  Returns (R, G, B) as 8-bit ints."""
        r = (entry >> 16) & 0xFF
        g = (entry >>  8) & 0xFF
        b =  entry        & 0xFF
        return r, g, b

    @staticmethod
    def decode_12bit(entry: int) -> tuple[int, int, int]:
        """Decode 12-bit legacy entry.  Returns (R, G, B) expanded to 8-bit.

        Nibble-repeat expansion: nib → {nib, nib}
          0x0 → 0x00,  0x8 → 0x88,  0xF → 0xFF  (linear 0..255 mapping)
        """
        r4 = (entry >> 12) & 0xF
        g4 = (entry >>  8) & 0xF
        b4 = (entry >>  4) & 0xF
        r = (r4 << 4) | r4
        g = (g4 << 4) | g4
        b = (b4 << 4) | b4
        return r, g, b

    # ── Palette lookup (single index) ─────────────────────────────────────────

    def lookup(self, idx: int, mode_12bit: bool = False) -> tuple[int, int, int]:
        """Look up palette index and return (R, G, B).

        In 12-bit mode the effective address is {1'b0, idx[11:0]} — upper
        index bit is zeroed, so the accessible range is 0x0000..0x0FFF.
        """
        if mode_12bit:
            effective = idx & 0x0FFF   # zero-extend: {1'b0, idx[11:0]}
        else:
            effective = idx & 0x1FFF

        entry = self.pal_ram[effective]

        if mode_12bit:
            return self.decode_12bit(entry)
        else:
            return self.decode_standard(entry)

    # ── Alpha blend MAC ───────────────────────────────────────────────────────

    @staticmethod
    def blend_channel(src_c: int, dst_c: int, src_blend: int, dst_blend: int) -> int:
        """Compute blended channel value.

        Formula: clamp((src_c * src_blend + dst_c * dst_blend) >> 3, 0, 255)
        Matches RTL section2_rtl_plan §2.2 formula exactly.
        """
        result = (src_c * src_blend + dst_c * dst_blend) >> 3
        return min(result, 255)

    def blend(
        self,
        src_idx: int,
        dst_idx: int,
        src_blend: int,
        dst_blend: int,
        do_blend: bool = True,
        mode_12bit: bool = False,
    ) -> tuple[int, int, int]:
        """Perform dual-index palette lookup + alpha blend MAC.

        When do_blend=False, return src_rgb directly (opaque passthrough).
        Coefficients are 4-bit (0–15) but hardware uses 0–8 range in practice.
        """
        src_r, src_g, src_b = self.lookup(src_idx, mode_12bit)

        if not do_blend:
            return src_r, src_g, src_b

        dst_r, dst_g, dst_b = self.lookup(dst_idx, mode_12bit)

        out_r = self.blend_channel(src_r, dst_r, src_blend, dst_blend)
        out_g = self.blend_channel(src_g, dst_g, src_blend, dst_blend)
        out_b = self.blend_channel(src_b, dst_b, src_blend, dst_blend)

        return out_r, out_g, out_b
