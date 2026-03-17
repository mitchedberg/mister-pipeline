"""
TC0630FDP behavioral model — Python reference implementation (Steps 1–7).

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

Step 8 scope (added):
  - Sprite RAM (32K × 16-bit words)
  - write_sprite_ram(): write sprite entry words directly into Sprite RAM
  - scan_sprites(vpos_range): walk entries 0–255, build per-scanline active-sprite list
  - render_sprite_scanline(vpos): fill 320-entry line buffer from active-sprite list for
    the scanline after vpos (no zoom, pen==0 transparent, flip X/Y supported)

  Sprite RAM entry format (section1 §8.1, 8 words per entry):
    Word 0: tile_lo[15:0]
    Word 2: scroll_mode[15:14], sx[11:0] (signed)
    Word 3: is_cmd[15],         sy[11:0] (signed)
    Word 4: block_ctrl[15:12], lock[11], flipY[10], flipX[9], color[7:0]
    Word 5: tile_hi[0]
  tile_code = {tile_hi, tile_lo}  (17-bit total)
  priority  = color[7:6]         (top 2 bits of color byte)
  palette   = color[5:0]         (lower 6 bits)

Step 7 scope (added):
  - _line_colscroll(plane, scan): returns 9-bit column scroll offset (§9.2 bits[8:0])
  - _line_pal_add(plane, scan): returns palette-line addition offset (§9.10)
  - render_bg_scanline now includes colscroll (pixel offset to effective_x) and
    palette addition (added to tile palette index before output)

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
    """Steps 1–8 behavioral model: control registers, video timing, text layer, BG layers, Line RAM, zoom, sprites."""

    # Memory sizes
    TEXT_RAM_WORDS  = 4096    # 64×64 tile map × 1 word each
    CHAR_RAM_BYTES  = 8192    # 256 tiles × 32 bytes = 8KB
    PF_RAM_WORDS    = 6144    # 0x1800 words per playfield
    GFX_ROM_WORDS   = 4096    # simulation GFX ROM (32-bit words) — matches RTL BRAM
    LINE_RAM_WORDS  = 32768   # 32K × 16-bit words = 64KB Line RAM (step 5)
    SPR_RAM_WORDS   = 32768   # 32K × 16-bit words = 64KB Sprite RAM (step 8)
    SPR_COUNT       = 256     # Step 8: scan only first 256 entries

    def __init__(self):
        self.ctrl     = [0] * 16          # 16 × 16-bit display control registers
        self.text_ram = [0] * self.TEXT_RAM_WORDS   # step 2
        self.char_ram = [0] * self.CHAR_RAM_BYTES   # step 2 (bytes)
        self.pf_ram   = [[0] * self.PF_RAM_WORDS for _ in range(4)]  # step 3
        self.gfx_rom  = [0] * self.GFX_ROM_WORDS   # step 3 (32-bit words)
        self.line_ram = [0] * self.LINE_RAM_WORDS   # step 5 (16-bit words)
        self.spr_ram  = [0] * self.SPR_RAM_WORDS    # step 8 (16-bit words)
        self._rst()

    def _rst(self):
        """Reset all state (mirrors async_rst_n behaviour)."""
        self.ctrl     = [0] * 16
        self.text_ram = [0] * self.TEXT_RAM_WORDS
        self.char_ram = [0] * self.CHAR_RAM_BYTES
        self.pf_ram   = [[0] * self.PF_RAM_WORDS for _ in range(4)]
        self.gfx_rom  = [0] * self.GFX_ROM_WORDS
        self.line_ram = [0] * self.LINE_RAM_WORDS
        self.spr_ram  = [0] * self.SPR_RAM_WORDS

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

    # ── Line RAM read/write (Step 5) ─────────────────────────────────────────

    def write_line_ram(self, word_addr: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word to Line RAM at 15-bit word address (0x0000–0x7FFF).

        Matches RTL lineram module: line_ram[cpu_addr[15:1]].
        The CPU uses chip-relative word address 0x10000+word_addr, but internally
        the BRAM is indexed by the lower 15 bits (0–32767).
        """
        word_addr &= 0x7FFF
        data &= 0xFFFF
        cur = self.line_ram[word_addr]
        if be & 0x2: cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1: cur = (cur & 0xFF00) | (data & 0x00FF)
        self.line_ram[word_addr] = cur

    def read_line_ram(self, word_addr: int) -> int:
        """Read 16-bit word from Line RAM at 15-bit word address."""
        return self.line_ram[word_addr & 0x7FFF]

    # ── Sprite RAM read/write (Step 8) ───────────────────────────────────────

    def write_sprite_ram(self, word_addr: int, data: int, be: int = 0x3) -> None:
        """Write 16-bit word to Sprite RAM at 15-bit word address (0..32767).

        Sprite entries are 8 words each (words 0,1,2,3,4,5,6,7).
        Entry N starts at word address N*8.
        Step 8 uses words 0, 2, 3, 4, 5 of each entry.
        """
        word_addr &= 0x7FFF
        data &= 0xFFFF
        cur = self.spr_ram[word_addr]
        if be & 0x2: cur = (cur & 0x00FF) | (data & 0xFF00)
        if be & 0x1: cur = (cur & 0xFF00) | (data & 0x00FF)
        self.spr_ram[word_addr] = cur

    def read_sprite_ram(self, word_addr: int) -> int:
        """Read 16-bit word from Sprite RAM at 15-bit word address."""
        return self.spr_ram[word_addr & 0x7FFF]

    def write_sprite_entry(self, idx: int, tile_code: int, sx: int, sy: int,
                           color: int, flipx: bool = False, flipy: bool = False) -> None:
        """Write a complete sprite entry to Sprite RAM.

        idx       : sprite entry index (0–255 for Step 8)
        tile_code : 17-bit tile code
        sx        : screen X (signed 12-bit, left edge of tile)
        sy        : screen Y (signed 12-bit, top edge of tile)
        color     : 8-bit color byte: [7:6]=priority_group, [5:0]=palette
        flipx     : horizontal flip
        flipy     : vertical flip
        """
        idx &= 0xFF
        base = idx * 8
        tile_lo = tile_code & 0xFFFF
        tile_hi = (tile_code >> 16) & 0x1

        # sy is signed 12-bit; mask to 12 bits
        sx_12 = sx & 0xFFF
        sy_12 = sy & 0xFFF

        # word 4: [10]=flipY, [9]=flipX, [7:0]=color
        w4 = (color & 0xFF)
        if flipx: w4 |= (1 << 9)
        if flipy: w4 |= (1 << 10)

        self.spr_ram[base + 0] = tile_lo
        self.spr_ram[base + 2] = sx_12
        self.spr_ram[base + 3] = sy_12
        self.spr_ram[base + 4] = w4
        self.spr_ram[base + 5] = tile_hi

    def scan_sprites(self) -> list:
        """Walk sprite entries 0..SPR_COUNT-1, build per-scanline active-sprite lists.

        Returns: list of 232 lists (one per screen scanline V_START..V_END-1),
                 each list containing up to 64 sprite descriptors (dict).
        Sprite descriptor fields: tile_code, sx, sy, palette, prio, flipx, flipy.
        Matches RTL scanner logic: V_START=24, V_END=256, MAX_SLOT=63, SPR_COUNT=256.
        """
        slist = [[] for _ in range(V_END - V_START)]  # 232 entries

        for idx in range(self.SPR_COUNT):
            base = idx * 8
            w0 = self.spr_ram[base + 0]
            w2 = self.spr_ram[base + 2]
            w3 = self.spr_ram[base + 3]
            w4 = self.spr_ram[base + 4]
            w5 = self.spr_ram[base + 5]

            tile_lo   = w0
            sx_raw    = w2 & 0xFFF
            sy_raw    = w3 & 0xFFF
            flipy     = bool(w4 & (1 << 10))
            flipx     = bool(w4 & (1 << 9))
            color     = w4 & 0xFF
            tile_hi   = w5 & 0x1
            tile_code = (tile_hi << 16) | tile_lo
            palette   = color & 0x3F
            prio      = (color >> 6) & 0x3

            # Sign-extend 12-bit to signed int
            sx = sx_raw if sx_raw < 0x800 else sx_raw - 0x1000
            sy = sy_raw if sy_raw < 0x800 else sy_raw - 0x1000

            # Compute active scanline range: sy to sy+15 (16×16 tile)
            sy_top = max(V_START, sy)
            sy_bot = min(V_END - 1, sy + 15)

            if sy_top > sy_bot:
                continue   # sprite entirely off screen

            for scan in range(sy_top, sy_bot + 1):
                scan_idx = scan - V_START
                if len(slist[scan_idx]) >= 64:
                    continue  # slot full
                slist[scan_idx].append({
                    'tile_code': tile_code,
                    'sx':        sx,
                    'sy':        sy,
                    'palette':   palette,
                    'prio':      prio,
                    'flipx':     flipx,
                    'flipy':     flipy,
                })

        return slist

    def render_sprite_scanline(self, vpos: int, slist: list = None) -> list:
        """Render sprites for scanline (vpos+1) into a 320-entry line buffer.

        Returns list of 320 12-bit pixels: {prio[1:0], palette[5:0], pen[3:0]}.
        Zero entry = transparent (no sprite pixel at that column).

        Parameters:
          vpos  : current scanline (renders vpos+1, matching RTL hblank_fall logic)
          slist : pre-built scanline sprite list (from scan_sprites()); if None,
                  will call scan_sprites() internally.

        Rendering:
          - Iterates sprites in slot order (0 first, last slot overwrites = on top).
          - For each sprite: compute tile row from (vpos+1) - sy.
          - Decode 16 pixels from GFX ROM (left 8 + right 8).
          - Write non-transparent (pen != 0) pixels to linebuf at sx + px.
          - flipX: reverse nibble order within each 8-pixel half.
          - flipY: use row (15 - tile_row) from GFX ROM.
        """
        render_scan = vpos + 1   # RTL renders scanline vpos+1

        if render_scan < V_START or render_scan >= V_END:
            return [0] * 320

        scan_idx = render_scan - V_START

        if slist is None:
            slist = self.scan_sprites()

        sprites = slist[scan_idx]
        linebuf = [0] * 320

        for spr in sprites:
            tile_code = spr['tile_code']
            sx        = spr['sx']
            sy        = spr['sy']
            palette   = spr['palette']
            prio      = spr['prio']
            flipx     = spr['flipx']
            flipy     = spr['flipy']

            # Tile row: lower 4 bits of (render_scan - sy)
            tile_row = (render_scan - sy) & 0xF
            fetch_row = (15 - tile_row) if flipy else tile_row

            left_addr  = tile_code * 32 + fetch_row * 2
            right_addr = left_addr + 1
            left_word  = self.gfx_rom[left_addr]  if left_addr  < self.GFX_ROM_WORDS else 0
            right_word = self.gfx_rom[right_addr] if right_addr < self.GFX_ROM_WORDS else 0

            for px in range(16):
                scol = sx + px
                if scol < 0 or scol >= 320:
                    continue

                # Select half word and nibble index
                if px < 8:
                    ni = (7 - px) if flipx else px
                    sh = 28 - ni * 4
                    pen = (left_word >> sh) & 0xF
                else:
                    ni = (7 - (px & 7)) if flipx else (px & 7)
                    sh = 28 - ni * 4
                    pen = (right_word >> sh) & 0xF

                if pen == 0:
                    continue  # transparent
                linebuf[scol] = (prio << 10) | (palette << 4) | pen

        return linebuf

    # ── Line RAM decoder helpers (Step 5 + Step 6) ───────────────────────────

    def _line_rowscroll(self, plane: int, scan: int) -> int:
        """Return effective rowscroll for PF(plane+1) on scanline scan.

        Returns 0 if rowscroll is disabled for this PF/scanline.

        section1 §9.11 + §9.1:
          enable word: line_ram[0x0600 + (scan & 0xFF)], bit[plane] = enable
          data   word: line_ram[0x5000 + plane*0x100 + (scan & 0xFF)]
        """
        scan8 = scan & 0xFF
        en_word = self.line_ram[0x0600 + scan8]
        if not (en_word >> plane) & 1:
            return 0
        return self.line_ram[0x5000 + plane * 0x100 + scan8]

    def _line_alt_tilemap(self, plane: int, scan: int) -> bool:
        """Return alt-tilemap flag for PF(plane+1) on scanline scan.

        section1 §9.2 + §9.1:
          enable word: line_ram[0x0000 + (scan & 0xFF)], bit[4+plane] = enable
          data   word: line_ram[0x2000 + plane*0x100 + (scan & 0xFF)], bit[9] = flag
        """
        scan8 = scan & 0xFF
        en_word = self.line_ram[0x0000 + scan8]
        if not (en_word >> (4 + plane)) & 1:
            return False
        cs_word = self.line_ram[0x2000 + plane * 0x100 + scan8]
        return bool((cs_word >> 9) & 1)

    def _line_zoom(self, plane: int, scan: int) -> tuple:
        """Return (zoom_x, zoom_y) for PF(plane+1) on scanline scan (Step 6).

        Returns (0x00, 0x80) if zoom is disabled for this PF/scanline
        (0x00 = no X zoom, 0x80 = 1:1 Y zoom).

        section1 §9.9 + §9.1:
          enable word: line_ram[0x0400 + (scan & 0xFF)], bit[plane] = enable
          data words (§9.9):
            PF1: line_ram[0x4000 + scan]   — normal (no swap)
            PF2: line_ram[0x4200 + scan]   — X zoom; Y physically at PF4 addr
            PF3: line_ram[0x4100 + scan]   — normal (no swap)
            PF4: line_ram[0x4300 + scan]   — X zoom; Y physically at PF2 addr
          format: bits[15:8] = Y_scale, bits[7:0] = X_scale
          PF2/PF4 Y-zoom swap (hardware quirk):
            PF2 Y-zoom stored at 0x4300+scan (PF4 addr)
            PF4 Y-zoom stored at 0x4200+scan (PF2 addr)
        """
        scan8 = scan & 0xFF
        en_word = self.line_ram[0x0400 + scan8]
        if not (en_word >> plane) & 1:
            return (0x00, 0x80)

        # X-zoom addresses (not swapped)
        # Y-zoom addresses (PF2 and PF4 are physically swapped)
        if plane == 0:    # PF1: both X and Y from 0x4000+scan
            w = self.line_ram[0x4000 + scan8]
            zoom_x = w & 0xFF
            zoom_y = (w >> 8) & 0xFF
        elif plane == 1:  # PF2: X from 0x4200+scan, Y from 0x4300+scan (swap)
            wx = self.line_ram[0x4200 + scan8]
            wy = self.line_ram[0x4300 + scan8]
            zoom_x = wx & 0xFF
            zoom_y = (wy >> 8) & 0xFF
        elif plane == 2:  # PF3: both X and Y from 0x4100+scan
            w = self.line_ram[0x4100 + scan8]
            zoom_x = w & 0xFF
            zoom_y = (w >> 8) & 0xFF
        else:             # PF4: X from 0x4300+scan, Y from 0x4200+scan (swap)
            wx = self.line_ram[0x4300 + scan8]
            wy = self.line_ram[0x4200 + scan8]
            zoom_x = wx & 0xFF
            zoom_y = (wy >> 8) & 0xFF
        return (zoom_x, zoom_y)

    def _line_colscroll(self, plane: int, scan: int) -> int:
        """Return effective colscroll pixel offset for PF(plane+1) on scanline scan (Step 7).

        Returns 0 if colscroll is disabled for this PF/scanline.

        section1 §9.2 + §9.1:
          enable word: line_ram[0x0000 + (scan & 0xFF)], bit[plane] = enable
          data   word: line_ram[0x2000 + plane*0x100 + (scan & 0xFF)], bits[8:0] = colscroll
        """
        scan8 = scan & 0xFF
        en_word = self.line_ram[0x0000 + scan8]
        if not (en_word >> plane) & 1:
            return 0
        cs_word = self.line_ram[0x2000 + plane * 0x100 + scan8]
        return cs_word & 0x1FF   # 9-bit column scroll (pixel offset)

    def _line_pal_add(self, plane: int, scan: int) -> int:
        """Return effective palette-line addition for PF(plane+1) on scanline scan (Step 7).

        Returns 0 if pal_add is disabled for this PF/scanline.

        section1 §9.10 + §9.1:
          enable word: line_ram[0x0500 + (scan & 0xFF)], bit[plane] = enable
          data   word: line_ram[0x4800 + plane*0x100 + (scan & 0xFF)]
          Format: raw 16-bit value = palette_offset * 16.
          Returns palette_offset = raw >> 4  (9-bit, wraps with 9-bit palette).
        """
        scan8 = scan & 0xFF
        en_word = self.line_ram[0x0500 + scan8]
        if not (en_word >> plane) & 1:
            return 0
        raw = self.line_ram[0x4800 + plane * 0x100 + scan8]
        return (raw >> 4) & 0x1FF   # palette-line offset (9-bit)

    # ── BG layer render (Step 3+5+6+7) ─────────────────────────────────────────

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

        Canvas Y (Step 6 zoom):
          canvas_y_raw = (vpos + 1 + yscroll_int) & 0x1FF
          canvas_y = (canvas_y_raw * zoom_y) >> 7   (0x80 = 1:1)

        X zoom accumulator (Step 6, §9.9):
          zoom_step = 0x100 + zoom_x   (0x100 = no zoom / 1:1)
          acc = eff_x * 256 at pixel 0
          per output pixel p: canvas_x_fp = acc + p * zoom_step
          canvas_x = canvas_x_fp >> 8; px_in_tile = canvas_x & 0xF
          advance after 16 pixels: acc += 16 * zoom_step; next_tile = acc >> 12

        GFX ROM decode:
          tile_code = code_word
          flipY: row = 15 - fetch_py if flipy else fetch_py
          left_word  = gfx_rom[tile_code * 32 + row * 2]
          right_word = gfx_rom[tile_code * 32 + row * 2 + 1]
          pixel px_in_tile (0..15 within tile):
            half_px = px_in_tile & 7
            ni = (7 - half_px) if flipX else half_px   # flipX reversal
            src_word = left_word if px_in_tile < 8 else right_word
            pen = (src_word >> ((7 - ni) * 4)) & 0xF
        """
        plane = plane & 3
        map_width = 64 if extend_mode else 32
        wrap_mask_tile = map_width - 1

        # Scroll decode
        xscroll_int = (xscroll >> 6) & 0x3FF    # 10-bit integer part
        yscroll_int = (yscroll >> 7) & 0x1FF    # 9-bit

        # Step 5: apply Line RAM rowscroll and alt-tilemap for vpos (next_scan = vpos+1)
        rs_raw    = self._line_rowscroll(plane, vpos + 1)
        rs_int    = (rs_raw >> 6) & 0x3FF        # 10-bit integer rowscroll
        alt_tmap  = self._line_alt_tilemap(plane, vpos + 1)
        pf_base_offset = 0x1000 if alt_tmap else 0   # alt-tilemap: +0x1000 words (=+0x2000 bytes)

        # Step 7: apply colscroll (9-bit pixel offset) and get palette addition
        colscroll   = self._line_colscroll(plane, vpos + 1)    # 9-bit pixel offset
        pal_add_off = self._line_pal_add(plane, vpos + 1)      # 9-bit palette-line offset

        # Effective X = global_xscroll + rowscroll + colscroll (all in pixel units, 10-bit wrap)
        eff_x_int = (xscroll_int + rs_int + colscroll) & 0x3FF  # effective X integer (10-bit)

        # Step 6: zoom (§9.9)
        zoom_x, zoom_y = self._line_zoom(plane, vpos + 1)

        # Y zoom: canvas_y_raw * zoom_y >> 7  (9-bit * 8-bit = 17-bit; use bits[15:7])
        canvas_y_raw = ((vpos + 1) + yscroll_int) & 0x1FF
        canvas_y = ((canvas_y_raw * zoom_y) >> 7) & 0x1FF
        fetch_py = canvas_y & 0xF
        fetch_ty = (canvas_y >> 4) & 0x1F

        # X zoom accumulator: zoom_step = 0x100 + zoom_x
        zoom_step = 0x100 + zoom_x   # 9-bit (256 = 1:1)

        # acc is 19-bit: 11 integer bits (canvas_x[10:0]) + 8 fractional bits
        acc = (eff_x_int & 0x3FF) << 8   # eff_x * 256 (start of first output pixel)

        # Fetch the first tile for this scanline
        first_tile_x = ((acc >> 12) & 0x3FF) & wrap_mask_tile
        current_tile_x = first_tile_x

        linebuf = [0] * 320

        # Simulate the FSM's 21-tile fetch loop
        for slot in range(21):
            # Fetch tile at current_tile_x
            tile_idx  = fetch_ty * map_width + current_tile_x
            word_base = tile_idx * 2 + pf_base_offset

            attr_word = self.pf_ram[plane][word_base]     if word_base < self.PF_RAM_WORDS else 0
            code_word = self.pf_ram[plane][word_base + 1] if word_base + 1 < self.PF_RAM_WORDS else 0

            palette   = attr_word & 0x1FF
            flipx     = bool(attr_word & (1 << 14))
            flipy     = bool(attr_word & (1 << 15))
            tile_code = code_word & 0xFFFF

            row = (15 - fetch_py) if flipy else fetch_py

            left_addr  = tile_code * 32 + row * 2
            right_addr = left_addr + 1
            left_word  = self.gfx_rom[left_addr]  if left_addr  < self.GFX_ROM_WORDS else 0
            right_word = self.gfx_rom[right_addr] if right_addr < self.GFX_ROM_WORDS else 0

            # Compute screen column base for this 16-output-pixel slot
            # run_xoff = eff_x_int & 0xF (pixel offset into first tile)
            run_xoff = eff_x_int & 0xF
            scol_base = slot * 16 - run_xoff

            # Write 16 output pixels for this slot
            for px in range(16):
                scol = scol_base + px
                if scol < 0 or scol >= 320:
                    continue

                # Per-pixel canvas X from zoom accumulator
                acc_px = acc + px * zoom_step
                px_in_tile = (acc_px >> 8) & 0xF   # canvas_x[3:0]

                # Select half word based on canvas pixel position (NOT flipped)
                src_word = right_word if (px_in_tile & 8) else left_word
                # Nibble index within the selected 8-px word.
                # Normal:  ni = px_in_tile & 7  (pixel 0 of half → nibble 0 → bits[31:28])
                # FlipX:   ni = 7 - (px_in_tile & 7)  (reverse within the half)
                ni    = (7 - (px_in_tile & 7)) if flipx else (px_in_tile & 7)
                shift = 28 - (ni * 4)     # ni=0→bits[31:28], ni=7→bits[3:0]
                pen   = (src_word >> shift) & 0xF

                # Palette addition (Step 7): add pal_add_off to palette index (9-bit wrap)
                eff_palette = (palette + pal_add_off) & 0x1FF
                linebuf[scol] = (eff_palette << 4) | pen

            # Advance accumulator and compute next tile
            acc = (acc + 16 * zoom_step) & 0x7FFFF   # keep 19 bits
            current_tile_x = (acc >> 12) & wrap_mask_tile

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
