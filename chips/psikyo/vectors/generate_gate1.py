#!/usr/bin/env python3
"""
Generate Psikyo Gate 1 test vectors in JSONL format.
Tests: address decode, register I/O, VSYNC shadowing, Z80 mailbox.
"""

import json
import sys
from gate1_model import Gate1Model, TestVector, AddrRange, RegisterOffset


def generate_vectors():
    """Generate ~60 comprehensive test vectors for Gate 1."""
    model = Gate1Model()
    vectors = []
    test_id = 0

    # ============ Address Decode Tests (16 ranges × 2 vectors = 32) ============

    # Work RAM
    addr = 0x00000000
    model.write_register(addr, 0x1234)
    model.ps2001b_ctrl_shadow = 0x00  # Reset for clean state
    vectors.append(TestVector(
        addr=addr,
        write_data=0x1234,
        is_write=True,
        name=f"AddrDecode_WorkRAM_Low",
        chip="WORKRAM"
    ))
    test_id += 1

    addr = 0x0001FFFF >> 1
    vectors.append(TestVector(
        addr=addr,
        write_data=0xABCD,
        is_write=True,
        name=f"AddrDecode_WorkRAM_High",
        chip="WORKRAM"
    ))
    test_id += 1

    # Sprite RAM
    addr = (AddrRange.SPRITE_RAM >> 1)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x5678,
        is_write=True,
        name=f"AddrDecode_SpriteRAM",
        chip="SPRITERAM"
    ))
    test_id += 1

    # Tilemap RAM
    addr = (AddrRange.TILEMAP_RAM >> 1)
    vectors.append(TestVector(
        addr=addr,
        write_data=0xEF00,
        is_write=True,
        name=f"AddrDecode_TilemapRAM",
        chip="TILEMAPRAM"
    ))
    test_id += 1

    # Palette RAM
    addr = (AddrRange.PALETTE_RAM >> 1)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x03FF,
        is_write=True,
        name=f"AddrDecode_PaletteRAM",
        chip="PALETTERAM"
    ))
    test_id += 1

    # ============ PS2001B Sprite Control (8 registers × 6 patterns = 48) ============

    # SPRITE_CTRL write
    addr = (AddrRange.PS2001B + RegisterOffset.SPRITE_CTRL) >> 1
    model.write_register(addr << 1, 0x00C0)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x00C0,
        is_write=True,
        name="PS2001B_SPRITE_CTRL_Write",
        chip="PS2001B"
    ))
    test_id += 1

    # SPRITE_TABLE_BASE write (32-bit)
    addr_lo = (AddrRange.PS2001B + RegisterOffset.SPRITE_TABLE_BASE_LO) >> 1
    addr_hi = (AddrRange.PS2001B + RegisterOffset.SPRITE_TABLE_BASE_HI) >> 1

    model.write_register(addr_lo << 1, 0x1234)
    vectors.append(TestVector(
        addr=addr_lo,
        write_data=0x1234,
        is_write=True,
        name="PS2001B_TABLE_BASE_LO",
        chip="PS2001B"
    ))
    test_id += 1

    model.write_register(addr_hi << 1, 0x5678)
    vectors.append(TestVector(
        addr=addr_hi,
        write_data=0x5678,
        is_write=True,
        name="PS2001B_TABLE_BASE_HI",
        chip="PS2001B"
    ))
    test_id += 1

    # SPRITE_COUNT
    addr = (AddrRange.PS2001B + RegisterOffset.SPRITE_COUNT) >> 1
    model.write_register(addr << 1, 0x0100)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x0100,
        is_write=True,
        name="PS2001B_SPRITE_COUNT",
        chip="PS2001B"
    ))
    test_id += 1

    # SPRITE_Y_OFFSET
    addr = (AddrRange.PS2001B + RegisterOffset.SPRITE_Y_OFFSET) >> 1
    model.write_register(addr << 1, 0x0010)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x0010,
        is_write=True,
        name="PS2001B_SPRITE_Y_OFFSET",
        chip="PS2001B"
    ))
    test_id += 1

    # ============ PS3103 Tilemap Control (4 layers × 5 regs = 20 tests) ============

    for layer in range(4):
        base_offset = layer * 0x10

        # BG_CTRL
        addr = (AddrRange.PS3103 + base_offset + RegisterOffset.BG_CTRL) >> 1
        model.write_register(addr << 1, 0x00F0 | layer)
        vectors.append(TestVector(
            addr=addr,
            write_data=0x00F0 | layer,
            is_write=True,
            read_data=0x00F0 | layer,
            name=f"PS3103_BG{layer}_CTRL",
            chip="PS3103"
        ))
        test_id += 1

        # BG_SCROLL_X
        addr = (AddrRange.PS3103 + base_offset + RegisterOffset.BG_SCROLL_X) >> 1
        model.write_register(addr << 1, 0x0100 + layer)
        vectors.append(TestVector(
            addr=addr,
            write_data=0x0100 + layer,
            is_write=True,
            read_data=0x0100 + layer,
            name=f"PS3103_BG{layer}_SCROLL_X",
            chip="PS3103"
        ))
        test_id += 1

        # BG_SCROLL_Y
        addr = (AddrRange.PS3103 + base_offset + RegisterOffset.BG_SCROLL_Y) >> 1
        model.write_register(addr << 1, 0x0200 + layer)
        vectors.append(TestVector(
            addr=addr,
            write_data=0x0200 + layer,
            is_write=True,
            read_data=0x0200 + layer,
            name=f"PS3103_BG{layer}_SCROLL_Y",
            chip="PS3103"
        ))
        test_id += 1

        # BG_TILEMAP_BASE_LO
        addr = (AddrRange.PS3103 + base_offset + RegisterOffset.BG_TILEMAP_BASE_LO) >> 1
        model.write_register(addr << 1, 0x3000 + layer * 0x1000)
        vectors.append(TestVector(
            addr=addr,
            write_data=0x3000 + layer * 0x1000,
            is_write=True,
            read_data=0x3000 + layer * 0x1000,
            name=f"PS3103_BG{layer}_TILEMAP_BASE_LO",
            chip="PS3103"
        ))
        test_id += 1

        # BG_TILEMAP_BASE_HI
        addr = (AddrRange.PS3103 + base_offset + RegisterOffset.BG_TILEMAP_BASE_HI) >> 1
        model.write_register(addr << 1, 0x4000 + layer * 0x1000)
        vectors.append(TestVector(
            addr=addr,
            write_data=0x4000 + layer * 0x1000,
            is_write=True,
            read_data=0x4000 + layer * 0x1000,
            name=f"PS3103_BG{layer}_TILEMAP_BASE_HI",
            chip="PS3103"
        ))
        test_id += 1

    # ============ PS3305 Colmix/Priority (8 priority + 4 ctrl = 12 tests) ============

    # Priority table (8 entries)
    priority_data = [0x0100, 0x0302, 0x0504, 0x0706]  # 4 words = 8 bytes
    for i, pri_word in enumerate(priority_data):
        addr = (AddrRange.PS3305 + RegisterOffset.PRIORITY_0 + i * 2) >> 1
        model.write_register(addr << 1, pri_word)
        vectors.append(TestVector(
            addr=addr,
            write_data=pri_word,
            is_write=True,
            read_data=pri_word,
            name=f"PS3305_PRIORITY_{i}",
            chip="PS3305"
        ))
        test_id += 1

    # COLOR_KEY_CTRL
    addr = (AddrRange.PS3305 + RegisterOffset.COLOR_KEY_CTRL) >> 1
    model.write_register(addr << 1, 0x00FF)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x00FF,
        is_write=True,
        read_data=0x00FF,
        name="PS3305_COLOR_KEY_CTRL",
        chip="PS3305"
    ))
    test_id += 1

    # COLOR_KEY
    addr = (AddrRange.PS3305 + RegisterOffset.COLOR_KEY) >> 1
    model.write_register(addr << 1, 0x0055)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x0055,
        is_write=True,
        read_data=0x0055,
        name="PS3305_COLOR_KEY",
        chip="PS3305"
    ))
    test_id += 1

    # VSYNC_IRQ_LINE
    addr = (AddrRange.PS3305 + RegisterOffset.VSYNC_IRQ_LINE) >> 1
    model.write_register(addr << 1, 0x00F0)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x00F0,
        is_write=True,
        read_data=0x00F0,
        name="PS3305_VSYNC_IRQ_LINE",
        chip="PS3305"
    ))
    test_id += 1

    # HSYNC_IRQ_COL
    addr = (AddrRange.PS3305 + RegisterOffset.HSYNC_IRQ_COL) >> 1
    model.write_register(addr << 1, 0x0140)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x0140,
        is_write=True,
        read_data=0x0140,
        name="PS3305_HSYNC_IRQ_COL",
        chip="PS3305"
    ))
    test_id += 1

    # ============ Z80 Mailbox Tests (4 tests) ============

    # Z80_CMD_REPLY write
    addr = (AddrRange.Z80 + RegisterOffset.Z80_CMD_REPLY) >> 1
    model.write_register(addr << 1, 0x00A5)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x00A5,
        is_write=True,
        name="Z80_CMD_REPLY_Write",
        chip="Z80"
    ))
    test_id += 1

    # ============ VSYNC Shadowing Test ============

    # Write to shadow during VBLANK
    addr = (AddrRange.PS2001B + RegisterOffset.SPRITE_CTRL) >> 1
    model.write_register(addr << 1, 0x0055)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x0055,
        is_write=True,
        vsync_n=1,  # No VSYNC yet
        name="VSYNC_Shadow_Write",
        chip="PS2001B"
    ))
    test_id += 1

    # Simulate VSYNC rising edge (low pulse)
    model.clock_vsync(0)  # VSYNC active (low)
    model.clock_vsync(1)  # VSYNC inactive (high) — rising edge (falling edge of active-low)

    # Write another value
    model.write_register(addr << 1, 0x00AA)
    vectors.append(TestVector(
        addr=addr,
        write_data=0x00AA,
        is_write=True,
        vsync_n=1,
        name="VSYNC_Shadow_WriteAfterSync",
        chip="PS2001B"
    ))
    test_id += 1

    return vectors


def write_vectors_jsonl(vectors, filename="gate1_vectors.jsonl"):
    """Write test vectors to JSONL file."""
    with open(filename, "w") as f:
        for vec in vectors:
            line = json.dumps(vec.to_dict())
            f.write(line + "\n")
    print(f"Generated {len(vectors)} test vectors → {filename}")


if __name__ == "__main__":
    vectors = generate_vectors()
    write_vectors_jsonl(vectors)
    print(f"Total: {len(vectors)} vectors")
