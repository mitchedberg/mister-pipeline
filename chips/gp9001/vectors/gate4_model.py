#!/usr/bin/env python3
"""
gate4_model.py — GP9001 Gate 4 behavioral model: per-scanline sprite rasterizer.

Takes the display_list produced by Gate 2 and, for a given scanline Y, renders
all sprites that intersect that scanline into a 320-pixel scanline buffer.

Sprite size encoding (matching Gate 2 sprite_entry_t):
  size=0: 1 tile  wide × 1 tile  tall  = 16×16 px
  size=1: 2 tiles wide × 2 tiles tall  = 32×32 px
  size=2: 4 tiles wide × 4 tiles tall  = 64×64 px
  size=3: 8 tiles wide × 8 tiles tall  = 128×128 px

Sprite ROM layout (4bpp packed, 2 pixels per byte):
  One 16×16 tile = 128 bytes (16 rows × 8 bytes/row).
  Tile T, row R (0..15), byte B (0..7):
    addr = T * 128 + R * 8 + B
  Within the byte:
    low  nibble [3:0] = left  pixel (screen X offset 0 for this pair)
    high nibble [7:4] = right pixel (screen X offset 1 for this pair)

Multi-tile sprite tile code layout (row-major):
  Full tile code for tile column tc, tile row tr:
    full_tile = sprite.tile_num + tr * tiles_wide + tc
  where tiles_wide = 1 << sprite.size

Flip:
  flip_y: row_in_sprite = (sprite_height - 1) - raw_row  (before tile/row decomp)
  flip_x: pixels within sprite are mirrored horizontally

Transparency: nibble == 0 → pixel is transparent (not written to buffer)

Priority: sprite.prio bit is stored per-pixel in the buffer.

References:
  MAME src/mame/toaplan/gp9001.cpp — rasterize_sprite_pixel(), screen_update()
  section2_behavior.md §2.2 — per-scanline sprite rasterization algorithm
"""

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

SCREEN_W        = 320     # active pixels per scanline
SPRITE_ROM_BYTES = 1 << 21   # 2 MB max (tile codes up to 1023 × 128 bytes)


# ─────────────────────────────────────────────────────────────────────────────
# Sprite entry (matches Gate 2 sprite_entry_t / gate2_model.SpriteEntry)
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class SpriteEntry:
    x:        int   = 0
    y:        int   = 0
    tile_num: int   = 0
    flip_x:   bool  = False
    flip_y:   bool  = False
    prio:     bool  = False
    palette:  int   = 0
    size:     int   = 0    # 0=16×16, 1=32×32, 2=64×64, 3=128×128
    valid:    bool  = False


# ─────────────────────────────────────────────────────────────────────────────
# Sprite ROM model
# ─────────────────────────────────────────────────────────────────────────────

class SpriteROM:
    """Software sprite ROM: byte-addressable, 4bpp packed (2 pixels/byte)."""

    def __init__(self):
        self._rom = [0] * SPRITE_ROM_BYTES

    def write_byte(self, addr: int, val: int) -> None:
        if 0 <= addr < SPRITE_ROM_BYTES:
            self._rom[addr] = val & 0xFF

    def read_byte(self, addr: int) -> int:
        if 0 <= addr < SPRITE_ROM_BYTES:
            return self._rom[addr]
        return 0

    def write_tile_pixel(self, tile_code: int, row: int, px: int, nybble: int) -> None:
        """Write one 4-bit pixel to a 16×16 tile.
        row: 0..15, px: 0..15, nybble: 0..15.
        Packed: byte_idx = row*8 + px//2; low nibble = even px, high = odd px.
        """
        addr = tile_code * 128 + row * 8 + px // 2
        cur = self._rom[addr]
        if px & 1:
            self._rom[addr] = (cur & 0x0F) | ((nybble & 0xF) << 4)
        else:
            self._rom[addr] = (cur & 0xF0) | (nybble & 0xF)

    def load_tile_row(self, tile_code: int, row: int, nybbles: List[int]) -> None:
        """Write 16 nybble values for one tile row (nybbles[0]=leftmost pixel)."""
        assert len(nybbles) == 16
        base = tile_code * 128 + row * 8
        for b in range(8):
            lo = nybbles[b * 2]
            hi = nybbles[b * 2 + 1]
            self._rom[base + b] = (hi << 4) | lo

    def load_solid_tile(self, tile_code: int, nybble: int) -> None:
        """Fill all 16×16 pixels of a tile with a single 4-bit value."""
        byte_val = (nybble << 4) | nybble
        base = tile_code * 128
        for b in range(128):
            self._rom[base + b] = byte_val

    def get_tile_row_pixels(self, tile_code: int, row: int) -> List[int]:
        """Return 16 nybble values for tile_code row `row`.
        Pixel 0 is leftmost (low nibble of byte 0).
        """
        base = tile_code * 128 + row * 8
        pixels = []
        for b in range(8):
            byte = self._rom[base + b]
            pixels.append(byte & 0xF)          # low nibble = left pixel
            pixels.append((byte >> 4) & 0xF)   # high nibble = right pixel
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

class GP9001SpriteRasterizer:
    """
    Behavioral model of the GP9001 Gate 4 per-scanline sprite rasterizer.

    Usage:
        rast = GP9001SpriteRasterizer(rom)
        # populate display_list: list of SpriteEntry (from Gate 2 model)
        buf = rast.render_scanline(display_list, display_list_count, current_y)
        # buf is a list of 320 PixelEntry
        pixel = buf[x]   # check pixel at screen X = x
    """

    def __init__(self, rom: SpriteROM):
        self.rom = rom

    def _sprite_dims(self, size: int) -> Tuple[int, int]:
        """Return (tiles_wide, pixel_width) for size code 0..3."""
        tiles_wide = 1 << size
        return tiles_wide, tiles_wide * 16

    def render_scanline(self, display_list: List[SpriteEntry],
                        display_list_count: int,
                        current_y: int) -> List[PixelEntry]:
        """
        Render one scanline.

        Sprites are drawn in display_list order; later sprites can overwrite
        earlier ones (last-writer wins, matching RTL FSM behavior).

        Returns list of 320 PixelEntry.
        """
        buf = [PixelEntry() for _ in range(SCREEN_W)]

        for idx in range(display_list_count):
            e = display_list[idx]
            if not e.valid:
                continue

            tiles_wide, px_width = self._sprite_dims(e.size)
            px_height = px_width  # square sprites

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

            # Decompose row_in_spr into tile row and row within tile
            tile_row   = row_in_spr >> 4    # row_in_spr // 16
            row_in_tile = row_in_spr & 0xF  # row_in_spr % 16

            # Iterate tile columns
            for tc in range(tiles_wide):
                full_tile = e.tile_num + tile_row * tiles_wide + tc

                # Fetch 16 pixels for this tile row
                pixels = self.rom.get_tile_row_pixels(full_tile, row_in_tile)
                # pixels[0..15]: pixel 0 = leftmost within the tile

                # Screen X base for this tile column (no flip)
                base_x = e.x + tc * 16

                for px_in_tile in range(16):
                    # Apply flip_x (mirror within entire sprite width)
                    if e.flip_x:
                        # Mirror position within the full sprite width
                        sprite_px = (tiles_wide * 16 - 1) - (tc * 16 + px_in_tile)
                        # Map back to which tile column and which pixel within it
                        eff_tc       = sprite_px // 16
                        eff_px_in_tc = sprite_px % 16
                        nybble = self.rom.get_tile_row_pixels(
                            e.tile_num + tile_row * tiles_wide + eff_tc,
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
    rast = GP9001SpriteRasterizer(rom)

    # --- Test 1: single 16×16 sprite, solid fill ---
    spr = SpriteEntry(x=10, y=20, tile_num=0, palette=3, size=0, valid=True)
    rom.load_solid_tile(0, 0x5)

    display_list = [spr] + [SpriteEntry() for _ in range(255)]
    buf = rast.render_scanline(display_list, 1, current_y=20)

    # Pixel at x=10 should be valid, color = {3, 5} = 0x35
    assert buf[10].valid,            f"Test1: pixel(10,20) not valid"
    assert buf[10].color == 0x35,    f"Test1: color={buf[10].color:#x}, expected 0x35"
    assert buf[10].priority == False, f"Test1: priority should be 0"

    # Pixel at x=9 (before sprite) should be transparent
    assert not buf[9].valid, f"Test1: pixel(9,20) should be transparent"

    # Pixel at x=25 (last pixel of sprite: x=10..25)
    assert buf[25].valid,  f"Test1: pixel(25,20) should be valid (last pixel)"
    # Pixel at x=26 (just after sprite)
    assert not buf[26].valid, f"Test1: pixel(26,20) should be transparent"

    print("Test1 PASS: single 16×16 solid sprite")

    # --- Test 2: flip_x ---
    rom2 = SpriteROM()
    rast2 = GP9001SpriteRasterizer(rom2)

    # Tile 1 row 0: pixels 0..15 = nybbles [1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,1]
    row0 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    rom2.load_tile_row(1, 0, row0)

    spr2 = SpriteEntry(x=0, y=0, tile_num=1, palette=1, size=0, flip_x=True, valid=True)
    dl2 = [spr2] + [SpriteEntry() for _ in range(255)]
    buf2 = rast2.render_scanline(dl2, 1, current_y=0)

    # With flip_x=True: screen pixel 0 gets nybble from sprite pixel 15 = 1
    # screen pixel 1 gets sprite pixel 14 = 0xF
    assert buf2[0].valid,               f"Test2: pixel(0) should be valid"
    assert buf2[0].color == 0x11,       f"Test2: px0 color={buf2[0].color:#x}, expected 0x11"
    assert buf2[1].color == 0x1F,       f"Test2: px1 color={buf2[1].color:#x}, expected 0x1F"
    assert buf2[15].color == (0x10 | 1),f"Test2: px15 color={buf2[15].color:#x}, expected 0x11"

    print("Test2 PASS: flip_x")

    # --- Test 3: flip_y ---
    rom3 = SpriteROM()
    rast3 = GP9001SpriteRasterizer(rom3)

    # Tile 2 row 0 = nybble 0xA, row 15 = nybble 0xB
    rom3.load_tile_row(2, 0,  [0xA] * 16)
    rom3.load_tile_row(2, 15, [0xB] * 16)

    spr3 = SpriteEntry(x=0, y=0, tile_num=2, palette=2, size=0, flip_y=True, valid=True)
    dl3 = [spr3] + [SpriteEntry() for _ in range(255)]

    # With flip_y=True: scanline y=0 maps to tile row 15 → nybble 0xB
    buf3 = rast3.render_scanline(dl3, 1, current_y=0)
    assert buf3[0].color == 0x2B, f"Test3: flip_y y=0 color={buf3[0].color:#x}, expected 0x2B"

    # Scanline y=15 maps to tile row 0 → nybble 0xA
    buf3b = rast3.render_scanline(dl3, 1, current_y=15)
    assert buf3b[0].color == 0x2A, f"Test3: flip_y y=15 color={buf3b[0].color:#x}, expected 0x2A"

    print("Test3 PASS: flip_y")

    # --- Test 4: 32×32 sprite (size=1, 2×2 tiles) ---
    rom4 = SpriteROM()
    rast4 = GP9001SpriteRasterizer(rom4)

    # Sprite base = tile 4, size=1 → 2×2 tiles.
    # Tile layout: [4]=top-left, [5]=top-right, [6]=bot-left, [7]=bot-right
    # Fill each with a distinct nybble:
    rom4.load_solid_tile(4, 0x1)  # top-left
    rom4.load_solid_tile(5, 0x2)  # top-right
    rom4.load_solid_tile(6, 0x3)  # bottom-left
    rom4.load_solid_tile(7, 0x4)  # bottom-right

    spr4 = SpriteEntry(x=0, y=0, tile_num=4, palette=5, size=1, valid=True)
    dl4 = [spr4] + [SpriteEntry() for _ in range(255)]

    # Scanline 0 → top row of tiles (tile_row=0): tile[4] and tile[5]
    # pixel x=0..15 → tile 4 (nybble 0x1), color = {5, 1} = 0x51
    # pixel x=16..31 → tile 5 (nybble 0x2), color = {5, 2} = 0x52
    buf4 = rast4.render_scanline(dl4, 1, current_y=0)
    assert buf4[0].color  == 0x51, f"Test4: px0 color={buf4[0].color:#x}"
    assert buf4[16].color == 0x52, f"Test4: px16 color={buf4[16].color:#x}"

    # Scanline 16 → bottom row of tiles (tile_row=1): tile[6] and tile[7]
    buf4b = rast4.render_scanline(dl4, 1, current_y=16)
    assert buf4b[0].color  == 0x53, f"Test4: bottom-left px0={buf4b[0].color:#x}"
    assert buf4b[16].color == 0x54, f"Test4: bottom-right px16={buf4b[16].color:#x}"

    # Pixels beyond sprite (x=32) should be transparent
    assert not buf4b[32].valid, f"Test4: pixel(32) should be transparent"

    print("Test4 PASS: 32×32 multi-tile sprite")

    # --- Test 5: transparency ---
    rom5 = SpriteROM()
    rast5 = GP9001SpriteRasterizer(rom5)

    rom5.load_solid_tile(10, 0)  # all transparent
    spr5 = SpriteEntry(x=5, y=5, tile_num=10, palette=7, size=0, valid=True)
    dl5 = [spr5] + [SpriteEntry() for _ in range(255)]
    buf5 = rast5.render_scanline(dl5, 1, current_y=5)

    for x in range(5, 21):
        assert not buf5[x].valid, f"Test5: pixel({x}) should be transparent (nybble=0)"
    print("Test5 PASS: transparent sprite")

    # --- Test 6: sprite outside scanline ---
    rom6 = SpriteROM()
    rast6 = GP9001SpriteRasterizer(rom6)

    rom6.load_solid_tile(11, 0xF)
    spr6 = SpriteEntry(x=0, y=50, tile_num=11, palette=1, size=0, valid=True)
    dl6 = [spr6] + [SpriteEntry() for _ in range(255)]
    buf6 = rast6.render_scanline(dl6, 1, current_y=0)   # scanline 0, sprite at y=50

    for x in range(16):
        assert not buf6[x].valid, f"Test6: pixel({x}) should be transparent (scanline miss)"
    print("Test6 PASS: sprite outside scanline")

    # --- Test 7: priority bit ---
    rom7 = SpriteROM()
    rast7 = GP9001SpriteRasterizer(rom7)
    rom7.load_solid_tile(12, 0x8)
    spr7 = SpriteEntry(x=0, y=0, tile_num=12, palette=0xF, size=0, prio=True, valid=True)
    dl7 = [spr7] + [SpriteEntry() for _ in range(255)]
    buf7 = rast7.render_scanline(dl7, 1, current_y=0)
    assert buf7[0].priority == True,  f"Test7: priority should be 1"
    assert buf7[0].color == 0xF8,     f"Test7: color={buf7[0].color:#x}"
    print("Test7 PASS: priority bit")

    print("gate4_model self-test PASS")
