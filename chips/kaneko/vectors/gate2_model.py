#!/usr/bin/env python3
"""
Kaneko 16 Gate 2 Reference Model
Sprite Scanner FSM (VU-001/VU-002)
"""

from enum import IntEnum


class SpriteDescriptorField(IntEnum):
    """Offsets within a sprite descriptor (8 words = 16 bytes)"""
    Y_POS = 0       # Word 0: Y position [8:0]
    TILE_NUM = 1    # Word 1: tile number [15:0]
    X_POS = 2       # Word 2: X position [8:0]
    ATTR = 3        # Word 3: attributes
    RESERVED_4 = 4  # Word 4-7: reserved
    RESERVED_5 = 5
    RESERVED_6 = 6
    RESERVED_7 = 7


class SpriteScannerModel:
    """Reference model of Kaneko 16 Gate 2 sprite scanner"""

    def __init__(self):
        """Initialize the model"""
        # Sprite RAM (64 KB = 32K words of 16-bit data)
        self.sprite_ram = [0x0000] * 32768

        # Display list (up to 256 sprites)
        self.display_list = []
        self.display_list_count = 0
        self.display_list_ready = False

        # Scanner state
        self.scanning = False
        self.vblank_prev = 1

    def set_sprite_ram(self, addr, data):
        """Set sprite RAM word"""
        self.sprite_ram[addr & 0x7FFF] = data & 0xFFFF

    def get_sprite_ram(self, addr):
        """Get sprite RAM word"""
        return self.sprite_ram[addr & 0x7FFF]

    def extract_sprite(self, sprite_index):
        """Extract sprite descriptor from RAM"""
        base_addr = sprite_index * 8

        y_pos = self.sprite_ram[(base_addr + 0) & 0x7FFF] & 0x01FF
        tile_num = self.sprite_ram[(base_addr + 1) & 0x7FFF]
        x_pos = self.sprite_ram[(base_addr + 2) & 0x7FFF] & 0x01FF
        attr = self.sprite_ram[(base_addr + 3) & 0x7FFF]

        palette = attr & 0x000F
        flip_x = (attr >> 4) & 0x0001
        flip_y = (attr >> 5) & 0x0001
        priority = (attr >> 6) & 0x000F
        size = (attr >> 10) & 0x000F

        return {
            'y': y_pos,
            'tile_num': tile_num,
            'x': x_pos,
            'palette': palette,
            'flip_x': flip_x,
            'flip_y': flip_y,
            'priority': priority,
            'size': size,
            'valid': y_pos != 0x1FF  # Sprite visible if Y != 0x1FF
        }

    def scan_sprites(self):
        """Scan all 256 sprites and build display list"""
        self.display_list = []

        for sprite_idx in range(256):
            sprite = self.extract_sprite(sprite_idx)
            if sprite['valid']:
                self.display_list.append(sprite)

        self.display_list_count = len(self.display_list)
        self.display_list_ready = True

    def vsync_edge(self, vsync_n):
        """Handle VBlank rising edge (vsync_n: 1 -> 0 -> 1)"""
        vblank_rising = (self.vblank_prev == 1) and (vsync_n == 0)
        self.vblank_prev = vsync_n

        if vblank_rising:
            self.scan_sprites()

        return vblank_rising

    def get_display_list(self):
        """Get the current display list"""
        return self.display_list

    def get_display_list_count(self):
        """Get number of valid sprites in display list"""
        return self.display_list_count

    def is_display_list_ready(self):
        """Check if display list is ready"""
        return self.display_list_ready
