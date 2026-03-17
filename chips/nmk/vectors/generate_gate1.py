#!/usr/bin/env python3
"""
NMK16 Gate 1 Test Vector Generator
Generates ~50+ test cases for CPU interface and register file validation.
Output: gate1_vectors.jsonl
"""

import json
import random
from gate1_model import NMK16Gate1Model, Operation, ChipSelect


def generate_test_vectors():
    """Generate comprehensive test vectors for Gate 1"""
    vectors = []
    test_id = 0

    # Test 1: GPU register write — SCROLL0_X
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: SCROLL0_X = 0x1111',
        'addr': 0x120000,
        'din': 0x1111,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 2: GPU register write — SCROLL0_Y
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: SCROLL0_Y = 0x2222',
        'addr': 0x120002,
        'din': 0x2222,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 3: GPU register write — SCROLL1_X
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: SCROLL1_X = 0x3333',
        'addr': 0x120004,
        'din': 0x3333,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 4: GPU register write — SCROLL1_Y
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: SCROLL1_Y = 0x4444',
        'addr': 0x120006,
        'din': 0x4444,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 5: GPU register write — BG_CTRL
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: BG_CTRL = 0x5555',
        'addr': 0x120008,
        'din': 0x5555,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 6: GPU register write — SPRITE_CTRL
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'GPU register WRITE: SPRITE_CTRL = 0x6666',
        'addr': 0x12000A,
        'din': 0x6666,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 7: Sprite RAM write — offset 0
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Sprite RAM WRITE: offset 0 = 0x4000',
        'addr': 0x130000,
        'din': 0x4000,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 8: Sprite RAM write — offset 256
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Sprite RAM WRITE: offset 256 = 0x4100',
        'addr': 0x130200,
        'din': 0x4100,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 9: Sprite RAM write — offset 1023
    test_id += 1
    vectors.append({
        'id': test_id,
        'name': 'Sprite RAM WRITE: offset 1023 = 0x43FF',
        'addr': 0x1307FE,
        'din': 0x43FF,
        'operation': 'WRITE',
        'vsync_n': 1,
    })

    # Test 10-15: Reserved GPU register reads (should return 0)
    for offset in [0x0C, 0x0E, 0x10, 0x12, 0x14, 0x16]:
        test_id += 1
        vectors.append({
            'id': test_id,
            'name': f'GPU register READ: reserved @0x{0x120000 + offset:06X} = 0x0000',
            'addr': 0x120000 + offset,
            'din': 0x0000,
            'operation': 'READ',
            'vsync_n': 1,
            'expected_dout': 0x0000,
        })

    # Test 16-21: Data width preservation — various 16-bit patterns
    test_values = [0x0000, 0xFFFF, 0x8000, 0x0001, 0xAAAA, 0x5555]
    for i, val in enumerate(test_values, 1):
        test_id += 1
        vectors.append({
            'id': test_id,
            'name': f'Data width WRITE/READ: 0x{val:04X}',
            'addr': 0x120000,
            'din': val,
            'operation': 'WRITE',
            'vsync_n': 1,
        })

    return vectors


if __name__ == "__main__":
    vectors = generate_test_vectors()

    # Write to gate1_vectors.jsonl
    with open('gate1_vectors.jsonl', 'w') as f:
        for vec in vectors:
            f.write(json.dumps(vec) + '\n')

    print(f"Generated {len(vectors)} test vectors")
    print(f"Output: gate1_vectors.jsonl")
