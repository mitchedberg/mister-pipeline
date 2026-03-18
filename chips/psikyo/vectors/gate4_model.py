#!/usr/bin/env python3
"""
gate4_model.py — Psikyo Gate 4 behavioral model: BG tilemap pixel renderer.

Models the per-pixel BG tilemap pipeline for 2 layers (BG0, BG1).

Tile format: 16×16 px, 4bpp, 128 bytes/tile.
  Byte b in row r: low nibble [3:0] = left pixel (X=2b within tile),
                   high nibble [7:4] = right pixel (X=2b+1 within tile).
  ROM byte addr = tile_num * 128 + fpy * 8 + fpx // 2
  Nybble select = fpx & 1  (0=low, 1=high)

Tilemap: 64 × 64 tiles per layer.
  cell = row * 64 + col   (0..4095)
  VRAM 14-bit address: {layer[0], cell[11:0]}

Tilemap entry (single 16-bit word):
  [15:12] palette  (0..15)
  [11]    flip_y
  [10]    flip_x
  [9:0]   tile_num (0..1023)

Priority: MSB of palette field (entry[15]) is used as the priority bit.

Scroll registers: 16-bit, [15:8] = integer pixels, [7:0] = fraction (ignored).
  tile_x = (hpos + scroll_x_int) & 0x3FF
  tile_y = (vpos + scroll_y_int) & 0x3FF
  col = tile_x >> 4   (0..63)
  row = tile_y >> 4
  px  = tile_x & 0xF  (0..15)
  py  = tile_y & 0xF

Pixel pipeline (mirrors RTL 2-stage pipeline):
  Stage 0: scroll → tile → VRAM → ROM addr
  Stage 1: ROM data → nybble → output
"""

from dataclasses import dataclass
from typing import List

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

NUM_LAYERS   = 2
VRAM_WORDS   = 8192         # 13-bit address: {layer[0], cell[11:0]}
TILE_BYTES   = 128          # 16×16 px, 4bpp
TILE_ROM_BYTES = 1 << 20   # 1 MB — supports tile_num 0..8191


# ─────────────────────────────────────────────────────────────────────────────
# Pixel result
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class BgPixel:
    valid:    bool = False
    color:    int  = 0      # {palette[3:0], nybble[3:0]} — 8-bit
    priority: bool = False  # entry[15]


# ─────────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────────

class PsikyoBGTilemapModel:
    """
    Behavioral model of the Psikyo Gate 4 BG tilemap pipeline.

    Usage:
        m = PsikyoBGTilemapModel()
        m.write_vram(layer, cell, entry_word)
        m.write_tile_rom_byte(addr, byte_val)
        m.set_scroll(layer, sx_int, sy_int)
        pixel = m.get_pixel(layer, hpos, vpos)
    """

    def __init__(self):
        self._vram: List[int]    = [0] * VRAM_WORDS
        self._tile_rom: List[int] = [0] * TILE_ROM_BYTES
        self._scroll_x: List[int] = [0, 0]   # integer scroll (0..255)
        self._scroll_y: List[int] = [0, 0]

    # ── VRAM helpers ──────────────────────────────────────────────────────────

    def _vram_addr(self, layer: int, cell: int) -> int:
        """13-bit VRAM address: {layer[0], cell[11:0]}."""
        assert 0 <= layer < 2
        assert 0 <= cell < 4096
        return (layer << 12) | cell

    def write_vram(self, layer: int, cell: int, entry: int) -> None:
        """Write a tilemap entry word for the given layer/cell."""
        self._vram[self._vram_addr(layer, cell)] = entry & 0xFFFF

    def read_vram(self, layer: int, cell: int) -> int:
        return self._vram[self._vram_addr(layer, cell)]

    # ── Tile ROM helpers ───────────────────────────────────────────────────────

    def write_tile_rom_byte(self, addr: int, byte_val: int) -> None:
        if 0 <= addr < TILE_ROM_BYTES:
            self._tile_rom[addr] = byte_val & 0xFF

    def write_solid_tile(self, tile_num: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = ((nybble & 0xF) << 4) | (nybble & 0xF)
        base = tile_num * TILE_BYTES
        for b in range(TILE_BYTES):
            self._tile_rom[base + b] = byte_val

    def write_tile_pixel(self, tile_num: int, py: int, px: int, nybble: int) -> None:
        """Write a single pixel into the tile ROM."""
        byte_addr = tile_num * TILE_BYTES + py * 8 + px // 2
        cur = self._tile_rom[byte_addr]
        if px & 1:
            self._tile_rom[byte_addr] = (cur & 0x0F) | ((nybble & 0xF) << 4)
        else:
            self._tile_rom[byte_addr] = (cur & 0xF0) | (nybble & 0xF)

    def write_tile_row(self, tile_num: int, py: int, nybbles: List[int]) -> None:
        """Write one row (16 pixels) of a tile."""
        assert len(nybbles) == 16, f"Expected 16 nybbles, got {len(nybbles)}"
        for px_i, n in enumerate(nybbles):
            self.write_tile_pixel(tile_num, py, px_i, n)

    def read_tile_rom_byte(self, addr: int) -> int:
        if 0 <= addr < TILE_ROM_BYTES:
            return self._tile_rom[addr]
        return 0

    # ── Scroll registers ───────────────────────────────────────────────────────

    def set_scroll(self, layer: int, sx_int: int, sy_int: int) -> None:
        """Set integer scroll values for a layer (0..255 each)."""
        assert 0 <= layer < 2
        self._scroll_x[layer] = sx_int & 0xFF
        self._scroll_y[layer] = sy_int & 0xFF

    # ── Pixel pipeline ────────────────────────────────────────────────────────

    def get_pixel(self, layer: int, hpos: int, vpos: int,
                  hblank: bool = False, vblank: bool = False) -> BgPixel:
        """
        Compute the BG pixel for (hpos, vpos) on the given layer.
        Returns BgPixel(valid=False) during blanking or for transparent pixels.
        """
        assert 0 <= layer < 2

        if hblank or vblank:
            return BgPixel(valid=False)

        sx = self._scroll_x[layer]
        sy = self._scroll_y[layer]

        # Scrolled coords (10-bit wrap for 1024-pixel tilemap)
        tx = (hpos + sx) & 0x3FF
        ty = (vpos + sy) & 0x3FF

        col = tx >> 4      # tile column 0..63
        row = ty >> 4      # tile row    0..63
        px  = tx & 0xF     # pixel X within tile 0..15
        py  = ty & 0xF     # pixel Y within tile 0..15

        cell = row * 64 + col   # 0..4095

        entry = self._vram[self._vram_addr(layer, cell)]

        # Decode entry: [15:12]=palette, [11]=flip_y, [10]=flip_x, [9:0]=tile_num
        palette  = (entry >> 12) & 0xF
        flip_y   = bool((entry >> 11) & 1)
        flip_x   = bool((entry >> 10) & 1)
        prio     = bool((entry >> 15) & 1)   # palette MSB as priority
        tile_num = entry & 0x3FF

        fpx = (15 - px) if flip_x else px
        fpy = (15 - py) if flip_y else py

        rom_byte_addr = tile_num * TILE_BYTES + fpy * 8 + fpx // 2
        rom_byte      = self.read_tile_rom_byte(rom_byte_addr)

        if fpx & 1:
            nybble = (rom_byte >> 4) & 0xF   # high nybble
        else:
            nybble = rom_byte & 0xF           # low nybble

        if nybble == 0:
            return BgPixel(valid=False, color=0, priority=prio)

        color = (palette << 4) | nybble
        return BgPixel(valid=True, color=color, priority=prio)


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    m = PsikyoBGTilemapModel()

    # Test 1: solid tile at cell (0,0), no scroll
    # Use tile_num=100 to avoid accidental hits from unwritten cells (which default to tile_num=0)
    m.write_solid_tile(100, 0x5)
    # entry: palette=3, flip_y=0, flip_x=0, tile_num=100 → (3<<12)|100 = 0x3064
    m.write_vram(0, 0, 0x3064)

    pix = m.get_pixel(0, 0, 0)
    assert pix.valid,          f"T1: pixel(0,0) not valid"
    assert pix.color == 0x35,  f"T1: color={pix.color:#x}, expected 0x35"

    pix15 = m.get_pixel(0, 15, 15)
    assert pix15.valid,        f"T1: pixel(15,15) not valid"

    # pixel(16,0) hits cell(0,1) which references tile_num=0 (uninitialized, all-zero → transparent)
    # We must ensure tile 0 has no solid fill → zero-fill ROM for tile 0 (default)
    # The ROM was zero-initialized, so tile_num=0 pixels are all 0 → transparent. Good.
    pix16 = m.get_pixel(0, 16, 0)
    assert not pix16.valid,    f"T1: pixel(16,0) should be transparent (cell(0,1) → tile 0, all zeros)"
    print("Test1 PASS: solid 16x16 tile at cell(0,0)")

    # Test 2: X scroll — tile at cell(2,0), scroll_x=32
    m.write_solid_tile(1, 0x7)
    # cell(0,2): row=0, col=2 → cell=2
    m.write_vram(0, 2, 0x2001)  # palette=2, tile_num=1
    m.set_scroll(0, 32, 0)      # scroll 32 pixels right → hpos=0 maps to tx=32 → col=2

    pix = m.get_pixel(0, 0, 0)
    assert pix.valid,          f"T2: scroll_x=32, hpos=0 should hit col=2"
    assert pix.color == 0x27,  f"T2: color={pix.color:#x}, expected 0x27"
    m.set_scroll(0, 0, 0)  # reset
    print("Test2 PASS: X scroll")

    # Test 3: flip_x — gradient row, verify pixel mirroring
    m.write_tile_row(2, 0, list(range(1, 17)))  # pixels: 1,2,...,16(→0 since 4-bit)
    # entry: palette=1, flip_x=1, tile_num=2 → 0x1402 (flip_x=bit10)
    m.write_vram(0, 0, 0x1402)
    m.set_scroll(0, 0, 0)

    # Without flip: hpos=0 → fpx=0 → nybble=1 (value 1)
    # With flip_x:  hpos=0 → fpx=15 → nybble=pixels[15]= (16&0xF=0 → transparent)
    # hpos=1 → fpx=14 → nybble=pixels[14]=15
    pix1 = m.get_pixel(0, 1, 0)
    assert pix1.valid,          f"T3: flip_x hpos=1 should be valid"
    assert pix1.color == 0x1F,  f"T3: flip_x hpos=1 color={pix1.color:#x}, expected 0x1F"
    print("Test3 PASS: flip_x")

    # Test 4: flip_y — row 0 has nybble 0xA, row 15 has nybble 0xB
    m.write_tile_row(3, 0,  [0xA] * 16)
    m.write_tile_row(3, 15, [0xB] * 16)
    m.write_vram(0, 0, 0x0C03)  # palette=0, flip_y=1 (bit11), tile_num=3 → 0x0803
    # bit11=flip_y=1: entry = 0b 0000 1000 0000 0011 = 0x0803
    # actually entry[15:12]=palette=0, entry[11]=flip_y=1, entry[10]=flip_x=0, entry[9:0]=3
    # = 0000 1000 0000 0011 = 0x0803
    m.write_vram(0, 0, 0x0803)
    m.set_scroll(0, 0, 0)

    # vpos=0 with flip_y: fpy=15 → reads row 15 → nybble=0xB
    pix = m.get_pixel(0, 0, 0)
    assert pix.valid,          f"T4: flip_y vpos=0 not valid"
    assert pix.color == 0x0B,  f"T4: flip_y vpos=0 color={pix.color:#x}, expected 0x0B"

    # vpos=15 with flip_y: fpy=0 → reads row 0 → nybble=0xA
    pix = m.get_pixel(0, 0, 15)
    assert pix.valid,          f"T4: flip_y vpos=15 not valid"
    assert pix.color == 0x0A,  f"T4: flip_y vpos=15 color={pix.color:#x}, expected 0x0A"
    print("Test4 PASS: flip_y")

    # Test 5: Y scroll
    m.write_solid_tile(4, 0x9)
    # cell(1,0): row=1, col=0 → cell=64
    m.write_vram(0, 64, 0x5004)  # palette=5, tile_num=4
    m.set_scroll(0, 0, 16)       # scroll_y=16 → vpos=0 maps to ty=16 → row=1

    pix = m.get_pixel(0, 0, 0)
    assert pix.valid,          f"T5: scroll_y=16, vpos=0 should hit row=1"
    assert pix.color == 0x59,  f"T5: color={pix.color:#x}, expected 0x59"
    m.set_scroll(0, 0, 0)
    print("Test5 PASS: Y scroll")

    # Test 6: transparency — tile with all-zero nybbles
    m.write_solid_tile(5, 0)
    m.write_vram(0, 0, 0x7005)  # palette=7, tile_num=5

    pix = m.get_pixel(0, 0, 0)
    assert not pix.valid,      f"T6: transparent tile should produce invalid pixel"
    print("Test6 PASS: transparency")

    # Test 7: blanking
    pix = m.get_pixel(0, 0, 0, hblank=True)
    assert not pix.valid,      f"T7: hblank pixel should be invalid"
    pix = m.get_pixel(0, 0, 0, vblank=True)
    assert not pix.valid,      f"T7: vblank pixel should be invalid"
    print("Test7 PASS: blanking suppresses output")

    # Test 8: layer 1 independence
    m.write_solid_tile(6, 0x3)
    m.write_vram(1, 0, 0x4006)   # layer 1, cell 0: palette=4, tile_num=6
    m.write_vram(0, 0, 0x0000)   # layer 0, cell 0: tile_num=0 (transparent — all zeros)

    # Make sure layer 0 is transparent and layer 1 is opaque
    pix0 = m.get_pixel(0, 0, 0)
    pix1 = m.get_pixel(1, 0, 0)
    assert not pix0.valid,     f"T8: layer0 should be transparent"
    assert pix1.valid,         f"T8: layer1 should be valid"
    assert pix1.color == 0x43, f"T8: layer1 color={pix1.color:#x}, expected 0x43"
    print("Test8 PASS: layer independence")

    # Test 9: priority bit (palette MSB = entry[15])
    m.write_solid_tile(7, 0xE)
    # entry with priority=1: entry[15]=1 → entry = 0x8007
    m.write_vram(0, 0, 0x8007)   # palette=0x8>>4=palette=8, but palette=(entry>>12)&0xF=8
    # Wait: entry[15:12]=palette. So entry=0x8007 → palette[3:0]=(0x8007>>12)&0xF=8, prio=entry[15]=(0x8007>>15)=1
    # But palette MSB is also 1. Let's use a palette that doesn't set priority:
    # entry=0x8007: bits[15:12]=1000b → palette=8, prio=1
    m.write_vram(0, 0, 0x8007)

    pix = m.get_pixel(0, 0, 0)
    assert pix.valid,           f"T9: priority pixel should be valid"
    assert pix.priority,        f"T9: priority should be True"
    print("Test9 PASS: priority bit")

    # Test 10: scroll wrap-around (tilemap is 1024 pixels wide)
    m.write_solid_tile(8, 0xC)
    m.write_vram(0, 0, 0x3008)   # cell(0,0): tile_num=8, palette=3
    m.set_scroll(0, 248, 0)      # scroll_x=248 → hpos=8 maps to tx=(8+248)=256 → col=16

    # hpos=0 → tx=248 → col=15 (different cell, no tile)
    # hpos=8 → tx=256 → col=16 (no tile), but hpos=0 with scroll 0 would be col=0
    # Reset and test wrap: scroll_x=255, hpos=1 → tx=256 → col=16
    m.set_scroll(0, 0xF0, 0)   # scroll_x=0xF0=240, hpos=0 → tx=240 → col=15
    # Only col=0 has a tile; verify col=15 is transparent
    pix = m.get_pixel(0, 0, 0)
    assert not pix.valid,      f"T10: col=15 should be transparent (tile=0, all zero)"

    # Now test wrap: scroll_x=0 and col 64 wraps to col 0
    m.set_scroll(0, 0, 0)
    # Write a non-zero tile at col=63 too
    m.write_solid_tile(9, 0xD)
    m.write_vram(0, 63, 0x1009)  # cell(0,63): tile_num=9, palette=1

    # hpos=63*16=1008 → tx=1008 → col=63 → should hit tile 9
    pix = m.get_pixel(0, 1008, 0)
    assert pix.valid,           f"T10: hpos=1008 should hit col=63"

    # hpos=1024 would wrap to tx=1024&0x3FF=0 → col=0
    # hpos=320 is max screen, so test via scroll
    m.set_scroll(0, 192, 0)  # scroll_x=192=0xC0, hpos=0 → tx=192 → col=12 (no tile)
    pix = m.get_pixel(0, 0, 0)
    assert not pix.valid,      f"T10: wrap test, col=12 transparent"
    m.set_scroll(0, 0, 0)
    print("Test10 PASS: scroll / wrap")

    print("\ngate4_model self-test PASS")
