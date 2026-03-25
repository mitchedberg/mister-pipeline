#!/usr/bin/env python3
"""Gate-5 WRAM comparison: Verilator sim vs MAME golden dumps.

Sim binary format (per frame): [4B LE frame#][32KB work RAM][8KB palette RAM]
MAME golden format (per frame): individual file frame_NNNNN.bin = 32KB raw WRAM

Usage:
  python3 gate5_compare.py --sim sim_frames.bin --golden golden/nastar/ [--frames N]
"""
import struct, sys, os, argparse

def load_sim_frames(path):
    """Load all frames from packed sim binary. Returns dict {frame_num: wram_bytes}."""
    SIM_FRAME_SIZE = 4 + 32768 + 8192   # 4B header + 32KB WRAM + 8KB palette
    frames = {}
    data = open(path, 'rb').read()
    offset = 0
    while offset + SIM_FRAME_SIZE <= len(data):
        frame_num = struct.unpack_from('<I', data, offset)[0]
        wram = data[offset+4 : offset+4+32768]
        frames[frame_num] = wram
        offset += SIM_FRAME_SIZE
    return frames

def load_golden_frames(dir_path, max_frames=None):
    """Load MAME golden frames from directory. Returns dict {frame_num: wram_bytes}."""
    frames = {}
    entries = sorted(os.listdir(dir_path))
    for fname in entries:
        if not fname.startswith('frame_') or not fname.endswith('.bin'):
            continue
        num = int(fname[6:11])
        fpath = os.path.join(dir_path, fname)
        data = open(fpath, 'rb').read()
        if len(data) != 32768:
            continue  # skip wrong-size files
        frames[num] = data
        if max_frames and len(frames) >= max_frames:
            break
    return frames

def compare(sim_frames, golden_frames):
    common = sorted(set(sim_frames) & set(golden_frames))
    if not common:
        print("ERROR: no frames in common")
        return

    print(f"Comparing {len(common)} frames ({common[0]}..{common[-1]})")
    print(f"  Sim has {len(sim_frames)} frames, golden has {len(golden_frames)} frames")
    print()

    total_bytes = len(common) * 32768
    total_diffs = 0
    first_diff_frame = None
    perfect_run = 0
    perfect_run_start = common[0]

    for fn in common:
        s = sim_frames[fn]
        g = golden_frames[fn]
        diffs = sum(1 for a, b in zip(s, g) if a != b)
        if diffs > 0:
            total_diffs += diffs
            if first_diff_frame is None:
                first_diff_frame = fn
                perfect_run = fn - perfect_run_start
            if diffs <= 10:
                # Show detail for small divergences
                diff_addrs = [i for i, (a, b) in enumerate(zip(s, g)) if a != b]
                print(f"  Frame {fn:4d}: {diffs:5d} diffs  addr={[hex(0x600000+a) for a in diff_addrs[:5]]}")
            elif fn <= common[0] + 100:
                print(f"  Frame {fn:4d}: {diffs:5d} diffs  ({diffs*100/32768:.2f}%)")

    match_rate = (total_bytes - total_diffs) / total_bytes * 100 if total_bytes > 0 else 100.0
    print()
    print(f"=== Summary ===")
    print(f"  Match rate:      {match_rate:.4f}%")
    print(f"  Total diffs:     {total_diffs} bytes / {total_bytes} total")
    if first_diff_frame is not None:
        print(f"  First diff:      frame {first_diff_frame}")
        print(f"  Perfect frames:  {perfect_run} (frames {perfect_run_start}..{first_diff_frame-1})")
    else:
        print(f"  Perfect match:   ALL {len(common)} frames")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', required=True, help='Sim binary dump file')
    ap.add_argument('--golden', required=True, help='MAME golden dump directory')
    ap.add_argument('--frames', type=int, default=None, help='Max frames to compare')
    args = ap.parse_args()

    print(f"Loading sim frames from {args.sim}...")
    sim = load_sim_frames(args.sim)
    print(f"Loading golden frames from {args.golden}...")
    gold = load_golden_frames(args.golden, args.frames)
    compare(sim, gold)

if __name__ == '__main__':
    main()
