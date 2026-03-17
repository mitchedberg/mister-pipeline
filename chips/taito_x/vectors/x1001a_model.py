"""
X1-001A Phase 1 software model.

Models the sprite RAM and control register read/write behavior.
Used by generate_vectors.py to produce ground-truth test vectors.

Phase 1 covers:
  - Sprite Y-coordinate RAM (0x300 bytes, accessed as 0x180 16-bit words)
  - Sprite code / attribute RAM (0x2000 × 16-bit words)
  - Control registers (4 × 8-bit registers)
  - Byte-enable write behavior
  - Double-buffer bank decode

MAME reference: src/devices/video/x1_001.cpp
"""

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
        addr = addr & (YRAM_WORDS - 1)   # mask to valid range (power-of-2 safe: 0x17F mask)
        addr = addr & 0x1FF              # full 9-bit mask
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
        """Read individual byte (byte address 0..0x2FF)."""
        byte_addr = byte_addr & 0x3FF
        word = byte_addr >> 1
        if word >= YRAM_WORDS:
            return 0xFF
        if byte_addr & 1:
            return self.hi[word]
        else:
            return self.lo[word]

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

    print("x1001a_model self-test PASS")
