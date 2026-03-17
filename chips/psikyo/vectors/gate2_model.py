#!/usr/bin/env python3
"""
Psikyo Gate 2 (Sprite Scanner) behavioral model.
Simulates PS2001B sprite list parsing and display list generation.
"""

import json
from dataclasses import dataclass


@dataclass
class TestVector:
    """Single test vector for Gate 2."""
    vsync_n: int
    spr_table_base: int
    spr_count: int
    spr_y_offset: int
    expected_display_list_count: int
    expected_valid_sprites: list  # List of visible sprite indices
    name: str
    chip: str = "PS2001B"


class Gate2Model:
    """
    Behavioral model of Gate 2 (Sprite Scanner).
    Simulates sprite list parsing on VBLANK rising edge.
    """

    def __init__(self):
        self.spr_table_base = 0x00000000
        self.spr_count = 0
        self.spr_y_offset = 0
        self.display_list = []
        self.display_list_ready = False
        self.display_list_count = 0

    def scan_sprites(self, sprite_list_data):
        """
        Scan sprite list and build display list.

        Args:
            sprite_list_data: Dictionary of sprite_index -> sprite_entry
            Each sprite entry is a dict with keys:
              - y: Y position [9:0] (0x3FF = inactive)
              - x: X position [9:0]
              - tile: tile number [15:0]
              - attr: attributes (palette, flip_x, flip_y, priority, size)
        """
        self.display_list = []
        self.display_list_count = 0

        # Current RTL is a stub: it just marks all sprites as valid if spr_count > 0
        # It doesn't actually read sprite_ram_dout, so we model that behavior.
        # In a full implementation, it would check Y != 0x3FF for each sprite.

        # For now: if spr_count > 0, all spr_count sprites are marked valid
        for idx in range(min(self.spr_count, 256)):
            entry = {
                'index': idx,
                'x': 0,
                'y': 0,
                'tile': 0,
                'palette': 0,
                'flip_x': 0,
                'flip_y': 0,
                'priority': 0,
                'size': 0,
                'valid': True  # Stub marks all as valid
            }
            self.display_list.append(entry)
            self.display_list_count += 1

        self.display_list_ready = True
        return self.display_list

    def reset(self):
        """Reset scanner state."""
        self.display_list = []
        self.display_list_ready = False
        self.display_list_count = 0


def generate_test_vectors():
    """Generate comprehensive Gate 2 test vectors."""
    vectors = []
    model = Gate2Model()

    # Test 1: Empty sprite list
    model.spr_table_base = 0x00020000
    model.spr_count = 0
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=0,
        spr_y_offset=0,
        expected_display_list_count=0,
        expected_valid_sprites=[],
        name="Empty_SpriteList"
    ))

    # Test 2: Single visible sprite
    sprite_list = {
        0: {'y': 0x50, 'x': 0x80, 'tile': 0x0001, 'attr': 0x0000}
    }
    model.spr_count = 1
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=1,
        spr_y_offset=0,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="Single_Visible_Sprite"
    ))

    # Test 3: Multiple visible sprites
    sprite_list = {
        0: {'y': 0x30, 'x': 0x40, 'tile': 0x0010, 'attr': 0x0000},
        1: {'y': 0x60, 'x': 0x80, 'tile': 0x0011, 'attr': 0x1000},
        2: {'y': 0x90, 'x': 0xC0, 'tile': 0x0012, 'attr': 0x2000},
    }
    model.spr_count = 3
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=3,
        spr_y_offset=0,
        expected_display_list_count=3,
        expected_valid_sprites=[0, 1, 2],
        name="Multiple_Visible_Sprites"
    ))

    # Test 4: Sprite with Y=0x3FF (inactive sentinel)
    sprite_list = {
        0: {'y': 0x50, 'x': 0x80, 'tile': 0x0001, 'attr': 0x0000},
        1: {'y': 0x3FF, 'x': 0x00, 'tile': 0x0000, 'attr': 0x0000},  # Inactive
        2: {'y': 0x70, 'x': 0x90, 'tile': 0x0003, 'attr': 0x0000},
    }
    model.spr_count = 3
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=3,
        spr_y_offset=0,
        expected_display_list_count=2,
        expected_valid_sprites=[0, 2],
        name="Inactive_Sprite_0x3FF"
    ))

    # Test 5: Maximum sprites (256)
    sprite_list = {}
    for i in range(256):
        sprite_list[i] = {
            'y': (i * 2) & 0x1FF,  # Vary Y positions
            'x': (i * 3) & 0x1FF,
            'tile': i & 0xFFFF,
            'attr': (i & 0xF) << 12  # Vary palette
        }
    model.spr_count = 256
    display_list = model.scan_sprites(sprite_list)
    # All should be visible (no 0x3FF values)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=256,
        spr_y_offset=0,
        expected_display_list_count=256,
        expected_valid_sprites=list(range(256)),
        name="Maximum_256_Sprites"
    ))

    # Test 6: Sprite with palette variations
    sprite_list = {
        0: {'y': 0x40, 'x': 0x50, 'tile': 0x0100, 'attr': 0x0000},  # Palette 0
        1: {'y': 0x40, 'x': 0x60, 'tile': 0x0101, 'attr': 0x1000},  # Palette 1
        2: {'y': 0x40, 'x': 0x70, 'tile': 0x0102, 'attr': 0x2000},  # Palette 2
        3: {'y': 0x40, 'x': 0x80, 'tile': 0x0103, 'attr': 0xF000},  # Palette 15
    }
    model.spr_count = 4
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=4,
        spr_y_offset=0,
        expected_display_list_count=4,
        expected_valid_sprites=[0, 1, 2, 3],
        name="Palette_Variation"
    ))

    # Test 7: Sprite with flip flags
    sprite_list = {
        0: {'y': 0x50, 'x': 0x80, 'tile': 0x0200, 'attr': 0x0000},  # No flip
        1: {'y': 0x50, 'x': 0x90, 'tile': 0x0201, 'attr': 0x0200},  # Flip X
        2: {'y': 0x50, 'x': 0xA0, 'tile': 0x0202, 'attr': 0x0100},  # Flip Y
        3: {'y': 0x50, 'x': 0xB0, 'tile': 0x0203, 'attr': 0x0300},  # Flip XY
    }
    model.spr_count = 4
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=4,
        spr_y_offset=0,
        expected_display_list_count=4,
        expected_valid_sprites=[0, 1, 2, 3],
        name="Flip_Flags_XY"
    ))

    # Test 8: Sprite with priority variations
    sprite_list = {
        0: {'y': 0x60, 'x': 0x80, 'tile': 0x0300, 'attr': 0x0000},  # Priority 0
        1: {'y': 0x60, 'x': 0x90, 'tile': 0x0301, 'attr': 0x0040},  # Priority 1
        2: {'y': 0x60, 'x': 0xA0, 'tile': 0x0302, 'attr': 0x0080},  # Priority 2
        3: {'y': 0x60, 'x': 0xB0, 'tile': 0x0303, 'attr': 0x00C0},  # Priority 3
    }
    model.spr_count = 4
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=4,
        spr_y_offset=0,
        expected_display_list_count=4,
        expected_valid_sprites=[0, 1, 2, 3],
        name="Priority_Variation"
    ))

    # Test 9: Sprite with size variations
    sprite_list = {
        0: {'y': 0x70, 'x': 0x80, 'tile': 0x0400, 'attr': 0x0000},  # Size 0
        1: {'y': 0x70, 'x': 0x90, 'tile': 0x0401, 'attr': 0x0001},  # Size 1
        2: {'y': 0x70, 'x': 0xA0, 'tile': 0x0402, 'attr': 0x0002},  # Size 2
        3: {'y': 0x70, 'x': 0xB0, 'tile': 0x0403, 'attr': 0x0007},  # Size 7
    }
    model.spr_count = 4
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=4,
        spr_y_offset=0,
        expected_display_list_count=4,
        expected_valid_sprites=[0, 1, 2, 3],
        name="Size_Variation"
    ))

    # Test 10: Sparse sprite list (many inactive)
    sprite_list = {}
    for i in range(256):
        if i % 4 == 0:
            sprite_list[i] = {'y': (i // 4) & 0xFF, 'x': (i // 2) & 0xFF, 'tile': i, 'attr': 0}
        else:
            sprite_list[i] = {'y': 0x3FF, 'x': 0, 'tile': 0, 'attr': 0}  # Inactive
    model.spr_count = 256
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=256,
        spr_y_offset=0,
        expected_display_list_count=64,  # 256 / 4
        expected_valid_sprites=[i for i in range(0, 256, 4)],
        name="Sparse_Sprite_List"
    ))

    # Test 11: Table base address variation
    sprite_list = {0: {'y': 0x80, 'x': 0x80, 'tile': 0x0500, 'attr': 0x0000}}
    model.spr_count = 1
    model.spr_table_base = 0x00022000
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00022000,
        spr_count=1,
        spr_y_offset=0,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="TableBase_Variation_0x22000"
    ))

    # Test 12: Y offset application
    sprite_list = {0: {'y': 0x80, 'x': 0x80, 'tile': 0x0600, 'attr': 0x0000}}
    model.spr_count = 1
    model.spr_table_base = 0x00020000
    model.spr_y_offset = 16
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=1,
        spr_y_offset=16,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="Y_Offset_Applied"
    ))

    # Test 13: VSYNC rising edge detection
    vectors.append(TestVector(
        vsync_n=1,
        spr_table_base=0x00020000,
        spr_count=0,
        spr_y_offset=0,
        expected_display_list_count=0,
        expected_valid_sprites=[],
        name="VSYNC_Not_Active"
    ))

    # Test 14: Rapid VSYNC pulses
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=0,
        spr_y_offset=0,
        expected_display_list_count=0,
        expected_valid_sprites=[],
        name="VSYNC_Rapid_Pulse_1"
    ))

    # Test 15: Large X/Y coordinates
    sprite_list = {
        0: {'y': 0x1FF, 'x': 0x1FF, 'tile': 0x7FFF, 'attr': 0xFFFF},
    }
    model.spr_count = 1
    model.spr_table_base = 0x00020000
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=1,
        spr_y_offset=0,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="Max_XY_Coordinates"
    ))

    return vectors


if __name__ == '__main__':
    vectors = generate_test_vectors()
    print(f"Generated {len(vectors)} test vectors")
    for v in vectors:
        print(f"  {v.name}: {v.expected_display_list_count} visible sprites")
