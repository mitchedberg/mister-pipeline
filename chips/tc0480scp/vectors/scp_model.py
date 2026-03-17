"""
TC0480SCP behavioral model.

Steps 1–8:
  Step 1: Control registers + video timing.
  Step 2: 64KB VRAM read/write.
  Step 3: FG0 text layer rendering.
  Step 4: BG0/BG1 tile layer rendering (global scroll, no zoom).
  Step 5: BG0/BG1 rowscroll (no-zoom path).
  Step 6: BG0/BG1 global zoom.
  Step 7: BG2/BG3 colscroll (colscroll applied before rowzoom).
  Step 8: BG2/BG3 per-row zoom.

Public API:
  TC0480SCPModel.__init__()
  write_ctrl(word_addr, data, be=0x3)   → write control register
  read_ctrl(word_addr)                   → read control register
  write_ram(word_addr, data, be=0x3)     → write VRAM (word address)
  read_ram(word_addr)                    → read VRAM (word address)
  load_gfx_rom(data_bytes)               → load packed GFX ROM image
  render_scanline(y) → [320 ints]        → composited pixel output for scanline y
  render_frame()     → [[ints]]          → full 240-scanline frame

  Decoded register accessors (from Step 1):
  bgscrollx(layer), bgscrolly(layer), bgzoom(layer)
  bg_dx(layer), bg_dy(layer), text_scrollx(), text_scrolly()
  dblwidth(), flipscreen(), priority_order(), rowzoom_en(layer), bg_priority()

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

# ── MAME rendering constants ─────────────────────────────────────────────────
# MAME renders a 512-wide source line internally; output is clipped to 320 pixels.
# y_offset / min_y in MAME bg01_draw = 0 (hardware starts at scanline 0 of active area).
_Y_OFFSET = 0
_MIN_Y    = 0
_MAX_Y    = 240


class TC0480SCPModel:
    """Behavioral model of TC0480SCP chip (Steps 1–8)."""

    def __init__(self):
        # Step 1: 24 × 16-bit control registers
        self._ctrl = [0] * 24
        # Step 2: 64KB VRAM as 32768 × 16-bit words
        self._vram = [0] * 32768
        # Step 4: GFX ROM as word-addressed 32-bit array (up to 2^21 words)
        self._gfx_rom = {}  # sparse dict: word_addr → 32-bit value

    # ── Register access (Step 1) ───────────────────────────────────────────

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

    # ── LAYER_CTRL decode (Step 1) ────────────────────────────────────────

    def _layer_ctrl(self) -> int:
        return self._ctrl[15]

    def dblwidth(self) -> bool:
        return bool(self._layer_ctrl() & 0x80)

    def flipscreen(self) -> bool:
        return bool(self._layer_ctrl() & 0x40)

    def priority_order(self) -> int:
        return (self._layer_ctrl() >> 2) & 0x7

    def rowzoom_en(self, layer: int) -> bool:
        if layer == 2:
            return bool(self._layer_ctrl() & 0x01)
        elif layer == 3:
            return bool(self._layer_ctrl() & 0x02)
        return False

    def bg_priority(self) -> int:
        return _PRI_LUT[self.priority_order()]

    # ── Scroll decode (Step 1) ────────────────────────────────────────────

    def bgscrollx(self, layer: int) -> int:
        raw = self._ctrl[layer] & 0xFFFF
        val = (raw + _STAGGER[layer]) & 0xFFFF
        if self.flipscreen():
            return val
        else:
            return (-val) & 0xFFFF

    def bgscrolly(self, layer: int) -> int:
        raw = self._ctrl[4 + layer] & 0xFFFF
        if self.flipscreen():
            return (-raw) & 0xFFFF
        else:
            return raw

    def bgzoom(self, layer: int) -> int:
        return self._ctrl[8 + layer] & 0xFFFF

    def bg_dx(self, layer: int) -> int:
        return self._ctrl[16 + layer] & 0xFF

    def bg_dy(self, layer: int) -> int:
        return self._ctrl[20 + layer] & 0xFF

    def text_scrollx(self) -> int:
        return self._ctrl[12] & 0xFFFF

    def text_scrolly(self) -> int:
        return self._ctrl[13] & 0xFFFF

    # ── VRAM access (Step 2) ──────────────────────────────────────────────

    def write_ram(self, word_addr: int, data: int, be: int = 0x3) -> None:
        """Write one VRAM word (16-bit).

        word_addr: 0–0x7FFF  (= byte_address >> 1, within 64KB VRAM window)
        data:      16-bit value
        be:        byte enables, bit1=upper, bit0=lower
        """
        if not (0 <= word_addr <= 0x7FFF):
            raise ValueError(f"word_addr 0x{word_addr:04X} out of VRAM range")
        data = data & 0xFFFF
        cur  = self._vram[word_addr]
        if be & 0x2:
            cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1:
            cur = (cur & 0xFF00) | (data & 0x00FF)
        self._vram[word_addr] = cur

    def read_ram(self, word_addr: int) -> int:
        """Read one VRAM word. Returns 16-bit value."""
        if not (0 <= word_addr <= 0x7FFF):
            raise ValueError(f"word_addr 0x{word_addr:04X} out of VRAM range")
        return self._vram[word_addr]

    # ── GFX ROM (Step 4) ──────────────────────────────────────────────────

    def load_gfx_rom(self, data_bytes: bytes) -> None:
        """Load packed GFX ROM image.

        data_bytes: raw bytes of the GFX ROM (little-endian 32-bit words).
        Length must be a multiple of 4 bytes (one 32-bit word per 4 bytes).
        """
        assert len(data_bytes) % 4 == 0, "GFX ROM size must be multiple of 4"
        self._gfx_rom = {}
        for i in range(len(data_bytes) // 4):
            b0 = data_bytes[i*4+0]
            b1 = data_bytes[i*4+1]
            b2 = data_bytes[i*4+2]
            b3 = data_bytes[i*4+3]
            word32 = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            self._gfx_rom[i] = word32

    def write_gfx_rom_word(self, word_addr: int, data32: int) -> None:
        """Write a single 32-bit word to the GFX ROM (for test setup)."""
        self._gfx_rom[word_addr] = data32 & 0xFFFFFFFF

    def _read_gfx_rom(self, word_addr: int) -> int:
        """Read a 32-bit word from GFX ROM. Returns 0 if not written."""
        return self._gfx_rom.get(word_addr, 0)

    # ── FG0 tile pixel decoder (Step 3) ──────────────────────────────────

    def _decode_fg_tile_row(self, tile_idx: int, py: int) -> list:
        """Decode 8 pixels from FG0 gfx data for tile tile_idx, row py.

        Returns list of 8 × 4-bit pen values (0 = transparent).
        Uses VRAM 0x7000 + tile_idx*16 + py*2 (two 16-bit words).

        Section1 §4.3 pixel layout:
          row32 = {word1, word0}
          px0=row32[15:12], px1=row32[11:8], px2=row32[7:4], px3=row32[3:0]
          px4=row32[31:28], px5=row32[27:24], px6=row32[23:20], px7=row32[19:16]
        """
        gfx_base = 0x7000 + tile_idx * 16
        word0 = self._vram[gfx_base + py * 2]
        word1 = self._vram[gfx_base + py * 2 + 1]
        row32 = ((word1 & 0xFFFF) << 16) | (word0 & 0xFFFF)
        pens = [
            (row32 >> 12) & 0xF,  # px0
            (row32 >>  8) & 0xF,  # px1
            (row32 >>  4) & 0xF,  # px2
            (row32 >>  0) & 0xF,  # px3
            (row32 >> 28) & 0xF,  # px4
            (row32 >> 24) & 0xF,  # px5
            (row32 >> 20) & 0xF,  # px6
            (row32 >> 16) & 0xF,  # px7
        ]
        return pens

    def _render_text_scanline(self, y: int) -> list:
        """Render FG0 text layer for visible scanline y (0-based, 0..239).

        Returns list of 320 × (color<<4|pen) values. pen==0 → 0 (transparent).
        """
        result = [0] * 320
        # Canvas Y for this scanline
        canvas_y = (y + self.text_scrolly()) & 0x1FF
        tile_row = (canvas_y >> 3) & 0x3F   # 6-bit tile row (0..63)
        py       = canvas_y & 0x7            # pixel row within tile

        for screen_x in range(320):
            canvas_x  = (screen_x + self.text_scrollx()) & 0x1FF
            tile_col  = (canvas_x >> 3) & 0x3F   # 6-bit tile col
            px_in_tile = canvas_x & 0x7           # pixel within tile

            # FG0 tile map word address: 0x6000 + tile_row*64 + tile_col
            map_addr = 0x6000 + tile_row * 64 + tile_col
            tile_word = self._vram[map_addr]

            tile_flipy = (tile_word >> 15) & 1
            tile_flipx = (tile_word >> 14) & 1
            color      = (tile_word >>  8) & 0x3F
            tile_idx   = tile_word & 0xFF

            # Apply flips
            row_py    = (7 - py)    if tile_flipy else py
            col_px    = (7 - px_in_tile) if tile_flipx else px_in_tile

            # Decode pixels
            pens = self._decode_fg_tile_row(tile_idx, row_py)
            pen  = pens[col_px]

            if pen != 0:
                result[screen_x] = (color << 4) | pen
        return result

    # ── BG tile pixel decoder (Step 4) ───────────────────────────────────

    def _decode_bg_tile_row(self, tile_code: int, py: int, flipx: bool, flipy: bool) -> list:
        """Decode 16 pixels from BG GFX ROM for tile tile_code, row py.

        GFX ROM format (section1 §8.1):
          16×16 tiles, 4bpp packed LSB.
          128 bytes/tile = 32 × 32-bit words.
          Left 8 pixels (row r): word = tile_code*32 + r*2
          Right 8 pixels:        word = tile_code*32 + r*2 + 1
          bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7

        flipX reverses nibble order within each 8-px half AND swaps halves.
        flipY uses row (15 - py).
        """
        actual_row = (15 - py) if flipy else py
        base = tile_code * 32 + actual_row * 2

        left_word  = self._read_gfx_rom(base)
        right_word = self._read_gfx_rom(base + 1)

        def extract_half(word32: int, flip: bool) -> list:
            # bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7
            raw = [(word32 >> (28 - 4*i)) & 0xF for i in range(8)]
            if flip:
                raw = raw[::-1]
            return raw

        if flipx:
            # flipX: swap halves AND reverse within each half
            pens = extract_half(right_word, True) + extract_half(left_word, True)
        else:
            pens = extract_half(left_word, False) + extract_half(right_word, False)
        return pens  # 16 pixels

    # ── VRAM scroll RAM address helpers (Steps 5–8) ───────────────────────

    def _rs_hi_addr(self, layer: int, row: int) -> int:
        """Word address of rowscroll-hi entry for layer/row."""
        dw = self.dblwidth()
        base = 0x4000 if dw else 0x2000
        return base + layer * 0x200 + (row & 0x1FF)

    def _rs_lo_addr(self, layer: int, row: int) -> int:
        """Word address of rowscroll-lo entry for layer/row."""
        dw = self.dblwidth()
        base = 0x4800 if dw else 0x2800
        return base + layer * 0x200 + (row & 0x1FF)

    def _rz_addr(self, layer: int, row: int) -> int:
        """Word address of rowzoom entry for BG2/BG3 layer/row."""
        assert layer >= 2
        dw = self.dblwidth()
        base = 0x5000 if dw else 0x3000
        return base + (layer - 2) * 0x200 + (row & 0x1FF)

    def _cs_addr(self, layer: int, col: int) -> int:
        """Word address of colscroll entry for BG2/BG3 layer/col."""
        assert layer >= 2
        dw = self.dblwidth()
        base = 0x5400 if dw else 0x3400
        return base + (layer - 2) * 0x200 + (col & 0x1FF)

    # ── BG zoom decode (Step 6) ───────────────────────────────────────────

    def _zoom_decode(self, layer: int):
        """Decode zoomx and zoomy from bgzoom register.

        Returns (zoomx, zoomy) as 32-bit fixed-point values.
        1:1 = 0x10000. Both are unsigned.
        """
        zoom_word = self.bgzoom(layer)
        xzoom = (zoom_word >> 8) & 0xFF
        yzoom = zoom_word & 0xFF
        zoomx = (0x10000 - (xzoom << 8)) & 0xFFFFFFFF
        # ydiff = yzoom - 0x7F (signed 9-bit, but just use Python int)
        ydiff = yzoom - 0x7F
        zoomy = (0x10000 - ydiff * 512) & 0xFFFFFFFF
        return zoomx, zoomy

    def _nozoom(self, layer: int) -> bool:
        zoomx, zoomy = self._zoom_decode(layer)
        return zoomx == 0x10000 and zoomy == 0x10000

    # ── BG rendering (Steps 4–8) ──────────────────────────────────────────

    def _render_bg_scanline(self, layer: int, y: int) -> list:
        """Render BG layer (0–3) for visible scanline y (0-based, 0..239).

        Supports all rendering modes:
          - No-zoom path: global scroll + per-row rowscroll (Steps 4–5)
          - Zoom path: global zoom, Y accumulator, X accumulator (Step 6)
          - BG2/BG3: colscroll before rowzoom (Steps 7–8)

        Returns list of 320 × (color<<4|pen) values. pen==0 → 0 (transparent).
        """
        result = [0] * 320
        scrollx = self.bgscrollx(layer)   # effective X scroll (stagger baked in)
        scrolly = self.bgscrolly(layer)   # effective Y scroll
        dw = self.dblwidth()
        flip = self.flipscreen()

        # Tile map geometry
        map_width  = 64 if dw else 32
        width_mask = 0x3FF if dw else 0x1FF
        layer_base = (layer * 0x0800) if dw else (layer * 0x0400)

        zoomx, zoomy = self._zoom_decode(layer)
        nozoom = (zoomx == 0x10000 and zoomy == 0x10000)

        if nozoom:
            # ── No-zoom path (Steps 4–5, 7) ───────────────────────────────
            # Source Y for this scanline: canvas_y = (y + scrolly) & 0x1FF
            canvas_y = (y + scrolly) & 0x1FF

            # BG2/BG3: apply colscroll before rowzoom/rowscroll (Step 7)
            if layer >= 2:
                col_idx = (0x1FF - y) & 0x1FF if flip else y & 0x1FF
                cs = self._vram[self._cs_addr(layer, col_idx)]
                cs_s = cs if cs < 0x8000 else cs - 0x10000
                src_y = (canvas_y + cs_s) & 0x1FF
            else:
                src_y = canvas_y

            tile_row = (src_y >> 4) & 0x1F
            py       = src_y & 0xF

            # Rowscroll for this source row (Step 5)
            row_idx = (0x1FF - src_y) & 0x1FF if flip else src_y & 0x1FF
            rs_hi = self._vram[self._rs_hi_addr(layer, row_idx)]
            rs_lo = self._vram[self._rs_lo_addr(layer, row_idx)]
            # rs_hi is signed 16-bit; rs_lo low byte is sub-pixel
            # effective_scrollx = bgscrollx - (rs_hi<<16) - (rs_lo<<8)  [fixed-point]
            # The integer pixel offset contributed:
            #   pixel_delta = rs_hi (whole pixels) + (rs_lo & 0xFF) as fractional
            # For the MAME tilemap engine equivalent:
            #   set_scrollx(row, bgscrollx - rowscroll_ram[row])
            # where rowscroll_ram[row] = rs_hi (in MAME, only hi byte is used for
            # integer scroll; lo adds sub-pixel). For whole-pixel accuracy:
            #   x_start_fp = (scrollx << 16) - (rs_hi_signed << 16) - ((rs_lo & 0xFF) << 8)
            rs_hi_s = rs_hi if rs_hi < 0x8000 else rs_hi - 0x10000
            x_fp = ((scrollx << 16) - (rs_hi_s << 16) - ((rs_lo & 0xFF) << 8)) & 0xFFFFFFFF

            for screen_x in range(320):
                src_x = (x_fp >> 16) & width_mask
                tile_col  = (src_x >> 4) & (map_width - 1)
                px_in_tile = src_x & 0xF
                tile_idx  = tile_row * map_width + tile_col
                word_base = layer_base + tile_idx * 2
                attr_word = self._vram[word_base]
                code_word = self._vram[word_base + 1]
                tile_flipy = (attr_word >> 15) & 1
                tile_flipx = (attr_word >> 14) & 1
                color      = attr_word & 0xFF
                tile_code  = code_word & 0x7FFF
                pens = self._decode_bg_tile_row(tile_code, py,
                                                bool(tile_flipx), bool(tile_flipy))
                pen = pens[px_in_tile]
                if pen != 0:
                    result[screen_x] = (color << 4) | pen
                x_fp = (x_fp + 0x10000) & 0xFFFFFFFF

        else:
            # ── Zoom path (Step 6) ────────────────────────────────────────
            # Y accumulator: y_index = (scrolly<<16) + (bg_dy<<8) - (y_offset-min_y)*zoomy
            # With y_offset=0, min_y=0: y_index_at_y = (scrolly<<16) + (bg_dy<<8) + y*zoomy
            # (y=0 → start value; advances by zoomy each scanline)
            bg_dy_val = self.bg_dy(layer)
            bg_dx_val = self.bg_dx(layer)
            y_index_start = ((scrolly << 16) + (bg_dy_val << 8)) & 0xFFFFFFFF
            y_index = (y_index_start + y * zoomy) & 0xFFFFFFFF

            src_y_raw = (y_index >> 16) & 0x1FF

            # BG2/BG3: apply colscroll (Step 7)
            if layer >= 2:
                col_idx = (0x1FF - y) & 0x1FF if flip else y & 0x1FF
                cs = self._vram[self._cs_addr(layer, col_idx)]
                cs_s = cs if cs < 0x8000 else cs - 0x10000
                src_y = (src_y_raw + cs_s) & 0x1FF
            else:
                src_y = src_y_raw

            row_idx = (0x1FF - src_y) & 0x1FF if flip else src_y

            # BG2/BG3: per-row zoom (Step 8)
            # Note: RTL does NOT apply rz_lo to x_step (x_step_r is unused in BG_WRITE).
            # Only the x_origin adjustment (rz_origin) is implemented.
            if layer >= 2 and self.rowzoom_en(layer):
                rz = self._vram[self._rz_addr(layer, row_idx)]
                rz_lo = rz & 0xFF
                x_step = zoomx  # RTL: x_step = zoomx (no rz reduction applied)
                # x_origin adjustment: x_index -= (LAYER*4 - 31) * (rz_lo<<8)
                factor = layer * 4 - 31
                rz_origin = factor * (rz_lo << 8)
            else:
                x_step = zoomx
                rz_origin = 0

            # Rowscroll (zoom path reads but applies rowscroll too per MAME)
            # Note: MAME's bg01_draw with zoom does read rowscroll! Check section2.
            # section2 §2.1 line 68: x_index = sx - rs_hi<<16 - rs_lo<<8
            # So rowscroll IS applied in zoom path too. Only difference: x_step=zoomx not 0x10000.
            rs_hi = self._vram[self._rs_hi_addr(layer, row_idx)]
            rs_lo = self._vram[self._rs_lo_addr(layer, row_idx)]
            rs_hi_s = rs_hi if rs_hi < 0x8000 else rs_hi - 0x10000

            # SX base (zoom path):
            # sx = (scrollx_raw + 15 + layer*4)<<16 + (255-bg_dx)<<8 + (-15-layer*4)*zoomx
            # scrollx_raw = ctrl[layer] (before stagger negation)
            scrollx_raw = self._ctrl[layer] & 0xFFFF
            scroll_adj = (scrollx_raw + 15 + layer * 4) & 0xFFFF
            # Sign-extend scroll_adj to 32-bit
            if scroll_adj >= 0x8000:
                scroll_adj_s = scroll_adj - 0x10000
            else:
                scroll_adj_s = scroll_adj
            sx_term_scroll = scroll_adj_s << 16
            sx_term_dx     = (255 - bg_dx_val) << 8
            neg_origin     = -15 - layer * 4
            sx_term_origin = neg_origin * zoomx
            sx = (sx_term_scroll + sx_term_dx + sx_term_origin) & 0xFFFFFFFF

            # x_index_start = sx - rs_hi<<16 - rs_lo<<8 - rz_origin
            x_fp = (sx - (rs_hi_s << 16) - ((rs_lo & 0xFF) << 8) - rz_origin) & 0xFFFFFFFF

            # Source Y tile row from src_y
            tile_row = (src_y >> 4) & 0x1F
            py       = src_y & 0xF

            for screen_x in range(320):
                src_x = (x_fp >> 16) & width_mask
                tile_col   = (src_x >> 4) & (map_width - 1)
                px_in_tile = src_x & 0xF
                tile_idx   = tile_row * map_width + tile_col
                word_base  = layer_base + tile_idx * 2
                attr_word  = self._vram[word_base]
                code_word  = self._vram[word_base + 1]
                tile_flipy = (attr_word >> 15) & 1
                tile_flipx = (attr_word >> 14) & 1
                color      = attr_word & 0xFF
                tile_code  = code_word & 0x7FFF
                pens = self._decode_bg_tile_row(tile_code, py,
                                                bool(tile_flipx), bool(tile_flipy))
                pen = pens[px_in_tile]
                if pen != 0:
                    result[screen_x] = (color << 4) | pen
                x_fp = (x_fp + x_step) & 0xFFFFFFFF

        return result

    # ── Compositing (Step 3+) ─────────────────────────────────────────────

    def render_scanline(self, y: int) -> list:
        """Render composited scanline y (0-based, 0..239) → list of 320 pixels.

        Compositing order (bottom to top):
          BG layers in bg_priority order (nibbles [15:12]=bottom, [3:0]=top)
          FG0 text always topmost.
        Transparent pen = 0 → pixel = 0 (does not overwrite lower layer).
        """
        # Result array: 320 pixels, initialized to 0 (background/transparent)
        output = [0] * 320

        # BG layers in priority order (bottom first)
        pri = self.bg_priority()
        for i in range(4):
            layer = (pri >> (12 - i * 4)) & 0xF
            bg_row = self._render_bg_scanline(layer, y)
            for x in range(320):
                if bg_row[x] != 0:
                    output[x] = bg_row[x]

        # FG0 text (always topmost)
        text_row = self._render_text_scanline(y)
        for x in range(320):
            if text_row[x] != 0:
                output[x] = text_row[x]

        return output

    def render_frame(self) -> list:
        """Render full 240-scanline frame → list of 240 × 320 pixels."""
        return [self.render_scanline(y) for y in range(240)]
