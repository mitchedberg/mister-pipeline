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
