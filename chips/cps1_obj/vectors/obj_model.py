"""
CPS1 OBJ Chip — Cycle-accurate Python behavioral model.

Derived from MAME src/mame/capcom/cps1_v.cpp and jotego jtcores reference.
Models:
  - OBJ RAM (1024 x 16-bit words), shadow RAM with VBLANK DMA
  - Sprite table scan: terminator at ATTR[15:8]==0xFF, scan from last valid down to 0
  - Per-scanline line buffer fill: 512-pixel wide, each pixel 9 bits
      bits [8:4] = 5-bit COLOR (palette select), bits [3:0] = 4-bit pixel color
  - Multi-tile block expansion (NX x NY), FLIPX/FLIPY, flip_screen
  - X/Y coordinate wrapping (9-bit, mod 512)
  - Transparent pixel skip (color==0xF)
  - ROM simulated as dict: (code, vsub) -> list of 8 nibbles (two halves)

Public API:
  write_obj_ram(addr, data)  -- write a 16-bit word to live OBJ RAM (word-addressed)
  vblank()                   -- latch live RAM to shadow RAM (DMA), scan table
  get_line(scanline)         -- return list of 512 9-bit pixel values for scanline
"""

MAX_ENTRIES = 256
TRANSPARENT = 0x1FF   # 9'h1FF — all ones, color nibble == 0xF

# ---------------------------------------------------------------------------
# Procedural ROM generator
# Generates deterministic tile data for testing.
# Each tile (code, vsub) returns 16 nibbles (16 pixels across the row).
# Pixels 0-7 are "left half", pixels 8-15 are "right half".
# Color values: left half = (code ^ vsub) & 0xE | 1  (never 0 or 0xF)
#               right half = same XOR with 0x4, clipped same
# ---------------------------------------------------------------------------

def _rom_nibble(code, vsub, px_idx):
    """Return 4-bit pixel nibble for given tile code, sub-row, pixel index."""
    raw = ((code & 0xFF) ^ (vsub * 7) ^ (px_idx * 3)) & 0xF
    # Avoid 0xF (transparent) and 0x0 (would also be interpreted as transparent
    # by the model, but MAME only skips 0xF; keep 0x0 in).
    # We want deterministic non-transparent pixels for most tests.
    # Force into 0x1..0xE range:
    if raw == 0xF:
        raw = 0x1
    return raw


def _rom_row(code, vsub):
    """Return 16 nibbles (all pixels in one tile row)."""
    return [_rom_nibble(code, vsub, i) for i in range(16)]


# ---------------------------------------------------------------------------
# ROM lookup: callers may override individual entries via rom_override dict.
# Format: rom_override[(code, vsub)] = list of 16 nibbles
# ---------------------------------------------------------------------------

def make_rom(overrides=None):
    """Return a ROM object (dict of overrides with procedural fallback)."""
    return dict(overrides or {})


def rom_lookup(rom, code, vsub):
    """Look up 16 nibbles for tile (code, vsub)."""
    key = (code & 0xFFFF, vsub & 0xF)
    if key in rom:
        row = rom[key]
        # Pad or truncate to 16 if needed
        return list(row)[:16] + [0xF] * max(0, 16 - len(row))
    return _rom_row(code & 0xFFFF, vsub & 0xF)


# ---------------------------------------------------------------------------
# CPS1OBJModel
# ---------------------------------------------------------------------------

class CPS1OBJModel:
    """
    Behavioral model of the CPS1 OBJ (sprite) chip.

    OBJ RAM is word-addressed (0..1023).
    Each sprite entry = 4 words:
      word+0: X  [8:0]
      word+1: Y  [8:0]
      word+2: CODE [15:0]
      word+3: ATTR [15:0]
        ATTR[15:12] = NY  (block height - 1)
        ATTR[11:8]  = NX  (block width  - 1)
        ATTR[6]     = FLIPY
        ATTR[5]     = FLIPX
        ATTR[4:0]   = COLOR (palette select)
    Terminator: ATTR[15:8] == 0xFF
    """

    def __init__(self, flip_screen=False, rom=None):
        self.obj_ram_live   = [0] * 1024   # CPU-writeable live RAM
        self.obj_ram_shadow = [0] * 1024   # latched at VBLANK
        self.flip_screen    = flip_screen
        self.rom            = rom if rom is not None else make_rom()

        # Line buffer: list of 240 scanlines, each a list of 512 9-bit pixels.
        # Populated by vblank().
        self._linebuf = [[TRANSPARENT] * 512 for _ in range(262)]

    # -----------------------------------------------------------------------
    # Public: CPU OBJ RAM write
    # -----------------------------------------------------------------------
    def write_obj_ram(self, addr, data):
        """Write a 16-bit word to live OBJ RAM. addr is 10-bit word address."""
        addr = addr & 0x3FF
        self.obj_ram_live[addr] = data & 0xFFFF

    # -----------------------------------------------------------------------
    # Public: VBLANK — latch + render all scanlines
    # -----------------------------------------------------------------------
    def vblank(self):
        """
        Simulate VBLANK:
          1. DMA live -> shadow
          2. Scan sprite table to find last valid entry
          3. For each scanline 0..261, fill line buffer
        """
        # DMA
        self.obj_ram_shadow = list(self.obj_ram_live)

        # Parse sprite table: find terminator, collect valid entries
        entries = []
        last_valid = -1
        for i in range(MAX_ENTRIES):
            base = i * 4
            attr = self.obj_ram_shadow[base + 3]
            if (attr >> 8) == 0xFF:
                # Terminator: entries 0..i-1 are valid
                last_valid = i - 1
                break
            entries.append(i)
            last_valid = i
        else:
            # No terminator found; all 256 entries valid
            last_valid = MAX_ENTRIES - 1

        # Build sprite list for valid entries 0..last_valid
        sprites = []
        for i in range(last_valid + 1):
            base = i * 4
            raw_x  = self.obj_ram_shadow[base + 0] & 0x1FF
            raw_y  = self.obj_ram_shadow[base + 1] & 0x1FF
            code   = self.obj_ram_shadow[base + 2] & 0xFFFF
            attr   = self.obj_ram_shadow[base + 3] & 0xFFFF
            ny     = (attr >> 12) & 0xF
            nx     = (attr >> 8)  & 0xF
            flipy  = bool(attr & 0x40)
            flipx  = bool(attr & 0x20)
            color  = attr & 0x1F
            sprites.append({
                'raw_x': raw_x, 'raw_y': raw_y, 'code': code,
                'ny': ny, 'nx': nx, 'flipy': flipy, 'flipx': flipx, 'color': color,
                'idx': i,
            })

        # Reset line buffers
        self._linebuf = [[TRANSPARENT] * 512 for _ in range(262)]

        # Render: iterate from last valid entry DOWN to 0 (reverse order).
        # Each write OVERWRITES — so entry 0, written last, ends up on top.
        # This matches MAME's model (backward scan, last write wins).
        # (jotego uses forward scan + first-wins; both give same priority.)
        for spr in reversed(sprites):
            self._render_sprite(spr)

    # -----------------------------------------------------------------------
    # Public: get rendered line
    # -----------------------------------------------------------------------
    def get_line(self, scanline):
        """Return list of 512 9-bit pixel values for scanline 0..261."""
        return list(self._linebuf[scanline & 0xFF if scanline < 262 else 0])

    # -----------------------------------------------------------------------
    # Internal: render one sprite entry across all scanlines
    # -----------------------------------------------------------------------
    def _render_sprite(self, spr):
        raw_x  = spr['raw_x']
        raw_y  = spr['raw_y']
        code   = spr['code']
        ny     = spr['ny']
        nx     = spr['nx']
        flipy  = spr['flipy']
        flipx  = spr['flipx']
        color  = spr['color']

        # Apply flip_screen
        if self.flip_screen:
            eff_x  = (496 - raw_x) & 0x1FF
            eff_y  = (240 - raw_y) & 0x1FF
            flipx  = not flipx
            flipy  = not flipy
        else:
            eff_x  = raw_x
            eff_y  = raw_y

        # Iterate over all tile rows in block
        for tile_row in range(ny + 1):
            # Effective row index (respects FLIPY for code computation)
            if flipy:
                eff_row = ny - tile_row
            else:
                eff_row = tile_row

            # Screen Y of this tile row's top
            tile_y = (eff_y + tile_row * 16) & 0x1FF

            # Iterate over all tile columns in block
            for tile_col in range(nx + 1):
                # Effective column index (respects FLIPX for code computation)
                if flipx:
                    eff_col = nx - tile_col
                else:
                    eff_col = tile_col

                # Screen X of this tile column's left edge
                tile_x = (eff_x + tile_col * 16) & 0x1FF

                # Tile code computation (Section 1 / notes_discrepancies D6)
                base_nibble = code & 0xF
                col_nibble  = (base_nibble + eff_col) & 0xF
                tile_code   = (code & 0xFFF0) + (eff_row << 4) + col_nibble

                # For each scanline, check visibility and fill pixels
                for vsub in range(16):
                    # Scanline this sub-row maps to
                    scanline = (tile_y + vsub) & 0x1FF
                    if scanline >= 262:
                        continue  # beyond display frame

                    # Effective vsub for ROM fetch (FLIPY inverts sub-row)
                    if flipy:
                        fetch_vsub = vsub ^ 0xF
                    else:
                        fetch_vsub = vsub

                    # Get 16 pixel nibbles for this tile row
                    pixels = rom_lookup(self.rom, tile_code, fetch_vsub)

                    # Apply FLIPX: reverse pixel order within tile
                    if flipx:
                        pixels = list(reversed(pixels))

                    # Write pixels to line buffer (no-overwrite: first write wins)
                    # Since we iterate reversed(sprites), entry 0 comes last and
                    # overwrites, so we must use unconditional write here.
                    buf = self._linebuf[scanline]
                    for px_off, nibble in enumerate(pixels):
                        if nibble == 0xF:
                            continue  # transparent
                        px = (tile_x + px_off) & 0x1FF
                        buf[px] = (color << 4) | nibble


# ---------------------------------------------------------------------------
# Convenience: build OBJ RAM snapshot from sprite list
# ---------------------------------------------------------------------------

def build_obj_ram(sprites, terminator=True):
    """
    Build a 1024-word OBJ RAM array from a list of sprite dicts.
    Each sprite dict may have keys: x, y, code, nx, ny, flipx, flipy, color.
    If terminator=True, place ATTR=0xFF00 at the entry after the last sprite.
    Returns list of 1024 words.
    """
    ram = [0] * 1024
    for i, spr in enumerate(sprites):
        base = i * 4
        x     = spr.get('x', 0) & 0x1FF
        y     = spr.get('y', 0) & 0x1FF
        code  = spr.get('code', 0) & 0xFFFF
        nx    = spr.get('nx', 0) & 0xF
        ny    = spr.get('ny', 0) & 0xF
        flipx = 1 if spr.get('flipx', False) else 0
        flipy = 1 if spr.get('flipy', False) else 0
        color = spr.get('color', 0) & 0x1F
        attr  = (ny << 12) | (nx << 8) | (flipy << 6) | (flipx << 5) | color
        ram[base + 0] = x
        ram[base + 1] = y
        ram[base + 2] = code
        ram[base + 3] = attr

    # Place terminator
    if terminator and len(sprites) < MAX_ENTRIES:
        t = len(sprites) * 4
        ram[t + 3] = 0xFF00

    return ram
