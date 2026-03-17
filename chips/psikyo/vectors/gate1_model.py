#!/usr/bin/env python3
"""
Psikyo Gate 1: Python reference model for CPU interface & register file.
Used for test vector generation and golden-reference comparison.
"""

import json
from dataclasses import dataclass, asdict
from typing import Optional, List
from enum import IntEnum


class AddrRange(IntEnum):
    """Address decode ranges."""
    WORK_RAM = 0x00000000
    SPRITE_RAM = 0x00020000
    TILEMAP_RAM = 0x00040000
    PALETTE_RAM = 0x00060000
    PS2001B = 0x00080000
    PS3103 = 0x00084000
    PS3204 = 0x00088000
    PS3305 = 0x0008C000
    Z80 = 0x00090000
    INT_CTRL = 0x000A0000


class RegisterOffset(IntEnum):
    """Register offsets within chip ranges."""
    # PS2001B
    SPRITE_CTRL = 0x00
    SPRITE_TABLE_BASE_LO = 0x04
    SPRITE_TABLE_BASE_HI = 0x06
    SPRITE_COUNT = 0x08
    SPRITE_Y_OFFSET = 0x0A
    SPRITE_STATUS = 0x0C

    # PS3103 (per layer, 0x10 spacing)
    BG_CTRL = 0x00
    BG_SCROLL_X = 0x04
    BG_SCROLL_Y = 0x08
    BG_TILEMAP_BASE_LO = 0x0C
    BG_TILEMAP_BASE_HI = 0x0E

    # PS3305
    PRIORITY_0 = 0x00
    PRIORITY_1 = 0x02
    PRIORITY_2 = 0x04
    PRIORITY_3 = 0x06
    COLOR_KEY_CTRL = 0x20
    COLOR_KEY = 0x24
    VSYNC_IRQ_LINE = 0x28
    HSYNC_IRQ_COL = 0x2C

    # Z80
    YM2610_ADDR_A = 0x00
    YM2610_DATA_A = 0x04
    YM2610_ADDR_B = 0x08
    YM2610_DATA_B = 0x0C
    Z80_STATUS = 0x10
    Z80_CMD_REPLY = 0x14


@dataclass
class TestVector:
    """Single test vector (CPU write or read)."""
    # Input
    addr: int                   # 23-bit address (word-addressed, so addr[23:1])
    write_data: Optional[int]   # Data for writes (None for reads)
    is_write: bool
    vsync_n: int = 1            # VBLANK signal (1=inactive, 0=active)

    # Expected output
    read_data: Optional[int] = None

    # Metadata
    name: str = ""
    chip: str = ""

    def to_dict(self):
        return asdict(self)


class Gate1Model:
    """Reference model for Psikyo Gate 1."""

    def __init__(self):
        """Initialize register file."""
        # PS2001B shadow & active registers
        self.ps2001b_ctrl_shadow = 0x00
        self.ps2001b_table_base_shadow = 0x00000000
        self.ps2001b_count_shadow = 0x0000
        self.ps2001b_y_offset_shadow = 0x00

        self.ps2001b_ctrl_active = 0x00
        self.ps2001b_table_base_active = 0x00000000
        self.ps2001b_count_active = 0x0000
        self.ps2001b_y_offset_active = 0x00

        # PS3103 shadow & active registers (4 layers)
        self.ps3103_ctrl_shadow = [0x00] * 4
        self.ps3103_scroll_x_shadow = [0x0000] * 4
        self.ps3103_scroll_y_shadow = [0x0000] * 4
        self.ps3103_tilemap_base_shadow = [0x00000000] * 4

        self.ps3103_ctrl_active = [0x00] * 4
        self.ps3103_scroll_x_active = [0x0000] * 4
        self.ps3103_scroll_y_active = [0x0000] * 4
        self.ps3103_tilemap_base_active = [0x00000000] * 4

        # PS3305 shadow & active registers
        self.ps3305_priority_shadow = bytes([0, 1, 2, 3, 4, 5, 6, 7])
        self.ps3305_priority_active = bytes([0, 1, 2, 3, 4, 5, 6, 7])
        self.ps3305_color_key_ctrl_shadow = 0x00
        self.ps3305_color_key_shadow = 0x00
        self.ps3305_vsync_irq_line_shadow = 0xF0
        self.ps3305_hsync_irq_col_shadow = 0x140

        self.ps3305_color_key_ctrl_active = 0x00
        self.ps3305_color_key_active = 0x00
        self.ps3305_vsync_irq_line_active = 0xF0
        self.ps3305_hsync_irq_col_active = 0x140

        # Z80 status/mailbox
        self.z80_status_reg = 0x00
        self.z80_cmd_reply_reg = 0x00

        # VSYNC state
        self.vsync_n_prev = 1
        self.vsync_edge_fired = False

    def write_register(self, addr: int, data: int) -> None:
        """Simulate CPU write."""
        chip_base = addr & 0xFF000
        reg_offset = addr & 0xFFF

        if chip_base == AddrRange.PS2001B:
            self._write_ps2001b(reg_offset, data)
        elif chip_base == AddrRange.PS3103:
            self._write_ps3103(reg_offset, data)
        elif chip_base == AddrRange.PS3305:
            self._write_ps3305(reg_offset, data)
        elif chip_base == AddrRange.Z80:
            self._write_z80(reg_offset, data)

    def read_register(self, addr: int) -> int:
        """Simulate CPU read."""
        chip_base = addr & 0xFF000
        reg_offset = addr & 0xFFF

        if chip_base == AddrRange.PS2001B:
            return self._read_ps2001b(reg_offset)
        elif chip_base == AddrRange.PS3103:
            return self._read_ps3103(reg_offset)
        elif chip_base == AddrRange.PS3305:
            return self._read_ps3305(reg_offset)
        elif chip_base == AddrRange.Z80:
            return self._read_z80(reg_offset)
        return 0

    def _write_ps2001b(self, offset: int, data: int) -> None:
        """PS2001B sprite control register write."""
        if offset == RegisterOffset.SPRITE_CTRL:
            self.ps2001b_ctrl_shadow = data & 0xFF
        elif offset == RegisterOffset.SPRITE_TABLE_BASE_LO:
            self.ps2001b_table_base_shadow = (
                (self.ps2001b_table_base_shadow & 0xFFFF0000) | (data & 0xFFFF)
            )
        elif offset == RegisterOffset.SPRITE_TABLE_BASE_HI:
            self.ps2001b_table_base_shadow = (
                (self.ps2001b_table_base_shadow & 0x0000FFFF) | ((data & 0xFFFF) << 16)
            )
        elif offset == RegisterOffset.SPRITE_COUNT:
            self.ps2001b_count_shadow = data & 0xFFFF
        elif offset == RegisterOffset.SPRITE_Y_OFFSET:
            self.ps2001b_y_offset_shadow = data & 0xFF

    def _read_ps2001b(self, offset: int) -> int:
        """PS2001B sprite control register read."""
        if offset == RegisterOffset.SPRITE_CTRL:
            return self.ps2001b_ctrl_shadow & 0xFF
        elif offset == RegisterOffset.SPRITE_TABLE_BASE_LO:
            return self.ps2001b_table_base_shadow & 0xFFFF
        elif offset == RegisterOffset.SPRITE_TABLE_BASE_HI:
            return (self.ps2001b_table_base_shadow >> 16) & 0xFFFF
        elif offset == RegisterOffset.SPRITE_COUNT:
            return self.ps2001b_count_shadow & 0xFFFF
        elif offset == RegisterOffset.SPRITE_Y_OFFSET:
            return self.ps2001b_y_offset_shadow & 0xFF
        elif offset == RegisterOffset.SPRITE_STATUS:
            return 0x01  # Ready bit
        return 0

    def _write_ps3103(self, offset: int, data: int) -> None:
        """PS3103 tilemap control register write."""
        # Registers are spaced at 0x10 bytes (8 words) per layer
        layer = (offset >> 4) & 0x3
        reg = offset & 0x0F

        if layer < 4:
            if reg == RegisterOffset.BG_CTRL:
                self.ps3103_ctrl_shadow[layer] = data & 0xFF
            elif reg == RegisterOffset.BG_SCROLL_X:
                self.ps3103_scroll_x_shadow[layer] = data & 0xFFFF
            elif reg == RegisterOffset.BG_SCROLL_Y:
                self.ps3103_scroll_y_shadow[layer] = data & 0xFFFF
            elif reg == RegisterOffset.BG_TILEMAP_BASE_LO:
                self.ps3103_tilemap_base_shadow[layer] = (
                    (self.ps3103_tilemap_base_shadow[layer] & 0xFFFF0000) | (data & 0xFFFF)
                )
            elif reg == RegisterOffset.BG_TILEMAP_BASE_HI:
                self.ps3103_tilemap_base_shadow[layer] = (
                    (self.ps3103_tilemap_base_shadow[layer] & 0x0000FFFF) | ((data & 0xFFFF) << 16)
                )

    def _read_ps3103(self, offset: int) -> int:
        """PS3103 tilemap control register read."""
        layer = (offset >> 4) & 0x3
        reg = offset & 0x0F

        if layer < 4:
            if reg == RegisterOffset.BG_CTRL:
                return self.ps3103_ctrl_shadow[layer] & 0xFF
            elif reg == RegisterOffset.BG_SCROLL_X:
                return self.ps3103_scroll_x_shadow[layer] & 0xFFFF
            elif reg == RegisterOffset.BG_SCROLL_Y:
                return self.ps3103_scroll_y_shadow[layer] & 0xFFFF
            elif reg == RegisterOffset.BG_TILEMAP_BASE_LO:
                return self.ps3103_tilemap_base_shadow[layer] & 0xFFFF
            elif reg == RegisterOffset.BG_TILEMAP_BASE_HI:
                return (self.ps3103_tilemap_base_shadow[layer] >> 16) & 0xFFFF
        return 0

    def _write_ps3305(self, offset: int, data: int) -> None:
        """PS3305 colmix/priority register write."""
        if offset == RegisterOffset.PRIORITY_0:
            self.ps3305_priority_shadow = (
                bytes([data & 0xFF, (data >> 8) & 0xFF]) + self.ps3305_priority_shadow[2:]
            )
        elif offset == RegisterOffset.PRIORITY_1:
            self.ps3305_priority_shadow = (
                self.ps3305_priority_shadow[:2] + bytes([data & 0xFF, (data >> 8) & 0xFF])
                + self.ps3305_priority_shadow[4:]
            )
        elif offset == RegisterOffset.PRIORITY_2:
            self.ps3305_priority_shadow = (
                self.ps3305_priority_shadow[:4] + bytes([data & 0xFF, (data >> 8) & 0xFF])
                + self.ps3305_priority_shadow[6:]
            )
        elif offset == RegisterOffset.PRIORITY_3:
            self.ps3305_priority_shadow = (
                self.ps3305_priority_shadow[:6] + bytes([data & 0xFF, (data >> 8) & 0xFF])
            )
        elif offset == RegisterOffset.COLOR_KEY_CTRL:
            self.ps3305_color_key_ctrl_shadow = data & 0xFF
        elif offset == RegisterOffset.COLOR_KEY:
            self.ps3305_color_key_shadow = data & 0xFF
        elif offset == RegisterOffset.VSYNC_IRQ_LINE:
            self.ps3305_vsync_irq_line_shadow = data & 0x1FF
        elif offset == RegisterOffset.HSYNC_IRQ_COL:
            self.ps3305_hsync_irq_col_shadow = data & 0x1FF

    def _read_ps3305(self, offset: int) -> int:
        """PS3305 colmix/priority register read."""
        if offset == RegisterOffset.PRIORITY_0:
            return (self.ps3305_priority_shadow[1] << 8) | self.ps3305_priority_shadow[0]
        elif offset == RegisterOffset.PRIORITY_1:
            return (self.ps3305_priority_shadow[3] << 8) | self.ps3305_priority_shadow[2]
        elif offset == RegisterOffset.PRIORITY_2:
            return (self.ps3305_priority_shadow[5] << 8) | self.ps3305_priority_shadow[4]
        elif offset == RegisterOffset.PRIORITY_3:
            return (self.ps3305_priority_shadow[7] << 8) | self.ps3305_priority_shadow[6]
        elif offset == RegisterOffset.COLOR_KEY_CTRL:
            return self.ps3305_color_key_ctrl_shadow & 0xFF
        elif offset == RegisterOffset.COLOR_KEY:
            return self.ps3305_color_key_shadow & 0xFF
        elif offset == RegisterOffset.VSYNC_IRQ_LINE:
            return self.ps3305_vsync_irq_line_shadow & 0x1FF
        elif offset == RegisterOffset.HSYNC_IRQ_COL:
            return self.ps3305_hsync_irq_col_shadow & 0x1FF
        return 0

    def _write_z80(self, offset: int, data: int) -> None:
        """Z80 sound interface register write."""
        if offset == RegisterOffset.Z80_CMD_REPLY:
            self.z80_cmd_reply_reg = data & 0xFF

    def _read_z80(self, offset: int) -> int:
        """Z80 sound interface register read."""
        if offset == RegisterOffset.Z80_STATUS:
            return self.z80_status_reg & 0xFF
        elif offset == RegisterOffset.Z80_CMD_REPLY:
            return self.z80_cmd_reply_reg & 0xFF
        return 0

    def clock_vsync(self, vsync_n: int) -> bool:
        """Clock VSYNC edge and return True if rising edge occurred."""
        vsync_rising = (self.vsync_n_prev == 1) and (vsync_n == 0)
        vsync_falling = (self.vsync_n_prev == 0) and (vsync_n == 1)

        if vsync_falling:
            # Copy shadow → active on VSYNC rising edge (falling edge of active-low signal)
            self.ps2001b_ctrl_active = self.ps2001b_ctrl_shadow
            self.ps2001b_table_base_active = self.ps2001b_table_base_shadow
            self.ps2001b_count_active = self.ps2001b_count_shadow
            self.ps2001b_y_offset_active = self.ps2001b_y_offset_shadow

            for i in range(4):
                self.ps3103_ctrl_active[i] = self.ps3103_ctrl_shadow[i]
                self.ps3103_scroll_x_active[i] = self.ps3103_scroll_x_shadow[i]
                self.ps3103_scroll_y_active[i] = self.ps3103_scroll_y_shadow[i]
                self.ps3103_tilemap_base_active[i] = self.ps3103_tilemap_base_shadow[i]

            self.ps3305_priority_active = self.ps3305_priority_shadow
            self.ps3305_color_key_ctrl_active = self.ps3305_color_key_ctrl_shadow
            self.ps3305_color_key_active = self.ps3305_color_key_shadow
            self.ps3305_vsync_irq_line_active = self.ps3305_vsync_irq_line_shadow
            self.ps3305_hsync_irq_col_active = self.ps3305_hsync_irq_col_shadow

        self.vsync_n_prev = vsync_n
        return vsync_falling
