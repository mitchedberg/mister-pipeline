#!/usr/bin/env python3
"""
compare_ram_dumps.py — Format-aware RAM comparison: MAME Lua dump vs Verilator sim dump.

MAME dump format (86028 bytes/frame):
  [0..3]           4B LE frame number
  [4..65539]       64KB Main RAM (0x0B0000-0x0BFFFF — tdragon WRAM, NOT 0x080000 which is I/O)
  [65540..67587]   2KB Palette RAM (0x0C8000-0x0C87FF — 1024 entries × 2B, NMK16 uses first 512)
  [67588..83971]   16KB BG VRAM (0x0CC000-0x0CFFFF)
  [83972..86019]   2KB TX VRAM (0x0D0000-0x0D07FF)
  [86020..86027]   8B Scroll regs (scroll0_x, scroll0_y, scroll1_x, scroll1_y)

SIM dump format (89100 bytes/frame):
  [0..3]           4B LE frame number
  [4..65539]       64KB Work RAM (0x0B0000-0x0BFFFF — tdragon WRAM, matches MAME MainRAM)
  [65540..66563]   1KB Palette RAM (512 entries × 2B big-endian)
  [66564..70659]   4KB Sprite RAM (2048 words × 2B — nmk16 sprite_ram_storage)
  [70660..87043]   16KB BG VRAM (2048 tilemap words padded to 16KB)
  [87044..89091]   2KB TX VRAM (stub zeros)
  [89092..89099]   8B Scroll regs

Usage:
  python3 compare_ram_dumps.py --mame FILE --sim FILE [--frames N] [--verbose]
"""

import argparse
import os
import struct
import sys

# ── Layout constants ──────────────────────────────────────────────────────────

MAME_FRAME = 86028
MAME_REGIONS = {
    'MainRAM': (4,                          65536),  # 64KB
    'Palette': (4 + 65536,                  2048),   # 2KB (1024 entries; first 512 used)
    'BGVRAM':  (4 + 65536 + 2048,           16384),  # 16KB
    'TXVRAM':  (4 + 65536 + 2048 + 16384,   2048),   # 2KB
    'Scroll':  (4 + 65536 + 2048 + 16384 + 2048, 8), # 8B
}

SIM_FRAME = 89100
SIM_REGIONS = {
    'MainRAM': (4,                               65536),  # 64KB
    'Palette': (4 + 65536,                       1024),   # 1KB (512 entries × 2B)
    'SprRAM':  (4 + 65536 + 1024,               4096),   # 4KB sprite RAM
    'BGVRAM':  (4 + 65536 + 1024 + 4096,        16384),  # 16KB (padded)
    'TXVRAM':  (4 + 65536 + 1024 + 4096 + 16384, 2048),  # 2KB stub
    'Scroll':  (4 + 65536 + 1024 + 4096 + 16384 + 2048, 8), # 8B
}

# Verify layout sizes sum correctly
assert sum(v for _, v in MAME_REGIONS.values()) + 4 == MAME_FRAME, \
    f"MAME layout sum mismatch: {sum(v for _,v in MAME_REGIONS.values())+4} != {MAME_FRAME}"
assert sum(v for _, v in SIM_REGIONS.values()) + 4 == SIM_FRAME, \
    f"SIM layout sum mismatch: {sum(v for _,v in SIM_REGIONS.values())+4} != {SIM_FRAME}"


def extract_region(data, offset, size):
    return data[offset:offset + size]


def count_byte_diffs(a, b, n=None):
    """Count differing bytes between a and b, optionally limited to first n bytes."""
    if n is not None:
        a = a[:n]
        b = b[:n]
    length = min(len(a), len(b))
    diffs = sum(1 for i in range(length) if a[i] != b[i])
    return diffs, length


def first_diff_offset(a, b, n=None):
    if n is not None:
        a = a[:n]
        b = b[:n]
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return i
    return -1


def format_region_detail(mame_data, sim_data, label, size, verbose=False):
    """Compare a region pair and return a summary string."""
    diffs, length = count_byte_diffs(mame_data, sim_data, size)
    pct = 100.0 * (length - diffs) / length if length else 0
    first = first_diff_offset(mame_data, sim_data, size)
    status = f"{length - diffs}/{length} bytes match ({pct:.1f}%)"
    if diffs == 0:
        status += " -- EXACT MATCH"
    else:
        status += f", first diff at byte {first}"
        if verbose:
            off = first
            m_bytes = list(mame_data[off:off+8]) if off >= 0 else []
            s_bytes = list(sim_data[off:off+8]) if off >= 0 else []
            status += f"\n      MAME[{off}..+7]: {[hex(x) for x in m_bytes]}"
            status += f"\n      SIM [{off}..+7]: {[hex(x) for x in s_bytes]}"
    return f"  {label:10s}: {status}"


def compare_palette(mame_pal_bytes, sim_pal_bytes):
    """
    Compare palette regions. MAME has 2048 bytes (1024 entries), SIM has 1024 bytes (512 entries).
    NMK16 hardware uses 512 entries. Compare first 512 entries (1024 bytes).
    """
    N_ENTRIES = 512
    N_BYTES = N_ENTRIES * 2
    mame_pal = mame_pal_bytes[:N_BYTES]
    sim_pal = sim_pal_bytes[:N_BYTES]
    diffs, length = count_byte_diffs(mame_pal, sim_pal)
    pct = 100.0 * (length - diffs) / length if length else 0
    first = first_diff_offset(mame_pal, sim_pal)
    status = f"{length - diffs}/{length} bytes match ({pct:.1f}%) [first 512 entries only]"
    if diffs == 0:
        status += " -- EXACT MATCH"
    elif first >= 0:
        entry = first // 2
        status += f", first diff entry #{entry} (byte {first})"
    return f"  {'Palette':10s}: {status}"


def compare_scroll(mame_scroll, sim_scroll):
    """Compare 8 bytes of scroll registers (4 × u16)."""
    diffs, length = count_byte_diffs(mame_scroll, sim_scroll, 8)
    pct = 100.0 * (length - diffs) / length if length else 0

    def parse_scroll(data):
        vals = []
        for i in range(4):
            if i * 2 + 2 <= len(data):
                vals.append(struct.unpack('>H', data[i*2:i*2+2])[0])
        return vals

    mame_vals = parse_scroll(mame_scroll)
    sim_vals = parse_scroll(sim_scroll)
    names = ['scr0_x', 'scr0_y', 'scr1_x', 'scr1_y']
    detail = []
    for i, name in enumerate(names):
        if i < len(mame_vals) and i < len(sim_vals):
            mark = '' if mame_vals[i] == sim_vals[i] else ' <-- DIFF'
            detail.append(f"{name}: MAME={mame_vals[i]:04X} SIM={sim_vals[i]:04X}{mark}")
    status = f"{length - diffs}/{length} bytes match ({pct:.1f}%)"
    if detail:
        status += "\n      " + "  ".join(detail)
    return f"  {'Scroll':10s}: {status}"


def analyze_bgvram(mame_bg, sim_bg, n=16384):
    """Count non-zero entries in BG VRAM."""
    mame_nz = sum(1 for i in range(0, min(n, len(mame_bg)), 2)
                  if i+1 < len(mame_bg) and (mame_bg[i] != 0 or mame_bg[i+1] != 0))
    sim_nz  = sum(1 for i in range(0, min(n, len(sim_bg)), 2)
                  if i+1 < len(sim_bg)  and (sim_bg[i] != 0  or sim_bg[i+1] != 0))
    return mame_nz, sim_nz


def main():
    parser = argparse.ArgumentParser(
        description='Format-aware MAME vs SIM RAM dump comparison (NMK/Thunder Dragon)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument('--mame',    required=True, help='MAME Lua RAM dump binary')
    parser.add_argument('--sim',     required=True, help='Verilator sim RAM dump binary')
    parser.add_argument('--frames',  type=int, default=200, help='Frames to compare (default 200)')
    parser.add_argument('--mame-start', type=int, default=0,
                        help='MAME frame index to start at (default 0)')
    parser.add_argument('--sim-start',  type=int, default=0,
                        help='SIM  frame index to start at (default 0)')
    parser.add_argument('--verbose', action='store_true', help='Show first-diff byte values')
    parser.add_argument('--per-frame', action='store_true',
                        help='Print per-frame region details (can be very long)')
    parser.add_argument('--regions', default='MainRAM,Palette,BGVRAM,Scroll',
                        help='Comma-separated regions to compare (default: MainRAM,Palette,BGVRAM,Scroll)')
    args = parser.parse_args()

    # Validate files
    for path, label in [(args.mame, 'MAME'), (args.sim, 'SIM')]:
        if not os.path.exists(path):
            print(f"ERROR: {label} file not found: {path}", file=sys.stderr)
            return 1

    mame_sz = os.path.getsize(args.mame)
    sim_sz  = os.path.getsize(args.sim)

    mame_total_frames = mame_sz // MAME_FRAME
    sim_total_frames  = sim_sz  // SIM_FRAME

    print(f"MAME dump: {mame_sz:,} bytes = {mame_total_frames} frames @ {MAME_FRAME} B/frame")
    print(f"SIM  dump: {sim_sz:,} bytes = {sim_total_frames} frames @ {SIM_FRAME} B/frame")

    if mame_sz % MAME_FRAME != 0:
        print(f"WARNING: MAME file size not a multiple of {MAME_FRAME} "
              f"(remainder {mame_sz % MAME_FRAME})")
    if sim_sz % SIM_FRAME != 0:
        print(f"WARNING: SIM file size not a multiple of {SIM_FRAME} "
              f"(remainder {sim_sz % SIM_FRAME})")

    n_compare = min(args.frames,
                    mame_total_frames - args.mame_start,
                    sim_total_frames - args.sim_start)

    print(f"\nComparing {n_compare} frames "
          f"(MAME[{args.mame_start}..] vs SIM[{args.sim_start}..])\n")

    # Region selection
    active_regions = [r.strip() for r in args.regions.split(',')]

    # Per-region accumulators
    region_stats = {r: {'match_frames': 0, 'total_bytes_match': 0, 'total_bytes': 0}
                    for r in ['MainRAM', 'Palette', 'BGVRAM', 'TXVRAM', 'Scroll']}

    mainram_match_frames = 0
    first_mainram_diff = None
    first_diff_frame = None
    per_frame_diffs = []

    with open(args.mame, 'rb') as mf, open(args.sim, 'rb') as sf:
        for i in range(n_compare):
            mame_idx = args.mame_start + i
            sim_idx  = args.sim_start + i

            mf.seek(mame_idx * MAME_FRAME)
            sf.seek(sim_idx  * SIM_FRAME)

            mframe = mf.read(MAME_FRAME)
            sframe = sf.read(SIM_FRAME)

            if len(mframe) < MAME_FRAME or len(sframe) < SIM_FRAME:
                print(f"  Frame {i}: short read — stopping")
                break

            # Decode headers
            m_fnum = struct.unpack('<I', mframe[:4])[0]
            s_fnum = struct.unpack('<I', sframe[:4])[0]

            # Extract regions
            m_mainram = extract_region(mframe, *MAME_REGIONS['MainRAM'])
            s_mainram = extract_region(sframe, *SIM_REGIONS['MainRAM'])

            m_palette = extract_region(mframe, *MAME_REGIONS['Palette'])
            s_palette = extract_region(sframe, *SIM_REGIONS['Palette'])

            m_bgvram  = extract_region(mframe, *MAME_REGIONS['BGVRAM'])
            s_bgvram  = extract_region(sframe, *SIM_REGIONS['BGVRAM'])

            m_txvram  = extract_region(mframe, *MAME_REGIONS['TXVRAM'])
            s_txvram  = extract_region(sframe, *SIM_REGIONS['TXVRAM'])

            m_scroll  = extract_region(mframe, *MAME_REGIONS['Scroll'])
            s_scroll  = extract_region(sframe, *SIM_REGIONS['Scroll'])

            # MainRAM comparison
            ram_diffs, ram_len = count_byte_diffs(m_mainram, s_mainram)
            ram_match = (ram_diffs == 0)
            if ram_match:
                mainram_match_frames += 1
            else:
                if first_mainram_diff is None:
                    first_mainram_diff = i
                if first_diff_frame is None:
                    first_diff_frame = i

            # Palette (compare first 512 entries = 1024 bytes)
            pal_diffs, pal_len = count_byte_diffs(m_palette[:1024], s_palette[:1024])

            # BGVRAM comparison
            bg_diffs, bg_len = count_byte_diffs(m_bgvram, s_bgvram)

            # TX VRAM: sim writes zeros, MAME may have data; note but don't score
            tx_diffs, tx_len = count_byte_diffs(m_txvram, s_txvram)

            # Scroll regs
            scroll_diffs, scroll_len = count_byte_diffs(m_scroll, s_scroll, 8)

            per_frame_diffs.append({
                'frame': i,
                'mame_fn': m_fnum,
                'sim_fn': s_fnum,
                'ram_diffs': ram_diffs,
                'pal_diffs': pal_diffs,
                'bg_diffs': bg_diffs,
                'tx_diffs': tx_diffs,
                'scroll_diffs': scroll_diffs,
            })

            # Accumulate stats
            region_stats['MainRAM']['total_bytes_match'] += ram_len - ram_diffs
            region_stats['MainRAM']['total_bytes'] += ram_len
            region_stats['Palette']['total_bytes_match'] += pal_len - pal_diffs
            region_stats['Palette']['total_bytes'] += pal_len
            region_stats['BGVRAM']['total_bytes_match'] += bg_len - bg_diffs
            region_stats['BGVRAM']['total_bytes'] += bg_len
            region_stats['TXVRAM']['total_bytes_match'] += tx_len - tx_diffs
            region_stats['TXVRAM']['total_bytes'] += tx_len
            region_stats['Scroll']['total_bytes_match'] += scroll_len - scroll_diffs
            region_stats['Scroll']['total_bytes'] += scroll_len

            if region_stats['MainRAM']['total_bytes_match'] == region_stats['MainRAM']['total_bytes']:
                region_stats['MainRAM']['match_frames'] += 1
            if region_stats['Palette']['total_bytes_match'] == region_stats['Palette']['total_bytes']:
                region_stats['Palette']['match_frames'] += 1
            if region_stats['BGVRAM']['total_bytes_match'] == region_stats['BGVRAM']['total_bytes']:
                region_stats['BGVRAM']['match_frames'] += 1

            if args.per_frame:
                print(f"\nFrame {i:4d}  (MAME#{m_fnum}, SIM#{s_fnum})")
                if 'MainRAM' in active_regions:
                    print(format_region_detail(m_mainram, s_mainram, 'MainRAM', 65536, args.verbose))
                if 'Palette' in active_regions:
                    print(compare_palette(m_palette, s_palette))
                if 'BGVRAM' in active_regions:
                    m_nz, s_nz = analyze_bgvram(m_bgvram, s_bgvram)
                    print(f"  {'BGVRAM':10s}: {format_region_detail(m_bgvram, s_bgvram, '', 16384, args.verbose).strip()}")
                    print(f"              non-zero words: MAME={m_nz}  SIM={s_nz}")
                if 'Scroll' in active_regions:
                    print(compare_scroll(m_scroll, s_scroll))

    n_frames_compared = len(per_frame_diffs)

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n{'='*70}")
    print(f"  SUMMARY: {n_frames_compared} frames compared")
    print(f"{'='*70}")

    # MainRAM
    ram_exact = sum(1 for f in per_frame_diffs if f['ram_diffs'] == 0)
    ram_total_diffs = sum(f['ram_diffs'] for f in per_frame_diffs)
    ram_total_bytes = 65536 * n_frames_compared
    ram_byte_pct = 100.0 * (ram_total_bytes - ram_total_diffs) / ram_total_bytes if ram_total_bytes else 0
    first_rd = next((f['frame'] for f in per_frame_diffs if f['ram_diffs'] > 0), None)
    print(f"\n  MainRAM (64KB):")
    print(f"    Exact-match frames:  {ram_exact}/{n_frames_compared} ({100.*ram_exact/n_frames_compared:.1f}%)")
    print(f"    Byte accuracy:       {ram_total_bytes - ram_total_diffs:,}/{ram_total_bytes:,} ({ram_byte_pct:.2f}%)")
    print(f"    Total byte diffs:    {ram_total_diffs:,}")
    print(f"    First divergence:    {'none' if first_rd is None else f'frame {first_rd}'}")

    # Palette (512 entries = 1024 bytes compared)
    pal_exact = sum(1 for f in per_frame_diffs if f['pal_diffs'] == 0)
    pal_total_diffs = sum(f['pal_diffs'] for f in per_frame_diffs)
    pal_total_bytes = 1024 * n_frames_compared
    pal_byte_pct = 100.0 * (pal_total_bytes - pal_total_diffs) / pal_total_bytes if pal_total_bytes else 0
    first_pd = next((f['frame'] for f in per_frame_diffs if f['pal_diffs'] > 0), None)
    print(f"\n  Palette (512 entries = 1024 bytes, comparing MAME[0..1023] vs SIM[0..1023]):")
    print(f"    Exact-match frames:  {pal_exact}/{n_frames_compared} ({100.*pal_exact/n_frames_compared:.1f}%)")
    print(f"    Byte accuracy:       {pal_total_bytes - pal_total_diffs:,}/{pal_total_bytes:,} ({pal_byte_pct:.2f}%)")
    print(f"    Total byte diffs:    {pal_total_diffs:,}")
    print(f"    First divergence:    {'none' if first_pd is None else f'frame {first_pd}'}")

    # BGVRAM
    bg_exact = sum(1 for f in per_frame_diffs if f['bg_diffs'] == 0)
    bg_total_diffs = sum(f['bg_diffs'] for f in per_frame_diffs)
    bg_total_bytes = 16384 * n_frames_compared
    bg_byte_pct = 100.0 * (bg_total_bytes - bg_total_diffs) / bg_total_bytes if bg_total_bytes else 0
    first_bgd = next((f['frame'] for f in per_frame_diffs if f['bg_diffs'] > 0), None)
    print(f"\n  BGVRAM (16KB):")
    print(f"    Exact-match frames:  {bg_exact}/{n_frames_compared} ({100.*bg_exact/n_frames_compared:.1f}%)")
    print(f"    Byte accuracy:       {bg_total_bytes - bg_total_diffs:,}/{bg_total_bytes:,} ({bg_byte_pct:.2f}%)")
    print(f"    Total byte diffs:    {bg_total_diffs:,}")
    print(f"    First divergence:    {'none' if first_bgd is None else f'frame {first_bgd}'}")

    # Scroll
    scroll_exact = sum(1 for f in per_frame_diffs if f['scroll_diffs'] == 0)
    scroll_total_diffs = sum(f['scroll_diffs'] for f in per_frame_diffs)
    scroll_total_bytes = 8 * n_frames_compared
    scroll_byte_pct = 100.0 * (scroll_total_bytes - scroll_total_diffs) / scroll_total_bytes if scroll_total_bytes else 0
    first_sd = next((f['frame'] for f in per_frame_diffs if f['scroll_diffs'] > 0), None)
    print(f"\n  Scroll regs (8 bytes = 4 × u16):")
    print(f"    Exact-match frames:  {scroll_exact}/{n_frames_compared} ({100.*scroll_exact/n_frames_compared:.1f}%)")
    print(f"    Byte accuracy:       {scroll_total_bytes - scroll_total_diffs:,}/{scroll_total_bytes:,} ({scroll_byte_pct:.2f}%)")
    print(f"    Total byte diffs:    {scroll_total_diffs:,}")
    print(f"    First divergence:    {'none' if first_sd is None else f'frame {first_sd}'}")

    # TX VRAM (SIM is zeros stub, so report separately)
    tx_total_diffs = sum(f['tx_diffs'] for f in per_frame_diffs)
    tx_total_bytes = 2048 * n_frames_compared
    tx_byte_pct = 100.0 * (tx_total_bytes - tx_total_diffs) / tx_total_bytes if tx_total_bytes else 0
    print(f"\n  TXVRAM (2KB — SIM is zero stub, MAME has live data):")
    print(f"    Byte accuracy:       {tx_total_bytes - tx_total_diffs:,}/{tx_total_bytes:,} ({tx_byte_pct:.2f}%)")
    print(f"    Note: TXVRAM diffs expected (sim has no TX layer yet)")

    # Worst frames for MainRAM
    worst = sorted(per_frame_diffs, key=lambda f: f['ram_diffs'], reverse=True)[:5]
    print(f"\n  Top 5 worst MainRAM frames (by byte diff count):")
    for w in worst:
        if w['ram_diffs'] > 0:
            pct = 100.0 * (65536 - w['ram_diffs']) / 65536
            print(f"    Frame {w['frame']:4d}: {w['ram_diffs']:6,} diffs ({pct:.2f}% match)")
        else:
            print(f"    (all remaining frames are exact matches)")
            break

    # Distribution of diff counts
    diff_buckets = [0, 1, 10, 100, 1000, 10000, 65536]
    print(f"\n  MainRAM diff distribution:")
    exact_count = sum(1 for f in per_frame_diffs if f['ram_diffs'] == 0)
    print(f"    exact (0 diffs):       {exact_count:4d} frames")
    for lo, hi in [(1, 10), (10, 100), (100, 1000), (1000, 10000), (10000, 65537)]:
        count = sum(1 for f in per_frame_diffs if lo <= f['ram_diffs'] < hi)
        print(f"    {lo:6,}-{hi-1:6,} diffs:    {count:4d} frames")

    print(f"\n{'='*70}")
    print(f"  ACCURACY SUMMARY")
    print(f"{'='*70}")
    print(f"  MainRAM:    {ram_byte_pct:6.2f}% byte match   ({ram_exact}/{n_frames_compared} exact frames)")
    print(f"  Palette:    {pal_byte_pct:6.2f}% byte match   ({pal_exact}/{n_frames_compared} exact frames)")
    print(f"  BGVRAM:     {bg_byte_pct:6.2f}% byte match   ({bg_exact}/{n_frames_compared} exact frames)")
    print(f"  Scroll:     {scroll_byte_pct:6.2f}% byte match   ({scroll_exact}/{n_frames_compared} exact frames)")
    print(f"  TXVRAM:     {tx_byte_pct:6.2f}% byte match   (stub zeros vs live data)")
    print(f"{'='*70}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
