#!/usr/bin/env python3
"""
gate3_model.py — NMK16 Gate 3 behavioral model: per-scanline sprite rasterizer.

Takes the display_list produced by Gate 2 and, for a given scanline Y,
renders all sprites that intersect that scanline into a 320-pixel scanline
buffer.

NMK16 sprite format (from Gate 2 RTL / gate2_model.py):
  Word 0: Y position [8:0]
  Word 1: X position [8:0]
  Word 2: Tile code  [11:0]
  Word 3: Attributes
    [7:4]   palette[3:0]
    [9]     flip_y
    [10]    flip_x
    [15:14] size[1:0]

Sprite size encoding:
  size=0: 1×1 tiles  = 16×16 px
  size=1: 2×2 tiles  = 32×32 px
  size=2: 4×4 tiles  = 64×64 px
  size=3: 8×8 tiles  = 128×128 px

Sprite ROM layout (4bpp packed, 2 pixels per byte):
  One 16×16 tile = 128 bytes (16 rows × 8 bytes/row).
  Tile T, row R (0..15), byte B (0..7):
    addr = T * 128 + R * 8 + B
  Within the byte:
    low  nibble [3:0] = left  pixel (screen X offset 2*B   within tile)
    high nibble [7:4] = right pixel (screen X offset 2*B+1 within tile)

Multi-tile sprite tile code layout (row-major):
  full_tile = sprite.tile_code + tile_row * tiles_wide + tile_col
  where tiles_wide = 1 << sprite.size

Flip:
  flip_y: row_in_sprite = (sprite_height - 1) - raw_row
  flip_x: sprite pixels are mirrored horizontally

Transparency: nibble == 0 → pixel is transparent (not written to buffer)

Priority: sprite.priority bit is stored per-pixel in the buffer.

References:
  MAME src/mame/nmk/nmk16.cpp — sprite drawing logic
  chips/nmk/GATE_PLAN.md      — NMK16 gate specification
"""

from dataclasses import dataclass
from typing import List, Tuple

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

SCREEN_W        = 320
SPR_ROM_BYTES   = 1 << 21   # 2 MB max


# ─────────────────────────────────────────────────────────────────────────────
# Sprite entry (mirrors display_list arrays in nmk16.sv Gate 2)
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class NMK16SpriteEntry:
    x:        int   = 0
    y:        int   = 0
    tile_code: int  = 0
    flip_x:   bool  = False
    flip_y:   bool  = False
    size:     int   = 0    # 0=16×16, 1=32×32, 2=64×64, 3=128×128
    palette:  int   = 0
    valid:    bool  = False


# ─────────────────────────────────────────────────────────────────────────────
# Sprite ROM model
# ─────────────────────────────────────────────────────────────────────────────

class SpriteROM:
    """Software sprite ROM: byte-addressable, 4bpp packed (2 pixels/byte)."""

    def __init__(self):
        self._rom = [0] * SPR_ROM_BYTES

    def write_byte(self, addr: int, val: int) -> None:
        if 0 <= addr < SPR_ROM_BYTES:
            self._rom[addr] = val & 0xFF

    def read_byte(self, addr: int) -> int:
        if 0 <= addr < SPR_ROM_BYTES:
            return self._rom[addr]
        return 0

    def load_solid_tile(self, tile_code: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = (nybble << 4) | nybble
        base = tile_code * 128
        for b in range(128):
            self._rom[base + b] = byte_val

    def load_tile_row(self, tile_code: int, row: int, nybbles: List[int]) -> None:
        """Write 16 nybble values for one tile row (nybbles[0]=leftmost pixel).
        Packing: byte b has lo=nybbles[2b], hi=nybbles[2b+1].
        """
        assert len(nybbles) == 16
        base = tile_code * 128 + row * 8
        for b in range(8):
            lo = nybbles[b * 2]
            hi = nybbles[b * 2 + 1]
            self._rom[base + b] = (hi << 4) | lo

    def get_tile_row_pixels(self, tile_code: int, row: int) -> List[int]:
        """Return 16 nybble values for tile_code row `row`.
        Pixel 0 is leftmost (low nibble of byte 0).
        """
        base = tile_code * 128 + row * 8
        pixels = []
        for b in range(8):
            byte = self._rom[base + b]
            pixels.append(byte & 0xF)         # low nibble  = left pixel
            pixels.append((byte >> 4) & 0xF)  # high nibble = right pixel
        return pixels   # 16 values


# ─────────────────────────────────────────────────────────────────────────────
# Pixel buffer entry
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class PixelEntry:
    valid:    bool  = False
    color:    int   = 0    # {palette[3:0], nybble[3:0]} = 8-bit
    priority: bool  = False


# ─────────────────────────────────────────────────────────────────────────────
# Rasterizer model
# ─────────────────────────────────────────────────────────────────────────────

class NMK16SpriteRasterizer:
    """
    Behavioral model of the NMK16 Gate 3 per-scanline sprite rasterizer.

    Usage:
        rast = NMK16SpriteRasterizer(rom)
        # populate display_list: list of NMK16SpriteEntry (from Gate 2 model)
        buf = rast.render_scanline(display_list, display_list_count, current_y)
        # buf is a list of 320 PixelEntry
        pixel = buf[x]   # check pixel at screen X = x
    """

    def __init__(self, rom: SpriteROM):
        self.rom = rom

    def render_scanline(self, display_list: List[NMK16SpriteEntry],
                        display_list_count: int,
                        current_y: int) -> List[PixelEntry]:
        """
        Render one scanline.

        Sprites are drawn in display_list order; later sprites overwrite
        earlier ones (last-writer wins, matching RTL FSM behavior).

        Returns list of 320 PixelEntry.
        """
        buf = [PixelEntry() for _ in range(SCREEN_W)]

        for idx in range(display_list_count):
            e = display_list[idx]
            if not e.valid:
                continue

            tiles_wide = 1 << e.size
            px_width   = tiles_wide * 16
            px_height  = px_width   # square sprites

            # Check if sprite intersects current_y
            if not (e.y <= current_y < e.y + px_height):
                continue

            # Row within sprite (before flip_y)
            raw_row = current_y - e.y

            # Apply flip_y
            if e.flip_y:
                row_in_spr = (px_height - 1) - raw_row
            else:
                row_in_spr = raw_row

            # Decompose into tile row and row within tile
            tile_row    = row_in_spr >> 4    # row_in_spr // 16
            row_in_tile = row_in_spr & 0xF  # row_in_spr % 16

            # Iterate tile columns
            for tc in range(tiles_wide):
                full_tile = e.tile_code + tile_row * tiles_wide + tc

                # Fetch 16 pixels for this tile row
                pixels = self.rom.get_tile_row_pixels(full_tile, row_in_tile)

                for px_in_tile in range(16):
                    # Apply flip_x (mirror within entire sprite width)
                    if e.flip_x:
                        sprite_px    = (px_width - 1) - (tc * 16 + px_in_tile)
                        eff_tc       = sprite_px // 16
                        eff_px_in_tc = sprite_px % 16
                        nybble = self.rom.get_tile_row_pixels(
                            e.tile_code + tile_row * tiles_wide + eff_tc,
                            row_in_tile
                        )[eff_px_in_tc]
                    else:
                        nybble = pixels[px_in_tile]

                    if nybble == 0:
                        continue  # transparent

                    screen_x = e.x + tc * 16 + px_in_tile
                    if 0 <= screen_x < SCREEN_W:
                        buf[screen_x] = PixelEntry(
                            valid    = True,
                            color    = (e.palette << 4) | nybble,
                            priority = False,  # NMK16 Gate 3: no per-sprite priority bit
                        )

        return buf

    def get_pixel(self, buf: List[PixelEntry], x: int) -> PixelEntry:
        """Helper: get pixel from buffer, returns transparent if out of range."""
        if 0 <= x < SCREEN_W:
            return buf[x]
        return PixelEntry()


# ─────────────────────────────────────────────────────────────────────────────
# Unit self-test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    # Test 1: single 16×16 sprite, solid fill
    spr = NMK16SpriteEntry(x=10, y=20, tile_code=0, palette=3, size=0, valid=True)
    rom.load_solid_tile(0, 0x5)

    display_list = [spr] + [NMK16SpriteEntry() for _ in range(255)]
    buf = rast.render_scanline(display_list, 1, current_y=20)

    assert buf[10].valid,           f"T1: pixel(10,20) not valid"
    assert buf[10].color == 0x35,   f"T1: color={buf[10].color:#x}, expected 0x35"
    assert not buf[9].valid,        f"T1: pixel(9) should be transparent"
    assert buf[25].valid,           f"T1: pixel(25) should be valid (last)"
    assert not buf[26].valid,       f"T1: pixel(26) should be transparent"
    print("Test1 PASS: single 16x16 solid sprite")

    # Test 2: flip_x
    rom2  = SpriteROM()
    rast2 = NMK16SpriteRasterizer(rom2)
    row0  = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    rom2.load_tile_row(1, 0, row0)
    spr2  = NMK16SpriteEntry(x=0, y=0, tile_code=1, palette=1, size=0, flip_x=True, valid=True)
    dl2   = [spr2] + [NMK16SpriteEntry() for _ in range(255)]
    buf2  = rast2.render_scanline(dl2, 1, current_y=0)
    assert buf2[0].valid,              f"T2: pixel(0) not valid"
    assert buf2[0].color  == 0x11,     f"T2: px0 color={buf2[0].color:#x}, expected 0x11"
    assert buf2[1].color  == 0x1F,     f"T2: px1 color={buf2[1].color:#x}, expected 0x1F"
    assert buf2[15].color == 0x11,     f"T2: px15 color={buf2[15].color:#x}, expected 0x11"
    print("Test2 PASS: flip_x")

    # Test 3: flip_y
    rom3  = SpriteROM()
    rast3 = NMK16SpriteRasterizer(rom3)
    rom3.load_tile_row(2, 0,  [0xA] * 16)
    rom3.load_tile_row(2, 15, [0xB] * 16)
    spr3  = NMK16SpriteEntry(x=0, y=0, tile_code=2, palette=2, size=0, flip_y=True, valid=True)
    dl3   = [spr3] + [NMK16SpriteEntry() for _ in range(255)]
    buf3  = rast3.render_scanline(dl3, 1, current_y=0)
    assert buf3[0].color == 0x2B, f"T3: flip_y y=0 color={buf3[0].color:#x}, expected 0x2B"
    buf3b = rast3.render_scanline(dl3, 1, current_y=15)
    assert buf3b[0].color == 0x2A, f"T3: flip_y y=15 color={buf3b[0].color:#x}, expected 0x2A"
    print("Test3 PASS: flip_y")

    # Test 4: 32×32 multi-tile sprite (size=1)
    rom4  = SpriteROM()
    rast4 = NMK16SpriteRasterizer(rom4)
    rom4.load_solid_tile(4, 0x1)   # top-left
    rom4.load_solid_tile(5, 0x2)   # top-right
    rom4.load_solid_tile(6, 0x3)   # bottom-left
    rom4.load_solid_tile(7, 0x4)   # bottom-right
    spr4  = NMK16SpriteEntry(x=0, y=0, tile_code=4, palette=5, size=1, valid=True)
    dl4   = [spr4] + [NMK16SpriteEntry() for _ in range(255)]
    buf4  = rast4.render_scanline(dl4, 1, current_y=0)
    assert buf4[0].color  == 0x51, f"T4: px0 color={buf4[0].color:#x}"
    assert buf4[16].color == 0x52, f"T4: px16 color={buf4[16].color:#x}"
    buf4b = rast4.render_scanline(dl4, 1, current_y=16)
    assert buf4b[0].color  == 0x53, f"T4: bottom-left px0={buf4b[0].color:#x}"
    assert buf4b[16].color == 0x54, f"T4: bottom-right px16={buf4b[16].color:#x}"
    assert not buf4b[32].valid,     f"T4: pixel(32) should be transparent"
    print("Test4 PASS: 32x32 multi-tile sprite")

    # Test 5: transparency (all-zero nybble tile)
    rom5  = SpriteROM()
    rast5 = NMK16SpriteRasterizer(rom5)
    rom5.load_solid_tile(10, 0)
    spr5  = NMK16SpriteEntry(x=5, y=5, tile_code=10, palette=7, size=0, valid=True)
    dl5   = [spr5] + [NMK16SpriteEntry() for _ in range(255)]
    buf5  = rast5.render_scanline(dl5, 1, current_y=5)
    for x in range(5, 21):
        assert not buf5[x].valid, f"T5: pixel({x}) should be transparent"
    print("Test5 PASS: transparent sprite")

    # Test 6: sprite outside scanline
    rom6  = SpriteROM()
    rast6 = NMK16SpriteRasterizer(rom6)
    rom6.load_solid_tile(11, 0xF)
    spr6  = NMK16SpriteEntry(x=0, y=50, tile_code=11, palette=1, size=0, valid=True)
    dl6   = [spr6] + [NMK16SpriteEntry() for _ in range(255)]
    buf6  = rast6.render_scanline(dl6, 1, current_y=0)
    for x in range(16):
        assert not buf6[x].valid, f"T6: pixel({x}) should be transparent (scanline miss)"
    print("Test6 PASS: sprite outside scanline")

    # Test 7: multiple sprites on same scanline (later overwrites earlier)
    rom7  = SpriteROM()
    rast7 = NMK16SpriteRasterizer(rom7)
    rom7.load_solid_tile(20, 0x6)
    rom7.load_solid_tile(21, 0xA)
    spr7a = NMK16SpriteEntry(x=0, y=0, tile_code=20, palette=1, size=0, valid=True)
    spr7b = NMK16SpriteEntry(x=8, y=0, tile_code=21, palette=2, size=0, valid=True)
    dl7   = [spr7a, spr7b] + [NMK16SpriteEntry() for _ in range(254)]
    buf7  = rast7.render_scanline(dl7, 2, current_y=0)
    assert buf7[0].color  == 0x16, f"T7: px0  color={buf7[0].color:#x}, expected 0x16"
    assert buf7[7].color  == 0x16, f"T7: px7  color={buf7[7].color:#x}, expected 0x16"
    assert buf7[8].color  == 0x2A, f"T7: px8  color={buf7[8].color:#x}, expected 0x2A"
    assert buf7[15].color == 0x2A, f"T7: px15 color={buf7[15].color:#x}, expected 0x2A"
    print("Test7 PASS: multiple sprites overlapping")

    # Test 8: sprite at right edge (x=304, width=16 → x=304..319)
    rom8  = SpriteROM()
    rast8 = NMK16SpriteRasterizer(rom8)
    rom8.load_solid_tile(30, 0xC)
    spr8  = NMK16SpriteEntry(x=304, y=0, tile_code=30, palette=6, size=0, valid=True)
    dl8   = [spr8] + [NMK16SpriteEntry() for _ in range(255)]
    buf8  = rast8.render_scanline(dl8, 1, current_y=0)
    assert buf8[304].valid,            f"T8: pixel(304) not valid"
    assert buf8[319].valid,            f"T8: pixel(319) not valid"
    assert not buf8[303].valid,        f"T8: pixel(303) should be transparent"
    print("Test8 PASS: sprite at right screen edge")

    print("gate3_model self-test PASS")
