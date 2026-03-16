"""
TC0630FDP behavioral model — Python reference implementation (Steps 1–3).

Step 1 scope:
  - Display control register bank (16 × 16-bit registers)
  - CPU bus read/write with byte-lane enables
  - Video timing: H/V counters, hblank/vblank/hsync/vsync, pixel_valid
  - Interrupt generation (int_vblank, int_hblank)

Step 2 scope (added):
  - Text RAM (4096 × 16-bit words): tile words for 64×64 8×8-tile text layer
  - Character RAM (8192 bytes): CPU-writable pixel data for 256 tiles × 32 bytes
  - render_text_scanline(vpos): returns 320-entry list of {color[4:0], pen[3:0]}

Step 3 scope (added):
  - PF RAM × 4 (0x1800 words each = 6144 × 16-bit): two words per 16×16 tile entry
  - GFX ROM (32-bit word array): nibble-packed 4bpp tile graphics
  - render_bg_scanline(vpos, plane, xscroll, yscroll, extend_mode):
      returns 320-entry list of {palette[8:0], pen[3:0]} packed as 13-bit int

  BG tile word format (section1 §4):
    Word 0 (attr): bits[8:0]=palette, bit[9]=blend, bits[11:10]=extra_planes,
                   bit[14]=flipX, bit[15]=flipY.
    Word 1 (code): bits[15:0]=tile_code.

  GFX ROM format (section1 §11.3, 32-bit wide, nibble-packed 4bpp):
    128 bytes (32 × 32-bit words) per 16×16 tile.
    Row r of tile T: left-8px word = gfx_rom[T*32 + r*2],
                     right-8px word = gfx_rom[T*32 + r*2 + 1].
    Within 32-bit word: bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7.
    flipX: read nibbles in reverse (px7..px0 → left..right output).
    flipY: row = 15 - fetch_py.

  Scroll (global, Step 3):
    X: pf_xscroll[15:6] = integer pixel offset.
       canvas_x at screen col 0 = xscroll_int = pf_xscroll >> 6.
    Y: pf_yscroll[15:7] = integer pixel offset.
       canvas_y = (vpos + 1 + yscroll_int) & 0x1FF.

  Text tile word format (section1 §5):
    bits[10:0]  = character code (wraps mod 256 for 256-tile char RAM)
    bits[15:11] = color (5 bits)

  Character RAM GFX decode (charlayout, section1 §11.1):
    8×8 tile, 4bpp, 32 bytes/tile.
    Each pixel row = 4 bytes at byte offset: char_code*32 + fetch_py*4
    X-offsets {20,16,28,24,4,0,12,8} → nibble mapping:
      px0→b2[7:4]  px1→b2[3:0]  px2→b3[7:4]  px3→b3[3:0]
      px4→b0[7:4]  px5→b0[3:0]  px6→b1[7:4]  px7→b1[3:0]
    where b0..b3 are the 4 bytes of the row (byte-address order).

Register map:
  Word 0  = PF1_XSCROLL   (10.6 fixed-point, inverted frac)
  Word 1  = PF2_XSCROLL
  Word 2  = PF3_XSCROLL
  Word 3  = PF4_XSCROLL
  Word 4  = PF1_YSCROLL   (9.7 fixed-point)
  Word 5  = PF2_YSCROLL
  Word 6  = PF3_YSCROLL
  Word 7  = PF4_YSCROLL
  Word 8–11 = unused (reads as 0, writes ignored)
  Word 12 = PIXEL_XSCROLL
  Word 13 = PIXEL_YSCROLL
  Word 14 = unused
  Word 15 = EXTEND_MODE (bit 7: 1=1024×512 tmap, 0=512×512)

Video timing (from MAME screen.set_raw):
  Pixel clock: 26.686 MHz / 4 = 6.6715 MHz
  H total: 432,  H start: 46,   H end: 366  (320 active pixels)
  V total: 262,  V start: 24,   V end: 256  (232 active lines)
"""

# ---------------------------------------------------------------------------
# Video timing constants (mirror RTL)
# ---------------------------------------------------------------------------
H_TOTAL  = 432
H_START  = 46
H_END    = 366   # H_START + 320
H_SYNC_S = 0
H_SYNC_E = 32

V_TOTAL  = 262
V_START  = 24
V_END    = 256   # V_START + 232
V_SYNC_S = 0
V_SYNC_E = 4

INT3_DELAY = 2500  # pixel clocks after vblank rise

# Unused register indices (writes ignored, reads return 0)
_UNUSED_REGS = {8, 9, 10, 11, 14}


class TaitoF3Model:
    """Steps 1–3 behavioral model: control registers, video timing, text layer, BG layers."""

    # Memory sizes
    TEXT_RAM_WORDS  = 4096    # 64×64 tile map × 1 word each
    CHAR_RAM_BYTES  = 8192    # 256 tiles × 32 bytes = 8KB
    PF_RAM_WORDS    = 6144    # 0x1800 words per playfield
    GFX_ROM_WORDS   = 4096    # simulation GFX ROM (32-bit words) — matches RTL BRAM

    def __init__(self):
        self.ctrl     = [0] * 16          # 16 × 16-bit display control registers
        self.text_ram = [0] * self.TEXT_RAM_WORDS   # step 2
        self.char_ram = [0] * self.CHAR_RAM_BYTES   # step 2 (bytes)
        self.pf_ram   = [[0] * self.PF_RAM_WORDS for _ in range(4)]  # step 3
        self.gfx_rom  = [0] * self.GFX_ROM_WORDS   # step 3 (32-bit words)
        self._rst()

    def _rst(self):
        """Reset all state (mirrors async_rst_n behaviour)."""
        self.ctrl     = [0] * 16
        self.text_ram = [0] * self.TEXT_RAM_WORDS
        self.char_ram = [0] * self.CHAR_RAM_BYTES
        self.pf_ram   = [[0] * self.PF_RAM_WORDS for _ in range(4)]
        self.gfx_rom  = [0] * self.GFX_ROM_WORDS

    # ── Address decode ──────────────────────────────────────────────────────

    @staticmethod
    def _ctrl_idx(word_addr: int) -> int:
        """Map a word address within the ctrl window to register index 0–15.

        cpu_addr[4:1] selects the register; the chip select window is
        0x660000–0x66001F (CPU byte addresses), which translates to
        word addresses 0–15 within the chip.
        """
        return word_addr & 0xF

    # ── CPU write ───────────────────────────────────────────────────────────

    def write(self, word_addr: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word at word address within the ctrl window.

        word_addr: bits [3:0] select register (0–15)
        data:      16-bit write data
        be:        byte enables: bit1=high byte, bit0=low byte
        """
        idx = self._ctrl_idx(word_addr)
        data &= 0xFFFF
        if idx in _UNUSED_REGS:
            return   # writes to unused registers are silently ignored
        cur = self.ctrl[idx]
        if be & 0x2: cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1: cur = (cur & 0xFF00) | (data & 0x00FF)
        self.ctrl[idx] = cur

    # ── CPU read ────────────────────────────────────────────────────────────

    def read(self, word_addr: int) -> int:
        """Read 16-bit word at word address within the ctrl window."""
        idx = self._ctrl_idx(word_addr)
        if idx in _UNUSED_REGS:
            return 0
        return self.ctrl[idx]

    # ── Text RAM read/write ─────────────────────────────────────────────────

    def write_text_ram(self, word_idx: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word to Text RAM at word index 0–4095."""
        word_idx &= 0xFFF
        data &= 0xFFFF
        cur = self.text_ram[word_idx]
        if be & 0x2: cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1: cur = (cur & 0xFF00) | (data & 0x00FF)
        self.text_ram[word_idx] = cur

    def read_text_ram(self, word_idx: int) -> int:
        """Read 16-bit word from Text RAM at word index 0–4095."""
        return self.text_ram[word_idx & 0xFFF]

    # ── Character RAM read/write ─────────────────────────────────────────────

    def write_char_ram(self, byte_addr: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word to Character RAM at byte address (byte_addr must be even)."""
        byte_addr &= 0x1FFE   # align to word boundary within 8KB
        data &= 0xFFFF
        if be & 0x2: self.char_ram[byte_addr]     = (data >> 8) & 0xFF
        if be & 0x1: self.char_ram[byte_addr + 1] = data & 0xFF

    def read_char_ram(self, byte_addr: int) -> int:
        """Read 16-bit word from Character RAM at byte address."""
        byte_addr &= 0x1FFE
        return (self.char_ram[byte_addr] << 8) | self.char_ram[byte_addr + 1]

    # ── PF RAM read/write (Step 3) ──────────────────────────────────────────

    def write_pf_ram(self, plane: int, word_idx: int, data: int,
                     be: int = 0x3) -> None:
        """Write 16-bit word to PF RAM for plane (0–3) at word index."""
        plane &= 3
        word_idx &= 0x17FF   # 0x1800 words max
        data &= 0xFFFF
        cur = self.pf_ram[plane][word_idx]
        if be & 0x2: cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1: cur = (cur & 0xFF00) | (data & 0x00FF)
        self.pf_ram[plane][word_idx] = cur

    def read_pf_ram(self, plane: int, word_idx: int) -> int:
        """Read 16-bit word from PF RAM."""
        return self.pf_ram[plane & 3][word_idx & 0x17FF]

    # ── GFX ROM write (Step 3) ──────────────────────────────────────────────

    def write_gfx_rom(self, word_addr: int, data: int) -> None:
        """Write 32-bit word to GFX ROM at word address."""
        if word_addr < self.GFX_ROM_WORDS:
            self.gfx_rom[word_addr] = data & 0xFFFFFFFF

    # ── BG layer render (Step 3) ────────────────────────────────────────────

    def render_bg_scanline(self, vpos: int, plane: int,
                           xscroll: int, yscroll: int,
                           extend_mode: bool = False) -> list:
        """Return 320-entry list of BG layer pixels for the scanline AFTER vpos.

        Pre-fetch pattern (matches RTL): fills during HBLANK of vpos,
        renders vpos+1.

        Each entry: {palette[8:0], pen[3:0]} packed as 13-bit int.
        pen == 0 → transparent (but pixel is still written with palette).

        Parameters:
          vpos        : current scanline (FSM fires on HBLANK of this line)
          plane       : 0..3 (PF1..PF4)
          xscroll     : raw pf_xscroll register value (16-bit)
          yscroll     : raw pf_yscroll register value (16-bit)
          extend_mode : False=32-wide map, True=64-wide map

        Scroll decode (section1 §3.1):
          xscroll_int = xscroll >> 6   (10-bit integer pixel offset)
          yscroll_int = yscroll >> 7   (9-bit integer pixel offset)

        Canvas Y = (vpos + 1 + yscroll_int) & 0x1FF
        fetch_py = canvas_y & 0xF     (row within 16px tile)
        fetch_ty = (canvas_y >> 4) & 0x1F  (tile row 0..31)

        Canvas X at screen col 0 = xscroll_int
        first_tx = (xscroll_int >> 4) & (63 if extend_mode else 31)
        fetch_xoff = xscroll_int & 0xF  (pixel offset within first tile)

        Tile fetch per screen column c:
          canvas_x = (c + xscroll_int) & wrap_mask
          tile_x = canvas_x >> 4
          tile_y = fetch_ty  (fixed per scanline)
          tile_idx = tile_y * map_width + tile_x
          word_base = tile_idx * 2
          attr_word = pf_ram[plane][word_base]
          code_word = pf_ram[plane][word_base + 1]

        GFX ROM decode:
          tile_code = code_word
          flipY: row = 15 - fetch_py if flipy else fetch_py
          left_word  = gfx_rom[tile_code * 32 + row * 2]
          right_word = gfx_rom[tile_code * 32 + row * 2 + 1]
          pixel px (0..7 in left, 8..15 in right):
            half_px = px & 7
            ni = (7 - half_px) if flipX else half_px   # flipX reversal
            src_word = left_word if px < 8 else right_word
            pen = (src_word >> ((7 - ni) * 4)) & 0xF
        """
        plane = plane & 3
        map_width = 64 if extend_mode else 32
        wrap_mask_px = (map_width * 16) - 1   # 1023 or 511

        # Scroll decode
        xscroll_int = (xscroll >> 6) & 0x3FF    # 10-bit
        yscroll_int = (yscroll >> 7) & 0x1FF    # 9-bit

        # Next scanline geometry
        canvas_y = ((vpos + 1) + yscroll_int) & 0x1FF
        fetch_py = canvas_y & 0xF
        fetch_ty = (canvas_y >> 4) & 0x1F

        linebuf = [0] * 320
        for scol in range(320):
            canvas_x = (scol + xscroll_int) & wrap_mask_px
            tile_x   = (canvas_x >> 4) & (map_width - 1)
            tile_idx = fetch_ty * map_width + tile_x
            word_base = tile_idx * 2

            attr_word = self.pf_ram[plane][word_base]
            code_word = self.pf_ram[plane][word_base + 1]

            palette     = attr_word & 0x1FF           # bits[8:0]
            flipx       = bool(attr_word & (1 << 14))
            flipy       = bool(attr_word & (1 << 15))
            tile_code   = code_word & 0xFFFF

            row = (15 - fetch_py) if flipy else fetch_py

            # GFX ROM lookup
            left_addr  = tile_code * 32 + row * 2
            right_addr = left_addr + 1

            left_word  = self.gfx_rom[left_addr]  if left_addr  < self.GFX_ROM_WORDS else 0
            right_word = self.gfx_rom[right_addr] if right_addr < self.GFX_ROM_WORDS else 0

            # Pixel position within tile row (0..15)
            px_in_tile = canvas_x & 0xF   # 0..15

            # Half: left (0..7) or right (8..15)
            half_px = px_in_tile & 7
            src_word = left_word if px_in_tile < 8 else right_word

            # Nibble index (flipX reverses order)
            ni = (7 - half_px) if flipx else half_px

            # Extract nibble: px0 at bits[31:28] → shift = (7 - ni) * 4
            shift = (7 - ni) * 4
            pen = (src_word >> shift) & 0xF

            linebuf[scol] = (palette << 4) | pen

        return linebuf

    # ── Text layer render ───────────────────────────────────────────────────

    def render_text_scanline(self, vpos: int) -> list:
        """Return 320-entry list of text layer pixels for the scanline AFTER vpos.

        Pre-fetch pattern (matches RTL): fills during HBLANK of vpos, renders vpos+1.
        Each entry: {color[4:0], pen[3:0]} packed as 9-bit int (bits 8:4=color, 3:0=pen).
        pen == 0 → transparent.

        Text layer: 64×64 tile map, 8×8 tiles, 4bpp.
        Text canvas is 512×512 pixels (64 tiles × 8 px = 512).
        Screen shows 320 pixels wide → 40 tile columns.

        Charlayout nibble decode (section1 §11.1):
          Each tile row = 4 bytes at byte offset = char_code * 32 + fetch_py * 4.
          X-offsets {20,16,28,24,4,0,12,8} → nibble mapping:
            px0 → b2[7:4],  px1 → b2[3:0],
            px2 → b3[7:4],  px3 → b3[3:0],
            px4 → b0[7:4],  px5 → b0[3:0],
            px6 → b1[7:4],  px7 → b1[3:0]
        """
        fetch_vpos = (vpos + 1) & 0x1FF   # 9-bit wrap (canvas is 512px tall)
        fetch_py   = fetch_vpos & 0x7      # pixel row within tile (0..7)
        fetch_row  = (fetch_vpos >> 3) & 0x3F   # tile row in 64-row map (0..63)

        linebuf = [0] * 320
        for col in range(40):    # 40 tiles × 8 px = 320 screen pixels
            tile_word = self.text_ram[fetch_row * 64 + col]
            color     = (tile_word >> 11) & 0x1F   # bits[15:11]
            char_code = tile_word & 0xFF             # bits[7:0] (lower 8 bits, wraps mod 256)

            # Charlayout byte offsets within tile
            row_base = char_code * 32 + fetch_py * 4
            b0 = self.char_ram[row_base + 0]
            b1 = self.char_ram[row_base + 1]
            b2 = self.char_ram[row_base + 2]
            b3 = self.char_ram[row_base + 3]

            # Decode 8 pixels from nibbles
            pens = [
                (b2 >> 4) & 0xF,   # px0: b2[7:4]
                (b2     ) & 0xF,   # px1: b2[3:0]
                (b3 >> 4) & 0xF,   # px2: b3[7:4]
                (b3     ) & 0xF,   # px3: b3[3:0]
                (b0 >> 4) & 0xF,   # px4: b0[7:4]
                (b0     ) & 0xF,   # px5: b0[3:0]
                (b1 >> 4) & 0xF,   # px6: b1[7:4]
                (b1     ) & 0xF,   # px7: b1[3:0]
            ]

            for px, pen in enumerate(pens):
                screen_x = col * 8 + px
                if screen_x < 320:
                    linebuf[screen_x] = (color << 4) | pen

        return linebuf

    # ── Decoded control register properties ─────────────────────────────────

    @property
    def pf_xscroll(self) -> list:
        """PF1–PF4 X scroll raw values (list of 4 ints, words 0–3)."""
        return [self.ctrl[i] for i in range(4)]

    @property
    def pf_yscroll(self) -> list:
        """PF1–PF4 Y scroll raw values (list of 4 ints, words 4–7)."""
        return [self.ctrl[4 + i] for i in range(4)]

    @property
    def pixel_xscroll(self) -> int:
        """Pixel/VRAM layer X scroll (ctrl[12])."""
        return self.ctrl[12]

    @property
    def pixel_yscroll(self) -> int:
        """Pixel/VRAM layer Y scroll (ctrl[13])."""
        return self.ctrl[13]

    @property
    def extend_mode(self) -> bool:
        """True = 64×32 tilemap (1024px wide), False = 32×32 (512px wide)."""
        return bool(self.ctrl[15] & 0x80)


# ---------------------------------------------------------------------------
# Video timing model
# ---------------------------------------------------------------------------

class VideoTiming:
    """Software model of the TC0630FDP video timing generator.

    Advances one pixel clock at a time via tick().
    Tracks hpos, vpos, hblank, vblank, hsync, vsync, pixel_valid.
    Also generates int_vblank and int_hblank pulses.
    """

    def __init__(self):
        self.hpos        = 0
        self.vpos        = 0
        self.hblank      = True
        self.vblank      = True
        self.hsync       = True
        self.vsync       = True
        self.pixel_valid = False
        self.int_vblank  = False
        self.int_hblank  = False
        self._int3_cnt   = 0
        self._vblank_prev = False
        self._tick_count = 0

    def _update_outputs(self):
        h = self.hpos
        v = self.vpos
        self.hblank      = (h < H_START) or (h >= H_END)
        self.vblank      = (v < V_START) or (v >= V_END)
        self.hsync       = (h >= H_SYNC_S) and (h < H_SYNC_E)
        self.vsync       = (v >= V_SYNC_S) and (v < V_SYNC_E)
        self.pixel_valid = not self.hblank and not self.vblank

    def tick(self):
        """Advance one pixel clock. Returns True if vblank rising edge occurred."""
        self._tick_count += 1

        # Update hpos / vpos (mirrors RTL counter logic)
        if self.hpos == H_TOTAL - 1:
            self.hpos = 0
            if self.vpos == V_TOTAL - 1:
                self.vpos = 0
            else:
                self.vpos += 1
        else:
            self.hpos += 1

        # Interrupts
        vblank_now = (self.vpos < V_START) or (self.vpos >= V_END)
        vblank_rise = vblank_now and not self._vblank_prev

        self.int_vblank = False
        self.int_hblank = False

        if vblank_rise:
            self.int_vblank = True
            self._int3_cnt  = INT3_DELAY

        if self._int3_cnt > 0:
            self._int3_cnt -= 1
            if self._int3_cnt == 0:
                self.int_hblank = True

        self._vblank_prev = vblank_now
        self._update_outputs()
        return vblank_rise

    def run_frame(self) -> dict:
        """Run exactly one complete frame (H_TOTAL × V_TOTAL ticks).

        Returns a dict with aggregate statistics:
          pixel_valid_count: number of cycles where pixel_valid was True
          hblank_cycles:     number of cycles in hblank
          vblank_cycles:     number of cycles in vblank
          int_vblank_count:  number of int_vblank pulses
          int_hblank_count:  number of int_hblank pulses
        """
        stats = {
            'pixel_valid_count': 0,
            'hblank_cycles':     0,
            'vblank_cycles':     0,
            'int_vblank_count':  0,
            'int_hblank_count':  0,
        }
        for _ in range(H_TOTAL * V_TOTAL):
            self.tick()
            if self.pixel_valid:  stats['pixel_valid_count'] += 1
            if self.hblank:       stats['hblank_cycles']     += 1
            if self.vblank:       stats['vblank_cycles']     += 1
            if self.int_vblank:   stats['int_vblank_count']  += 1
            if self.int_hblank:   stats['int_hblank_count']  += 1
        return stats
