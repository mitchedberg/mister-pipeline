#!/usr/bin/env python3
"""
NMK16 Gate 2 Python Model — Sprite Scanner FSM
Simulates the sprite scanner behavioral model for test vector generation and validation.
"""

import json
from enum import IntEnum
from typing import List, Tuple


class SpriteAttr(IntEnum):
    """Sprite attribute bit fields"""
    SIZE_0 = 0
    SIZE_1 = 1
    FLIP_X = 2
    FLIP_Y = 3
    PALETTE_0 = 4
    PALETTE_1 = 5
    PALETTE_2 = 6
    PALETTE_3 = 7
    # Word 3, bits [15:8] reserved or per-game specific


class NMK16Gate2Model:
    """
    Simulates NMK16 Gate 2 sprite scanner FSM.
    - Reads all 256 sprites from sprite RAM
    - Filters visible sprites (Y != 0x01FF inactive sentinel)
    - Builds display_list[] of visible sprites
    - Signals display_list_ready pulse on completion
    - Signals irq_vblank pulse at end of VBLANK
    """

    INACTIVE_Y = 0x01FF  # 9-bit Y position sentinel for hidden sprites

    def __init__(self):
        # Sprite RAM (256 sprites × 4 words = 1024 × 16-bit)
        self.sprite_ram = [0x0000] * 1024

        # Display list (up to 256 visible sprites)
        self.display_list = []
        self.display_list_ready = False
        self.irq_vblank = False

        # FSM state
        self.vblank_active = False
        self.scan_index = 0
        self.scan_done = False

    def write_sprite_ram(self, addr: int, data: int):
        """Write to sprite RAM (word-addressed)"""
        sprite_addr = addr & 0x3FF  # 1024 × 16-bit words
        self.sprite_ram[sprite_addr] = data & 0xFFFF

    def read_sprite_ram(self, addr: int) -> int:
        """Read from sprite RAM (word-addressed)"""
        sprite_addr = addr & 0x3FF
        return self.sprite_ram[sprite_addr]

    def process_vblank_rising_edge(self):
        """
        Called when VBLANK assertion (vsync_n falling edge, i.e., 1 -> 0).
        Initiates sprite scanning FSM.
        """
        self.vblank_active = True
        self.scan_index = 0
        self.display_list = []
        self.display_list_ready = False
        self.irq_vblank = False
        self.scan_done = False

    def process_vblank_cycle(self):
        """
        Execute one cycle of sprite scanning during VBLANK.
        In real hardware, this scans one sprite per cycle.
        For testing, we batch-scan all sprites when called.
        """
        if not self.vblank_active:
            return

        # Scan sprites (batch mode for testing)
        if not self.scan_done:
            self._scan_all_sprites()
            self.scan_done = True
            self.display_list_ready = True
            self.irq_vblank = True

    def _scan_all_sprites(self):
        """
        Scan all 256 sprites and build display_list.
        Each sprite occupies 4 words in sprite RAM:
          Word 0: Y position [15:0] (9-bit valid, bit 8 = bit 0 of signed number)
          Word 1: X position [15:0] (9-bit valid)
          Word 2: Tile code [15:0]
          Word 3: Attributes [15:0]
        """
        self.display_list = []

        for sprite_idx in range(256):
            base_addr = sprite_idx * 4

            # Read 4 words (Y, X, tile code, attributes)
            y_word = self.sprite_ram[base_addr + 0]
            x_word = self.sprite_ram[base_addr + 1]
            tile_word = self.sprite_ram[base_addr + 2]
            attr_word = self.sprite_ram[base_addr + 3]

            # Extract Y position (bits [8:0], 9-bit signed)
            y_pos = y_word & 0x01FF

            # Check if sprite is active (Y != 0x01FF sentinel)
            if y_pos == self.INACTIVE_Y:
                continue  # Skip hidden sprite

            # Extract X position (bits [8:0], 9-bit)
            x_pos = x_word & 0x01FF

            # Extract tile code (bits [11:0])
            tile_code = tile_word & 0x0FFF

            # Extract attributes from Word 3
            flip_x = (attr_word >> 10) & 1
            flip_y = (attr_word >> 9) & 1
            size = (attr_word >> 14) & 3
            palette = (attr_word >> 4) & 0x0F

            # Add to display list
            sprite_entry = {
                'sprite_idx': sprite_idx,
                'x': x_pos,
                'y': y_pos,
                'tile_code': tile_code,
                'flip_x': flip_x,
                'flip_y': flip_y,
                'size': size,
                'palette': palette,
                'valid': 1,
            }
            self.display_list.append(sprite_entry)

    def get_display_list(self) -> List[dict]:
        """Return current display list"""
        return self.display_list

    def get_display_list_count(self) -> int:
        """Return number of visible sprites in display list"""
        return len(self.display_list)

    def clear_vblank(self):
        """Clear VBLANK state (called when vsync_n rises, i.e., 0 -> 1)"""
        self.vblank_active = False
        self.display_list_ready = False
        self.irq_vblank = False


if __name__ == "__main__":
    # Quick test of the model
    model = NMK16Gate2Model()

    # Test 1: Write sprite 0 (Y=0x0000, X=0x0050, tile=0x0100, attr=0x0000)
    # (Note: bytes are word-addressable, so address is already /2)
    model.write_sprite_ram(0, 0x0000)  # Y
    model.write_sprite_ram(1, 0x0050)  # X
    model.write_sprite_ram(2, 0x0100)  # Tile
    model.write_sprite_ram(3, 0x0000)  # Attr

    # Test 2: Write sprite 1 (Y=0x0010, X=0x0060, tile=0x0101, attr=0x4400)
    model.write_sprite_ram(4, 0x0010)  # Y
    model.write_sprite_ram(5, 0x0060)  # X
    model.write_sprite_ram(6, 0x0101)  # Tile
    model.write_sprite_ram(7, 0x4400)  # Attr (palette=4, size=1)

    # Test 3: Write hidden sprite 255 (Y=0x01FF inactive sentinel)
    model.write_sprite_ram(1020, 0x01FF)  # Y (hidden)
    model.write_sprite_ram(1021, 0x0000)  # X
    model.write_sprite_ram(1022, 0x0200)  # Tile
    model.write_sprite_ram(1023, 0x0000)  # Attr

    # Scan sprites
    model.process_vblank_rising_edge()
    model.process_vblank_cycle()

    # Verify
    display_list = model.get_display_list()
    assert len(display_list) == 2, f"Expected 2 visible sprites, got {len(display_list)}"
    assert display_list[0]['x'] == 0x50, "Sprite 0 X mismatch"
    assert display_list[0]['y'] == 0x00, "Sprite 0 Y mismatch"
    assert display_list[1]['x'] == 0x60, "Sprite 1 X mismatch"
    assert display_list[1]['y'] == 0x10, "Sprite 1 Y mismatch"
    assert display_list[1]['palette'] == 4, "Sprite 1 palette mismatch"
    assert display_list[1]['size'] == 1, "Sprite 1 size mismatch"

    print("✓ All model tests passed")
