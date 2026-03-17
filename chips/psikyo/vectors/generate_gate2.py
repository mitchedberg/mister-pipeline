#!/usr/bin/env python3
"""
Generate Psikyo Gate 2 test vectors in JSONL format.
Tests: sprite list parsing, display list generation, VSYNC scanning.

Note: Current RTL stub behavior:
- Marks all spr_count sprites as valid (full implementation would check Y != 0x3FF)
- Tests below reflect stub behavior; will be updated when scanner reads sprite_ram_dout
"""

import json
import sys
from gate2_model import Gate2Model, TestVector


def generate_test_vectors():
    """Generate comprehensive Gate 2 test vectors."""
    vectors = []
    model = Gate2Model()

    # Test 1: Empty sprite list (spr_count=0)
    model.spr_table_base = 0x00020000
    model.spr_count = 0
    display_list = model.scan_sprites({})
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=0,
        spr_y_offset=0,
        expected_display_list_count=0,
        expected_valid_sprites=[],
        name="Empty_SpriteList"
    ))

    # Test 2: Single visible sprite (spr_count=1)
    model.spr_count = 1
    display_list = model.scan_sprites({0: {'y': 0x50, 'x': 0x80, 'tile': 0x0001, 'attr': 0x0000}})
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=1,
        spr_y_offset=0,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="Single_Visible_Sprite"
    ))

    # Test 3: Multiple visible sprites (spr_count=3)
    model.spr_count = 3
    display_list = model.scan_sprites({
        0: {'y': 0x30, 'x': 0x40, 'tile': 0x0010, 'attr': 0x0000},
        1: {'y': 0x60, 'x': 0x80, 'tile': 0x0011, 'attr': 0x1000},
        2: {'y': 0x90, 'x': 0xC0, 'tile': 0x0012, 'attr': 0x2000},
    })
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=3,
        spr_y_offset=0,
        expected_display_list_count=3,
        expected_valid_sprites=[0, 1, 2],
        name="Multiple_Visible_Sprites"
    ))

    # Test 4: Sprite with Y=0x3FF (stub still marks all as valid)
    model.spr_count = 3
    display_list = model.scan_sprites({
        0: {'y': 0x50, 'x': 0x80, 'tile': 0x0001, 'attr': 0x0000},
        1: {'y': 0x3FF, 'x': 0x00, 'tile': 0x0000, 'attr': 0x0000},
        2: {'y': 0x70, 'x': 0x90, 'tile': 0x0003, 'attr': 0x0000},
    })
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=3,
        spr_y_offset=0,
        expected_display_list_count=3,
        expected_valid_sprites=[0, 1, 2],
        name="Inactive_Sprite_0x3FF"
    ))

    # Test 5: Maximum sprites (256) - stub marks all as valid
    sprite_list = {}
    for i in range(256):
        sprite_list[i] = {
            'y': (i * 2) & 0x1FF,
            'x': (i * 3) & 0x1FF,
            'tile': i & 0xFFFF,
            'attr': (i & 0xF) << 12
        }
    model.spr_count = 256
    display_list = model.scan_sprites(sprite_list)
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
    model.spr_count = 4
    display_list = model.scan_sprites({
        0: {'y': 0x40, 'x': 0x50, 'tile': 0x0100, 'attr': 0x0000},
        1: {'y': 0x40, 'x': 0x60, 'tile': 0x0101, 'attr': 0x1000},
        2: {'y': 0x40, 'x': 0x70, 'tile': 0x0102, 'attr': 0x2000},
        3: {'y': 0x40, 'x': 0x80, 'tile': 0x0103, 'attr': 0xF000},
    })
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
    model.spr_count = 4
    display_list = model.scan_sprites({
        0: {'y': 0x50, 'x': 0x80, 'tile': 0x0200, 'attr': 0x0000},
        1: {'y': 0x50, 'x': 0x90, 'tile': 0x0201, 'attr': 0x0200},
        2: {'y': 0x50, 'x': 0xA0, 'tile': 0x0202, 'attr': 0x0100},
        3: {'y': 0x50, 'x': 0xB0, 'tile': 0x0203, 'attr': 0x0300},
    })
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
    model.spr_count = 4
    display_list = model.scan_sprites({
        0: {'y': 0x60, 'x': 0x80, 'tile': 0x0300, 'attr': 0x0000},
        1: {'y': 0x60, 'x': 0x90, 'tile': 0x0301, 'attr': 0x0040},
        2: {'y': 0x60, 'x': 0xA0, 'tile': 0x0302, 'attr': 0x0080},
        3: {'y': 0x60, 'x': 0xB0, 'tile': 0x0303, 'attr': 0x00C0},
    })
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
    model.spr_count = 4
    display_list = model.scan_sprites({
        0: {'y': 0x70, 'x': 0x80, 'tile': 0x0400, 'attr': 0x0000},
        1: {'y': 0x70, 'x': 0x90, 'tile': 0x0401, 'attr': 0x0001},
        2: {'y': 0x70, 'x': 0xA0, 'tile': 0x0402, 'attr': 0x0002},
        3: {'y': 0x70, 'x': 0xB0, 'tile': 0x0403, 'attr': 0x0007},
    })
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=4,
        spr_y_offset=0,
        expected_display_list_count=4,
        expected_valid_sprites=[0, 1, 2, 3],
        name="Size_Variation"
    ))

    # Test 10: Sparse sprite list (64 active of 256)
    sprite_list = {}
    for i in range(256):
        if i % 4 == 0:
            sprite_list[i] = {'y': (i // 4) & 0xFF, 'x': (i // 2) & 0xFF, 'tile': i, 'attr': 0}
        else:
            sprite_list[i] = {'y': 0x3FF, 'x': 0, 'tile': 0, 'attr': 0}
    model.spr_count = 256
    display_list = model.scan_sprites(sprite_list)
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=256,
        spr_y_offset=0,
        expected_display_list_count=256,  # Stub marks all 256 as valid
        expected_valid_sprites=list(range(256)),
        name="Sparse_Sprite_List"
    ))

    # Test 11: Table base address variation
    model.spr_count = 1
    model.spr_table_base = 0x00022000
    display_list = model.scan_sprites({0: {'y': 0x80, 'x': 0x80, 'tile': 0x0500, 'attr': 0x0000}})
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
    model.spr_count = 1
    model.spr_table_base = 0x00020000
    model.spr_y_offset = 16
    display_list = model.scan_sprites({0: {'y': 0x80, 'x': 0x80, 'tile': 0x0600, 'attr': 0x0000}})
    vectors.append(TestVector(
        vsync_n=0,
        spr_table_base=0x00020000,
        spr_count=1,
        spr_y_offset=16,
        expected_display_list_count=1,
        expected_valid_sprites=[0],
        name="Y_Offset_Applied"
    ))

    # Test 13: VSYNC not active (vsync_n=1)
    model.spr_count = 0
    model.spr_table_base = 0x00020000
    display_list = model.scan_sprites({})
    vectors.append(TestVector(
        vsync_n=1,
        spr_table_base=0x00020000,
        spr_count=0,
        spr_y_offset=0,
        expected_display_list_count=0,
        expected_valid_sprites=[],
        name="VSYNC_Not_Active"
    ))

    # Test 14: VSYNC rapid pulse
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
    model.spr_count = 1
    display_list = model.scan_sprites({
        0: {'y': 0x1FF, 'x': 0x1FF, 'tile': 0x7FFF, 'attr': 0xFFFF},
    })
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


def output_jsonl_vectors(vectors, output_file='gate2_vectors.jsonl'):
    """Write test vectors to JSONL file (one per line)."""
    with open(output_file, 'w') as f:
        for idx, tv in enumerate(vectors):
            entry = {
                'vector_id': idx,
                'vsync_n': tv.vsync_n,
                'spr_table_base': tv.spr_table_base,
                'spr_count': tv.spr_count,
                'spr_y_offset': tv.spr_y_offset,
                'expected_display_list_count': tv.expected_display_list_count,
                'expected_valid_sprites': tv.expected_valid_sprites,
                'name': tv.name,
                'chip': tv.chip,
            }
            f.write(json.dumps(entry) + '\n')

    print(f"Wrote {len(vectors)} vectors to {output_file}")


def main():
    print("=== Psikyo Gate 2 Test Vector Generator ===")
    print("Generating sprite scanner test vectors...\n")

    vectors = generate_test_vectors()
    output_jsonl_vectors(vectors)

    print("\nTest vector summary:")
    print(f"  Total vectors: {len(vectors)}")
    print(f"  Tests generated successfully")

    print("\nExample vectors:")
    for v in vectors[:3]:
        print(f"  {v.name}:")
        print(f"    - Table base: 0x{v.spr_table_base:08X}")
        print(f"    - Sprite count: {v.spr_count}")
        print(f"    - Expected visible: {v.expected_display_list_count}")


if __name__ == '__main__':
    main()
