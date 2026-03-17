#!/usr/bin/env python3
"""
Kaneko 16 Gate 1 Reference Model
CPU Interface & Register File
"""

import struct
from enum import IntEnum


class RegisterOffset(IntEnum):
    """Register offsets in the address space"""
    # BG0 (0x130000 base)
    SCROLL_X_0 = 0x0000
    SCROLL_Y_0 = 0x0002
    CTRL_0 = 0x0004

    # BG1 (0x130100 base)
    SCROLL_X_1 = 0x0100
    SCROLL_Y_1 = 0x0102
    CTRL_1 = 0x0104

    # BG2 (0x130200 base)
    SCROLL_X_2 = 0x0200
    SCROLL_Y_2 = 0x0202
    CTRL_2 = 0x0204

    # BG3 (0x130300 base)
    SCROLL_X_3 = 0x0300
    SCROLL_Y_3 = 0x0302
    CTRL_3 = 0x0304

    # Control
    SPRITE_CTRL = 0x0400
    MAP_BASE = 0x0010
    GFX_BANK = 0x0020

    # I/O (at 0x180000 base, decoded as offsets from base)
    IO_JOYSTICK_1 = 0x8000
    IO_JOYSTICK_2 = 0x8002
    IO_COIN = 0x8004
    IO_DIP = 0x8006
    IO_WATCHDOG = 0x8008
    IO_INT_CTRL = 0x800E

    # MCU (at 0x1A0000 base)
    MCU_STATUS = 0xA000
    MCU_COMMAND = 0xA001
    MCU_PARAM1 = 0xA002
    MCU_PARAM2 = 0xA003


class Kaneko16Model:
    """Reference model of Kaneko 16 Gate 1"""

    def __init__(self):
        """Initialize the model"""
        # Shadow registers (written by CPU)
        self.shadow_regs = {}
        self.shadow_regs[RegisterOffset.SCROLL_X_0] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_Y_0] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_X_1] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_Y_1] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_X_2] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_Y_2] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_X_3] = 0x0000
        self.shadow_regs[RegisterOffset.SCROLL_Y_3] = 0x0000

        self.shadow_regs[RegisterOffset.CTRL_0] = 0x00
        self.shadow_regs[RegisterOffset.CTRL_1] = 0x00
        self.shadow_regs[RegisterOffset.CTRL_2] = 0x00
        self.shadow_regs[RegisterOffset.CTRL_3] = 0x00

        self.shadow_regs[RegisterOffset.SPRITE_CTRL] = 0x00
        self.shadow_regs[RegisterOffset.MAP_BASE] = 0x00
        self.shadow_regs[RegisterOffset.GFX_BANK] = 0x00

        self.shadow_regs[RegisterOffset.IO_JOYSTICK_1] = 0x0000
        self.shadow_regs[RegisterOffset.IO_JOYSTICK_2] = 0x0000
        self.shadow_regs[RegisterOffset.IO_COIN] = 0x0000
        self.shadow_regs[RegisterOffset.IO_DIP] = 0x0000
        self.shadow_regs[RegisterOffset.IO_INT_CTRL] = 0x00

        self.shadow_regs[RegisterOffset.MCU_STATUS] = 0x00
        self.shadow_regs[RegisterOffset.MCU_COMMAND] = 0x00
        self.shadow_regs[RegisterOffset.MCU_PARAM1] = 0x00
        self.shadow_regs[RegisterOffset.MCU_PARAM2] = 0x00

        # Active registers (latched at VBlank)
        self.active_regs = dict(self.shadow_regs)

        # Sprite RAM (64 KB = 32K words of 16-bit data)
        self.sprite_ram = [0x0000] * 32768

        # Watchdog counter
        self.watchdog_counter = 0x00
        self.watchdog_timeout = False

        # VBlank state
        self.vsync_prev = 1

    def cpu_write(self, addr, data, lds_n, uds_n):
        """Simulate CPU write to a register or memory location"""
        addr_16 = addr & 0xFFFF  # 16-bit address offset within region

        # Sprite RAM write (0x120000 range)
        if (addr >> 16) & 0x0F == 0x12:
            sprite_addr = addr & 0x7FFF
            if not lds_n:
                self.sprite_ram[sprite_addr] = (self.sprite_ram[sprite_addr] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.sprite_ram[sprite_addr] = (self.sprite_ram[sprite_addr] & 0x00FF) | (data & 0xFF00)
            return

        # Register writes
        if addr_16 == RegisterOffset.SCROLL_X_0:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_0] = (self.shadow_regs[RegisterOffset.SCROLL_X_0] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_0] = (self.shadow_regs[RegisterOffset.SCROLL_X_0] & 0x00FF) | (data & 0xFF00)
        elif addr_16 == RegisterOffset.SCROLL_Y_0:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_0] = (self.shadow_regs[RegisterOffset.SCROLL_Y_0] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_0] = (self.shadow_regs[RegisterOffset.SCROLL_Y_0] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.SCROLL_X_1:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_1] = (self.shadow_regs[RegisterOffset.SCROLL_X_1] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_1] = (self.shadow_regs[RegisterOffset.SCROLL_X_1] & 0x00FF) | (data & 0xFF00)
        elif addr_16 == RegisterOffset.SCROLL_Y_1:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_1] = (self.shadow_regs[RegisterOffset.SCROLL_Y_1] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_1] = (self.shadow_regs[RegisterOffset.SCROLL_Y_1] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.SCROLL_X_2:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_2] = (self.shadow_regs[RegisterOffset.SCROLL_X_2] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_2] = (self.shadow_regs[RegisterOffset.SCROLL_X_2] & 0x00FF) | (data & 0xFF00)
        elif addr_16 == RegisterOffset.SCROLL_Y_2:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_2] = (self.shadow_regs[RegisterOffset.SCROLL_Y_2] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_2] = (self.shadow_regs[RegisterOffset.SCROLL_Y_2] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.SCROLL_X_3:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_3] = (self.shadow_regs[RegisterOffset.SCROLL_X_3] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_X_3] = (self.shadow_regs[RegisterOffset.SCROLL_X_3] & 0x00FF) | (data & 0xFF00)
        elif addr_16 == RegisterOffset.SCROLL_Y_3:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_3] = (self.shadow_regs[RegisterOffset.SCROLL_Y_3] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.SCROLL_Y_3] = (self.shadow_regs[RegisterOffset.SCROLL_Y_3] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.CTRL_0:
            if not lds_n:
                self.shadow_regs[RegisterOffset.CTRL_0] = data & 0xFF
        elif addr_16 == RegisterOffset.CTRL_1:
            if not lds_n:
                self.shadow_regs[RegisterOffset.CTRL_1] = data & 0xFF
        elif addr_16 == RegisterOffset.CTRL_2:
            if not lds_n:
                self.shadow_regs[RegisterOffset.CTRL_2] = data & 0xFF
        elif addr_16 == RegisterOffset.CTRL_3:
            if not lds_n:
                self.shadow_regs[RegisterOffset.CTRL_3] = data & 0xFF

        elif addr_16 == RegisterOffset.SPRITE_CTRL:
            if not lds_n:
                self.shadow_regs[RegisterOffset.SPRITE_CTRL] = data & 0xFF

        elif addr_16 == RegisterOffset.MAP_BASE:
            if not lds_n:
                self.shadow_regs[RegisterOffset.MAP_BASE] = data & 0x0F

        elif addr_16 == RegisterOffset.GFX_BANK:
            if not lds_n:
                self.shadow_regs[RegisterOffset.GFX_BANK] = data & 0x7F

        elif addr_16 == RegisterOffset.IO_JOYSTICK_1:
            if not lds_n:
                self.shadow_regs[RegisterOffset.IO_JOYSTICK_1] = (self.shadow_regs[RegisterOffset.IO_JOYSTICK_1] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.IO_JOYSTICK_1] = (self.shadow_regs[RegisterOffset.IO_JOYSTICK_1] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.IO_JOYSTICK_2:
            if not lds_n:
                self.shadow_regs[RegisterOffset.IO_JOYSTICK_2] = (self.shadow_regs[RegisterOffset.IO_JOYSTICK_2] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.IO_JOYSTICK_2] = (self.shadow_regs[RegisterOffset.IO_JOYSTICK_2] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.IO_COIN:
            if not lds_n:
                self.shadow_regs[RegisterOffset.IO_COIN] = (self.shadow_regs[RegisterOffset.IO_COIN] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.IO_COIN] = (self.shadow_regs[RegisterOffset.IO_COIN] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.IO_DIP:
            if not lds_n:
                self.shadow_regs[RegisterOffset.IO_DIP] = (self.shadow_regs[RegisterOffset.IO_DIP] & 0xFF00) | (data & 0x00FF)
            if not uds_n:
                self.shadow_regs[RegisterOffset.IO_DIP] = (self.shadow_regs[RegisterOffset.IO_DIP] & 0x00FF) | (data & 0xFF00)

        elif addr_16 == RegisterOffset.IO_WATCHDOG:
            self.watchdog_counter = 0x00
            self.watchdog_timeout = False

        elif addr_16 == RegisterOffset.IO_INT_CTRL:
            if not lds_n:
                self.shadow_regs[RegisterOffset.IO_INT_CTRL] = data & 0xFF

        elif addr_16 == RegisterOffset.MCU_STATUS:
            if not lds_n:
                self.shadow_regs[RegisterOffset.MCU_STATUS] = data & 0xFF
        elif addr_16 == RegisterOffset.MCU_COMMAND:
            if not lds_n:
                self.shadow_regs[RegisterOffset.MCU_COMMAND] = data & 0xFF
        elif addr_16 == RegisterOffset.MCU_PARAM1:
            if not lds_n:
                self.shadow_regs[RegisterOffset.MCU_PARAM1] = data & 0xFF
        elif addr_16 == RegisterOffset.MCU_PARAM2:
            if not lds_n:
                self.shadow_regs[RegisterOffset.MCU_PARAM2] = data & 0xFF

    def cpu_read(self, addr):
        """Simulate CPU read from a register or memory location"""
        addr_16 = addr & 0xFFFF

        # Sprite RAM read
        if (addr >> 16) & 0x0F == 0x12:
            sprite_addr = addr & 0x7FFF
            return self.sprite_ram[sprite_addr]

        # Register reads
        if addr_16 in self.shadow_regs:
            return self.shadow_regs[addr_16]

        return 0x0000

    def vsync_edge(self):
        """Simulate VBlank synchronization (latch shadow → active)"""
        self.active_regs = dict(self.shadow_regs)

    def tick_watchdog(self):
        """Increment watchdog counter"""
        self.watchdog_counter = (self.watchdog_counter + 1) & 0xFF
        if self.watchdog_counter == 0xFF:
            self.watchdog_timeout = True

    def get_active_register(self, reg_offset):
        """Get the active (latched) register value"""
        return self.active_regs.get(reg_offset, 0x0000)

    def get_shadow_register(self, reg_offset):
        """Get the shadow (CPU-written) register value"""
        return self.shadow_regs.get(reg_offset, 0x0000)

    def get_sprite_ram(self, addr):
        """Get sprite RAM word"""
        return self.sprite_ram[addr & 0x7FFF]

    def set_sprite_ram(self, addr, data):
        """Set sprite RAM word"""
        self.sprite_ram[addr & 0x7FFF] = data & 0xFFFF
