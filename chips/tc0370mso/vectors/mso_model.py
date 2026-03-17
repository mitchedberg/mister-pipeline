"""
TC0370MSO software model.

Implements the sprite scanner algorithm from bshark_draw_sprites_16x8 (MAME taito_z_v.cpp).
Used by generate_vectors.py to produce ground-truth test vectors.
"""

# ─── Video timing ─────────────────────────────────────────────────────────────
H_END   = 320
V_START = 16
V_END   = 256


# ─── Sprite RAM / ROM models ──────────────────────────────────────────────────

class SpriteRAM:
    """0x2000 × 16-bit sprite RAM."""
    def __init__(self):
        self.words = [0] * 0x2000

    def write_entry(self, idx, zoomy, y, priority, color, zoomx, flipy, flipx, x, tilenum):
        """Write one 4-word sprite entry at index idx (0..0x7FF)."""
        base = idx * 4
        self.words[base + 0] = ((zoomy & 0x7F) << 9) | (y & 0x1FF)
        self.words[base + 1] = ((priority & 1) << 15) | ((color & 0xFF) << 7) | (zoomx & 0x3F)
        self.words[base + 2] = ((flipy & 1) << 15) | ((flipx & 1) << 14) | (x & 0x1FF)
        self.words[base + 3] = tilenum & 0x1FFF

    def clear(self):
        self.words = [0] * 0x2000


class SpriteMAPROM:
    """512KB spritemap ROM (0x40000 × 16-bit)."""
    def __init__(self):
        self.words = [0xFFFF] * 0x40000

    def set_chunk(self, tilenum, px, py, code):
        """Set chunk code for sprite tilenum, column px, row py."""
        addr = (tilenum << 5) | (py * 4 + px)
        self.words[addr & 0x3FFFF] = code & 0xFFFF


class OBJRom:
    """4MB OBJ GFX ROM (64-bit wide per tile row)."""
    def __init__(self):
        # Store as bytes; 4MB = 0x400000 bytes
        self.data = bytearray(0x400000)

    def set_tile_row(self, code, row, pixels_16):
        """
        Set 16 pixels for tile `code` at source row `row`.
        pixels_16: list/tuple of 16 four-bit pixel values (0..15).
        Layout: plane0=[15:0], plane1=[31:16], plane2=[47:32], plane3=[63:48].
        pixel x=0 → bit 0 of plane.
        """
        byte_base = code * 64 + row * 8
        plane = [0, 0, 0, 0]
        for x in range(16):
            pix = pixels_16[x] & 0xF
            for p in range(4):
                if pix & (1 << p):
                    plane[p] |= (1 << x)
        # Pack: bytes 0-1 = plane0, 2-3 = plane1, 4-5 = plane2, 6-7 = plane3
        for p in range(4):
            addr = byte_base + p * 2
            self.data[addr]     = plane[p] & 0xFF
            self.data[addr + 1] = (plane[p] >> 8) & 0xFF

    def get_tile_row_64(self, code, row):
        """Return 64-bit integer for tile `code`, source `row`."""
        byte_base = code * 64 + row * 8
        val = 0
        for i in range(8):
            val |= self.data[byte_base + i] << (i * 8)
        return val & 0xFFFFFFFFFFFFFFFF

    def get_pixel(self, code, row, x):
        """Return 4-bit pixel value at (code, row, x)."""
        row64 = self.get_tile_row_64(code, row)
        p0 = (row64 >>  0) & 0xFFFF
        p1 = (row64 >> 16) & 0xFFFF
        p2 = (row64 >> 32) & 0xFFFF
        p3 = (row64 >> 48) & 0xFFFF
        bit = 1 << x
        pix = (
            ((p0 & bit) != 0) |
            (((p1 & bit) != 0) << 1) |
            (((p2 & bit) != 0) << 2) |
            (((p3 & bit) != 0) << 3)
        )
        return pix


# ─── Line buffer ──────────────────────────────────────────────────────────────

class LineBuffer:
    """320 × 13-bit line buffer. pixel[11:0]=palette_index, bit12=priority."""
    TRANSPARENT = 0   # palette_index == 0 → transparent

    def __init__(self):
        self.buf = [[0, 0]] * 256   # [priority, palette_index] per scanline
        self.pixels = [[None] * H_END for _ in range(256)]  # None = transparent

    def clear_scanline(self, vpos):
        self.pixels[vpos] = [None] * H_END

    def write(self, vpos, x, priority, palette_index):
        """Back-to-front: later writes win (overwrite)."""
        if 0 <= x < H_END and 0 <= vpos < 256:
            if palette_index != 0:
                self.pixels[vpos][x] = (priority, palette_index)

    def read(self, vpos, x):
        """Returns (priority, palette_index) or None if transparent."""
        if 0 <= x < H_END and 0 <= vpos < 256:
            return self.pixels[vpos][x]
        return None


# ─── Zoom helpers ─────────────────────────────────────────────────────────────

def sign_extend_9(v):
    """Sign extend 9-bit raw to signed int."""
    v = v & 0x1FF
    if v > 0x140:
        v -= 0x200
    return v


def chunk_geometry(x, y, k, j, zoomx_eff, zoomy_eff):
    """
    Compute per-chunk screen geometry.
    Returns (curx, cury, zx, zy) as integers.
    """
    curx = x + (k * zoomx_eff) // 4
    cury = y + (j * zoomy_eff) // 8
    zx   = x + ((k + 1) * zoomx_eff) // 4 - curx
    zy   = y + ((j + 1) * zoomy_eff) // 8 - cury
    return curx, cury, zx, zy


def zoom_src_x(ox, zx):
    """Map output column ox to source pixel index (0..15)."""
    if zx == 0:
        return 0
    return (ox * 16) // zx


# ─── Renderer ─────────────────────────────────────────────────────────────────

def render_frame(spr_ram, stym_rom, obj_rom, y_offs=7, frame_sel=0):
    """
    Run the sprite scanner for one frame.
    Returns a 256×320 list-of-lists: each element is (priority, palette_index) or None.
    """
    lb = LineBuffer()

    # Determine frame bounds (back-to-front scan)
    if frame_sel:
        last = 0x7FF   # 0x800..0xFFF half
        first = 0x400
        addr_last = 0xFFC
        addr_first = 0x800
    else:
        addr_last  = 0x7FC   # word addresses (entry_addr are word-based in RTL)
        addr_first = 0x000

    # Scan entries back-to-front (RTL uses word addresses; entry i = words 4i..4i+3)
    # Number of entries in half = 0x800 / 4 = 0x200 = 512
    num_entries = 0x200

    for entry_word in range(addr_last, addr_first - 4, -4):
        entry_idx = entry_word // 4

        w0 = spr_ram.words[entry_word + 0]
        w1 = spr_ram.words[entry_word + 1]
        w2 = spr_ram.words[entry_word + 2]
        w3 = spr_ram.words[entry_word + 3]

        zoomy_raw = (w0 >> 9) & 0x7F
        y_raw     = w0 & 0x1FF
        priority  = (w1 >> 15) & 1
        color     = (w1 >> 7) & 0xFF
        zoomx_raw = w1 & 0x3F
        flipy     = (w2 >> 15) & 1
        flipx     = (w2 >> 14) & 1
        x_raw     = w2 & 0x1FF
        tilenum   = w3 & 0x1FFF

        if tilenum == 0:
            continue

        zoomx_eff = zoomx_raw + 1
        zoomy_eff = zoomy_raw + 1

        x = sign_extend_9(x_raw)
        y = sign_extend_9(y_raw)
        y += y_offs
        y += (64 - zoomy_eff)

        map_offset = tilenum << 5

        # Iterate 32 chunks (k=0..3 col, j=0..7 row)
        for chunk in range(32):
            k = chunk % 4
            j = chunk // 4

            # Spritemap px/py with flip
            px = (3 - k) if flipx else k
            py = (7 - j) if flipy else j

            stym_addr = map_offset + py * 4 + px
            code = stym_rom.words[stym_addr & 0x3FFFF]
            if code == 0xFFFF:
                continue

            curx, cury, zx, zy = chunk_geometry(x, y, k, j, zoomx_eff, zoomy_eff)

            # Render 8 rows
            for row in range(8):
                screen_y = cury + row
                if screen_y < 0 or screen_y >= 256:
                    continue

                src_row = (7 - row) if flipy else row

                # Render zx output pixels
                for ox in range(zx):
                    src_x_raw = zoom_src_x(ox, zx)
                    src_x = (15 - src_x_raw) if flipx else src_x_raw

                    pix = obj_rom.get_pixel(code, src_row, src_x)
                    if pix == 0:
                        continue

                    screen_x = curx + ox
                    if screen_x < 0 or screen_x >= H_END:
                        continue

                    palette_idx = color * 16 + pix
                    lb.write(screen_y, screen_x, priority, palette_idx)

    return lb.pixels


# ─── Unit self-test ──────────────────────────────────────────────────────────

if __name__ == '__main__':
    sram   = SpriteRAM()
    stym   = SpriteMAPROM()
    obj    = OBJRom()

    # Write one sprite entry: tilenum=1, x=100, y=80, zoom nominal (63 raw → 64 eff)
    sram.write_entry(idx=0x1FF, zoomy=63, y=80, priority=0, color=5,
                     zoomx=63, flipy=0, flipx=0, x=100, tilenum=1)
    # Spritemap: chunk (px=0,py=0) → code=1
    stym.set_chunk(tilenum=1, px=0, py=0, code=1)
    # OBJ ROM: tile 1, row 0: all pixels = pen 7
    obj.set_tile_row(code=1, row=0, pixels_16=[7]*16)

    pixels = render_frame(sram, stym, obj, y_offs=7)

    # With nominal zoom (64 eff), y_offs=7, zoomy_shift=(64-64)=0:
    # y_screen = 80 + 7 + 0 = 87
    # chunk (k=0,j=0): curx=100, cury=87, zx=16, zy=8
    # Row 0 of chunk (0,0) → screen_y=87, screen_x=100..115, pen=7, color=5
    # palette_idx = 5*16+7 = 87
    ok = True
    for x in range(100, 116):
        p = pixels[87][x]
        if p != (0, 87):
            print(f"FAIL at x={x}: got {p}")
            ok = False
    if ok:
        print("mso_model self-test PASS")
    else:
        print("mso_model self-test FAIL")
        raise SystemExit(1)
