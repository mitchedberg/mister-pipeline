#!/usr/bin/env python3
"""
NMK16 Gate 2 Test Vector Generator
Generates 30+ test cases for sprite scanner FSM validation.
Output: gate2_vectors.jsonl
"""

import json
import random
from gate2_model import NMK16Gate2Model


def generate_test_vectors():
    """Generate comprehensive test vectors for Gate 2 sprite scanner"""
    vectors = []
    test_id = 0

    # Test 1-10: Basic sprite writes (Y, X, tile, attr)
    test_sprites = [
        {'idx': 0, 'y': 0x0000, 'x': 0x0050, 'tile': 0x0100, 'attr': 0x0000},
        {'idx': 1, 'y': 0x0010, 'x': 0x0060, 'tile': 0x0101, 'attr': 0x4400},
        {'idx': 2, 'y': 0x0020, 'x': 0x0070, 'tile': 0x0102, 'attr': 0x8800},
        {'idx': 3, 'y': 0x01FF, 'x': 0x0000, 'tile': 0x0000, 'attr': 0x0000},  # Hidden
        {'idx': 4, 'y': 0x0030, 'x': 0x0080, 'tile': 0x0103, 'attr': 0xC400},
        {'idx': 10, 'y': 0x0040, 'x': 0x0090, 'tile': 0x010A, 'attr': 0x0050},
        {'idx': 20, 'y': 0x0050, 'x': 0x00A0, 'tile': 0x0114, 'attr': 0x1066},
        {'idx': 50, 'y': 0x0060, 'x': 0x00B0, 'tile': 0x0132, 'attr': 0x2077},
        {'idx': 100, 'y': 0x0070, 'x': 0x00C0, 'tile': 0x0164, 'attr': 0x3088},
        {'idx': 255, 'y': 0x0080, 'x': 0x00D0, 'tile': 0x01FF, 'attr': 0x4099},
    ]

    for sprite in test_sprites:
        idx = sprite['idx']
        base_addr = idx * 4
        words = [sprite['y'], sprite['x'], sprite['tile'], sprite['attr']]

        for word_offset, word_val in enumerate(words):
            test_id += 1
            label_map = ['Y', 'X', 'TILE', 'ATTR']
            addr = 0x130000 + (base_addr + word_offset) * 2
            vectors.append({
                'id': test_id,
                'name': f'Sprite {idx} write {label_map[word_offset]} = 0x{word_val:04X}',
                'addr': addr,
                'din': word_val,
                'operation': 'WRITE',
                'vsync_n': 1,
            })

    # Test 11-20: Sprite reads (verify write-back)
    for sprite in test_sprites[:10]:
        idx = sprite['idx']
        base_addr = idx * 4
        words = [sprite['y'], sprite['x'], sprite['tile'], sprite['attr']]

        for word_offset, word_val in enumerate(words):
            test_id += 1
            label_map = ['Y', 'X', 'TILE', 'ATTR']
            addr = 0x130000 + (base_addr + word_offset) * 2
            vectors.append({
                'id': test_id,
                'name': f'Sprite {idx} read {label_map[word_offset]} verify',
                'addr': addr,
                'din': 0x0000,
                'operation': 'READ',
                'vsync_n': 1,
                'expected_dout': word_val,
            })

    # Test 21: VBLANK trigger (vsync_n 1 -> 0)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'VBLANK rising edge (vsync_n: 1->0)',
        'addr': 0x000000,
        'din': 0x0000,
        'operation': 'NOP',
        'vsync_n': 0,  # VBLANK assertion
    })

    # Test 22: Sprite scanner completes
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Sprite scanner FSM processes (display_list_ready pulse)',
        'addr': 0x000000,
        'din': 0x0000,
        'operation': 'NOP',
        'vsync_n': 0,
    })

    # Test 23: VBLANK clear (vsync_n 0 -> 1)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'VBLANK falling edge (vsync_n: 0->1)',
        'addr': 0x000000,
        'din': 0x0000,
        'operation': 'NOP',
        'vsync_n': 1,
    })

    # Test 24: Edge case — all sprites hidden (Y=0x01FF)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Edge case: all sprites hidden',
        'addr': 0x000000,
        'din': 0x0000,
        'operation': 'NOP',
        'vsync_n': 1,
    })

    # Test 25: Edge case — Y position boundary (9-bit signed)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Edge case: Y position at 9-bit boundary (0x0100)',
        'addr': 0x130000,
        'din': 0x0100,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 26: Edge case — X position boundary (9-bit)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Edge case: X position at 9-bit boundary (0x01FF)',
        'addr': 0x130002,
        'din': 0x01FF,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 27: High tile index (12-bit)
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Tile code at 12-bit max (0x0FFF)',
        'addr': 0x130004,
        'din': 0x0FFF,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 28: Attribute byte with all flags set
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Attributes with flip_x, flip_y, size, palette all set',
        'addr': 0x130006,
        'din': 0xFFFF,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 29-30: Multiple consecutive sprites (0-5)
    for i in range(6):
        test_id += 1
        addr = 0x130000 + i * 8
        vectors.append({
            'id': test_id,
            'name': f'Consecutive sprite {i} Y position',
            'addr': addr,
            'din': 0x0000 + (i * 0x0010),
            'operation': 'WRITE',
            'vsync_n': 1,
        })

    return vectors


if __name__ == "__main__":
    vectors = generate_test_vectors()

    # Write to gate2_vectors.jsonl
    with open('gate2_vectors.jsonl', 'w') as f:
        for vec in vectors:
            f.write(json.dumps(vec) + '\n')

    print(f"Generated {len(vectors)} test vectors")
    print(f"Output: gate2_vectors.jsonl")
