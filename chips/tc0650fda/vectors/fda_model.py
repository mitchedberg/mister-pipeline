"""
TC0650FDA behavioral model — Python reference implementation.

Step 1 scope:
  - 8192-entry × 32-bit palette RAM (CPU write with byte enables)
  - Single-index lookup: src_pal → RGB888 output (2-cycle pipeline)
  - 12-bit legacy decode (nibble-repeat 4→8 expansion)

Not modelled here (Step 2):
  - dst_pal lookup
  - Alpha blend MAC pipeline

Format reference (section1 §2):
  Standard:  bits[23:16]=R, bits[15:8]=G, bits[7:0]=B
  12-bit:    bits[15:12]=R[3:0], bits[11:8]=G[3:0], bits[7:4]=B[3:0]
"""


class TC0650FDA:
    PALETTE_DEPTH = 8192  # 0x2000 entries

    def __init__(self) -> None:
        # Palette RAM: 8192 entries × 32-bit (stored as Python ints)
        self.pal_ram: list[int] = [0] * self.PALETTE_DEPTH
        # Video output (after 2-cycle pipeline — modelled as instant in software)
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

    # ── Pixel lookup (software model — no pipeline delay) ────────────────────

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
