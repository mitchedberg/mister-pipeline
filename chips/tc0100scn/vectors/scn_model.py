"""
TC0100SCN Streaming Tilemap Generator — Python behavioral model.

Derived from MAME src/mame/taito/tc0100scn.cpp (rev. master 2024-03).
Models:
  - Three layers: BG0, BG1, FG0
  - VRAM: 128K×16-bit flat dict (sparse, address -> value)
  - Control registers: 8 × 16-bit (scroll×6, layer_ctrl, flip_ctrl)
  - Scroll values negated internally on write (per MAME ctrl_w)
  - For each scanline: compute tile index from scroll + hcount, fetch tile row, output pixels
  - BG0/BG1: 4bpp, ROM-sourced tiles; BG1 also has per-column colscroll
  - FG0: 2bpp, CPU-writeable char RAM
  - Per-row rowscroll on BG0 and BG1
  - Priority: bottomlayer bit from ctrl[6] bit 3
  - Tile flip: X and Y from tile attribute word bits [15:14]
  - ROM simulated procedurally (deterministic, address-based)

Public API:
  write(addr, data)              -- write 16-bit word to VRAM (word-addressed)
  write_ctrl(reg, data)          -- write control register (reg 0-7)
  get_line(scanline) -> list     -- 320 tuples: (bg0_pix, bg1_pix, fg0_pix, priority)
      bg0_pix: 4-bit (0=transparent)
      bg1_pix: 4-bit (0=transparent)
      fg0_pix: 2-bit (0=transparent)
      priority: bottomlayer bit (0=BG0 bottom, 1=BG1 bottom)
"""

# ---------------------------------------------------------------------------
# Procedural ROM generator for tile data.
# BG tiles: 8×8 pixels, 4bpp, 8 pixels per 32-bit word.
# ROM address = {tile_code[15:0], 1'b0, trow[2:0]} (20 bits, per RTL).
# Returns 8 nibbles (pixels 0-7, pixel 0 in bits [31:28] of the 32-bit word).
# ---------------------------------------------------------------------------

def rom_data_32(addr20):
    """Return a 32-bit tile ROM word for the given 20-bit address.
    Pixel 0 is in bits [31:28] (MSB), pixel 7 is in bits [3:0] (LSB).
    Values are 4-bit nibbles, never 0 (use 1..15 range to ensure non-transparent)."""
    code  = (addr20 >> 4) & 0xFFFF   # tile code from upper 16 bits
    trow  = addr20 & 0x7              # tile row from bottom 3 bits
    result = 0
    for px in range(8):
        raw = ((code & 0xFF) ^ (trow * 7) ^ (px * 3)) & 0xF
        if raw == 0:
            raw = 1   # avoid transparent (0=transparent for BG layers)
        result = (result << 4) | raw
    return result & 0xFFFFFFFF


def rom_nibbles(code, trow):
    """Return list of 8 nibbles [px0..px7] for a BG tile row."""
    addr20 = ((code & 0xFFFF) << 4) | (trow & 0x7)
    word = rom_data_32(addr20)
    return [(word >> (28 - i*4)) & 0xF for i in range(8)]


# ---------------------------------------------------------------------------
# TC0100SCNModel
# ---------------------------------------------------------------------------

class TC0100SCNModel:
    """
    Behavioral model of the TC0100SCN tilemap generator.

    VRAM word addresses (16-bit words) — single-width mode:
      0x0000-0x1FFF  BG0 tilemap (64×64 × 2 words, byte 0x0000-0x3FFF)
      0x2000-0x2FFF  BG1 tilemap (64×64 × 2 words, byte 0x4000-0x5FFF)
      0x3000-0x37FF  FG0 char RAM (256 chars × 8 words, byte 0x6000-0x6FFF)
      0x4000-0x4FFF  FG0 tilemap  (64×64 × 1 word,  byte 0x8000-0x9FFF)
      Rowscroll/colscroll shadow RAMs are written at RTL-decoded addresses:
        BG0 rowscroll: word 0x3000-0x31FF (RTL: addr[15:9]==0x18, byte 0x6000)
        BG1 rowscroll: word 0x3200-0x33FF (RTL: addr[15:9]==0x19, byte 0x6400)
        BG1 colscroll: word 0x3800-0x387F (RTL: addr[15:7]==0x70,  byte 0x7000)
      Note: BG0 rowscroll region (0x3000) overlaps with FG0 char RAM in the
      unified VRAM; in Verilator mode this is handled by the flat array.

    Control registers (write via write_ctrl):
      0: BG0_SCROLLX   1: BG1_SCROLLX   2: FG0_SCROLLX
      3: BG0_SCROLLY   4: BG1_SCROLLY   5: FG0_SCROLLY
      6: LAYER_CTRL    7: FLIP_CTRL

    LAYER_CTRL (ctrl[6]) bits:
      [0] bg0_dis   [1] bg1_dis   [2] fg0_dis
      [3] priority swap (bottomlayer: 0=BG0 bottom, 1=BG1 bottom)
      [4] double-width (not fully modelled here; single-width assumed)

    FLIP_CTRL (ctrl[7]) bits:
      [0] flip_screen (X+Y flip of all layers)
    """

    # VRAM base addresses (word offsets in standard single-width mode)
    # These match the RTL's actual address decode logic, not the spec comments.
    # RTL uses addr[15:9] comparisons:
    #   BG0 rowscroll: addr[15:9]==0x18 → word 0x3000 (byte 0x6000)
    #   BG1 rowscroll: addr[15:9]==0x19 → word 0x3200 (byte 0x6400)
    #   BG1 colscroll: addr[15:7]==0x70 → word 0x3800 (byte 0x7000)
    # Note: section1_registers.md lists different byte addresses (0xC000/0xC400/0xE000)
    #   but the RTL implements addresses 0x6000/0x6400/0x7000 (byte). We match RTL.
    BG0_BASE  = 0x0000   # BG0 tilemap: 64×64 × 2 words
    BG1_BASE  = 0x2000   # BG1 tilemap: 64×64 × 2 words (byte 0x4000)
    FG_CHAR_BASE = 0x3000  # FG0 char RAM: 256 chars × 8 words each (byte 0x6000)
    FG_MAP_BASE  = 0x4000  # FG0 tilemap: 64×64 × 1 word (byte 0x8000)
    BG0_RS_BASE  = 0x3000  # BG0 rowscroll RAM (512 words, byte 0x6000) — RTL addr
    BG1_RS_BASE  = 0x3200  # BG1 rowscroll RAM (512 words, byte 0x6400) — RTL addr
    BG1_CS_BASE  = 0x3800  # BG1 colscroll RAM (128 words, byte 0x7000) — RTL addr

    MAP_W = 64   # tilemap width in tiles (single-width)
    MAP_H = 64   # tilemap height in tiles

    def __init__(self):
        self.vram = {}           # word addr → 16-bit value (sparse)
        self.ctrl = [0] * 8     # raw CPU values (for readback)

        # Internal scroll registers (negated): internal = -cpu_value, 10-bit
        self._bg0_scrollx = 0
        self._bg0_scrolly = 0
        self._bg1_scrollx = 0
        self._bg1_scrolly = 0
        self._fg0_scrollx = 0
        self._fg0_scrolly = 0

    # -----------------------------------------------------------------------
    # Public: VRAM write (word address)
    # -----------------------------------------------------------------------
    def write(self, addr, data):
        """Write a 16-bit word to VRAM. addr is word-addressed (byte_addr >> 1)."""
        addr = addr & 0x1FFFF   # 17-bit word address (128K words)
        self.vram[addr] = data & 0xFFFF

    # -----------------------------------------------------------------------
    # Public: Control register write
    # -----------------------------------------------------------------------
    def write_ctrl(self, reg, data):
        """Write control register reg (0-7) with 16-bit data."""
        reg = reg & 0x7
        self.ctrl[reg] = data & 0xFFFF
        # Scroll registers: negate and mask to 10 bits
        if reg == 0:
            self._bg0_scrollx = (-data) & 0x3FF
        elif reg == 1:
            self._bg1_scrollx = (-data) & 0x3FF
        elif reg == 2:
            self._fg0_scrollx = (-data) & 0x3FF
        elif reg == 3:
            self._bg0_scrolly = (-data) & 0x3FF
        elif reg == 4:
            self._bg1_scrolly = (-data) & 0x3FF
        elif reg == 5:
            self._fg0_scrolly = (-data) & 0x3FF

    # -----------------------------------------------------------------------
    # Helper: read VRAM word (returns 0 if not written)
    # -----------------------------------------------------------------------
    def _vr(self, addr):
        return self.vram.get(addr & 0x1FFFF, 0)

    # -----------------------------------------------------------------------
    # Helper: sign-extend a 16-bit value to signed int
    # -----------------------------------------------------------------------
    @staticmethod
    def _s16(v):
        v = v & 0xFFFF
        return v if v < 0x8000 else v - 0x10000

    # -----------------------------------------------------------------------
    # Helper: get BG tile entry for a given tile (col, row) in the map
    # Returns (flip_x, flip_y, color, code)
    # -----------------------------------------------------------------------
    def _bg_tile(self, layer, col, row):
        """Get BG tile entry.  layer=0→BG0, layer=1→BG1."""
        col = col & (self.MAP_W - 1)
        row = row & (self.MAP_H - 1)
        if layer == 0:
            base = self.BG0_BASE
        else:
            base = self.BG1_BASE
        waddr = base + (row * self.MAP_W + col) * 2
        attr = self._vr(waddr)
        code = self._vr(waddr + 1)
        flip_yx = (attr >> 14) & 0x3   # [1]=yflip [0]=xflip
        color   = attr & 0xFF
        return bool(flip_yx & 1), bool(flip_yx & 2), color, code & 0xFFFF

    # -----------------------------------------------------------------------
    # Helper: get FG tile entry for a given tile (col, row)
    # Returns (flip_x, flip_y, color, char_code)
    # -----------------------------------------------------------------------
    def _fg_tile(self, col, row):
        col = col & (self.MAP_W - 1)
        row = row & (self.MAP_H - 1)
        waddr = self.FG_MAP_BASE + row * self.MAP_W + col
        attr = self._vr(waddr)
        char_code = attr & 0xFF
        color     = (attr >> 8) & 0x3F
        flip_yx   = (attr >> 14) & 0x3
        return bool(flip_yx & 1), bool(flip_yx & 2), color, char_code

    # -----------------------------------------------------------------------
    # Helper: get FG character pixel row
    # char data: 2bpp, 1 word per row, 8 rows per char
    # word bits [15:14] = px0, [13:12]=px1, ..., [1:0]=px7 (MSB first)
    # Returns list of 8 2-bit values
    # -----------------------------------------------------------------------
    def _fg_char_row(self, char_code, row):
        waddr = self.FG_CHAR_BASE + (char_code & 0xFF) * 8 + (row & 7)
        word = self._vr(waddr)
        return [(word >> (14 - i*2)) & 0x3 for i in range(8)]

    # -----------------------------------------------------------------------
    # Helper: read rowscroll for a given layer and scanline
    # Rowscroll index: (scanline + global_scrolly) & 0x1FF
    # -----------------------------------------------------------------------
    def _bg_rowscroll(self, layer, scanline, scrolly):
        ridx = (scanline + scrolly) & 0x1FF
        if layer == 0:
            base = self.BG0_RS_BASE
        else:
            base = self.BG1_RS_BASE
        return self._s16(self._vr(base + ridx))

    # -----------------------------------------------------------------------
    # Helper: read BG1 colscroll for a given tile-space X position
    # colscroll index: tilemap-space X / 8 (0-127)
    # -----------------------------------------------------------------------
    def _bg1_colscroll(self, tx_x):
        ridx = (tx_x >> 3) & 0x7F
        return self._s16(self._vr(self.BG1_CS_BASE + ridx))

    # -----------------------------------------------------------------------
    # Public: get_line — compute one scanline of pixel output
    # Returns list of 320 tuples: (bg0_pix, bg1_pix, fg0_pix, priority)
    # -----------------------------------------------------------------------
    def get_line(self, scanline):
        """
        Compute pixel output for scanline (0-261).
        Returns 320 tuples of (bg0_pix, bg1_pix, fg0_pix, priority):
          bg0_pix: 4-bit (0=transparent)
          bg1_pix: 4-bit (0=transparent)
          fg0_pix: 2-bit (0=transparent)
          priority: bottomlayer bit (ctrl[6] bit 3)
        """
        lc = self.ctrl[6]
        fc = self.ctrl[7]

        bg0_dis = bool(lc & 0x01)
        bg1_dis = bool(lc & 0x02)
        fg0_dis = bool(lc & 0x04)
        bottomlayer = (lc >> 3) & 1
        flip_screen = bool(fc & 0x01)

        # Effective scanline after Y-flip
        eff_scanline = scanline
        if flip_screen:
            eff_scanline = 239 - scanline   # mirror within 240-line display

        result = []
        for px in range(320):
            # Effective X after screen X-flip
            eff_px = px
            if flip_screen:
                eff_px = 319 - px

            # ── BG0 pixel ─────────────────────────────────────────────────
            bg0_pix = 0
            if not bg0_dis:
                # Rowscroll per spec: effective_x = bg0_scrollx_r - rowscroll_ram[scanline]
                # bg0_scrollx_r = -cpu_scrollx = _bg0_scrollx (already negated)
                rs = self._bg_rowscroll(0, eff_scanline, self._bg0_scrolly)
                # effective tilemap X: scrollx - rowscroll + screen_x
                tx_x = (self._bg0_scrollx - rs + eff_px) & 0x1FF
                ty_y = (self._bg0_scrolly + eff_scanline) & 0x1FF

                tile_col = (tx_x >> 3) & (self.MAP_W - 1)
                tile_row = (ty_y >> 3) & (self.MAP_H - 1)
                px_in_tile = tx_x & 7
                row_in_tile = ty_y & 7

                flip_x, flip_y, _color, code = self._bg_tile(0, tile_col, tile_row)
                if flip_y:
                    row_in_tile = 7 - row_in_tile
                pixels = rom_nibbles(code, row_in_tile)
                if flip_x:
                    pixels = list(reversed(pixels))
                bg0_pix = pixels[px_in_tile]

            # ── BG1 pixel ─────────────────────────────────────────────────
            bg1_pix = 0
            if not bg1_dis:
                rs = self._bg_rowscroll(1, eff_scanline, self._bg1_scrolly)
                tx_x = (self._bg1_scrollx - rs + eff_px) & 0x1FF
                ty_y_base = (self._bg1_scrolly + eff_scanline) & 0x1FF

                # Colscroll: Y offset per 8-pixel column (indexed by tilemap-space X)
                cs = self._bg1_colscroll(tx_x)
                ty_y = (ty_y_base - cs) & 0x1FF

                tile_col = (tx_x >> 3) & (self.MAP_W - 1)
                tile_row = (ty_y >> 3) & (self.MAP_H - 1)
                px_in_tile = tx_x & 7
                row_in_tile = ty_y & 7

                flip_x, flip_y, _color, code = self._bg_tile(1, tile_col, tile_row)
                if flip_y:
                    row_in_tile = 7 - row_in_tile
                pixels = rom_nibbles(code, row_in_tile)
                if flip_x:
                    pixels = list(reversed(pixels))
                bg1_pix = pixels[px_in_tile]

            # ── FG0 pixel ─────────────────────────────────────────────────
            fg0_pix = 0
            if not fg0_dis:
                tx_x = (self._fg0_scrollx + eff_px) & 0x1FF
                ty_y = (self._fg0_scrolly + eff_scanline) & 0x1FF

                tile_col = (tx_x >> 3) & (self.MAP_W - 1)
                tile_row = (ty_y >> 3) & (self.MAP_H - 1)
                px_in_tile = tx_x & 7
                row_in_tile = ty_y & 7

                flip_x, flip_y, _color, char_code = self._fg_tile(tile_col, tile_row)
                if flip_y:
                    row_in_tile = 7 - row_in_tile
                pixels = self._fg_char_row(char_code, row_in_tile)
                if flip_x:
                    pixels = list(reversed(pixels))
                fg0_pix = pixels[px_in_tile]

            result.append((bg0_pix, bg1_pix, fg0_pix, bottomlayer))

        return result
