#!/usr/bin/env python3
"""
NMK16 Gate 1 Python Model — CPU Interface & Register File
Simulates the register file behavior for test vector generation and validation.
"""

import json
from enum import IntEnum

class Operation(IntEnum):
    """CPU bus operation types"""
    NOP = 0          # No operation
    READ = 1         # CPU read (rd_n=0)
    WRITE = 2        # CPU write (wr_n=0)

class ChipSelect(IntEnum):
    """Address regions"""
    NONE = 0
    ROM = 1           # $000000–$07FFFF
    WRAM = 2          # $100000–$10FFFF
    GPU = 3           # $120000–$12FFFF
    SPRITE = 4        # $130000–$13FFFF
    PALETTE = 5       # $140000–$14FFFF
    IO = 6            # $150000–$15FFFF


class NMK16Gate1Model:
    """
    Simulates NMK16 Gate 1 CPU interface and register file.
    - Maintains shadow and active register states
    - Simulates VBLANK edge detection and register latching
    - Provides read/write access to sprite RAM
    """

    def __init__(self):
        # Shadow registers (CPU-writable, latched on VBLANK)
        self.scroll0_x_shadow = 0x0000
        self.scroll0_y_shadow = 0x0000
        self.scroll1_x_shadow = 0x0000
        self.scroll1_y_shadow = 0x0000
        self.bg_ctrl_shadow = 0x0000
        self.sprite_ctrl_shadow = 0x0000

        # Active registers (latched from shadow on VBLANK falling edge)
        self.scroll0_x_active = 0x0000
        self.scroll0_y_active = 0x0000
        self.scroll1_x_active = 0x0000
        self.scroll1_y_active = 0x0000
        self.bg_ctrl_active = 0x0000
        self.sprite_ctrl_active = 0x0000

        # Status register (read-only, driven by external signals)
        self.vblank_irq = 0
        self.sprite_done_irq = 0

        # Sprite RAM (256 sprites × 4 words = 1024 × 16-bit)
        self.sprite_ram = [0x0000] * 1024

        # Previous VSYNC state for edge detection
        self.vsync_n_prev = 1

    def decode_address(self, addr: int) -> ChipSelect:
        """Decode 21-bit CPU address to chip select region"""
        addr_20_16 = (addr >> 16) & 0x1F

        if addr_20_16 < 0x04:  # $000000–$07FFFF
            return ChipSelect.ROM
        elif addr_20_16 == 0x10:  # $100000–$10FFFF
            return ChipSelect.WRAM
        elif addr_20_16 == 0x12:  # $120000–$12FFFF
            return ChipSelect.GPU
        elif addr_20_16 == 0x13:  # $130000–$13FFFF
            return ChipSelect.SPRITE
        elif addr_20_16 == 0x14:  # $140000–$14FFFF
            return ChipSelect.PALETTE
        elif addr_20_16 == 0x15:  # $150000–$15FFFF
            return ChipSelect.IO
        else:
            return ChipSelect.NONE

    def get_register_offset(self, addr: int) -> int:
        """Extract GPU register offset from word address"""
        return (addr >> 1) & 0x0F

    def process_cpu_cycle(self, addr: int, din: int, op: Operation, vsync_n: int) -> int:
        """
        Simulate one CPU cycle.

        Args:
            addr: 21-bit word address (addr[0] = 0)
            din: 16-bit data input from CPU
            op: Operation type (NOP, READ, WRITE)
            vsync_n: VSYNC signal state (1 = inactive, 0 = active)

        Returns:
            16-bit data output to CPU
        """

        # Detect VBLANK falling edge (1 -> 0 transition)
        if self.vsync_n_prev == 1 and vsync_n == 0:
            self._latch_active_registers()
        self.vsync_n_prev = vsync_n

        chip = self.decode_address(addr)
        dout = 0x0000

        if op == Operation.WRITE:
            if chip == ChipSelect.GPU:
                self._write_gpu_register(addr, din)
            elif chip == ChipSelect.SPRITE:
                self._write_sprite_ram(addr, din)

        elif op == Operation.READ:
            if chip == ChipSelect.GPU:
                dout = self._read_gpu_register(addr)
            elif chip == ChipSelect.SPRITE:
                dout = self._read_sprite_ram(addr)

        return dout

    def _latch_active_registers(self):
        """Copy shadow -> active registers on VBLANK falling edge"""
        self.scroll0_x_active = self.scroll0_x_shadow
        self.scroll0_y_active = self.scroll0_y_shadow
        self.scroll1_x_active = self.scroll1_x_shadow
        self.scroll1_y_active = self.scroll1_y_shadow
        self.bg_ctrl_active = self.bg_ctrl_shadow
        self.sprite_ctrl_active = self.sprite_ctrl_shadow

    def _write_gpu_register(self, addr: int, data: int):
        """Write to GPU control register"""
        offset = self.get_register_offset(addr)

        if offset == 0:
            self.scroll0_x_shadow = data & 0xFFFF
        elif offset == 1:
            self.scroll0_y_shadow = data & 0xFFFF
        elif offset == 2:
            self.scroll1_x_shadow = data & 0xFFFF
        elif offset == 3:
            self.scroll1_y_shadow = data & 0xFFFF
        elif offset == 4:
            self.bg_ctrl_shadow = data & 0xFFFF
        elif offset == 5:
            self.sprite_ctrl_shadow = data & 0xFFFF

    def _read_gpu_register(self, addr: int) -> int:
        """Read GPU control register"""
        offset = self.get_register_offset(addr)

        if offset == 0:
            return self.scroll0_x_shadow
        elif offset == 1:
            return self.scroll0_y_shadow
        elif offset == 2:
            return self.scroll1_x_shadow
        elif offset == 3:
            return self.scroll1_y_shadow
        elif offset == 4:
            return self.bg_ctrl_shadow
        elif offset == 5:
            return self.sprite_ctrl_shadow
        else:
            return 0x0000

    def _write_sprite_ram(self, addr: int, data: int):
        """Write to sprite RAM"""
        # Address is word-aligned; extract word address within sprite region
        sprite_addr = (addr >> 1) & 0x3FF  # 1024 × 16-bit words
        self.sprite_ram[sprite_addr] = data & 0xFFFF

    def _read_sprite_ram(self, addr: int) -> int:
        """Read from sprite RAM"""
        sprite_addr = (addr >> 1) & 0x3FF
        return self.sprite_ram[sprite_addr]

    def get_status_register(self) -> int:
        """Compose status register from interrupt flags"""
        status = 0x0000
        if self.vblank_irq:
            status |= 0x0080  # Bit 7
        if self.sprite_done_irq:
            status |= 0x0040  # Bit 6
        return status

    def set_interrupt_flags(self, vblank: bool, sprite_done: bool):
        """Set interrupt flags"""
        self.vblank_irq = 1 if vblank else 0
        self.sprite_done_irq = 1 if sprite_done else 0


if __name__ == "__main__":
    # Quick test of the model
    model = NMK16Gate1Model()

    # Test 1: Write to scroll0_x_shadow
    model.process_cpu_cycle(0x120000, 0x1234, Operation.WRITE, 1)
    assert model.scroll0_x_shadow == 0x1234, "Write to scroll0_x_shadow failed"

    # Test 2: Read back scroll0_x_shadow
    result = model.process_cpu_cycle(0x120000, 0x0000, Operation.READ, 1)
    assert result == 0x1234, "Read scroll0_x_shadow failed"

    # Test 3: VBLANK latch
    model.process_cpu_cycle(0x000000, 0x0000, Operation.NOP, 0)  # VBLANK edge: 1->0
    assert model.scroll0_x_active == 0x1234, "VBLANK latch failed"

    # Test 4: Sprite RAM write (address is 21-bit word address, not byte address)
    model.process_cpu_cycle(0x130000, 0xABCD, Operation.WRITE, 1)
    assert model.sprite_ram[0] == 0xABCD, "Sprite RAM write failed"

    # Test 5: Sprite RAM read
    result = model.process_cpu_cycle(0x130000, 0x0000, Operation.READ, 1)
    assert result == 0xABCD, "Sprite RAM read failed"

    print("✓ All model tests passed")
