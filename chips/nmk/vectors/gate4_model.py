#!/usr/bin/env python3
"""
gate4_model.py — NMK16 Gate 4 behavioral model: BG tilemap pixel renderer.

Models the BG tilemap pipeline for 2 layers:
  - 2 layers (BG0, BG1), each a 32×32 tile map × 16×16 pixels = 512×512 pixel space
  - Per-layer global X/Y scroll
  - Tilemap RAM: one 16-bit word per tile cell
  - Tile ROM: 4bpp packed (2 pixels/byte), byte-addressed
  - Output: per-pixel {valid, color{palette[3:0], index[3:0]}}

Tilemap RAM word format (16-bit):
  [15:12] palette  (0..15)
  [11]    flip_y
  [10]    flip_x
  [9:0]   tile_index (0..1023)

CPU write address (is_tilemap = $110000-$11FFFF):
  addr[11] = layer (0=layer0, 1=layer1)
  addr[10:6] = tile_row (0..31)
  addr[5:1]  = tile_col (0..31)
  word_index = {layer, tile_row[4:0], tile_col[4:0]}   — 11 bits, 0..2047

Pixel pipeline:
  src_x = (bg_x + scroll_x) & 0x1FF       (9-bit wrap)
  src_y = (bg_y + scroll_y) & 0x1FF       (9-bit wrap)
  tile_col = src_x >> 4    (0..31)
  tile_row = src_y >> 4    (0..31)
  pix_x    = src_x & 0xF  (0..15)
  pix_y    = src_y & 0xF  (0..15)
  tram_word = tilemap_ram[layer * 1024 + tile_row * 32 + tile_col]
  tile_idx = tram_word & 0x3FF
  palette  = (tram_word >> 12) & 0xF
  flip_x   = (tram_word >> 10) & 1
  flip_y   = (tram_word >> 11) & 1
  fpx = (15 - pix_x) if flip_x else pix_x
  fpy = (15 - pix_y) if flip_y else pix_y
  rom_byte_addr = tile_idx * 128 + fpy * 8 + fpx // 2
  byte     = tile_rom[rom_byte_addr]
  nibble   = (byte >> 4) & 0xF  if fpx & 1 else byte & 0xF
  valid    = (nibble != 0)
  color    = (palette << 4) | nibble
"""

from dataclasses import dataclass
from typing import List

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

TRAM_WORDS     = 2048           # 2 layers × 1024 cells
TILE_ROM_BYTES = 1 << 17        # 128 KB: 1024 tiles × 128 bytes/tile

NUM_LAYERS = 2
TILES_PER_LAYER = 1024          # 32×32 tile map


# ─────────────────────────────────────────────────────────────────────────────
# Pixel result
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class BgPixel:
    valid:   bool = False
    color:   int  = 0      # {palette[3:0], pix_index[3:0]}


# ─────────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────────

class NMK16TilemapModel:
    """
    Behavioral model of the NMK16 Gate 4 BG tilemap pipeline.

    Usage:
        m = NMK16TilemapModel()
        # Write tilemap RAM via CPU window
        m.write_tram(layer, tile_row, tile_col, word)
        # Write tile ROM data
        m.write_tile_rom_byte(addr, byte_val)
        # Set scroll registers
        m.set_scroll(layer, sx, sy)
        # Get pixel for a coordinate
        pixel = m.get_pixel(layer, bg_x, bg_y)
    """

    def __init__(self):
        self._tram: List[int] = [0] * TRAM_WORDS
        self._tile_rom: List[int] = [0] * TILE_ROM_BYTES
        # Scroll registers: [layer]
        self._scroll_x: List[int] = [0, 0]
        self._scroll_y: List[int] = [0, 0]

    # ── Tilemap RAM helpers ────────────────────────────────────────────────────

    def _tram_addr(self, layer: int, tile_row: int, tile_col: int) -> int:
        """11-bit TRAM address."""
        assert 0 <= layer < 2
        assert 0 <= tile_row < 32
        assert 0 <= tile_col < 32
        return (layer << 10) | (tile_row << 5) | tile_col

    def write_tram(self, layer: int, tile_row: int, tile_col: int, word: int) -> None:
        """Write one tilemap cell word."""
        self._tram[self._tram_addr(layer, tile_row, tile_col)] = word & 0xFFFF

    def cpu_write_tram(self, addr_word: int, data: int) -> None:
        """
        Simulate CPU write: addr_word = addr[11:1] (11-bit word offset).
        Maps to tilemap_ram[addr[11:1]].
        """
        idx = addr_word & 0x7FF  # 11 bits
        self._tram[idx] = data & 0xFFFF

    def read_tram(self, layer: int, tile_row: int, tile_col: int) -> int:
        return self._tram[self._tram_addr(layer, tile_row, tile_col)]

    # ── Tile ROM helpers ───────────────────────────────────────────────────────

    def write_tile_rom_byte(self, addr: int, byte_val: int) -> None:
        """Write a byte to tile ROM (contains 2 packed 4-bit pixels)."""
        if 0 <= addr < TILE_ROM_BYTES:
            self._tile_rom[addr] = byte_val & 0xFF

    def write_tile_pixel(self, tile_num: int, py: int, px: int, nybble: int) -> None:
        """Write a single 4-bit pixel into the tile ROM."""
        assert 0 <= tile_num < 1024
        assert 0 <= py < 16
        assert 0 <= px < 16
        assert 0 <= nybble < 16
        byte_addr = tile_num * 128 + py * 8 + px // 2
        cur = self._tile_rom[byte_addr]
        if px & 1:
            self._tile_rom[byte_addr] = (cur & 0x0F) | (nybble << 4)
        else:
            self._tile_rom[byte_addr] = (cur & 0xF0) | nybble

    def write_solid_tile(self, tile_num: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * 128
        for b in range(128):
            self._tile_rom[base + b] = byte_val

    def write_tile_row(self, tile_num: int, py: int, nybbles: List[int]) -> None:
        """Write one row (16 pixels) of a tile."""
        assert len(nybbles) == 16
        for px_i, n in enumerate(nybbles):
            self.write_tile_pixel(tile_num, py, px_i, n)

    def read_tile_rom_byte(self, addr: int) -> int:
        if addr < 0 or addr >= TILE_ROM_BYTES:
            return 0
        return self._tile_rom[addr]

    # ── Scroll registers ───────────────────────────────────────────────────────

    def set_scroll(self, layer: int, sx: int, sy: int) -> None:
        assert 0 <= layer < 2
        self._scroll_x[layer] = sx & 0x1FF
        self._scroll_y[layer] = sy & 0x1FF

    # ── Pixel pipeline ────────────────────────────────────────────────────────

    def get_pixel(self, layer: int, bg_x: int, bg_y: int) -> BgPixel:
        """
        Compute the BG pixel for (bg_x, bg_y) on the given layer.
        Returns BgPixel(valid=False) if transparent.
        """
        assert 0 <= layer < 2

        sx = self._scroll_x[layer]
        sy = self._scroll_y[layer]

        src_x = (bg_x + sx) & 0x1FF   # 9-bit wrap
        src_y = (bg_y + sy) & 0x1FF   # 9-bit wrap

        tile_col = src_x >> 4   # 0..31
        tile_row = src_y >> 4   # 0..31
        pix_x    = src_x & 0xF  # 0..15
        pix_y    = src_y & 0xF  # 0..15

        tram_word = self._tram[self._tram_addr(layer, tile_row, tile_col)]

        tile_idx = tram_word & 0x3FF
        palette  = (tram_word >> 12) & 0xF
        flip_x   = bool((tram_word >> 10) & 1)
        flip_y   = bool((tram_word >> 11) & 1)

        fpx = (15 - pix_x) if flip_x else pix_x
        fpy = (15 - pix_y) if flip_y else pix_y

        rom_byte_addr = tile_idx * 128 + fpy * 8 + fpx // 2
        rom_byte      = self.read_tile_rom_byte(rom_byte_addr)

        if fpx & 1:
            nybble = (rom_byte >> 4) & 0xF   # high nybble
        else:
            nybble = rom_byte & 0xF           # low nybble

        if nybble == 0:
            return BgPixel(valid=False, color=0)

        color = (palette << 4) | nybble
        return BgPixel(valid=True, color=color)
