#!/usr/bin/env python3
"""
Generate test vectors for Kaneko 16 Gate 1
"""

import json
import sys
from gate1_model import Kaneko16Model, RegisterOffset


def generate_vectors():
    """Generate comprehensive test vectors for Gate 1"""
    vectors = []
    test_id = 0

    model = Kaneko16Model()

    # ========================================================================
    # Test 1-8: Scroll Register Writes (BG0-BG3)
    # ========================================================================
    for bg in range(4):
        scroll_x_offset = RegisterOffset.SCROLL_X_0 + bg * 0x0100
        scroll_y_offset = RegisterOffset.SCROLL_Y_0 + bg * 0x0100

        # Write scroll X
        model.cpu_write(scroll_x_offset, 0x1234, 0, 1)  # Write lower byte
        model.cpu_write(scroll_x_offset, 0x5600, 1, 0)  # Write upper byte
        expected_x = model.get_shadow_register(scroll_x_offset)

        vectors.append({
            "id": test_id,
            "name": f"BG{bg} Scroll X write",
            "op": "write",
            "addr": scroll_x_offset,
            "data": 0x5634,
            "lds_n": 0,
            "uds_n": 0,
            "expected_shadow": expected_x,
        })
        test_id += 1

        # Write scroll Y
        model.cpu_write(scroll_y_offset, 0xABCD, 0, 1)
        model.cpu_write(scroll_y_offset, 0xEF00, 1, 0)
        expected_y = model.get_shadow_register(scroll_y_offset)

        vectors.append({
            "id": test_id,
            "name": f"BG{bg} Scroll Y write",
            "op": "write",
            "addr": scroll_y_offset,
            "data": 0xEFAB,
            "lds_n": 0,
            "uds_n": 0,
            "expected_shadow": expected_y,
        })
        test_id += 1

    # ========================================================================
    # Test 9-12: Layer Control Writes
    # ========================================================================
    for bg in range(4):
        ctrl_offset = RegisterOffset.CTRL_0 + bg * 0x0100
        test_ctrl = 0x55  # Enable + palette bits

        model.cpu_write(ctrl_offset, test_ctrl, 0, 1)
        expected_ctrl = model.get_shadow_register(ctrl_offset)

        vectors.append({
            "id": test_id,
            "name": f"BG{bg} Layer control write",
            "op": "write",
            "addr": ctrl_offset,
            "data": test_ctrl,
            "lds_n": 0,
            "uds_n": 1,
            "expected_shadow": expected_ctrl,
        })
        test_id += 1

    # ========================================================================
    # Test 13: Sprite Control Write
    # ========================================================================
    sprite_ctrl_val = 0xAA
    model.cpu_write(RegisterOffset.SPRITE_CTRL, sprite_ctrl_val, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "Sprite control write",
        "op": "write",
        "addr": RegisterOffset.SPRITE_CTRL,
        "data": sprite_ctrl_val,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.SPRITE_CTRL),
    })
    test_id += 1

    # ========================================================================
    # Test 14: Map Base Select Write
    # ========================================================================
    map_base_val = 0x05
    model.cpu_write(RegisterOffset.MAP_BASE, map_base_val, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "Map base select write",
        "op": "write",
        "addr": RegisterOffset.MAP_BASE,
        "data": map_base_val,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.MAP_BASE) & 0x0F,
    })
    test_id += 1

    # ========================================================================
    # Test 15: GFX Bank Select Write
    # ========================================================================
    gfx_bank_val = 0x42
    model.cpu_write(RegisterOffset.GFX_BANK, gfx_bank_val, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "GFX bank select write",
        "op": "write",
        "addr": RegisterOffset.GFX_BANK,
        "data": gfx_bank_val,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.GFX_BANK) & 0x7F,
    })
    test_id += 1

    # ========================================================================
    # Test 16-19: I/O Register Writes (Joystick, Coin, DIP)
    # ========================================================================
    model.cpu_write(RegisterOffset.IO_JOYSTICK_1, 0x1234, 0, 0)
    vectors.append({
        "id": test_id,
        "name": "Joystick 1 write",
        "op": "write",
        "addr": RegisterOffset.IO_JOYSTICK_1,
        "data": 0x1234,
        "lds_n": 0,
        "uds_n": 0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.IO_JOYSTICK_1),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.IO_JOYSTICK_2, 0x5678, 0, 0)
    vectors.append({
        "id": test_id,
        "name": "Joystick 2 write",
        "op": "write",
        "addr": RegisterOffset.IO_JOYSTICK_2,
        "data": 0x5678,
        "lds_n": 0,
        "uds_n": 0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.IO_JOYSTICK_2),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.IO_COIN, 0x00FF, 0, 0)
    vectors.append({
        "id": test_id,
        "name": "Coin input write",
        "op": "write",
        "addr": RegisterOffset.IO_COIN,
        "data": 0x00FF,
        "lds_n": 0,
        "uds_n": 0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.IO_COIN),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.IO_DIP, 0xAAAA, 0, 0)
    vectors.append({
        "id": test_id,
        "name": "DIP switches write",
        "op": "write",
        "addr": RegisterOffset.IO_DIP,
        "data": 0xAAAA,
        "lds_n": 0,
        "uds_n": 0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.IO_DIP),
    })
    test_id += 1

    # ========================================================================
    # Test 20: Watchdog Kick
    # ========================================================================
    model.tick_watchdog()
    model.tick_watchdog()
    initial_wd = model.watchdog_counter
    model.cpu_write(RegisterOffset.IO_WATCHDOG, 0x0000, 0, 0)
    vectors.append({
        "id": test_id,
        "name": "Watchdog kick reset",
        "op": "write",
        "addr": RegisterOffset.IO_WATCHDOG,
        "data": 0x0000,
        "lds_n": 0,
        "uds_n": 0,
        "expected_watchdog": 0x00,
    })
    test_id += 1

    # ========================================================================
    # Test 21: Video Interrupt Control
    # ========================================================================
    int_ctrl_val = 0x03
    model.cpu_write(RegisterOffset.IO_INT_CTRL, int_ctrl_val, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "Video interrupt control write",
        "op": "write",
        "addr": RegisterOffset.IO_INT_CTRL,
        "data": int_ctrl_val,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.IO_INT_CTRL),
    })
    test_id += 1

    # ========================================================================
    # Test 22-25: MCU Interface Writes
    # ========================================================================
    model.cpu_write(RegisterOffset.MCU_STATUS, 0x00, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "MCU status write",
        "op": "write",
        "addr": RegisterOffset.MCU_STATUS,
        "data": 0x00,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.MCU_STATUS),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.MCU_COMMAND, 0x42, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "MCU command write",
        "op": "write",
        "addr": RegisterOffset.MCU_COMMAND,
        "data": 0x42,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.MCU_COMMAND),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.MCU_PARAM1, 0xAB, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "MCU parameter 1 write",
        "op": "write",
        "addr": RegisterOffset.MCU_PARAM1,
        "data": 0xAB,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.MCU_PARAM1),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.MCU_PARAM2, 0xCD, 0, 1)
    vectors.append({
        "id": test_id,
        "name": "MCU parameter 2 write",
        "op": "write",
        "addr": RegisterOffset.MCU_PARAM2,
        "data": 0xCD,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.MCU_PARAM2),
    })
    test_id += 1

    # ========================================================================
    # Test 26-33: Sprite RAM Writes
    # ========================================================================
    for i in range(8):
        addr = i * 2
        data = 0x1000 + (i * 0x0111)
        model.set_sprite_ram(addr, data)
        vectors.append({
            "id": test_id,
            "name": f"Sprite RAM write [{addr}]",
            "op": "sprite_ram_write",
            "addr": addr,
            "data": data,
            "lds_n": 0,
            "uds_n": 0,
            "expected_sprite_ram": data,
        })
        test_id += 1

    # ========================================================================
    # Test 34-41: Sprite RAM Reads
    # ========================================================================
    for i in range(8):
        addr = i * 2
        expected = model.get_sprite_ram(addr)
        vectors.append({
            "id": test_id,
            "name": f"Sprite RAM read [{addr}]",
            "op": "sprite_ram_read",
            "addr": addr,
            "expected_sprite_ram": expected,
        })
        test_id += 1

    # ========================================================================
    # Test 42-45: Register Read-Back (verify shadow is readable)
    # ========================================================================
    vectors.append({
        "id": test_id,
        "name": "Read scroll X BG0",
        "op": "read",
        "addr": RegisterOffset.SCROLL_X_0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.SCROLL_X_0),
    })
    test_id += 1

    vectors.append({
        "id": test_id,
        "name": "Read scroll Y BG0",
        "op": "read",
        "addr": RegisterOffset.SCROLL_Y_0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.SCROLL_Y_0),
    })
    test_id += 1

    vectors.append({
        "id": test_id,
        "name": "Read layer control BG0",
        "op": "read",
        "addr": RegisterOffset.CTRL_0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.CTRL_0),
    })
    test_id += 1

    vectors.append({
        "id": test_id,
        "name": "Read GFX bank",
        "op": "read",
        "addr": RegisterOffset.GFX_BANK,
        "expected_shadow": model.get_shadow_register(RegisterOffset.GFX_BANK),
    })
    test_id += 1

    # ========================================================================
    # Test 46: VBlank Edge - Latch Shadow → Active
    # ========================================================================
    # Write some values to shadow registers
    model.cpu_write(RegisterOffset.SCROLL_X_0, 0x1111, 0, 0)
    model.cpu_write(RegisterOffset.SCROLL_Y_1, 0x2222, 0, 0)

    shadow_x = model.get_shadow_register(RegisterOffset.SCROLL_X_0)
    shadow_y = model.get_shadow_register(RegisterOffset.SCROLL_Y_1)

    model.vsync_edge()

    active_x = model.get_active_register(RegisterOffset.SCROLL_X_0)
    active_y = model.get_active_register(RegisterOffset.SCROLL_Y_1)

    vectors.append({
        "id": test_id,
        "name": "VBlank edge: shadow → active latch",
        "op": "vsync_edge",
        "expected_shadow_x0": shadow_x,
        "expected_active_x0": active_x,
        "expected_shadow_y1": shadow_y,
        "expected_active_y1": active_y,
    })
    test_id += 1

    # ========================================================================
    # Test 47-50: Byte-aligned Writes (LDS_N only, UDS_N only)
    # ========================================================================
    model.cpu_write(RegisterOffset.SCROLL_X_0, 0xFF00, 0, 1)  # Lower byte only
    vectors.append({
        "id": test_id,
        "name": "Lower byte write (LDS_N=0, UDS_N=1)",
        "op": "write",
        "addr": RegisterOffset.SCROLL_X_0,
        "data": 0xFF00,
        "lds_n": 0,
        "uds_n": 1,
        "expected_shadow": model.get_shadow_register(RegisterOffset.SCROLL_X_0),
    })
    test_id += 1

    model.cpu_write(RegisterOffset.SCROLL_X_1, 0x00FF, 1, 0)  # Upper byte only
    vectors.append({
        "id": test_id,
        "name": "Upper byte write (LDS_N=1, UDS_N=0)",
        "op": "write",
        "addr": RegisterOffset.SCROLL_X_1,
        "data": 0x00FF,
        "lds_n": 1,
        "uds_n": 0,
        "expected_shadow": model.get_shadow_register(RegisterOffset.SCROLL_X_1),
    })
    test_id += 1

    # ========================================================================
    # Test 51-52: Watchdog Timeout Simulation
    # ========================================================================
    model2 = Kaneko16Model()
    for _ in range(256):
        model2.tick_watchdog()
    vectors.append({
        "id": test_id,
        "name": "Watchdog counter overflow",
        "op": "watchdog_tick",
        "expected_watchdog_timeout": model2.watchdog_timeout,
    })
    test_id += 1

    # Partial counter (not overflow)
    model3 = Kaneko16Model()
    for _ in range(128):
        model3.tick_watchdog()
    vectors.append({
        "id": test_id,
        "name": "Watchdog counter partial (no timeout)",
        "op": "watchdog_tick",
        "expected_watchdog_timeout": model3.watchdog_timeout,
        "expected_watchdog_counter": 128,
    })
    test_id += 1

    return vectors


def main():
    """Generate and output test vectors as JSONL"""
    vectors = generate_vectors()

    for vec in vectors:
        print(json.dumps(vec))

    print(f"\n# Generated {len(vectors)} test vectors", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
