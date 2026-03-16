"""
TC0180VCU behavioral model — Python reference implementation.
Covers: CPU bus interface, register bank, VRAM, sprite RAM, scroll RAM.
Pixel rendering pipeline is a future extension (section2_behavior.md §6).
"""


class TC0180VCU:
    # Memory sizes (in 16-bit words)
    VRAM_WORDS    = 32768   # 64KB
    SPRITE_WORDS  = 3264    # 0x1980 bytes / 2 = 3264 words = 408 sprites × 8 words
    SCROLL_WORDS  = 1024    # 2048 bytes

    def __init__(self):
        self.ctrl       = [0] * 16
        self.vram       = [0] * self.VRAM_WORDS
        self.sprite_ram = [0] * self.SPRITE_WORDS
        self.scroll_ram = [0] * self.SCROLL_WORDS
        # Framebuffer: two 512×256 pages
        self.fb         = [[0] * (512 * 256) for _ in range(2)]
        self.fb_page    = 0      # current write page
        self._rst()

    def _rst(self):
        self.ctrl       = [0] * 16
        self.vram       = [0] * self.VRAM_WORDS
        self.sprite_ram = [0] * self.SPRITE_WORDS
        self.scroll_ram = [0] * self.SCROLL_WORDS
        self.fb         = [[0] * (512 * 256) for _ in range(2)]
        self.fb_page    = 0

    # ── Address decode ──────────────────────────────────────────────────────

    def _decode(self, addr19):
        """Return (region, sub_addr) for a 19-bit word address."""
        if addr19 < 0x8000:                        # 0x00000–0x0FFFF VRAM
            return ('vram', addr19 & 0x7FFF)
        if 0x8000 <= addr19 <= 0x8CBF:             # 0x10000–0x1197F sprite
            return ('sprite', addr19 - 0x8000)
        if 0x9C00 <= addr19 <= 0x9FFF:             # 0x13800–0x13FFF scroll
            return ('scroll', addr19 - 0x9C00)
        if 0xC000 <= addr19 <= 0xC00F:             # 0x18000–0x1801F ctrl
            return ('ctrl', addr19 - 0xC000)
        if addr19 >= 0x20000:                      # 0x40000–0x7FFFF framebuffer
            return ('fb', addr19 - 0x20000)
        return ('none', 0)

    # ── CPU write ───────────────────────────────────────────────────────────

    def write(self, addr19: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word at 19-bit word address. be: bit1=high byte, bit0=low byte."""
        region, sub = self._decode(addr19)
        data &= 0xFFFF
        if region == 'vram':
            cur = self.vram[sub]
            if be & 2: cur = (cur & 0x00FF) | (data & 0xFF00)
            if be & 1: cur = (cur & 0xFF00) | (data & 0x00FF)
            self.vram[sub] = cur
        elif region == 'sprite':
            cur = self.sprite_ram[sub]
            if be & 2: cur = (cur & 0x00FF) | (data & 0xFF00)
            if be & 1: cur = (cur & 0xFF00) | (data & 0x00FF)
            self.sprite_ram[sub] = cur
        elif region == 'scroll':
            cur = self.scroll_ram[sub]
            if be & 2: cur = (cur & 0x00FF) | (data & 0xFF00)
            if be & 1: cur = (cur & 0xFF00) | (data & 0x00FF)
            self.scroll_ram[sub] = cur
        elif region == 'ctrl':
            cur = self.ctrl[sub]
            if be & 2: cur = (cur & 0x00FF) | (data & 0xFF00)
            if be & 1: cur = (cur & 0xFF00) | (data & 0x00FF)
            self.ctrl[sub] = cur

    # ── CPU read ────────────────────────────────────────────────────────────

    def read(self, addr19: int) -> int:
        """Read 16-bit word at 19-bit word address."""
        region, sub = self._decode(addr19)
        if region == 'vram':    return self.vram[sub]
        if region == 'sprite':  return self.sprite_ram[sub]
        if region == 'scroll':  return self.scroll_ram[sub]
        if region == 'ctrl':    return self.ctrl[sub]
        return 0

    # ── Control register accessors ──────────────────────────────────────────

    @property
    def fg_bank0(self):  return (self.ctrl[0] >> 8) & 0xF

    @property
    def fg_bank1(self):  return (self.ctrl[0] >> 12) & 0xF

    @property
    def bg_bank0(self):  return (self.ctrl[1] >> 8) & 0xF

    @property
    def bg_bank1(self):  return (self.ctrl[1] >> 12) & 0xF

    @property
    def fg_lpb(self):
        """FG lines per scroll block (1–256)."""
        n = (self.ctrl[2] >> 8) & 0xFF
        return 256 - n if n else 256

    @property
    def bg_lpb(self):
        """BG lines per scroll block (1–256)."""
        n = (self.ctrl[3] >> 8) & 0xFF
        return 256 - n if n else 256

    @property
    def tx_bank0(self):  return (self.ctrl[4] >> 8) & 0x3F

    @property
    def tx_bank1(self):  return (self.ctrl[5] >> 8) & 0x3F

    @property
    def tx_rampage(self): return (self.ctrl[6] >> 8) & 0xF

    @property
    def video_ctrl(self): return (self.ctrl[7] >> 8) & 0xFF

    # ── Tilemap helpers ─────────────────────────────────────────────────────

    def bg_tile(self, col: int, row: int):
        """Return (tile_code, color, flipx, flipy) for BG at (col, row) in 64×64 grid."""
        idx   = row * 64 + col
        bank0 = self.bg_bank0 << 12
        bank1 = self.bg_bank1 << 12
        code  = self.vram[bank0 + idx] & 0x7FFF
        attr  = self.vram[bank1 + idx]
        color = attr & 0x3F
        flipx = bool(attr & 0x4000)
        flipy = bool(attr & 0x8000)
        return (code, color, flipx, flipy)

    def fg_tile(self, col: int, row: int):
        """Return (tile_code, color, flipx, flipy) for FG at (col, row)."""
        idx   = row * 64 + col
        bank0 = self.fg_bank0 << 12
        bank1 = self.fg_bank1 << 12
        code  = self.vram[bank0 + idx] & 0x7FFF
        attr  = self.vram[bank1 + idx]
        color = attr & 0x3F
        flipx = bool(attr & 0x4000)
        flipy = bool(attr & 0x8000)
        return (code, color, flipx, flipy)

    def tx_tile(self, col: int, row: int):
        """Return (gfx_code, color) for TX at (col, row) in 64×32 grid."""
        idx      = row * 64 + col
        tx_base  = self.tx_rampage << 11
        word     = self.vram[tx_base + idx]
        color    = (word >> 12) & 0xF
        bank_sel = (word >> 11) & 0x1
        tile_idx = word & 0x7FF
        bank     = self.tx_bank0 if bank_sel == 0 else self.tx_bank1
        gfx_code = (bank << 11) | tile_idx
        return (gfx_code, color)

    def fg_scroll(self, scanline: int):
        """Return (scrollX, scrollY) for FG at given scanline."""
        lpb   = self.fg_lpb
        block = scanline // lpb
        sx    = self.scroll_ram[block * 2 * lpb]
        sy    = self.scroll_ram[block * 2 * lpb + 1]
        return (sx, sy)

    def bg_scroll(self, scanline: int):
        """Return (scrollX, scrollY) for BG at given scanline."""
        lpb   = self.bg_lpb
        block = scanline // lpb
        sx    = self.scroll_ram[0x200 + block * 2 * lpb]
        sy    = self.scroll_ram[0x200 + block * 2 * lpb + 1]
        return (sx, sy)

    # ── Sprite accessors ────────────────────────────────────────────────────

    NUM_SPRITES = 408

    # ── TX render ───────────────────────────────────────────────────────────

    def tx_render_line(self, vpos: int, gfx_rom: bytes) -> list:
        """Return 512-byte line buffer {color[3:0], pixel_idx[3:0]} for the
        scanline following vpos (pre-fetch pattern: fills during HBLANK).
        gfx_rom: bytes-like, at least 8MB (0x800000 bytes).
        """
        fetch_vpos = (vpos + 1) & 0xFF
        fetch_py   = fetch_vpos & 0x7
        fetch_row  = (fetch_vpos >> 3) & 0x1F
        tx_base    = self.tx_rampage << 11

        linebuf = [0] * 512
        for col in range(64):
            vram_idx  = tx_base + fetch_row * 64 + col
            word      = self.vram[vram_idx]
            color     = (word >> 12) & 0xF
            bank_sel  = (word >> 11) & 0x1
            tile_idx  = word & 0x7FF
            bank      = self.tx_bank1 if bank_sel else self.tx_bank0
            gfx_code  = (bank << 11) | tile_idx
            gfx_base  = gfx_code * 32 + fetch_py * 2
            b0 = gfx_rom[gfx_base + 0]   # plane 0
            b1 = gfx_rom[gfx_base + 1]   # plane 1
            b2 = gfx_rom[gfx_base + 16]  # plane 2
            b3 = gfx_rom[gfx_base + 17]  # plane 3
            for px in range(8):
                bit = 7 - px
                pidx = (((b3 >> bit) & 1) << 3 |
                        ((b2 >> bit) & 1) << 2 |
                        ((b1 >> bit) & 1) << 1 |
                        ((b0 >> bit) & 1))
                linebuf[col * 8 + px] = (color << 4) | pidx
        return linebuf

    def render_scanline_bg(self, vpos: int, plane: int, gfx_rom: bytes,
                           lpb_ctrl: int = 0) -> list:
        """Return 512-entry line buffer [{color[5:0], pix_idx[3:0]}, ...] for the
        BG (plane=1) or FG (plane=0) tilemap layer, for the scanline following vpos.
        Pre-fetch pattern: canvas_y = (vpos + 1 + scrollY) & 0x3FF.
        gfx_rom: bytes-like, at least 8MB (0x800000 bytes).
        lpb_ctrl: lines-per-block control byte (ctrl[2] high byte for FG, ctrl[3] for BG).
                  lpb = 256 - lpb_ctrl (lpb_ctrl=0 → 256 = global scroll, backward compat).
        Returns 0 for transparent pixels (pix_idx == 0).

        Per-block scroll:
          lpb  = 256 - lpb_ctrl
          fetch_vpos = (vpos + 1) & 0xFF
          block = fetch_vpos // lpb
          scroll_off = block * 2 * lpb  (word offset within the plane's scroll region)
          scrollX = scroll_ram[scroll_base + scroll_off]
          scrollY = scroll_ram[scroll_base + scroll_off + 1]

        GFX ROM format (16×16 tile = 128 bytes):
          4 char-blocks 2×2: block 0=top-left, 1=top-right, 2=bot-left, 3=bot-right
          char_base = tile_code*128 + block*32 + char_row*2
          plane0 = gfx_rom[char_base+0],  plane1 = gfx_rom[char_base+1]
          plane2 = gfx_rom[char_base+16], plane3 = gfx_rom[char_base+17]
          pix_idx = {p3[7-lx], p2[7-lx], p1[7-lx], p0[7-lx]}
        flipX: swap left/right char-blocks; reverse bit order within half.
        flipY: py_eff = 15 - fetch_py.
        """
        # Per-block scroll address computation (mirrors RTL exactly)
        scroll_base = 0x200 if plane == 1 else 0x000
        lpb         = 256 - lpb_ctrl if lpb_ctrl != 0 else 256   # matches 9'(256) - {1'b0, lpb_ctrl}
        fetch_vpos  = (vpos + 1) & 0xFF
        block       = fetch_vpos // lpb
        scroll_off  = block * 2 * lpb
        scroll_x = self.scroll_ram[scroll_base + scroll_off]     & 0x3FF
        scroll_y = self.scroll_ram[scroll_base + scroll_off + 1] & 0x3FF

        # Fetch geometry
        canvas_y    = (vpos + 1 + scroll_y) & 0x3FF
        fetch_py    = canvas_y & 0xF
        fetch_ty    = (canvas_y >> 4) & 0x3F
        sx_frac     = scroll_x & 0xF        # pixel offset within first tile
        sx_tile     = (scroll_x >> 4) & 0x3F  # first tile column in map

        # VRAM banks
        if plane == 1:
            bank0 = self.bg_bank0 & 0x7
            bank1 = self.bg_bank1 & 0x7
        else:
            bank0 = self.fg_bank0 & 0x7
            bank1 = self.fg_bank1 & 0x7

        linebuf = [0] * 512

        for tile_col in range(22):
            cur_map_col = (sx_tile + tile_col) & 0x3F
            tile_map_idx = (fetch_ty << 6) | cur_map_col  # 12 bits
            code_word = self.vram[(bank0 << 12) | tile_map_idx]
            attr_word = self.vram[(bank1 << 12) | tile_map_idx]

            tile_code = code_word & 0x7FFF
            color     = attr_word & 0x3F
            flipx     = bool(attr_word & 0x4000)
            flipy     = bool(attr_word & 0x8000)

            py_eff   = (15 - fetch_py) if flipy else fetch_py
            char_row = py_eff & 0x7
            tile_row = (py_eff >> 3) & 0x1

            tile_base = tile_code * 128  # byte address of first char-block

            for half in range(2):
                # Select char-block for screen-left (half=0) and screen-right (half=1)
                cb_left  = tile_row * 2 + 0
                cb_right = tile_row * 2 + 1
                if flipx:
                    cb = cb_right if half == 0 else cb_left
                else:
                    cb = cb_left  if half == 0 else cb_right

                char_base = tile_base + cb * 32 + char_row * 2
                b0 = gfx_rom[char_base + 0]
                b1 = gfx_rom[char_base + 1]
                b2 = gfx_rom[char_base + 16]
                b3 = gfx_rom[char_base + 17]

                for lx in range(8):
                    bit = lx if flipx else (7 - lx)
                    pidx = (((b3 >> bit) & 1) << 3 |
                            ((b2 >> bit) & 1) << 2 |
                            ((b1 >> bit) & 1) << 1 |
                            ((b0 >> bit) & 1))
                    pos = tile_col * 16 + half * 8 + lx
                    linebuf[pos] = 0 if pidx == 0 else ((color << 4) | pidx)

        # Build output with scroll_x_frac applied
        out = [0] * 512
        for hpos in range(512):
            idx = (hpos + sx_frac) & 0x1FF
            out[hpos] = linebuf[idx]
        return out

    def sprite(self, idx: int) -> dict:
        """Return sprite dict for sprite index (0 = highest priority)."""
        base  = idx * 8
        code  = self.sprite_ram[base + 0] & 0x7FFF
        attr  = self.sprite_ram[base + 1]
        color = attr & 0x3F
        flipx = bool(attr & 0x4000)
        flipy = bool(attr & 0x8000)
        x     = self.sprite_ram[base + 2] & 0x3FF
        y     = self.sprite_ram[base + 3] & 0x3FF
        if x >= 0x200: x -= 0x400
        if y >= 0x200: y -= 0x400
        zoom  = self.sprite_ram[base + 4]
        zoomx = (zoom >> 8) & 0xFF
        zoomy = (zoom >> 0) & 0xFF
        big   = self.sprite_ram[base + 5]
        x_num = (big >> 8) & 0xFF
        y_num = (big >> 0) & 0xFF
        return dict(code=code, color=color, flipx=flipx, flipy=flipy,
                    x=x, y=y, zoomx=zoomx, zoomy=zoomy,
                    x_num=x_num, y_num=y_num, is_big=(big != 0))

    # ── Sprite framebuffer rendering (step 6) ───────────────────────────────

    def _render_tile(self, tile_code: int, color: int, flipx: bool, flipy: bool,
                     tile_x: int, tile_y: int, zx: int, zy: int,
                     gfx_rom: bytes) -> None:
        """Render a single 16×16 tile (with zoom) into the active framebuffer page.

        tile_x, tile_y: top-left screen position (signed; wrapped modulo 512/256).
        zx, zy:         render dimensions in pixels (1..16); must be > 0.
        Nearest-neighbor zoom: src = out * 16 // zx.
        fb_pixel = color<<2 | (pixel_idx & 3); transparent if pixel_idx==0.
        """
        tile_base = tile_code * 128

        for out_sy in range(zy):
            src_y    = out_sy * 16 // zy
            py_eff   = (15 - src_y) if flipy else src_y
            char_row = py_eff & 0x7
            tile_row = (py_eff >> 3) & 0x1

            row_bytes = []
            for half in range(2):
                cb_left  = tile_row * 2 + 0
                cb_right = tile_row * 2 + 1
                cb = (cb_right if half == 0 else cb_left) if flipx else \
                     (cb_left  if half == 0 else cb_right)
                char_base = tile_base + cb * 32 + char_row * 2
                b0 = gfx_rom[char_base + 0]
                b1 = gfx_rom[char_base + 1]
                b2 = gfx_rom[char_base + 16]
                b3 = gfx_rom[char_base + 17]
                row_bytes.append((b0, b1, b2, b3))

            screen_y = (tile_y + out_sy) & 0xFF

            for out_sx in range(zx):
                src_x   = out_sx * 16 // zx
                half    = (src_x >> 3) & 1
                local_x = src_x & 7
                bit = local_x if flipx else (7 - local_x)
                b0, b1, b2, b3 = row_bytes[half]
                pidx = (((b3 >> bit) & 1) << 3 |
                        ((b2 >> bit) & 1) << 2 |
                        ((b1 >> bit) & 1) << 1 |
                        ((b0 >> bit) & 1))
                if pidx == 0:
                    continue
                fb_pixel = (color << 2) | (pidx & 3)
                screen_x = (tile_x + out_sx) & 0x1FF
                self.fb[self.fb_page][screen_y * 512 + screen_x] = fb_pixel

    def render_sprites(self, gfx_rom: bytes) -> None:
        """Render all sprites (including big sprite groups) into the active framebuffer
        page, implementing the MAME draw_sprites algorithm (section2_behavior.md §2.1).

        Big sprite state machine (MAME algorithm):
          Walk sprite RAM from index 407 down to 0. A sprite with word+5 != 0 and
          not currently in a big sprite group is the ANCHOR: latches x/y/zoom/counts,
          starts group with x_no=0, y_no=0. Subsequent entries are group tiles.

          For group tile (x_no, y_no):
            zoomx, zoomy = zoomxlatch, zoomylatch  (from anchor)
            x = xlatch + (x_no * (0xFF - zoomx) + 15) // 16
            y = ylatch + (y_no * (0xFF - zoomy) + 15) // 16
            zx = x_of(x_no+1) - x
            zy = y_of(y_no+1) - y
          y_no advances first, then x_no (y 0→y_num inside each x column).
          Group ends when x_no > x_num.

        Single-tile sprites (word+5 == 0, not in big sprite group):
          zx = (0x100 - zoomx) // 16
          zy = (0x100 - zoomy) // 16
          Skip if zx==0 or zy==0.

        Framebuffer layout: self.fb[page][y*512 + x] (flat 512×256 array).
        gfx_rom: bytes-like, at least 8MB (0x800000 bytes).
        """
        no_erase = bool(self.video_ctrl & 0x01)

        if not no_erase:
            self.fb[self.fb_page] = [0] * (512 * 256)

        # Big sprite group state
        in_big  = False
        x_num   = 0
        y_num   = 0
        x_no    = 0
        y_no    = 0
        xlatch  = 0
        ylatch  = 0
        zoomxl  = 0
        zoomyl  = 0

        def bs_pos(xno, zoomx):
            """Compute big-sprite tile x offset for column xno."""
            return (xno * (0xFF - zoomx) + 15) // 16

        # Walk sprites 407 → 0 (lower index = higher priority = drawn last)
        for raw_idx in range(407, -1, -1):
            spr = self.sprite(raw_idx)

            # Recover the raw big word (word+5) for this entry
            big_word = self.sprite_ram[raw_idx * 8 + 5]

            if big_word != 0 and not in_big:
                # ── Anchor: start new big sprite group ──────────────────────
                x_num  = (big_word >> 8) & 0xFF
                y_num  = (big_word >> 0) & 0xFF
                xlatch = spr['x']
                ylatch = spr['y']
                zoomxl = spr['zoomx']
                zoomyl = spr['zoomy']
                x_no   = 0
                y_no   = 0
                in_big = True

            if in_big:
                # ── Big sprite tile (anchor or subsequent entry) ─────────────
                # Override position and zoom from anchor
                x_off      = bs_pos(x_no,     zoomxl)
                x_off_next = bs_pos(x_no + 1, zoomxl)
                y_off      = bs_pos(y_no,     zoomyl)
                y_off_next = bs_pos(y_no + 1, zoomyl)

                tile_x = xlatch + x_off
                tile_y = ylatch + y_off
                zx = x_off_next - x_off
                zy = y_off_next - y_off

                # Advance counters (y first, then x)
                y_no += 1
                if y_no > y_num:
                    y_no = 0
                    x_no += 1
                    if x_no > x_num:
                        in_big = False

                if zx > 0 and zy > 0:
                    self._render_tile(spr['code'], spr['color'],
                                      spr['flipx'], spr['flipy'],
                                      tile_x, tile_y, zx, zy, gfx_rom)

            else:
                # ── Single-tile sprite ───────────────────────────────────────
                zoomx = spr['zoomx']
                zoomy = spr['zoomy']
                zx = (0x100 - zoomx) // 16
                zy = (0x100 - zoomy) // 16
                if zx == 0 or zy == 0:
                    continue
                self._render_tile(spr['code'], spr['color'],
                                  spr['flipx'], spr['flipy'],
                                  spr['x'], spr['y'], zx, zy, gfx_rom)

        # Page flip (mirrors RTL vblank_fall page toggle)
        self.fb_page ^= 1

    def get_fb_pixel(self, x: int, y: int) -> int:
        """Return the framebuffer pixel at screen (x, y) from the DISPLAY page.

        The display page is the non-active (previous-frame) page:
            display_page = 1 - self.fb_page
        This mirrors the RTL display_page = ~fb_page_reg read.
        """
        display_page = 1 - self.fb_page
        return self.fb[display_page][(y & 0xFF) * 512 + (x & 0x1FF)]
