#!/usr/bin/env python3
"""
gate2_model.py — GP9001 Gate 2 Python behavioral model.

Models the sprite scanner FSM that runs during VBLANK.

Sprite RAM word layout (per sprite, 4 consecutive 16-bit words):
  Word 0  [8:0]   y_pos       (9-bit; 0x100 = null/invisible sentinel)
  Word 1  [9:0]   tile_num;  [10] flip_x;  [11] flip_y;  [15] priority
  Word 2  [8:0]   x_pos       (9-bit)
  Word 3  [3:0]   palette;   [5:4] size (0=8x8, 1=16x16, 2=32x32, 3=64x64)

Scan count from SPRITE_CTRL[15:12] (sprite_list_len_code):
  0  → scan 256 slots
  1  → scan 128 slots
  2  → scan 64 slots
  3  → scan 32 slots
  ≥4 → scan 16 slots

Sort mode from SPRITE_CTRL[6] (sprite_sort_mode bit 0):
  0 = forward scan (slot 0 first)
  1 = reverse scan (slot N-1 first → back-to-front)
"""

from dataclasses import dataclass, field
from typing import List, Optional

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

NUM_SPRITES     = 256
WORDS_PER_SPRITE = 4
SPRITE_RAM_WORDS = NUM_SPRITES * WORDS_PER_SPRITE  # 1024

Y_NULL_SENTINEL = 0x100   # sprite is invisible when word0[8:0] == this


# ─────────────────────────────────────────────────────────────────────────────
# Display list entry
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class SpriteEntry:
    x:        int    = 0
    y:        int    = 0
    tile_num: int    = 0
    flip_x:   bool   = False
    flip_y:   bool   = False
    priority: bool   = False
    palette:  int    = 0
    size:     int    = 0     # 0=8x8, 1=16x16, 2=32x32, 3=64x64
    valid:    bool   = False

    def to_dict(self) -> dict:
        return {
            'x':        self.x,
            'y':        self.y,
            'tile_num': self.tile_num,
            'flip_x':   int(self.flip_x),
            'flip_y':   int(self.flip_y),
            'priority': int(self.priority),
            'palette':  self.palette,
            'size':     self.size,
            'valid':    int(self.valid),
        }


# ─────────────────────────────────────────────────────────────────────────────
# Scanner model
# ─────────────────────────────────────────────────────────────────────────────

class GP9001ScannerModel:
    """
    Behavioral model of the GP9001 Gate 2 sprite scanner.

    Usage:
        model = GP9001ScannerModel()
        model.write_sprite_raw(word_idx, value)   # populate sprite RAM
        model.sprite_ctrl = 0x0000                # set SPRITE_CTRL
        display_list, count = model.run_scan()
    """

    def __init__(self):
        # Sprite RAM: 1024 × 16-bit words
        self._sprite_ram: List[int] = [0] * SPRITE_RAM_WORDS

        # SPRITE_CTRL active register (set before calling run_scan)
        self.sprite_ctrl: int = 0x0000

    # ── Sprite RAM access ─────────────────────────────────────────────────────

    def write_sprite_raw(self, word_idx: int, val: int) -> None:
        assert 0 <= word_idx < SPRITE_RAM_WORDS, f"word_idx {word_idx} out of range"
        self._sprite_ram[word_idx] = val & 0xFFFF

    def read_sprite_raw(self, word_idx: int) -> int:
        assert 0 <= word_idx < SPRITE_RAM_WORDS
        return self._sprite_ram[word_idx]

    def write_sprite(self, sprite_idx: int, word_offset: int, val: int) -> None:
        assert 0 <= sprite_idx < NUM_SPRITES
        assert 0 <= word_offset < WORDS_PER_SPRITE
        self._sprite_ram[sprite_idx * WORDS_PER_SPRITE + word_offset] = val & 0xFFFF

    def read_sprite(self, sprite_idx: int, word_offset: int) -> int:
        assert 0 <= sprite_idx < NUM_SPRITES
        assert 0 <= word_offset < WORDS_PER_SPRITE
        return self._sprite_ram[sprite_idx * WORDS_PER_SPRITE + word_offset]

    # ── Control register helpers ──────────────────────────────────────────────

    @property
    def sprite_list_len_code(self) -> int:
        """SPRITE_CTRL[15:12] — scan count code."""
        return (self.sprite_ctrl >> 12) & 0xF

    @property
    def scan_max(self) -> int:
        """Number of sprite slots to scan (max 64 due to CPU address decode).
        The RTL caps at 64 since only sram[256..511] is CPU-accessible."""
        code = self.sprite_list_len_code
        if   code == 0: return 64   # capped at 64
        elif code == 1: return 64   # capped at 64
        elif code == 2: return 64   # capped at 64
        elif code == 3: return 32
        else:           return 16

    @property
    def reverse_scan(self) -> bool:
        """SPRITE_CTRL[6] — if True, scan in reverse order (N-1 down to 0)."""
        return bool((self.sprite_ctrl >> 6) & 1)

    # ── Scanner ───────────────────────────────────────────────────────────────

    def _decode_slot(self, slot_idx: int) -> Optional[SpriteEntry]:
        """
        Decode one sprite slot.  Returns SpriteEntry if visible, else None.
        Slot index: 0..255.
        """
        base = slot_idx * WORDS_PER_SPRITE
        w0 = self._sprite_ram[base + 0]
        w1 = self._sprite_ram[base + 1]
        w2 = self._sprite_ram[base + 2]
        w3 = self._sprite_ram[base + 3]

        y_pos = w0 & 0x1FF          # 9-bit
        if y_pos == Y_NULL_SENTINEL:
            return None             # invisible

        tile_num  = w1 & 0x3FF      # bits [9:0]
        flip_x    = bool((w1 >> 10) & 1)
        flip_y    = bool((w1 >> 11) & 1)
        priority  = bool((w1 >> 15) & 1)
        x_pos     = w2 & 0x1FF      # 9-bit
        palette   = w3 & 0xF        # bits [3:0]
        size      = (w3 >> 4) & 0x3 # bits [5:4]

        return SpriteEntry(
            x=x_pos, y=y_pos,
            tile_num=tile_num,
            flip_x=flip_x, flip_y=flip_y,
            priority=priority,
            palette=palette, size=size,
            valid=True,
        )

    def run_scan(self) -> tuple:
        """
        Run one full scan (as triggered by a VBLANK edge).

        Returns:
            (display_list, count)
            display_list: list of up to 256 SpriteEntry objects
            count: number of valid entries in display_list
        """
        n = self.scan_max
        reverse = self.reverse_scan

        # Build ordered list of slot indices to scan
        if reverse:
            slots = list(range(n - 1, -1, -1))   # [n-1, n-2, ..., 0]
        else:
            slots = list(range(n))                # [0, 1, ..., n-1]

        display_list: List[SpriteEntry] = []
        for slot_idx in slots:
            entry = self._decode_slot(slot_idx)
            if entry is not None:
                display_list.append(entry)
                if len(display_list) >= 256:
                    break  # safety cap

        count = len(display_list)
        # Pad to 256 with empty entries
        while len(display_list) < 256:
            display_list.append(SpriteEntry())

        return display_list, count
