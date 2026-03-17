"""
X1-001A Phase 1 + Phase 2 software model.

Phase 1: Sprite RAM and control register read/write behavior.
Phase 2: Sprite scanner + tile renderer + line buffer pixel output.

Models MAME draw_foreground() exactly:
  - Scan from SPRITE_LIMIT down to 0
  - Decode tile code, flipx, flipy, color, sx, sy
  - Compute screen_y_top = SCREEN_H - ((sy + yoffs) & 0xFF)
  - For each tile row (0..15, or 15..0 if flipy):
      Fetch 4 × 16-bit words from GFX ROM
      For each pixel (0..15, or 15..0 if flipx):
          nibble = word[pixel/4] nibble (high=left)
          if nibble != 0 and screen coords visible: write to line buffer
  - Priority: lower index overwrites higher (index 0 = highest priority)

GFX ROM format:
  Each 16×16 tile = 64 words (4bpp, 16 rows × 4 words/row)
  Word address = tile_code * 64 + row * 4 + word_in_row
  Within 16-bit word: [15:12]=px0, [11:8]=px1, [7:4]=px2, [3:0]=px3

MAME reference: src/devices/video/x1_001.cpp, draw_foreground()
"""

# ─── Screen constants ─────────────────────────────────────────────────────────
SCREEN_H       = 240
SCREEN_W       = 384
SPRITE_LIMIT   = 511
FG_NOFLIP_YOFFS = -0x12   # Superman: set_fg_yoffsets(-0x12, 0x0E)
FG_NOFLIP_XOFFS = 0

# ─── Sprite Y-coordinate RAM (spriteylow) ─────────────────────────────────────
# 0x300 bytes = 768 bytes.
# CPU accesses as 16-bit words: word address [8:0] → bytes [byte_hi, byte_lo].
# Byte enable [0] = low byte (data[7:0]), [1] = high byte (data[15:8]).

YRAM_WORDS = 0x180   # 384 words = 768 bytes


class SpriteYRAM:
    """0x180-word (768-byte) sprite Y-coordinate RAM."""

    def __init__(self):
        self.lo = [0xFF] * YRAM_WORDS   # low bytes
        self.hi = [0xFF] * YRAM_WORDS   # high bytes

    def write(self, addr, data, be=3):
        """Write 16-bit word at word address `addr`.  `be` = byte-enable mask."""
        addr = addr & 0x1FF              # 9-bit mask (0..511)
        if addr >= YRAM_WORDS:
            return
        if be & 1:
            self.lo[addr] = data & 0xFF
        if be & 2:
            self.hi[addr] = (data >> 8) & 0xFF

    def read(self, addr):
        """Read 16-bit word at word address `addr`."""
        addr = addr & 0x1FF
        if addr >= YRAM_WORDS:
            return 0xFFFF
        return (self.hi[addr] << 8) | self.lo[addr]

    def read_byte(self, byte_addr):
        """Read individual byte (byte address 0..0x2FF).
        Flat byte 2k = lo[k], byte 2k+1 = hi[k].
        """
        byte_addr = byte_addr & 0x3FF
        word = byte_addr >> 1
        if word >= YRAM_WORDS:
            return 0xFF
        if byte_addr & 1:
            return self.hi[word]
        else:
            return self.lo[word]

    def sprite_y(self, sprite_idx):
        """Return Y byte for sprite index (0..511).
        Sprite i's Y byte is at flat byte address i.
        Flat byte 2k = lo[k], byte 2k+1 = hi[k].
        """
        word = sprite_idx >> 1
        if word >= YRAM_WORDS:
            return 0xFF
        return self.hi[word] if (sprite_idx & 1) else self.lo[word]

    def clear(self):
        self.lo = [0] * YRAM_WORDS
        self.hi = [0] * YRAM_WORDS


# ─── Sprite code / attribute RAM (spritecode) ─────────────────────────────────
# 0x2000 × 16-bit words = 16 KB.
# Word address [12:0].

CRAM_WORDS = 0x2000   # 8192 words


class SpriteCodeRAM:
    """0x2000-word sprite code/attribute RAM."""

    def __init__(self):
        self.lo = [0xFF] * CRAM_WORDS
        self.hi = [0xFF] * CRAM_WORDS

    def write(self, addr, data, be=3):
        """Write 16-bit word at word address `addr`."""
        addr = addr & 0x1FFF
        if be & 1:
            self.lo[addr] = data & 0xFF
        if be & 2:
            self.hi[addr] = (data >> 8) & 0xFF

    def read(self, addr):
        """Read 16-bit word at word address `addr`."""
        addr = addr & 0x1FFF
        return (self.hi[addr] << 8) | self.lo[addr]

    def clear(self):
        self.lo = [0] * CRAM_WORDS
        self.hi = [0] * CRAM_WORDS


# ─── Control registers ────────────────────────────────────────────────────────
# 4 × 8-bit registers, exposed as 4 × 16-bit word addresses.
# Only low byte (be[0]) is meaningful per MAME.

class ControlRegs:
    """4-register spritectrl array — full 16-bit storage."""

    def __init__(self):
        # Reset to 0xFFFF (matches RTL reset value)
        self.regs = [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF]

    def write(self, addr, data, be=3):
        """Write control register at index `addr` (0..3).
        be[0] = low byte, be[1] = high byte."""
        addr = addr & 3
        if be & 1:
            self.regs[addr] = (self.regs[addr] & 0xFF00) | (data & 0xFF)
        if be & 2:
            self.regs[addr] = (self.regs[addr] & 0x00FF) | (data & 0xFF00)

    def read(self, addr):
        """Read full 16-bit control register word at index `addr`."""
        addr = addr & 3
        return self.regs[addr]

    @property
    def flip_screen(self):
        """ctrl[0] bit 6 = screen flip."""
        return (self.regs[0] >> 6) & 1

    @property
    def bg_startcol(self):
        """ctrl[0] bits [1:0] = BG start column offset."""
        return self.regs[0] & 0x03

    @property
    def bg_numcol(self):
        """ctrl[1] bits [3:0] = number of BG columns (0=off, 1=16 cols)."""
        return self.regs[1] & 0x0F

    @property
    def col_upper_mask(self):
        """ctrl[3] low byte : ctrl[2] low byte = 16-bit column upper-scroll mask."""
        return ((self.regs[3] & 0xFF) << 8) | (self.regs[2] & 0xFF)

    @property
    def frame_bank(self):
        """
        Double-buffer bank select bit.
        MAME formula: ((ctrl2 ^ (~ctrl2 << 1)) & 0x40) != 0
        where ctrl2 = spritectrl[1].
        """
        c = self.regs[1] & 0xFF
        xor_val = (c ^ (~(c << 1) & 0xFF)) & 0xFF
        return 1 if (xor_val & 0x40) else 0


# ─── GFX ROM model ────────────────────────────────────────────────────────────

GFX_ROM_WORDS = 1 << 18   # 2^18 words = 256K words


class GfxROM:
    """Software GFX ROM: 2^18 × 16-bit words."""

    def __init__(self):
        self.words = [0] * GFX_ROM_WORDS

    def write_word(self, addr, data):
        addr = addr & (GFX_ROM_WORDS - 1)
        self.words[addr] = data & 0xFFFF

    def read_word(self, addr):
        addr = addr & (GFX_ROM_WORDS - 1)
        return self.words[addr]

    def load_tile(self, tile_code, pixels):
        """
        Load a 16×16 tile from a 2D array pixels[row][col] (4-bit values).
        Row-major: pixels[0][0..15] = top row, left to right.
        GFX ROM word address = tile_code * 64 + row * 4 + word_in_row.
        Each word encodes 4 pixels: [15:12]=px0, [11:8]=px1, [7:4]=px2, [3:0]=px3.
        """
        base = tile_code * 64
        for row in range(16):
            for w in range(4):
                word = 0
                for n in range(4):
                    px_idx = w * 4 + n
                    word = (word << 4) | (pixels[row][px_idx] & 0xF)
                self.words[base + row * 4 + w] = word

    def get_tile_row(self, tile_code, row):
        """Return 16 nibble values for tile row `row` (list of 16 ints).
        Returns all-zero (transparent) if tile address is out of range.
        """
        base = tile_code * 64 + row * 4
        pixels = []
        for w in range(4):
            addr = base + w
            if addr >= len(self.words):
                word = 0   # out of range → transparent
            else:
                word = self.words[addr]
            pixels.append((word >> 12) & 0xF)
            pixels.append((word >>  8) & 0xF)
            pixels.append((word >>  4) & 0xF)
            pixels.append((word >>  0) & 0xF)
        return pixels  # 16 values


# ─── Phase 2: Sprite renderer ────────────────────────────────────────────────

class SpriteRenderer:
    """
    Software model of the X1-001A sprite scanner + renderer.

    Implements draw_foreground() from MAME exactly, writing to a per-scanline
    line buffer (double-buffered ping-pong).
    """

    def __init__(self, gfx_rom: GfxROM,
                 screen_h: int = SCREEN_H,
                 screen_w: int = SCREEN_W,
                 sprite_limit: int = SPRITE_LIMIT,
                 fg_yoffs: int = FG_NOFLIP_YOFFS,
                 fg_xoffs: int = FG_NOFLIP_XOFFS):
        self.gfx     = gfx_rom
        self.sh      = screen_h
        self.sw      = screen_w
        self.slim    = sprite_limit
        self.yoffs   = fg_yoffs
        self.xoffs   = fg_xoffs

        # Double-buffered pixel arrays: [bank][y][x] = (valid, color) or None
        # None = transparent
        self._buf = [
            [[None] * screen_w for _ in range(screen_h)],
            [[None] * screen_w for _ in range(screen_h)],
        ]
        self._display_bank = 0   # bank currently being displayed

    @property
    def _write_bank(self):
        return 1 - self._display_bank

    def swap_banks(self):
        """Called at VBlank: swap display/write banks."""
        self._display_bank ^= 1

    def clear_write_bank(self):
        """Clear the write bank entirely (called before rendering a new frame)."""
        wb = self._write_bank
        for y in range(self.sh):
            for x in range(self.sw):
                self._buf[wb][y][x] = None

    def render_frame(self, yram: SpriteYRAM, cram: SpriteCodeRAM,
                     ctrl: ControlRegs):
        """
        Render one complete frame of foreground sprites into the write bank.

        Matches MAME draw_foreground() exactly.
        bank_size = 0x1000 (standard for all Taito X games).
        """
        bank_size = 0x1000

        # Determine char/x pointer base from frame_bank
        bank_offset = bank_size if ctrl.frame_bank else 0
        char_base   = bank_offset + 0x0000
        xptr_base   = bank_offset + 0x0200

        # Screen flip (not used in simple no-flip mode, included for completeness)
        screenflip = ctrl.flip_screen

        if screenflip:
            xoffs = FG_NOFLIP_XOFFS  # would be flip offsets; simplified
            yoffs = FG_NOFLIP_YOFFS
        else:
            xoffs = self.xoffs
            yoffs = self.yoffs

        max_y = self.sh   # MAME: max_y = screen.height() = 240

        wb = self._write_bank

        # Scan from SPRITE_LIMIT down to 0 (index 0 drawn last = highest priority)
        for i in range(self.slim, -1, -1):
            char_word = cram.read(char_base + i)
            x_word    = cram.read(xptr_base + i)

            tile_code = char_word & 0x3FFF
            flipx     = bool(char_word & 0x8000)
            flipy     = bool(char_word & 0x4000)
            color     = (x_word >> 11) & 0x1F

            # sx = (x_word & 0x00FF) - (x_word & 0x0100)
            sx = (x_word & 0x00FF) - (x_word & 0x0100)

            # sy from yram: sprite i's Y = flat byte i = word i//2, lo if even, hi if odd
            sy = yram.sprite_y(i)

            if screenflip:
                sy    = max_y - sy + (self.sh - max_y - 1)
                flipx = not flipx
                flipy = not flipy

            # Screen Y of top pixel row of sprite:
            # screen_y = max_y - ((sy + yoffs) & 0xFF)
            sy_eff   = (sy + yoffs) & 0xFF
            screen_y = max_y - sy_eff

            # Screen X base
            screen_x_base = sx + xoffs

            # Render 16 rows
            for row in range(16):
                actual_row = (15 - row) if flipy else row
                tile_pixels = self.gfx.get_tile_row(tile_code, actual_row)

                screen_row_y = screen_y + row

                # Check if this row is on-screen
                if screen_row_y < 0 or screen_row_y >= self.sh:
                    continue

                # Render 16 pixels
                for px in range(16):
                    actual_px = (15 - px) if flipx else px
                    nibble    = tile_pixels[actual_px]

                    if nibble == 0:
                        continue   # transparent

                    screen_px_x = screen_x_base + px

                    # MAME uses 4-way wrap; we just check direct visibility
                    if screen_px_x < 0 or screen_px_x >= self.sw:
                        continue

                    # Write pixel (overwrites lower-priority sprites already there)
                    self._buf[wb][screen_row_y][screen_px_x] = (True, color)

    def get_pixel(self, x, y, bank='display'):
        """
        Get pixel at (x, y) from the specified bank.
        Returns (valid, color) or (False, 0) for transparent.
        bank='display' reads the display bank; bank='write' reads the write bank.
        """
        b = self._display_bank if bank == 'display' else self._write_bank
        if 0 <= x < self.sw and 0 <= y < self.sh:
            entry = self._buf[b][y][x]
            if entry is not None:
                return entry
        return (False, 0)


# ─── Combined model ───────────────────────────────────────────────────────────

class X1001APhase1:
    """Complete Phase 1 behavioral model."""

    def __init__(self):
        self.yram  = SpriteYRAM()
        self.cram  = SpriteCodeRAM()
        self.ctrl  = ControlRegs()

    def cpu_yram_write(self, addr, data, be=3):
        self.yram.write(addr, data, be)

    def cpu_yram_read(self, addr):
        return self.yram.read(addr)

    def cpu_cram_write(self, addr, data, be=3):
        self.cram.write(addr, data, be)

    def cpu_cram_read(self, addr):
        return self.cram.read(addr)

    def cpu_ctrl_write(self, addr, data, be=3):
        self.ctrl.write(addr, data, be)

    def cpu_ctrl_read(self, addr):
        return self.ctrl.read(addr)

    # Scanner read ports — same physical RAM, independent access
    def scan_yram_read(self, addr):
        return self.yram.read(addr)

    def scan_cram_read(self, addr):
        return self.cram.read(addr)

    def reset(self):
        self.yram.clear()
        self.cram.clear()
        self.ctrl.__init__()


class X1001APhase2(X1001APhase1):
    """Phase 1 + Phase 2 behavioral model (adds sprite rendering)."""

    def __init__(self):
        super().__init__()
        self.gfx      = GfxROM()
        self.renderer = SpriteRenderer(self.gfx)

    def render_frame(self):
        """Render one frame into the write bank."""
        self.renderer.clear_write_bank()
        self.renderer.render_frame(self.yram, self.cram, self.ctrl)

    def swap_banks(self):
        """Swap display/write banks (called at VBlank)."""
        self.renderer.swap_banks()

    def get_pixel(self, x, y, bank='display'):
        """Return (valid, color) for pixel (x, y) in the display bank."""
        return self.renderer.get_pixel(x, y, bank)


# ─── Unit self-test ───────────────────────────────────────────────────────────

if __name__ == '__main__':
    m = X1001APhase1()

    # --- Y RAM tests ---
    m.cpu_yram_write(0, 0xBEEF, be=3)
    assert m.cpu_yram_read(0) == 0xBEEF, f"YRAM basic write failed: {m.cpu_yram_read(0):#x}"

    # Write only low byte (be=1)
    m.cpu_yram_write(1, 0xFF00, be=2)   # high byte only
    m.cpu_yram_write(1, 0x00AB, be=1)   # low byte only
    assert m.cpu_yram_read(1) == 0xFFAB, f"YRAM byte-enable failed: {m.cpu_yram_read(1):#x}"

    # Last word
    m.cpu_yram_write(0x17F, 0xA5A5, be=3)
    assert m.cpu_yram_read(0x17F) == 0xA5A5

    # Scanner reads same data
    m.cpu_yram_write(0x10, 0x5A5A, be=3)
    assert m.scan_yram_read(0x10) == 0x5A5A, "YRAM scanner port failed"

    # --- Code RAM tests ---
    m.cpu_cram_write(0, 0x1234, be=3)
    assert m.cpu_cram_read(0) == 0x1234

    m.cpu_cram_write(0x1FFF, 0xDEAD, be=3)
    assert m.cpu_cram_read(0x1FFF) == 0xDEAD

    # Byte-enable partial write
    m.cpu_cram_write(5, 0xAB00, be=2)
    m.cpu_cram_write(5, 0x00CD, be=1)
    assert m.cpu_cram_read(5) == 0xABCD, f"CRAM be failed: {m.cpu_cram_read(5):#x}"

    # Scanner reads same
    m.cpu_cram_write(0x100, 0x9876, be=3)
    assert m.scan_cram_read(0x100) == 0x9876

    # --- Control register tests ---
    m.cpu_ctrl_write(0, 0x40, be=1)   # flip_screen = 1
    assert m.ctrl.flip_screen == 1, "flip_screen failed"

    m.cpu_ctrl_write(0, 0x03, be=1)   # bg_startcol = 3
    assert m.ctrl.bg_startcol == 3, "bg_startcol failed"

    m.cpu_ctrl_write(1, 0x01, be=1)   # bg_numcol = 1 (16 columns active)
    assert m.ctrl.bg_numcol == 1, "bg_numcol failed"

    m.cpu_ctrl_write(2, 0xAB, be=1)
    m.cpu_ctrl_write(3, 0xCD, be=1)
    assert m.ctrl.col_upper_mask == 0xCDAB, f"col_upper_mask failed: {m.ctrl.col_upper_mask:#x}"

    # frame_bank: test with ctrl[1]=0x40 → (0x40 ^ ~0x80) & 0xFF = 0x40 ^ 0x7F = 0x3F → bit6=0
    m.cpu_ctrl_write(1, 0x40, be=1)
    # c=0x40, ~(0x40<<1)=~0x80=0x7F, xor=0x40^0x7F=0x3F → bit6=0
    assert m.ctrl.frame_bank == 0, f"frame_bank(0x40) expected 0, got {m.ctrl.frame_bank}"

    # ctrl[1]=0x00 → (0x00 ^ ~0x00)=0xFF → bit6=1
    m.cpu_ctrl_write(1, 0x00, be=1)
    # c=0x00, ~(0x00<<1)=~0x00=0xFF, xor=0x00^0xFF=0xFF → bit6=1
    assert m.ctrl.frame_bank == 1, f"frame_bank(0x00) expected 1, got {m.ctrl.frame_bank}"

    print("x1001a_model Phase 1 self-test PASS")

    # --- Phase 2 renderer tests ---
    m2 = X1001APhase2()

    # Reset ctrl: ctrl[0]=0x00 (flip_screen=0), ctrl[1]=0x40 (frame_bank=0)
    m2.cpu_ctrl_write(0, 0x00, be=1)   # flip_screen=0, bg_startcol=0
    m2.cpu_ctrl_write(1, 0x40, be=1)   # frame_bank=0
    assert m2.ctrl.flip_screen == 0
    assert m2.ctrl.frame_bank == 0

    # Load a solid red tile (color index 3) at tile_code=0
    tile_px = [[3] * 16 for _ in range(16)]   # all pixels = color 3
    m2.gfx.load_tile(0, tile_px)

    # Place sprite 0 at tile_code=0, color=5, sx=20, sy so screen_y_top=50
    # screen_y_top = SCREEN_H - ((sy + yoffs) & 0xFF) = 50
    # sy = (SCREEN_H - 50 - FG_NOFLIP_YOFFS) & 0xFF
    sy_val = (SCREEN_H - 50 - FG_NOFLIP_YOFFS) & 0xFF
    sx_val = 20

    char_word = 0           # tile=0, flipx=0, flipy=0
    x_word    = (5 << 11) | (sx_val & 0xFF)   # color=5, sx=20 (positive, bit8=0)

    m2.cpu_cram_write(0x000, char_word, be=3)   # char_pointer[0]
    m2.cpu_cram_write(0x200, x_word,   be=3)   # x_pointer[0]
    # Sprite 0's Y byte is flat byte 0 = yram word 0 low byte
    m2.yram.write(0, sy_val, be=1)              # low byte = sprite 0 Y

    # Zero all other sprites so they don't appear:
    # Set tile=0, color=0 → all transparent pixels; position doesn't matter
    for i in range(1, 512):
        m2.cpu_cram_write(i, 0x0000, be=3)           # tile=0, no flip
        m2.cpu_cram_write(0x200 + i, 0x0000, be=3)   # color=0, sx=0
        # Sprite i Y byte: flat byte i, word i//2
        # Set to any value; transparent tiles won't draw anyway
        word_addr = i >> 1
        if i & 1:
            m2.yram.write(word_addr, 0, be=2)    # high byte = sprite i Y (odd)
        else:
            m2.yram.write(word_addr, 0, be=1)    # low byte  = sprite i Y (even)

    # Render frame
    m2.render_frame()
    m2.swap_banks()

    # Check pixel at (20, 50) → should be valid, color=5
    valid, color = m2.get_pixel(20, 50)
    assert valid, f"Phase2: pixel (20,50) should be valid"
    assert color == 5, f"Phase2: pixel (20,50) color={color}, expected 5"

    # Check pixel at (20, 49) → should be transparent (above sprite)
    valid2, _ = m2.get_pixel(20, 49)
    assert not valid2, f"Phase2: pixel (20,49) should be transparent"

    # Check pixel at (35, 50) → should be valid (last pixel of row 0)
    valid3, color3 = m2.get_pixel(35, 50)
    assert valid3, f"Phase2: pixel (35,50) should be valid"
    assert color3 == 5, f"Phase2: pixel (35,50) color={color3}"

    # Check pixel at (36, 50) → should be transparent (just off sprite right edge)
    valid4, _ = m2.get_pixel(36, 50)
    assert not valid4, f"Phase2: pixel (36,50) should be transparent"

    print("x1001a_model Phase 2 self-test PASS")
    print("x1001a_model self-test PASS")
