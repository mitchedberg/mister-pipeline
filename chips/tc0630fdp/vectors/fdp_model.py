"""
TC0630FDP behavioral model — Python reference implementation (Step 1).

Step 1 scope:
  - Display control register bank (16 × 16-bit registers)
  - CPU bus read/write with byte-lane enables
  - Video timing: H/V counters, hblank/vblank/hsync/vsync, pixel_valid
  - Interrupt generation (int_vblank, int_hblank)

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
    """Step 1 behavioral model: control registers + video timing."""

    def __init__(self):
        self.ctrl = [0] * 16   # 16 × 16-bit display control registers
        self._rst()

    def _rst(self):
        """Reset all state (mirrors async_rst_n behaviour)."""
        self.ctrl = [0] * 16

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
