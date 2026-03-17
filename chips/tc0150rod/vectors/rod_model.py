"""
rod_model.py — Python behavioral model for TC0150ROD

Implements the MAME tc0150rod.cpp rendering algorithm exactly.
Used by generate_vectors.py to produce JSONL test vectors.

Section references map to section1_registers.md.
"""

import struct

# Video timing (same as TC0480SCP)
H_TOTAL = 424
H_END   = 320   # hblank starts here
V_TOTAL = 262
V_START = 16
V_END   = 256
W       = H_END  # active width

# =============================================================================
# RoadRAM — simple 0x1000-word array
# =============================================================================

class RoadRAM:
    def __init__(self):
        self.words = [0] * 0x1000

    def write16(self, addr, data, be=0x3):
        """Write with byte-enable (be[1]=UDS, be[0]=LDS)."""
        if addr < 0 or addr >= 0x1000:
            raise ValueError(f"RoadRAM write out of range: {addr:#x}")
        w = self.words[addr]
        if be & 2:
            w = (w & 0x00ff) | (data & 0xff00)
        if be & 1:
            w = (w & 0xff00) | (data & 0x00ff)
        self.words[addr] = w

    def read16(self, addr):
        if addr < 0 or addr >= 0x1000:
            raise ValueError(f"RoadRAM read out of range: {addr:#x}")
        return self.words[addr]

    def zero_range(self, base, count):
        for i in range(count):
            self.words[(base + i) & 0xfff] = 0

# =============================================================================
# GFX ROM — 256 × 16-bit tile cache per tile (simulated from full rom array)
# =============================================================================

class RoadROM:
    def __init__(self, size=0x40000):
        """size in words (0x40000 = 512KB / 2)."""
        self.words = [0] * size

    def write16(self, word_addr, data):
        self.words[word_addr] = data & 0xffff

    def read16(self, word_addr):
        return self.words[word_addr] & 0xffff

    def get_tile_cache(self, tile_num):
        """Return 256-word list for tile_num."""
        base = (tile_num & 0x3ff) << 8
        return [self.read16(base + i) for i in range(256)]

# =============================================================================
# Geometry helpers
# =============================================================================

def xoffset_for_center(screen_center):
    """
    Compute xoffset such that road_center == screen_center (0..319).
    road_center = 0x5ff - ((-xoffset + 0xa7) & 0x7ff)
    => (-xoffset + 0xa7) & 0x7ff = 0x5ff - screen_center
    => xoffset = (0xa7 - (0x5ff - screen_center)) & 0x7ff
    """
    needed = (0x5ff - screen_center) & 0x7ff
    return (0xa7 - needed) & 0x7ff

def road_center_from_xoffset(xoffset):
    """Compute road_center from xoffset."""
    return (0x5ff - ((-xoffset + 0xa7) & 0x7ff)) & 0x7ff

# =============================================================================
# 2bpp pixel lookup (section1 §5)
# =============================================================================

def lookup_2bpp(cache_word, xi_low):
    """
    cache_word: 16-bit word
    xi_low:     x_index[2:0]  (0..7)
    returns: 2-bit pixel value (0..3)
    """
    shift = 7 - (xi_low & 7)
    bit1 = (cache_word >> (8 + shift)) & 1
    bit0 = (cache_word >>      shift ) & 1
    return (bit1 << 1) | bit0

# =============================================================================
# Palette color (section1 §6)
# =============================================================================

def pal_color(palette_offs, colbank, e_offs, pixel, road_type):
    """
    palette_offs: 8-bit global offset (0xc0 for dblaxle)
    colbank:      6-bit colbank (0..60, step 4) from (ram[3] & 0xf000)>>10
    e_offs:       2-bit edge offset (0 or 2 from clip bit12, or 0/2/4/6 from body bits12:11)
    pixel:        2-bit pixel from ROM (0..3)
    road_type:    0=standard, 1=contcirc, 2=aquajack
    returns:      12-bit palette index
    """
    if road_type != 0:
        pixel_r = (pixel - 1) & 3
    else:
        pixel_r = pixel
    base_ent = 4 if road_type == 0 else 1
    base_col = (palette_offs + colbank + e_offs) & 0xff
    return (((base_col & 0xff) << 4) | (base_ent & 0xf)) + pixel_r

# =============================================================================
# Road line renderer (section1 §8)
# =============================================================================

TRANSPARENT  = 0x8000
HI_TRANSP    = 0xf000

def render_road(ram, rom, vpos,
                y_offs=-1, palette_offs=0xc0, road_type=0, road_trans=False,
                low_priority=1, high_priority=2):
    """
    Render one scanline of road output.
    Returns: list of 320 × 16-bit words (transparent=0x8000, hi-transp=0xf000, else {0,pri[2:0],pal[11:0]})
    """
    # Read control word (RAM offset 0x0FFF)
    road_ctrl = ram.read16(0x0FFF)

    # Compute base addresses (section1 §3)
    road_a_base = ((y_offs * 4) + ((road_ctrl & 0x0300) << 2)) & 0xfff
    road_b_base = ((y_offs * 4) + ((road_ctrl & 0x0c00) << 0)) & 0xfff
    priority_switch_line = (road_ctrl & 0x00ff) - y_offs

    # Road B enable
    road_b_en = bool(road_ctrl & 0x800) or (road_type == 2)

    # Read Road A RAM entry for this scanline
    idx_a = (road_a_base + vpos * 4) & 0xfff
    roada_clipr    = ram.read16((idx_a + 0) & 0xfff)
    roada_clipl    = ram.read16((idx_a + 1) & 0xfff)
    roada_bodyctrl = ram.read16((idx_a + 2) & 0xfff)
    roada_gfx      = ram.read16((idx_a + 3) & 0xfff)
    colbank_a      = (roada_gfx & 0xf000) >> 10
    tile_a         = roada_gfx & 0x3ff

    # Read Road B RAM entry for this scanline
    idx_b = (road_b_base + vpos * 4) & 0xfff
    roadb_clipr    = ram.read16((idx_b + 0) & 0xfff)
    roadb_clipl    = ram.read16((idx_b + 1) & 0xfff)
    roadb_bodyctrl = ram.read16((idx_b + 2) & 0xfff)
    roadb_gfx      = ram.read16((idx_b + 3) & 0xfff)
    colbank_b      = (roadb_gfx & 0xf000) >> 10
    tile_b         = roadb_gfx & 0x3ff

    # Priority table with modifiers (section1 §7)
    p = [1, 1, 2, 3, 3, 4]
    if roada_bodyctrl & 0x2000: p[2] += 2
    if roadb_bodyctrl & 0x2000: p[2] += 1
    if roada_clipl    & 0x2000: p[3] -= 1
    if roadb_clipl    & 0x2000: p[3] -= 2
    if roada_clipr    & 0x2000: p[4] -= 1
    if roadb_clipr    & 0x2000: p[4] -= 2
    if p[4] == 0:               p[4]  = 1

    # Palette edge offsets
    palroffs_a = 2 if (roada_clipr & 0x1000) else 0
    palloffs_a = 2 if (roada_clipl & 0x1000) else 0
    paloffs_a  = (roada_bodyctrl & 0x1800) >> 11   # 0,1,2,3 → *2 = 0,2,4,6
    palroffs_b = 2 if (roadb_clipr & 0x1000) else 0
    palloffs_b = 2 if (roadb_clipl & 0x1000) else 0
    paloffs_b  = (roadb_bodyctrl & 0x1800) >> 11

    # Road A geometry (section1 §8 step 5)
    xoffset_a   = roada_bodyctrl & 0x7ff
    road_center_a = (0x5ff - ((-xoffset_a + 0xa7) & 0x7ff)) & 0x7ff
    left_edge_a   = road_center_a - (roada_clipl & 0x3ff)
    right_edge_a  = road_center_a + 1 + (roada_clipr & 0x3ff)

    # Road B geometry
    xoffset_b   = roadb_bodyctrl & 0x7ff
    road_center_b = (0x5ff - ((-xoffset_b + 0xa7) & 0x7ff)) & 0x7ff
    left_edge_b   = road_center_b - (roadb_clipl & 0x3ff)
    right_edge_b  = road_center_b + 1 + (roadb_clipr & 0x3ff)

    # Tile caches
    cache_a = rom.get_tile_cache(tile_a) if tile_a != 0 else None
    cache_b = rom.get_tile_cache(tile_b) if tile_b != 0 else None

    roada_line = [TRANSPARENT] * W
    roadb_line = [TRANSPARENT] * W

    # ── Render Road A ──────────────────────────────────────────────────────
    if tile_a != 0:
        # Body (left_edge_a+1 .. right_edge_a-1)
        for x in range(left_edge_a + 1, right_edge_a):
            if x < 0 or x >= W:
                continue
            xi = (0xa7 - xoffset_a + x) & 0x7ff
            # Body line: xi 0x200..0x3ff (second half of tile)
            xi_body = xi | 0x200
            word_idx = xi_body >> 3
            word     = cache_a[word_idx] if word_idx < 256 else 0
            pixel    = lookup_2bpp(word, xi_body & 7)
            if pixel != 0 or not road_trans:
                col = pal_color(palette_offs, colbank_a, paloffs_a * 2, pixel, road_type)
                roada_line[W - 1 - x] = (p[2] << 12) | col
            else:
                roada_line[W - 1 - x] = HI_TRANSP

        # Left edge (left_edge_a .. 0)
        for x in range(left_edge_a, -1, -1):
            if x < 0 or x >= W:
                continue
            xi = (0x1ff - (left_edge_a - x)) & 0x1ff
            word_idx = xi >> 3
            word     = cache_a[word_idx] if word_idx < 256 else 0
            pixel    = lookup_2bpp(word, xi & 7)
            if pixel != 0 or (roada_clipl & 0x8000):
                col = pal_color(palette_offs, colbank_a, palloffs_a, pixel, road_type)
                roada_line[W - 1 - x] = (p[0] << 12) | col

        # Right edge (right_edge_a .. W-1)
        for x in range(right_edge_a, W):
            if x < 0 or x >= W:
                continue
            xi = (0x200 + (x - right_edge_a)) & 0x3ff
            word_idx = xi >> 3
            word     = cache_a[word_idx] if word_idx < 256 else 0
            pixel    = lookup_2bpp(word, xi & 7)
            if pixel != 0 or (roada_clipr & 0x8000):
                col = pal_color(palette_offs, colbank_a, palroffs_a, pixel, road_type)
                roada_line[W - 1 - x] = (p[1] << 12) | col

    # ── Render Road B ──────────────────────────────────────────────────────
    if road_b_en and tile_b != 0:
        # Body
        for x in range(left_edge_b + 1, right_edge_b):
            if x < 0 or x >= W:
                continue
            xi = (0xa7 - xoffset_b + x) & 0x7ff
            # Road B body: only rendered when xi > 0x1ff (section1 §5 Road B note)
            if xi <= 0x1ff:
                continue
            xi_body = xi | 0x200
            word_idx = xi_body >> 3
            word     = (cache_b[word_idx] if cache_b and word_idx < 256 else 0)
            pixel    = lookup_2bpp(word, xi_body & 7)
            if pixel != 0 or not road_trans:
                col = pal_color(palette_offs, colbank_b, paloffs_b * 2, pixel, road_type)
                roadb_line[W - 1 - x] = (p[5] << 12) | col
            else:
                roadb_line[W - 1 - x] = HI_TRANSP

        # Left edge
        for x in range(left_edge_b, -1, -1):
            if x < 0 or x >= W:
                continue
            xi = (0x1ff - (left_edge_b - x)) & 0x1ff
            word_idx = xi >> 3
            word     = (cache_b[word_idx] if cache_b and word_idx < 256 else 0)
            pixel    = lookup_2bpp(word, xi & 7)
            if pixel != 0 or (roadb_clipl & 0x8000):
                col = pal_color(palette_offs, colbank_b, palloffs_b, pixel, road_type)
                roadb_line[W - 1 - x] = (p[3] << 12) | col

        # Right edge
        for x in range(right_edge_b, W):
            if x < 0 or x >= W:
                continue
            xi = (0x200 + (x - right_edge_b)) & 0x3ff
            word_idx = xi >> 3
            word     = (cache_b[word_idx] if cache_b and word_idx < 256 else 0)
            pixel    = lookup_2bpp(word, xi & 7)
            if pixel != 0 or (roadb_clipr & 0x8000):
                col = pal_color(palette_offs, colbank_b, palroffs_b, pixel, road_type)
                roadb_line[W - 1 - x] = (p[4] << 12) | col

    # ── Arbitrate A vs B (section1 §7) ─────────────────────────────────────
    scanline = []
    for i in range(W):
        pa = roada_line[i]
        pb = roadb_line[i]
        if pa == TRANSPARENT:
            scanline.append(pb & 0x8fff)
        elif pb == TRANSPARENT:
            scanline.append(pa & 0x8fff)
        else:
            if (pb & 0x7000) > (pa & 0x7000):
                scanline.append(pb & 0x8fff)
            else:
                scanline.append(pa & 0x8fff)

    return scanline
