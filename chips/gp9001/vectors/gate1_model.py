#!/usr/bin/env python3
"""
gate1_model.py — GP9001 Gate 1 Python behavioral model.

Models the CPU interface and register file only (no rendering).

Register map (word offsets, chip-relative):
  0x00  SCROLL0_X
  0x01  SCROLL0_Y
  0x02  SCROLL1_X
  0x03  SCROLL1_Y
  0x04  SCROLL2_X
  0x05  SCROLL2_Y
  0x06  SCROLL3_X
  0x07  SCROLL3_Y
  0x08  ROWSCROLL_X
  0x09  LAYER_CTRL
  0x0A  SPRITE_CTRL
  0x0B  LAYER_SIZE
  0x0C  COLOR_KEY
  0x0D  BLEND_CTRL
  0x0E  STATUS       (read-only)
  0x0F  (reserved)

Sprite RAM: 256 sprites × 4 words = 1024 × 16-bit.
Address decode:
  addr[9:8] == 0b00  →  control registers
  addr[9:8] == 0b01  →  sprite RAM (addr[9:0] = word index)
"""

# ─────────────────────────────────────────────────────────────────────────────
# Register index constants (word offsets)
# ─────────────────────────────────────────────────────────────────────────────

REG_SCROLL0_X   = 0x00
REG_SCROLL0_Y   = 0x01
REG_SCROLL1_X   = 0x02
REG_SCROLL1_Y   = 0x03
REG_SCROLL2_X   = 0x04
REG_SCROLL2_Y   = 0x05
REG_SCROLL3_X   = 0x06
REG_SCROLL3_Y   = 0x07
REG_ROWSCROLL   = 0x08
REG_LAYER_CTRL  = 0x09
REG_SPRITE_CTRL = 0x0A
REG_LAYER_SIZE  = 0x0B
REG_COLOR_KEY   = 0x0C
REG_BLEND_CTRL  = 0x0D
REG_STATUS      = 0x0E
REG_RESERVED    = 0x0F

SPRITE_RAM_BASE = 0x100   # word offset for sprite RAM start
NUM_SPRITES     = 256
WORDS_PER_SPRITE = 4
SPRITE_RAM_WORDS = NUM_SPRITES * WORDS_PER_SPRITE  # 1024


class GP9001Model:
    """
    Behavioral model of GP9001 Gate 1 (CPU interface + register file).

    Tracks shadow registers (CPU-visible) and active registers (renderer-visible,
    updated on vsync).  Sprite RAM is a flat 1024-word array.
    """

    def __init__(self):
        # Shadow registers (written by CPU)
        self._shadow = [0] * 16      # indexed by reg offset 0x00–0x0F
        self._shadow[REG_STATUS] = 0  # status read-only; starts 0

        # Active registers (committed on vsync)
        self._active = [0] * 16

        # Sprite RAM: 1024 × 16-bit
        self._sprite_ram = [0] * SPRITE_RAM_WORDS

    # ──────────────────────────────────────────────────────────────────────────
    # CPU bus operations
    # ──────────────────────────────────────────────────────────────────────────

    def write_reg(self, word_offset: int, data: int) -> None:
        """
        Write a control register (word_offset 0x00–0x0F).
        STATUS and RESERVED are ignored.
        """
        word_offset &= 0xF
        data &= 0xFFFF
        if word_offset == REG_STATUS:
            return  # read-only
        if word_offset == REG_RESERVED:
            return  # writes ignored
        self._shadow[word_offset] = data

    def read_reg(self, word_offset: int) -> int:
        """
        Read a control register (word_offset 0x00–0x0F).
        Reads come from shadow (what the CPU last wrote).
        STATUS returns current vblank state (always 0 in model).
        """
        word_offset &= 0xF
        if word_offset == REG_STATUS:
            return 0  # vblank=0 (no video timing in model)
        if word_offset == REG_RESERVED:
            return 0
        return self._shadow[word_offset]

    def write_sprite(self, sprite_idx: int, word_offset: int, val: int) -> None:
        """
        Write one word of a sprite entry.
        sprite_idx: 0..255
        word_offset: 0..3 (selects attr0..attr3)
        val: 16-bit value
        """
        assert 0 <= sprite_idx < NUM_SPRITES, f"sprite_idx {sprite_idx} out of range"
        assert 0 <= word_offset < WORDS_PER_SPRITE, f"word_offset {word_offset} out of range"
        ram_idx = sprite_idx * WORDS_PER_SPRITE + word_offset
        self._sprite_ram[ram_idx] = val & 0xFFFF

    def read_sprite(self, sprite_idx: int, word_offset: int) -> int:
        """Read one word of a sprite entry."""
        assert 0 <= sprite_idx < NUM_SPRITES
        assert 0 <= word_offset < WORDS_PER_SPRITE
        return self._sprite_ram[sprite_idx * WORDS_PER_SPRITE + word_offset]

    def write_sprite_raw(self, ram_word_idx: int, val: int) -> None:
        """Write sprite RAM by flat word index (0..1023)."""
        assert 0 <= ram_word_idx < SPRITE_RAM_WORDS
        self._sprite_ram[ram_word_idx] = val & 0xFFFF

    def read_sprite_raw(self, ram_word_idx: int) -> int:
        """Read sprite RAM by flat word index (0..1023)."""
        assert 0 <= ram_word_idx < SPRITE_RAM_WORDS
        return self._sprite_ram[ram_word_idx]

    # ──────────────────────────────────────────────────────────────────────────
    # vsync staging
    # ──────────────────────────────────────────────────────────────────────────

    def vsync_pulse(self) -> None:
        """
        Simulate a vsync rising edge: copy shadow → active.
        Call this to latch shadow register values into the active set.
        """
        self._active = list(self._shadow)

    # ──────────────────────────────────────────────────────────────────────────
    # Decoded active register values
    # ──────────────────────────────────────────────────────────────────────────

    @property
    def scroll(self) -> list:
        """Active scroll registers as [scroll0_x, scroll0_y, ..., scroll3_y]."""
        return [self._active[i] for i in range(8)]

    @property
    def scroll0_x(self) -> int: return self._active[REG_SCROLL0_X]
    @property
    def scroll0_y(self) -> int: return self._active[REG_SCROLL0_Y]
    @property
    def scroll1_x(self) -> int: return self._active[REG_SCROLL1_X]
    @property
    def scroll1_y(self) -> int: return self._active[REG_SCROLL1_Y]
    @property
    def scroll2_x(self) -> int: return self._active[REG_SCROLL2_X]
    @property
    def scroll2_y(self) -> int: return self._active[REG_SCROLL2_Y]
    @property
    def scroll3_x(self) -> int: return self._active[REG_SCROLL3_X]
    @property
    def scroll3_y(self) -> int: return self._active[REG_SCROLL3_Y]

    @property
    def rowscroll_ctrl(self) -> int: return self._active[REG_ROWSCROLL]

    @property
    def layer_ctrl(self) -> int: return self._active[REG_LAYER_CTRL]

    @property
    def num_layers_active(self) -> int:
        """Bits [7:6] of LAYER_CTRL: 0=2 layers, 1=3 layers, 2=4 layers."""
        return (self._active[REG_LAYER_CTRL] >> 6) & 0x3

    @property
    def bg0_priority(self) -> int:
        return (self._active[REG_LAYER_CTRL] >> 4) & 0x3

    @property
    def bg1_priority(self) -> int:
        return (self._active[REG_LAYER_CTRL] >> 2) & 0x3

    @property
    def bg23_priority(self) -> int:
        return (self._active[REG_LAYER_CTRL] >> 0) & 0x3

    @property
    def sprite_ctrl(self) -> int: return self._active[REG_SPRITE_CTRL]

    @property
    def sprite_list_len_code(self) -> int:
        """Bits [15:12] of SPRITE_CTRL."""
        return (self._active[REG_SPRITE_CTRL] >> 12) & 0xF

    @property
    def sprite_sort_mode(self) -> int:
        """Bits [7:6] of SPRITE_CTRL."""
        return (self._active[REG_SPRITE_CTRL] >> 6) & 0x3

    @property
    def sprite_prefetch_mode(self) -> int:
        """Bits [5:4] of SPRITE_CTRL."""
        return (self._active[REG_SPRITE_CTRL] >> 4) & 0x3

    @property
    def layer_size(self) -> int: return self._active[REG_LAYER_SIZE]

    @property
    def color_key(self) -> int: return self._active[REG_COLOR_KEY]

    @property
    def blend_ctrl(self) -> int: return self._active[REG_BLEND_CTRL]

    @property
    def sprite_en(self) -> bool:
        """Sprite list is enabled when sprite_list_len_code != 0."""
        return self.sprite_list_len_code != 0

    # ──────────────────────────────────────────────────────────────────────────
    # Decoded sprite entry helper
    # ──────────────────────────────────────────────────────────────────────────

    def decode_sprite(self, sprite_idx: int) -> dict:
        """
        Return a dict with decoded fields for sprite sprite_idx.
        Uses values currently in sprite RAM (not staged).
        """
        w0 = self.read_sprite(sprite_idx, 0)
        w1 = self.read_sprite(sprite_idx, 1)
        w2 = self.read_sprite(sprite_idx, 2)
        w3 = self.read_sprite(sprite_idx, 3)

        flip_y      = (w0 >> 15) & 1
        flip_x      = (w0 >> 14) & 1
        color_bank  = (w0 >> 8)  & 0x3F
        code_lo     = (w0 >> 0)  & 0xFF

        code_hi     = (w1 >> 8)  & 0xFF
        y_pos       = (w1 >> 0)  & 0xFF   # signed 8-bit
        y_signed    = y_pos if y_pos < 128 else y_pos - 256

        width_code  = (w2 >> 14) & 0x3
        height_code = (w2 >> 12) & 0x3
        x_pos       = (w2 >> 0)  & 0xFFF  # signed 12-bit
        x_signed    = x_pos if x_pos < 2048 else x_pos - 4096

        priority    = (w3 >> 15) & 1
        blend_mode  = (w3 >> 12) & 0x7

        sprite_code = (code_hi << 8) | code_lo
        width_px    = [16, 32, 64, 128][width_code]
        height_px   = [16, 32, 64, 128][height_code]

        return {
            'code':       sprite_code,
            'color_bank': color_bank,
            'flip_x':     bool(flip_x),
            'flip_y':     bool(flip_y),
            'x':          x_signed,
            'y':          y_signed,
            'width':      width_px,
            'height':     height_px,
            'priority':   bool(priority),
            'blend_mode': blend_mode,
            'enabled':    (sprite_code != 0),
        }

    def __repr__(self) -> str:
        return (
            f"GP9001Model("
            f"scroll0=({self.scroll0_x:#06x},{self.scroll0_y:#06x}) "
            f"layer_ctrl={self.layer_ctrl:#06x} "
            f"sprite_ctrl={self.sprite_ctrl:#06x} "
            f"sprite_en={self.sprite_en})"
        )
