#!/usr/bin/env python3
"""
gate3_model.py — GP9001 Gate 3 behavioral model: tilemap pixel renderer.

Models the BG tilemap pipeline:
  - 4 layers, each 64×64 tiles × 8×8 pixels = 512×512 pixel map
  - Per-layer global X/Y scroll
  - VRAM: code word + attr word per cell
  - Tile ROM: 4bpp packed (2 pixels/byte), byte addressed
  - Output: per-pixel {valid, color{palette[3:0], index[3:0]}, priority}

VRAM layout (word-addressed, 15-bit):
  bits [14:13] = layer (0..3)
  bits [12: 1] = cell index = row*64 + col  (0..4095)
  bit  [    0] = 0:code word, 1:attr word

CPU window (used in tests):
  vram_cpu_addr = {layer[1:0], 3'b000, addr[9:0]}
  addr[9:1] = cell index (0..511), addr[0] = word select (0=code,1=attr)

Pixel pipeline:
  tile_x = (hpos + scroll_x) & 0x1FF   (mod 512)
  tile_y = (vpos + scroll_y) & 0x1FF
  col = tile_x >> 3   (0..63)
  row = tile_y >> 3
  px  = tile_x & 7    (pixel within tile)
  py  = tile_y & 7
  cell = row * 64 + col
  code = vram[{layer, cell, 0}]
  attr = vram[{layer, cell, 1}]
  tile_num = code & 0xFFF
  palette  = attr & 0xF
  flip_x   = (attr >> 4) & 1
  flip_y   = (attr >> 5) & 1
  prio     = (attr >> 6) & 1
  fpx = (7 - px) if flip_x else px
  fpy = (7 - py) if flip_y else py
  rom_byte_addr = tile_num * 32 + fpy * 4 + fpx // 2
  byte = tile_rom[rom_byte_addr]
  nybble = (byte >> 4) & 0xF if fpx & 1 else byte & 0xF
  valid = (nybble != 0)
  color = (palette << 4) | nybble
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

VRAM_WORDS  = 32768   # 15-bit address
TILE_ROM_BYTES = 1 << 20  # 1MB, 4bpp: supports tile indices 0..32767

NUM_LAYERS = 4


# ─────────────────────────────────────────────────────────────────────────────
# Pixel result
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class BgPixel:
    valid:    bool  = False
    color:    int   = 0     # {palette[3:0], pix_index[3:0]}
    priority: bool  = False


# ─────────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────────

class GP9001TilemapModel:
    """
    Behavioral model of the GP9001 Gate 3 tilemap pipeline.

    Usage:
        m = GP9001TilemapModel()
        # Write VRAM via CPU window
        m.cpu_write_vram(layer, cell, code_word, attr_word)
        # Write tile ROM data
        m.write_tile_rom(tile_num, py, px, nybble)
        # Set scroll registers
        m.set_scroll(layer, sx, sy)
        # Get pixel for a coordinate
        pixel = m.get_pixel(layer, hpos, vpos)
    """

    def __init__(self):
        self._vram: List[int] = [0] * VRAM_WORDS
        self._tile_rom: List[int] = [0] * TILE_ROM_BYTES
        # Scroll registers: scroll_x[layer], scroll_y[layer]
        self._scroll_x: List[int] = [0, 0, 0, 0]
        self._scroll_y: List[int] = [0, 0, 0, 0]

    # ── VRAM helpers ──────────────────────────────────────────────────────────

    def _vram_code_addr(self, layer: int, cell: int) -> int:
        """15-bit VRAM address for code word of a cell."""
        assert 0 <= layer < 4
        assert 0 <= cell < 4096
        return (layer << 13) | (cell << 1) | 0

    def _vram_attr_addr(self, layer: int, cell: int) -> int:
        """15-bit VRAM address for attr word of a cell."""
        assert 0 <= layer < 4
        assert 0 <= cell < 4096
        return (layer << 13) | (cell << 1) | 1

    def write_vram(self, layer: int, cell: int, code: int, attr: int) -> None:
        """Write code and attr words for a tile cell."""
        self._vram[self._vram_code_addr(layer, cell)] = code & 0xFFFF
        self._vram[self._vram_attr_addr(layer, cell)] = attr & 0xFFFF

    def cpu_write_vram(self, layer: int, addr_low: int, data: int) -> None:
        """
        Simulate CPU write: addr_low = addr[9:0] within layer window.
        Maps to VRAM address {layer[1:0], 3'b000, addr[9:0]}.
        """
        vram_addr = (layer << 13) | (addr_low & 0x3FF)
        # Wait — the RTL uses {vram_layer_sel_r, 3'b000, addr[9:0]}.
        # That is layer[1:0] in bits [14:13], 3'b000 in [12:10], addr[9:0] in [9:0].
        # Total 15 bits.  So addr_low maps directly to bits [9:0].
        # But cell = row*64+col = bits [12:1] of the full 15-bit address.
        # {layer, 3'b000, addr[9:0]}: bits[14:13]=layer, bits[12:10]=0, bits[9:0]=addr.
        # This means cell bits [12:1] = {3'b000, addr[9:1]}, i.e., cell = addr[9:1].
        # And word_sel = addr[0].
        # So: cell = addr_low >> 1, word_sel = addr_low & 1.
        # This is consistent with addr[9:1] being cell index (0..511).
        vram_addr = (layer << 13) | (addr_low & 0x3FF)
        self._vram[vram_addr] = data & 0xFFFF

    def read_vram_raw(self, vram_addr: int) -> int:
        """Raw VRAM read by 15-bit address."""
        return self._vram[vram_addr & 0x7FFF]

    # ── Tile ROM helpers ───────────────────────────────────────────────────────

    def write_tile_rom_byte(self, addr: int, byte_val: int) -> None:
        """Write a byte to tile ROM (2 pixels, 4bpp packed)."""
        assert 0 <= addr < TILE_ROM_BYTES
        self._tile_rom[addr] = byte_val & 0xFF

    def write_tile_pixel(self, tile_num: int, py: int, px: int, nybble: int) -> None:
        """Write a single 4-bit pixel into the tile ROM."""
        assert 0 <= tile_num < 4096
        assert 0 <= py < 8
        assert 0 <= px < 8
        assert 0 <= nybble < 16
        byte_addr = tile_num * 32 + py * 4 + px // 2
        cur = self._tile_rom[byte_addr]
        if px & 1:
            # High nybble
            self._tile_rom[byte_addr] = (cur & 0x0F) | (nybble << 4)
        else:
            # Low nybble
            self._tile_rom[byte_addr] = (cur & 0xF0) | nybble

    def read_tile_rom_byte(self, addr: int) -> int:
        if addr < 0 or addr >= TILE_ROM_BYTES:
            return 0
        return self._tile_rom[addr]

    # ── Scroll registers ───────────────────────────────────────────────────────

    def set_scroll(self, layer: int, sx: int, sy: int) -> None:
        assert 0 <= layer < 4
        self._scroll_x[layer] = sx & 0x1FF
        self._scroll_y[layer] = sy & 0x1FF

    # ── Pixel pipeline ────────────────────────────────────────────────────────

    def get_pixel(self, layer: int, hpos: int, vpos: int,
                  hblank: bool = False, vblank: bool = False) -> BgPixel:
        """
        Compute the BG pixel for (hpos, vpos) on the given layer.
        Returns BgPixel(valid=False) if transparent or during blanking.
        """
        assert 0 <= layer < 4

        if hblank or vblank:
            return BgPixel(valid=False)

        sx = self._scroll_x[layer]
        sy = self._scroll_y[layer]

        tile_x = (hpos + sx) & 0x1FF   # 9-bit wrap
        tile_y = (vpos + sy) & 0x1FF

        col = tile_x >> 3   # 0..63
        row = tile_y >> 3
        px  = tile_x & 7    # 0..7
        py  = tile_y & 7

        cell = row * 64 + col   # 0..4095

        code = self._vram[self._vram_code_addr(layer, cell)]
        attr = self._vram[self._vram_attr_addr(layer, cell)]

        tile_num = code & 0xFFF
        palette  = attr & 0xF
        flip_x   = bool((attr >> 4) & 1)
        flip_y   = bool((attr >> 5) & 1)
        prio     = bool((attr >> 6) & 1)

        fpx = (7 - px) if flip_x else px
        fpy = (7 - py) if flip_y else py

        rom_byte_addr = tile_num * 32 + fpy * 4 + fpx // 2
        rom_byte      = self.read_tile_rom_byte(rom_byte_addr)

        if fpx & 1:
            nybble = (rom_byte >> 4) & 0xF   # high nybble
        else:
            nybble = rom_byte & 0xF           # low nybble

        if nybble == 0:
            return BgPixel(valid=False, color=0, priority=prio)

        color = (palette << 4) | nybble
        return BgPixel(valid=True, color=color, priority=prio)

    # ── Convenience: write a solid tile (all pixels same nybble) ─────────────

    def write_solid_tile(self, tile_num: int, nybble: int) -> None:
        """Fill all 8×8 pixels of a tile with a single 4-bit value."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * 32
        for b in range(32):
            self._tile_rom[base + b] = byte_val

    def write_tile_row(self, tile_num: int, py: int, nybbles: List[int]) -> None:
        """Write one row (8 pixels) of a tile."""
        assert len(nybbles) == 8
        for px_i, n in enumerate(nybbles):
            self.write_tile_pixel(tile_num, py, px_i, n)
