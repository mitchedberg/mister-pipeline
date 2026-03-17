#!/usr/bin/env python3
"""
gate3_model.py — Psikyo Gate 3 behavioral model: per-scanline sprite rasterizer.

Takes the display_list produced by Gate 2 (PS2001B sprite scanner) and, for a
given scanline Y, renders all sprites that intersect that scanline into a
320-pixel scanline buffer.

Psikyo sprite format (from psikyo.sv display_list typedef psikyo_sprite_t):
  x        [9:0]   X position
  y        [9:0]   Y position
  tile_num [15:0]  Tile code
  flip_x          horizontal flip
  flip_y          vertical flip
  prio     [1:0]   priority
  size     [2:0]   sprite size encoding (see below)
  palette  [3:0]   palette select
  valid           entry is active

Sprite size encoding:
  size=0: 1×1  tiles =  16×16 px
  size=1: 2×2  tiles =  32×32 px
  size=2: 4×4  tiles =  64×64 px
  size=3: 8×8  tiles = 128×128 px
  size=4: 16×16 tiles = 256×256 px
  (sizes 5-7: treated as 1×1 for safety)

Sprite ROM layout (4bpp packed, 2 pixels per byte):
  One 16×16 tile = 128 bytes (16 rows × 8 bytes/row).
  Tile T, row R (0..15), byte B (0..7):
    addr = T * 128 + R * 8 + B
  Within the byte:
    low  nibble [3:0] = left  pixel (screen X offset 2*B   within tile)
    high nibble [7:4] = right pixel (screen X offset 2*B+1 within tile)

Multi-tile sprite tile code layout (row-major):
  full_tile = sprite.tile_num + tile_row * tiles_wide + tile_col
  where tiles_wide = 1 << sprite.size  (capped at 16)

Flip:
  flip_y: row_in_sprite = (sprite_height - 1) - raw_row
  flip_x: sprite pixels mirrored horizontally

Transparency: nibble == 0 → pixel is transparent (not written to buffer)

Priority: sprite.prio stored per-pixel alongside color.

References:
  MAME src/mame/psikyo/psikyo_gfx.cpp — sprite drawing logic
  chips/psikyo/GATE_PLAN.md            — Psikyo gate specification
"""

from dataclasses import dataclass, field
from typing import List

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

SCREEN_W      = 320
SPR_ROM_BYTES = 1 << 24   # 16 MB addressable (24-bit addr)
MAX_TILES_WIDE = 16       # size=4 → 16×16 tiles


# ─────────────────────────────────────────────────────────────────────────────
# Sprite entry (mirrors psikyo_sprite_t in psikyo.sv)
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class PsikyoSpriteEntry:
    x:         int  = 0
    y:         int  = 0
    tile_num:  int  = 0
    flip_x:    bool = False
    flip_y:    bool = False
    prio:      int  = 0    # [1:0]
    size:      int  = 0    # 0=16×16 .. 4=256×256
    palette:   int  = 0    # [3:0]
    valid:     bool = False


# ─────────────────────────────────────────────────────────────────────────────
# Sprite ROM model
# ─────────────────────────────────────────────────────────────────────────────

class SpriteROM:
    """Software sprite ROM: byte-addressable, 4bpp packed (2 pixels/byte)."""

    def __init__(self):
        self._rom = bytearray(SPR_ROM_BYTES)

    def write_byte(self, addr: int, val: int) -> None:
        if 0 <= addr < SPR_ROM_BYTES:
            self._rom[addr] = val & 0xFF

    def read_byte(self, addr: int) -> int:
        if 0 <= addr < SPR_ROM_BYTES:
            return self._rom[addr]
        return 0

    def load_solid_tile(self, tile_code: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = ((nybble & 0xF) << 4) | (nybble & 0xF)
        base = tile_code * 128
        for b in range(128):
            self._rom[base + b] = byte_val

    def load_tile_row(self, tile_code: int, row: int, nybbles: List[int]) -> None:
        """Write 16 nybble values for one tile row.
        nybbles[0] = leftmost pixel.
        Packing: byte b → lo=nybbles[2b], hi=nybbles[2b+1].
        """
        assert len(nybbles) == 16, f"Expected 16 nybbles, got {len(nybbles)}"
        base = tile_code * 128 + row * 8
        for b in range(8):
            lo = nybbles[b * 2] & 0xF
            hi = nybbles[b * 2 + 1] & 0xF
            self._rom[base + b] = (hi << 4) | lo

    def get_tile_row_pixels(self, tile_code: int, row: int) -> List[int]:
        """Return 16 nybble values for tile_code row `row`.
        Pixel 0 is leftmost (low nibble of byte 0).
        """
        base = tile_code * 128 + row * 8
        pixels = []
        for b in range(8):
            byte = self._rom[base + b]
            pixels.append(byte & 0xF)          # low nibble  = left pixel
            pixels.append((byte >> 4) & 0xF)   # high nibble = right pixel
        return pixels   # 16 values


# ─────────────────────────────────────────────────────────────────────────────
# Pixel buffer entry
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class PixelEntry:
    valid:    bool  = False
    color:    int   = 0    # {palette[3:0], nybble[3:0]} = 8-bit
    priority: int   = 0    # [1:0] sprite priority


# ─────────────────────────────────────────────────────────────────────────────
# Rasterizer model
# ─────────────────────────────────────────────────────────────────────────────

class PsikyoSpriteRasterizer:
    """
    Behavioral model of the Psikyo Gate 3 per-scanline sprite rasterizer.

    Usage:
        rast = PsikyoSpriteRasterizer(rom)
        buf = rast.render_scanline(display_list, display_list_count, current_y)
        pixel = buf[x]
    """

    def __init__(self, rom: SpriteROM):
        self.rom = rom

    @staticmethod
    def tiles_wide(size: int) -> int:
        """Return tiles_wide from size field (capped at MAX_TILES_WIDE)."""
        if size > 4:
            return 1
        return min(1 << size, MAX_TILES_WIDE)

    def render_scanline(self, display_list: List[PsikyoSpriteEntry],
                        display_list_count: int,
                        current_y: int) -> List[PixelEntry]:
        """
        Render one scanline.

        Sprites are drawn in display_list order; later sprites overwrite
        earlier ones (last-writer wins, matching RTL FSM behavior).

        Returns list of SCREEN_W PixelEntry.
        """
        buf = [PixelEntry() for _ in range(SCREEN_W)]

        for idx in range(display_list_count):
            e = display_list[idx]
            if not e.valid:
                continue

            tw         = self.tiles_wide(e.size)
            px_width   = tw * 16
            px_height  = px_width   # square sprites

            # Check if sprite intersects current_y
            if not (e.y <= current_y < e.y + px_height):
                continue

            raw_row = current_y - e.y

            # Apply flip_y
            if e.flip_y:
                row_in_spr = (px_height - 1) - raw_row
            else:
                row_in_spr = raw_row

            tile_row    = row_in_spr >> 4    # row_in_spr // 16
            row_in_tile = row_in_spr & 0xF   # row_in_spr % 16

            # Iterate tile columns
            for tc in range(tw):
                full_tile = e.tile_num + tile_row * tw + tc

                # Fetch 16 pixels for this tile row
                pixels = self.rom.get_tile_row_pixels(full_tile, row_in_tile)

                for px_in_tile in range(16):
                    # Apply flip_x (mirror within entire sprite width)
                    if e.flip_x:
                        sprite_px    = (px_width - 1) - (tc * 16 + px_in_tile)
                        eff_tc       = sprite_px // 16
                        eff_px_in_tc = sprite_px % 16
                        nybble = self.rom.get_tile_row_pixels(
                            e.tile_num + tile_row * tw + eff_tc,
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
                            priority = e.prio,
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
    rast = PsikyoSpriteRasterizer(rom)

    # Test 1: single 16×16 sprite, solid fill
    spr = PsikyoSpriteEntry(x=10, y=20, tile_num=0, palette=3, size=0, valid=True)
    rom.load_solid_tile(0, 0x5)
    display_list = [spr] + [PsikyoSpriteEntry() for _ in range(255)]
    buf = rast.render_scanline(display_list, 1, current_y=20)
    assert buf[10].valid,            f"T1: pixel(10,20) not valid"
    assert buf[10].color == 0x35,    f"T1: color={buf[10].color:#x}, expected 0x35"
    assert not buf[9].valid,         f"T1: pixel(9) should be transparent"
    assert buf[25].valid,            f"T1: pixel(25) should be valid (last)"
    assert not buf[26].valid,        f"T1: pixel(26) should be transparent"
    print("Test1 PASS: single 16x16 solid sprite")

    # Test 2: flip_x
    rom2  = SpriteROM()
    rast2 = PsikyoSpriteRasterizer(rom2)
    row0  = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    rom2.load_tile_row(1, 0, row0)
    spr2  = PsikyoSpriteEntry(x=0, y=0, tile_num=1, palette=1, size=0, flip_x=True, valid=True)
    dl2   = [spr2] + [PsikyoSpriteEntry() for _ in range(255)]
    buf2  = rast2.render_scanline(dl2, 1, current_y=0)
    assert buf2[0].valid,              f"T2: pixel(0) not valid"
    assert buf2[0].color  == 0x11,     f"T2: px0 color={buf2[0].color:#x}, expected 0x11"
    assert buf2[1].color  == 0x1F,     f"T2: px1 color={buf2[1].color:#x}, expected 0x1F"
    assert buf2[15].color == 0x11,     f"T2: px15 color={buf2[15].color:#x}, expected 0x11"
    print("Test2 PASS: flip_x")

    # Test 3: flip_y
    rom3  = SpriteROM()
    rast3 = PsikyoSpriteRasterizer(rom3)
    rom3.load_tile_row(2, 0,  [0xA] * 16)
    rom3.load_tile_row(2, 15, [0xB] * 16)
    spr3  = PsikyoSpriteEntry(x=0, y=0, tile_num=2, palette=2, size=0, flip_y=True, valid=True)
    dl3   = [spr3] + [PsikyoSpriteEntry() for _ in range(255)]
    buf3  = rast3.render_scanline(dl3, 1, current_y=0)
    assert buf3[0].color == 0x2B, f"T3: flip_y y=0 color={buf3[0].color:#x}, expected 0x2B"
    buf3b = rast3.render_scanline(dl3, 1, current_y=15)
    assert buf3b[0].color == 0x2A, f"T3: flip_y y=15 color={buf3b[0].color:#x}, expected 0x2A"
    print("Test3 PASS: flip_y")

    # Test 4: 32×32 multi-tile sprite (size=1)
    rom4  = SpriteROM()
    rast4 = PsikyoSpriteRasterizer(rom4)
    rom4.load_solid_tile(4, 0x1)   # top-left
    rom4.load_solid_tile(5, 0x2)   # top-right
    rom4.load_solid_tile(6, 0x3)   # bottom-left
    rom4.load_solid_tile(7, 0x4)   # bottom-right
    spr4  = PsikyoSpriteEntry(x=0, y=0, tile_num=4, palette=5, size=1, valid=True)
    dl4   = [spr4] + [PsikyoSpriteEntry() for _ in range(255)]
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
    rast5 = PsikyoSpriteRasterizer(rom5)
    rom5.load_solid_tile(10, 0)
    spr5  = PsikyoSpriteEntry(x=5, y=5, tile_num=10, palette=7, size=0, valid=True)
    dl5   = [spr5] + [PsikyoSpriteEntry() for _ in range(255)]
    buf5  = rast5.render_scanline(dl5, 1, current_y=5)
    for x in range(5, 21):
        assert not buf5[x].valid, f"T5: pixel({x}) should be transparent"
    print("Test5 PASS: transparent sprite")

    # Test 6: sprite outside scanline (Y-miss)
    rom6  = SpriteROM()
    rast6 = PsikyoSpriteRasterizer(rom6)
    rom6.load_solid_tile(11, 0xF)
    spr6  = PsikyoSpriteEntry(x=0, y=50, tile_num=11, palette=1, size=0, valid=True)
    dl6   = [spr6] + [PsikyoSpriteEntry() for _ in range(255)]
    buf6  = rast6.render_scanline(dl6, 1, current_y=0)
    for x in range(16):
        assert not buf6[x].valid, f"T6: pixel({x}) should be transparent (scanline miss)"
    print("Test6 PASS: Y-miss (sprite outside scanline)")

    # Test 7: multiple sprites on same scanline (later overwrites earlier)
    rom7  = SpriteROM()
    rast7 = PsikyoSpriteRasterizer(rom7)
    rom7.load_solid_tile(20, 0x6)
    rom7.load_solid_tile(21, 0xA)
    spr7a = PsikyoSpriteEntry(x=0, y=0, tile_num=20, palette=1, size=0, valid=True)
    spr7b = PsikyoSpriteEntry(x=8, y=0, tile_num=21, palette=2, size=0, valid=True)
    dl7   = [spr7a, spr7b] + [PsikyoSpriteEntry() for _ in range(254)]
    buf7  = rast7.render_scanline(dl7, 2, current_y=0)
    assert buf7[0].color  == 0x16, f"T7: px0  color={buf7[0].color:#x}, expected 0x16"
    assert buf7[7].color  == 0x16, f"T7: px7  color={buf7[7].color:#x}, expected 0x16"
    assert buf7[8].color  == 0x2A, f"T7: px8  color={buf7[8].color:#x}, expected 0x2A"
    assert buf7[15].color == 0x2A, f"T7: px15 color={buf7[15].color:#x}, expected 0x2A"
    print("Test7 PASS: multiple sprites overlapping")

    # Test 8: sprite at right screen edge
    rom8  = SpriteROM()
    rast8 = PsikyoSpriteRasterizer(rom8)
    rom8.load_solid_tile(30, 0xC)
    spr8  = PsikyoSpriteEntry(x=304, y=0, tile_num=30, palette=6, size=0, valid=True)
    dl8   = [spr8] + [PsikyoSpriteEntry() for _ in range(255)]
    buf8  = rast8.render_scanline(dl8, 1, current_y=0)
    assert buf8[304].valid,        f"T8: pixel(304) not valid"
    assert buf8[319].valid,        f"T8: pixel(319) not valid"
    assert not buf8[303].valid,    f"T8: pixel(303) should be transparent"
    print("Test8 PASS: sprite at right screen edge")

    # Test 9: priority field is stored per-pixel
    rom9  = SpriteROM()
    rast9 = PsikyoSpriteRasterizer(rom9)
    rom9.load_solid_tile(40, 0x7)
    spr9  = PsikyoSpriteEntry(x=0, y=0, tile_num=40, palette=0, prio=3, size=0, valid=True)
    dl9   = [spr9] + [PsikyoSpriteEntry() for _ in range(255)]
    buf9  = rast9.render_scanline(dl9, 1, current_y=0)
    assert buf9[0].priority == 3, f"T9: priority={buf9[0].priority}, expected 3"
    print("Test9 PASS: priority stored per pixel")

    # Test 10: invalid entry is skipped
    rom10  = SpriteROM()
    rast10 = PsikyoSpriteRasterizer(rom10)
    rom10.load_solid_tile(50, 0x9)
    spr10  = PsikyoSpriteEntry(x=0, y=0, tile_num=50, palette=0, size=0, valid=False)
    dl10   = [spr10] + [PsikyoSpriteEntry() for _ in range(255)]
    buf10  = rast10.render_scanline(dl10, 1, current_y=0)
    for x in range(16):
        assert not buf10[x].valid, f"T10: pixel({x}) should be transparent (invalid entry)"
    print("Test10 PASS: invalid entry skipped")

    print("\ngate3_model self-test PASS")
