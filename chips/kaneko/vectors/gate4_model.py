#!/usr/bin/env python3
"""
gate4_model.py — Kaneko16 Gate 4 behavioral model: BG tilemap pixel renderer.

Models the VIEW2-CHIP BG tilemap pipeline:
  - 4 layers (BG0..BG3), each a 32×32-tile scrolling map = 512×512 pixel space
  - Per-layer global X/Y scroll (9-bit wrap)
  - VRAM: one 16-bit word per cell (tile index + attributes packed)
  - Tile ROM: 16×16 px tiles, 4bpp packed (2 pixels/byte, 8 bytes/row, 128 bytes/tile)
  - Output: per-pixel {valid, color{palette[3:0], index[3:0]}, priority}

VRAM layout (word-addressed, 12-bit):
  bits [11:10] = layer  (0..3)
  bits [9:5]   = row    (0..31)
  bits [4:0]   = col    (0..31)

Tilemap entry format (16-bit word, from GATE_PLAN.md):
  bits [15:8]  = tile_index (0..255; upper 8 bits for 256-tile ROM space)
  bits [7:4]   = palette[3:0]
  bit  [3]     = VFLIP
  bit  [2]     = HFLIP
  bits [1:0]   = reserved

Pixel pipeline (per layer, per pixel):
  tile_x = (hpos + scroll_x[layer]) & 0x1FF   (9-bit wrap in 512px map)
  tile_y = (vpos + scroll_y[layer]) & 0x1FF
  col = (tile_x >> 4) & 0x1F    (0..31, 16px/tile)
  row = (tile_y >> 4) & 0x1F
  px  = tile_x & 0xF            (pixel within tile X: 0..15)
  py  = tile_y & 0xF            (pixel within tile Y: 0..15)
  cell = row * 32 + col
  vram_word = vram[{layer, row[4:0], col[4:0]}]
  tile_num = vram_word[11:0]
  palette  = vram_word[15:12]
  hflip    = vram_word[2]
  vflip    = vram_word[3]
  fpx = (15 - px) if hflip else px
  fpy = (15 - py) if vflip else py
  rom_byte_addr = tile_num * 128 + fpy * 8 + fpx // 2
  byte = tile_rom[rom_byte_addr]
  nybble = (byte >> 4) & 0xF if (fpx & 1) else byte & 0xF
  valid = (nybble != 0)
  color = (palette << 4) | nybble
"""

from dataclasses import dataclass
from typing import List

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

VRAM_WORDS     = 4096       # 12-bit address: 4 layers × 32×32 = 4096 cells
TILE_ROM_BYTES = 1 << 21    # 2 MB: supports tile indices 0..16383 (each 128 bytes)
NUM_LAYERS     = 4
TILES_PER_ROW  = 32         # 32 tile columns per layer
TILE_PX        = 16         # 16×16 pixels per tile
BYTES_PER_TILE = 128        # 16 rows × 8 bytes/row


# ─────────────────────────────────────────────────────────────────────────────
# Pixel result
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class BgPixel:
    valid:    bool = False
    color:    int  = 0      # {palette[3:0], pix_index[3:0]}
    priority: bool = False


# ─────────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────────

class Kaneko16TilemapModel:
    """
    Behavioral model of the Kaneko16 Gate 4 BG tilemap pipeline.

    Usage:
        m = Kaneko16TilemapModel()
        m.write_vram(layer, row, col, vram_word)    # write one tile entry
        m.write_tile_rom_byte(addr, byte_val)        # write tile ROM byte
        m.set_scroll(layer, sx, sy)                  # set per-layer scroll
        pixel = m.get_pixel(layer, hpos, vpos)       # query pixel output
    """

    def __init__(self):
        self._vram: List[int]      = [0] * VRAM_WORDS
        self._tile_rom: List[int]  = [0] * TILE_ROM_BYTES
        self._scroll_x: List[int]  = [0, 0, 0, 0]
        self._scroll_y: List[int]  = [0, 0, 0, 0]

    # ── VRAM address ──────────────────────────────────────────────────────────

    def _vram_addr(self, layer: int, row: int, col: int) -> int:
        """12-bit VRAM address for a tile cell."""
        assert 0 <= layer < 4
        assert 0 <= row   < TILES_PER_ROW
        assert 0 <= col   < TILES_PER_ROW
        return (layer << 10) | (row << 5) | col

    # ── VRAM helpers ──────────────────────────────────────────────────────────

    def write_vram(self, layer: int, row: int, col: int, vram_word: int) -> None:
        """Write a tile entry directly."""
        self._vram[self._vram_addr(layer, row, col)] = vram_word & 0xFFFF

    def make_vram_word(self, tile_num: int, palette: int,
                       hflip: bool = False, vflip: bool = False) -> int:
        """
        Assemble a 16-bit VRAM word from tile fields.
        Encoding (from GATE_PLAN.md):
          [15:8]  tile_num (0..255)
          [7:4]   palette[3:0]
          [3]     VFLIP
          [2]     HFLIP
          [1:0]   reserved
        """
        w  = ((tile_num & 0xFF) << 8)
        w |= ((palette & 0xF) << 4)
        if vflip:
            w |= (1 << 3)
        if hflip:
            w |= (1 << 2)
        return w

    def cpu_write_vram(self, layer: int, row: int, col: int,
                       tile_num: int, palette: int,
                       hflip: bool = False, vflip: bool = False) -> None:
        """Convenience: write a tile cell by fields."""
        word = self.make_vram_word(tile_num, palette, hflip, vflip)
        self.write_vram(layer, row, col, word)

    def read_vram_raw(self, vram_addr: int) -> int:
        """Raw VRAM read by 12-bit address."""
        return self._vram[vram_addr & 0xFFF]

    # ── Tile ROM helpers ───────────────────────────────────────────────────────

    def write_tile_rom_byte(self, addr: int, byte_val: int) -> None:
        if 0 <= addr < TILE_ROM_BYTES:
            self._tile_rom[addr] = byte_val & 0xFF

    def write_tile_pixel(self, tile_num: int, py: int, px: int, nybble: int) -> None:
        """Write a single 4-bit pixel into the tile ROM (16×16 tile)."""
        assert 0 <= tile_num < 16384
        assert 0 <= py < 16
        assert 0 <= px < 16
        assert 0 <= nybble < 16
        byte_addr = tile_num * BYTES_PER_TILE + py * 8 + px // 2
        cur = self._tile_rom[byte_addr]
        if px & 1:
            self._tile_rom[byte_addr] = (cur & 0x0F) | (nybble << 4)
        else:
            self._tile_rom[byte_addr] = (cur & 0xF0) | nybble

    def write_solid_tile(self, tile_num: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * BYTES_PER_TILE
        for b in range(BYTES_PER_TILE):
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
        assert 0 <= layer < 4
        self._scroll_x[layer] = sx & 0x1FF
        self._scroll_y[layer] = sy & 0x1FF

    # ── Pixel pipeline ─────────────────────────────────────────────────────────

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

        tile_x = (hpos + sx) & 0x1FF   # 9-bit wrap (512px map)
        tile_y = (vpos + sy) & 0x1FF

        col = (tile_x >> 4) & 0x1F     # tile column (0..31)
        row = (tile_y >> 4) & 0x1F     # tile row    (0..31)
        px  = tile_x & 0xF             # pixel X within tile (0..15)
        py  = tile_y & 0xF             # pixel Y within tile (0..15)

        vram_word = self._vram[self._vram_addr(layer, row, col)]

        # VRAM word encoding (GATE_PLAN.md):
        # [15:8] tile_num, [7:4] palette, [3] VFLIP, [2] HFLIP
        tile_num = (vram_word >> 8) & 0xFF
        palette  = (vram_word >> 4) & 0xF
        vflip    = bool((vram_word >> 3) & 1)
        hflip    = bool((vram_word >> 2) & 1)

        fpx = (15 - px) if hflip else px
        fpy = (15 - py) if vflip else py

        rom_byte_addr = tile_num * BYTES_PER_TILE + fpy * 8 + fpx // 2
        rom_byte      = self.read_tile_rom_byte(rom_byte_addr)

        if fpx & 1:
            nybble = (rom_byte >> 4) & 0xF   # high nybble (right pixel)
        else:
            nybble = rom_byte & 0xF           # low nybble  (left pixel)

        if nybble == 0:
            return BgPixel(valid=False, color=0, priority=False)

        color = (palette << 4) | nybble
        return BgPixel(valid=True, color=color, priority=False)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    m = Kaneko16TilemapModel()

    # Test 1: single tile, solid fill, scroll=0
    m.write_solid_tile(1, 0x5)
    m.cpu_write_vram(0, 0, 0, tile_num=1, palette=3)
    m.set_scroll(0, 0, 0)
    p = m.get_pixel(0, 0, 0)
    assert p.valid,         f"T1: expected valid, got {p}"
    assert p.color == 0x35, f"T1: color={p.color:#x}, expected 0x35"
    p_past = m.get_pixel(0, 16, 0)  # next tile (empty)
    assert not p_past.valid, f"T1: pixel at x=16 should be transparent"
    print("Test1 PASS: solid tile, no scroll")

    # Test 2: scroll wraps into next tile column
    m2 = Kaneko16TilemapModel()
    m2.write_solid_tile(2, 0x7)
    m2.cpu_write_vram(0, 0, 1, tile_num=2, palette=1)  # tile at col=1
    m2.set_scroll(0, 16, 0)   # scroll by exactly one tile width
    p2 = m2.get_pixel(0, 0, 0)  # hpos=0 + scroll=16 → tile_x=16 → col=1
    assert p2.valid,         f"T2: expected valid after scroll"
    assert p2.color == 0x17, f"T2: color={p2.color:#x}, expected 0x17"
    print("Test2 PASS: scroll wraps to tile col=1")

    # Test 3: HFLIP
    m3 = Kaneko16TilemapModel()
    row0 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    for r in range(16):
        m3.write_tile_row(3, r, row0)
    m3.cpu_write_vram(0, 0, 0, tile_num=3, palette=1, hflip=True)
    m3.set_scroll(0, 0, 0)
    # hflip: screen px 0 → tile px 15 → nybble row0[15]=1 → color {1,1}=0x11
    p3a = m3.get_pixel(0, 0, 0)
    assert p3a.valid,          f"T3: px0 not valid"
    assert p3a.color == 0x11,  f"T3: px0 color={p3a.color:#x}, expected 0x11"
    # screen px 1 → tile px 14 → nybble row0[14]=F → color {1,F}=0x1F
    p3b = m3.get_pixel(0, 1, 0)
    assert p3b.color == 0x1F,  f"T3: px1 color={p3b.color:#x}, expected 0x1F"
    print("Test3 PASS: HFLIP")

    # Test 4: VFLIP
    m4 = Kaneko16TilemapModel()
    m4.write_tile_row(4, 0,  [0xA] * 16)
    m4.write_tile_row(4, 15, [0xB] * 16)
    m4.cpu_write_vram(0, 0, 0, tile_num=4, palette=2, vflip=True)
    m4.set_scroll(0, 0, 0)
    # vflip: vpos=0 → py=0 → fpy=15 → nybble 0xB → color {2,B}=0x2B
    p4a = m4.get_pixel(0, 0, 0)
    assert p4a.color == 0x2B, f"T4: vpos=0 color={p4a.color:#x}, expected 0x2B"
    # vpos=15 → py=15 → fpy=0 → nybble 0xA → color {2,A}=0x2A
    p4b = m4.get_pixel(0, 0, 15)
    assert p4b.color == 0x2A, f"T4: vpos=15 color={p4b.color:#x}, expected 0x2A"
    print("Test4 PASS: VFLIP")

    # Test 5: transparency (nybble=0)
    m5 = Kaneko16TilemapModel()
    m5.write_solid_tile(5, 0)
    m5.cpu_write_vram(0, 0, 0, tile_num=5, palette=7)
    m5.set_scroll(0, 0, 0)
    p5 = m5.get_pixel(0, 0, 0)
    assert not p5.valid, f"T5: transparent tile should give valid=False"
    print("Test5 PASS: transparency")

    # Test 6: layer independence
    m6 = Kaneko16TilemapModel()
    m6.write_solid_tile(10, 0xA)
    m6.write_solid_tile(11, 0xB)
    m6.cpu_write_vram(0, 0, 0, tile_num=10, palette=4)
    m6.cpu_write_vram(1, 0, 0, tile_num=11, palette=5)
    m6.set_scroll(0, 0, 0)
    m6.set_scroll(1, 0, 0)
    p6a = m6.get_pixel(0, 0, 0)
    p6b = m6.get_pixel(1, 0, 0)
    assert p6a.color == 0x4A, f"T6: layer0 color={p6a.color:#x}, expected 0x4A"
    assert p6b.color == 0x5B, f"T6: layer1 color={p6b.color:#x}, expected 0x5B"
    print("Test6 PASS: layer independence")

    # Test 7: 512px scroll wrap-around
    m7 = Kaneko16TilemapModel()
    m7.write_solid_tile(20, 0xC)
    m7.cpu_write_vram(2, 0, 0, tile_num=20, palette=6)  # row=0, col=0
    m7.set_scroll(2, 0x1F0, 0)   # scroll near end of 512px map
    # tile_x = (0 + 0x1F0) & 0x1FF = 0x1F0 → col = 0x1F0>>4 = 0x1F = 31
    # so row=0, col=31 — that's empty (we only filled col=0)
    p7a = m7.get_pixel(2, 0, 0)
    assert not p7a.valid, f"T7: expected transparent at col=31"
    # tile_x = (16 + 0x1F0) & 0x1FF = (0x200) & 0x1FF = 0 → col=0 → hits tile 20
    p7b = m7.get_pixel(2, 16, 0)
    assert p7b.valid,         f"T7: expected valid after wrap at col=0"
    assert p7b.color == 0x6C, f"T7: color={p7b.color:#x}, expected 0x6C"
    print("Test7 PASS: 512px scroll wrap")

    print("gate4_model self-test PASS")
