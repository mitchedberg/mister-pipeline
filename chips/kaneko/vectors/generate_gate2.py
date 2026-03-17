#!/usr/bin/env python3
"""
Generate test vectors for Kaneko 16 Gate 2 (sprite scanner)
"""

import json
import sys
from gate2_model import SpriteScannerModel


def generate_vectors():
    """Generate comprehensive test vectors for Gate 2"""
    vectors = []
    test_id = 0

    model = SpriteScannerModel()

    # ========================================================================
    # Test 1-10: Basic sprite positioning (X, Y variations)
    # ========================================================================
    test_cases = [
        {"name": "Sprite at (0, 0)", "x": 0x000, "y": 0x000, "tile": 0x0001},
        {"name": "Sprite at (319, 0)", "x": 0x13F, "y": 0x000, "tile": 0x0002},
        {"name": "Sprite at (0, 239)", "x": 0x000, "y": 0x0EF, "tile": 0x0003},
        {"name": "Sprite at (319, 239)", "x": 0x13F, "y": 0x0EF, "tile": 0x0004},
        {"name": "Sprite at (160, 120)", "x": 0x0A0, "y": 0x078, "tile": 0x0005},
        {"name": "Off-screen left (negative X)", "x": 0x1FE, "y": 0x078, "tile": 0x0006},  # -2 in 9-bit
        {"name": "Off-screen top (negative Y)", "x": 0x0A0, "y": 0x1FE, "tile": 0x0007},   # -2 in 9-bit
        {"name": "Off-screen right (X>319)", "x": 0x140, "y": 0x078, "tile": 0x0008},
        {"name": "Off-screen bottom (Y>239)", "x": 0x0A0, "y": 0x0F0, "tile": 0x0009},
        {"name": "Inactive sprite (Y=0x1FF)", "x": 0x0A0, "y": 0x1FF, "tile": 0x000A},
    ]

    for test_case in test_cases:
        sprite_index = test_id
        base_addr = sprite_index * 8

        # Write sprite descriptor to RAM
        model.set_sprite_ram(base_addr + 0, test_case["y"])
        model.set_sprite_ram(base_addr + 1, test_case["tile"])
        model.set_sprite_ram(base_addr + 2, test_case["x"])
        model.set_sprite_ram(base_addr + 3, 0x0000)  # No attributes

        vectors.append({
            "id": test_id,
            "name": test_case["name"],
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "x": test_case["x"],
            "y": test_case["y"],
            "tile": test_case["tile"],
            "palette": 0,
            "flip_x": 0,
            "flip_y": 0,
            "priority": 0,
            "size": 0,
        })
        test_id += 1

    # ========================================================================
    # Test 11-20: Tile number variations
    # ========================================================================
    for tile_idx in range(10):
        sprite_index = 10 + tile_idx
        base_addr = sprite_index * 8
        tile_num = (tile_idx + 1) * 0x0100

        model.set_sprite_ram(base_addr + 0, 0x0050)  # Y = 80
        model.set_sprite_ram(base_addr + 1, tile_num)
        model.set_sprite_ram(base_addr + 2, 0x0050 + tile_idx * 16)  # X = 80 + offset
        model.set_sprite_ram(base_addr + 3, 0x0000)

        vectors.append({
            "id": test_id,
            "name": f"Tile number 0x{tile_num:04X}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "tile": tile_num,
            "x": 0x0050 + tile_idx * 16,
            "y": 0x0050,
        })
        test_id += 1

    # ========================================================================
    # Test 21-25: Palette select
    # ========================================================================
    for palette_idx in range(5):
        sprite_index = 20 + palette_idx
        base_addr = sprite_index * 8
        attr = palette_idx & 0x0F  # Palette in bits [3:0]

        model.set_sprite_ram(base_addr + 0, 0x0060)  # Y = 96
        model.set_sprite_ram(base_addr + 1, 0x1000 + palette_idx)
        model.set_sprite_ram(base_addr + 2, 0x0060 + palette_idx * 16)  # X = 96 + offset
        model.set_sprite_ram(base_addr + 3, attr)

        vectors.append({
            "id": test_id,
            "name": f"Palette {palette_idx}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "palette": palette_idx,
            "x": 0x0060 + palette_idx * 16,
            "y": 0x0060,
        })
        test_id += 1

    # ========================================================================
    # Test 26-30: Flip flags
    # ========================================================================
    flip_cases = [
        {"name": "No flip", "flip_x": 0, "flip_y": 0},
        {"name": "Flip X only", "flip_x": 1, "flip_y": 0},
        {"name": "Flip Y only", "flip_x": 0, "flip_y": 1},
        {"name": "Flip X and Y", "flip_x": 1, "flip_y": 1},
        {"name": "Flip X, Y, priority bits", "flip_x": 1, "flip_y": 1},
    ]

    for flip_idx, flip_case in enumerate(flip_cases):
        sprite_index = 25 + flip_idx
        base_addr = sprite_index * 8
        attr = (flip_case["flip_x"] << 4) | (flip_case["flip_y"] << 5)

        model.set_sprite_ram(base_addr + 0, 0x0070)  # Y = 112
        model.set_sprite_ram(base_addr + 1, 0x2000 + flip_idx)
        model.set_sprite_ram(base_addr + 2, 0x0070 + flip_idx * 16)
        model.set_sprite_ram(base_addr + 3, attr)

        vectors.append({
            "id": test_id,
            "name": flip_case["name"],
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "flip_x": flip_case["flip_x"],
            "flip_y": flip_case["flip_y"],
            "x": 0x0070 + flip_idx * 16,
            "y": 0x0070,
        })
        test_id += 1

    # ========================================================================
    # Test 31-35: Priority levels
    # ========================================================================
    for priority_idx in range(5):
        sprite_index = 30 + priority_idx
        base_addr = sprite_index * 8
        attr = (priority_idx & 0x0F) << 6  # Priority in bits [9:6]

        model.set_sprite_ram(base_addr + 0, 0x0080)  # Y = 128
        model.set_sprite_ram(base_addr + 1, 0x3000 + priority_idx)
        model.set_sprite_ram(base_addr + 2, 0x0080 + priority_idx * 16)
        model.set_sprite_ram(base_addr + 3, attr)

        vectors.append({
            "id": test_id,
            "name": f"Priority {priority_idx}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "priority": priority_idx,
            "x": 0x0080 + priority_idx * 16,
            "y": 0x0080,
        })
        test_id += 1

    # ========================================================================
    # Test 36-40: Size codes
    # ========================================================================
    for size_idx in range(5):
        sprite_index = 35 + size_idx
        base_addr = sprite_index * 8
        attr = (size_idx & 0x0F) << 10  # Size in bits [13:10]

        model.set_sprite_ram(base_addr + 0, 0x0090)  # Y = 144
        model.set_sprite_ram(base_addr + 1, 0x4000 + size_idx)
        model.set_sprite_ram(base_addr + 2, 0x0090 + size_idx * 16)
        model.set_sprite_ram(base_addr + 3, attr)

        vectors.append({
            "id": test_id,
            "name": f"Size code {size_idx}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "size": size_idx,
            "x": 0x0090 + size_idx * 16,
            "y": 0x0090,
        })
        test_id += 1

    # ========================================================================
    # Test 41-45: Multiple sprites in sequence
    # ========================================================================
    for multi_idx in range(5):
        sprite_index = 40 + multi_idx
        base_addr = sprite_index * 8

        model.set_sprite_ram(base_addr + 0, 0x00A0 + multi_idx)
        model.set_sprite_ram(base_addr + 1, 0x5000 + multi_idx)
        model.set_sprite_ram(base_addr + 2, 0x00A0 + multi_idx * 8)
        model.set_sprite_ram(base_addr + 3, multi_idx << 4)  # Palette = multi_idx

        vectors.append({
            "id": test_id,
            "name": f"Multi-sprite {multi_idx}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "x": 0x00A0 + multi_idx * 8,
            "y": 0x00A0 + multi_idx,
            "palette": multi_idx,
        })
        test_id += 1

    # ========================================================================
    # Test 46: VBlank trigger - scan all sprites
    # ========================================================================
    # Set up multiple sprites (some valid, some inactive)
    for i in range(10):
        base_addr = i * 8
        if i < 5:
            # Valid sprites
            model.set_sprite_ram(base_addr + 0, 0x00B0 + i)
            model.set_sprite_ram(base_addr + 1, 0x6000 + i)
            model.set_sprite_ram(base_addr + 2, 0x00B0 + i * 10)
        else:
            # Inactive sprites (Y = 0x1FF)
            model.set_sprite_ram(base_addr + 0, 0x01FF)
            model.set_sprite_ram(base_addr + 1, 0x0000)
            model.set_sprite_ram(base_addr + 2, 0x0000)
        model.set_sprite_ram(base_addr + 3, 0x0000)

    vectors.append({
        "id": test_id,
        "name": "VBlank trigger - scan sprites",
        "op": "vsync_pulse",
        "expected_count": 5,  # Expect 5 valid sprites
    })
    test_id += 1

    # ========================================================================
    # Test 47: Verify display list ready signal
    # ========================================================================
    vectors.append({
        "id": test_id,
        "name": "Display list ready after scan",
        "op": "check_display_list_ready",
    })
    test_id += 1

    # ========================================================================
    # Test 48-50: Edge cases - very high Y values (off-screen bottom)
    # ========================================================================
    for edge_idx in range(3):
        sprite_index = 50 + edge_idx
        base_addr = sprite_index * 8
        y_val = 0x0F0 + edge_idx  # Y > 239 (off-screen)

        model.set_sprite_ram(base_addr + 0, y_val)
        model.set_sprite_ram(base_addr + 1, 0x7000 + edge_idx)
        model.set_sprite_ram(base_addr + 2, 0x00C0 + edge_idx * 16)
        model.set_sprite_ram(base_addr + 3, 0x0000)

        vectors.append({
            "id": test_id,
            "name": f"Off-screen bottom Y=0x{y_val:03X}",
            "op": "write_sprite",
            "sprite_index": sprite_index,
            "y": y_val,
            "x": 0x00C0 + edge_idx * 16,
        })
        test_id += 1

    # ========================================================================
    # Output JSON
    # ========================================================================
    return vectors


if __name__ == "__main__":
    vectors = generate_vectors()
    for vec in vectors:
        print(json.dumps(vec))
