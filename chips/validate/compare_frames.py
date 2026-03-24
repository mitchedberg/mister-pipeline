#!/usr/bin/env python3
"""
compare_frames.py — Pixel-accurate comparison of Verilator sim vs MAME reference frames.

Usage:
  python3 compare_frames.py --sim-dir <dir> --ref-dir <dir> [options]

Options:
  --sim-dir DIR      Directory with sim PPM frames (frame_NNNN.ppm)
  --ref-dir DIR      Directory with MAME reference frames (frame_NNNN.ppm or .png)
  --frames N         Max frames to compare (default: all found)
  --sim-offset N     Start sim frames at this index (default: 0)
  --ref-offset N     Start ref frames at this index (default: 0)
  --diff-dir DIR     Output directory for diff images (default: none)
  --threshold N      Pixel diff threshold per channel (default: 0 = exact match)
  --summary          Print only summary, not per-frame details
  --csv FILE         Write per-frame results to CSV

Output:
  Per-frame: frame number, match/diff, pixel diff count, percentage
  Summary: total frames, exact matches, accuracy %, first divergence frame
"""

import argparse
import os
import sys
import csv

def read_ppm(path):
    """Read P6 PPM, return (width, height, bytes)."""
    with open(path, 'rb') as f:
        data = f.read()
    lines = data.split(b'\n', 3)
    if lines[0] != b'P6':
        raise ValueError(f"Not P6 PPM: {path}")
    w, h = map(int, lines[1].split())
    pixels = lines[3]
    return w, h, pixels

def read_png_as_rgb(path):
    """Read PNG via PIL, return (width, height, bytes)."""
    from PIL import Image
    img = Image.open(path).convert('RGB')
    return img.size[0], img.size[1], img.tobytes()

def read_frame(path):
    """Read PPM or PNG frame."""
    if path.endswith('.png'):
        return read_png_as_rgb(path)
    return read_ppm(path)

def compare_pixels(sim_pix, ref_pix, n_pixels, threshold=0):
    """Compare pixel arrays, return (n_diff_pixels, diff_positions)."""
    diffs = []
    for i in range(n_pixels):
        r_diff = abs(sim_pix[i*3] - ref_pix[i*3])
        g_diff = abs(sim_pix[i*3+1] - ref_pix[i*3+1])
        b_diff = abs(sim_pix[i*3+2] - ref_pix[i*3+2])
        if r_diff > threshold or g_diff > threshold or b_diff > threshold:
            diffs.append(i)
    return len(diffs), diffs

def write_diff_ppm(path, w, h, sim_pix, ref_pix, diff_positions):
    """Write a diff image: red where pixels differ, dim original elsewhere."""
    out = bytearray(w * h * 3)
    diff_set = set(diff_positions)
    for i in range(w * h):
        if i in diff_set:
            out[i*3] = 255      # red
            out[i*3+1] = 0
            out[i*3+2] = 0
        else:
            # Dim the reference image
            out[i*3] = ref_pix[i*3] // 2
            out[i*3+1] = ref_pix[i*3+1] // 2
            out[i*3+2] = ref_pix[i*3+2] // 2
    header = f"P6\n{w} {h}\n255\n".encode()
    with open(path, 'wb') as f:
        f.write(header + bytes(out))

def find_frames(directory, offset=0, max_frames=0):
    """Find frame files in directory, return sorted list of (index, path)."""
    frames = []
    for fname in os.listdir(directory):
        if fname.startswith('frame_') and (fname.endswith('.ppm') or fname.endswith('.png')):
            try:
                idx = int(fname.split('_')[1].split('.')[0])
                frames.append((idx, os.path.join(directory, fname)))
            except (ValueError, IndexError):
                continue
    frames.sort()
    frames = [(idx, path) for idx, path in frames if idx >= offset]
    if max_frames > 0:
        frames = frames[:max_frames]
    return frames

def main():
    parser = argparse.ArgumentParser(description='Compare Verilator sim frames vs MAME reference')
    parser.add_argument('--sim-dir', required=True, help='Sim PPM directory')
    parser.add_argument('--ref-dir', required=True, help='Reference PPM/PNG directory')
    parser.add_argument('--frames', type=int, default=0, help='Max frames to compare')
    parser.add_argument('--sim-offset', type=int, default=0, help='Start sim frame index')
    parser.add_argument('--ref-offset', type=int, default=0, help='Start ref frame index')
    parser.add_argument('--diff-dir', default=None, help='Write diff images here')
    parser.add_argument('--threshold', type=int, default=0, help='Per-channel diff threshold')
    parser.add_argument('--summary', action='store_true', help='Summary only')
    parser.add_argument('--csv', default=None, help='Write CSV results')
    args = parser.parse_args()

    # Find frames
    sim_frames = find_frames(args.sim_dir, args.sim_offset, args.frames)
    ref_frames = find_frames(args.ref_dir, args.ref_offset, args.frames)

    # Build index maps
    sim_map = {idx: path for idx, path in sim_frames}
    ref_map = {idx: path for idx, path in ref_frames}

    # Pair frames: match by relative position (sim[i] vs ref[i])
    sim_indices = sorted(sim_map.keys())
    ref_indices = sorted(ref_map.keys())
    n_compare = min(len(sim_indices), len(ref_indices))
    if args.frames > 0:
        n_compare = min(n_compare, args.frames)

    if n_compare == 0:
        print("No frames to compare.")
        return 1

    # Optional output
    if args.diff_dir:
        os.makedirs(args.diff_dir, exist_ok=True)

    csv_writer = None
    csv_file = None
    if args.csv:
        csv_file = open(args.csv, 'w', newline='')
        csv_writer = csv.writer(csv_file)
        csv_writer.writerow(['sim_frame', 'ref_frame', 'match', 'diff_pixels', 'total_pixels', 'pct_match'])

    # Compare
    exact_matches = 0
    first_divergence = None
    worst_frame = None
    worst_diffs = 0
    total_pixel_diffs = 0

    for i in range(n_compare):
        sim_idx = sim_indices[i]
        ref_idx = ref_indices[i]

        try:
            sw, sh, spix = read_frame(sim_map[sim_idx])
            rw, rh, rpix = read_frame(ref_map[ref_idx])
        except Exception as e:
            if not args.summary:
                print(f"  frame {sim_idx} vs {ref_idx}: ERROR - {e}")
            continue

        if sw != rw or sh != rh:
            if not args.summary:
                print(f"  frame {sim_idx} vs {ref_idx}: SIZE MISMATCH ({sw}x{sh} vs {rw}x{rh})")
            continue

        n_pixels = sw * sh
        n_diffs, diff_pos = compare_pixels(spix, rpix, n_pixels, args.threshold)

        is_match = (n_diffs == 0)
        if is_match:
            exact_matches += 1
        else:
            total_pixel_diffs += n_diffs
            if first_divergence is None:
                first_divergence = sim_idx
            if n_diffs > worst_diffs:
                worst_diffs = n_diffs
                worst_frame = sim_idx

        pct = 100.0 * (n_pixels - n_diffs) / n_pixels if n_pixels else 0

        if not args.summary:
            status = 'MATCH' if is_match else f'DIFF ({n_diffs}/{n_pixels} pixels, {pct:.1f}% match)'
            print(f"  frame {sim_idx:>4d} vs {ref_idx:>4d}: {status}")

        if csv_writer:
            csv_writer.writerow([sim_idx, ref_idx, int(is_match), n_diffs, n_pixels, f"{pct:.2f}"])

        if args.diff_dir and not is_match:
            diff_path = os.path.join(args.diff_dir, f"diff_{sim_idx:04d}.ppm")
            write_diff_ppm(diff_path, sw, sh, spix, rpix, diff_pos)

    if csv_file:
        csv_file.close()

    # Summary
    accuracy = 100.0 * exact_matches / n_compare if n_compare else 0
    print(f"\n{'='*60}")
    print(f"  Frames compared:    {n_compare}")
    print(f"  Exact matches:      {exact_matches}/{n_compare} ({accuracy:.1f}%)")
    print(f"  First divergence:   {f'frame {first_divergence}' if first_divergence is not None else 'none'}")
    print(f"  Worst frame:        {f'frame {worst_frame} ({worst_diffs} pixel diffs)' if worst_frame else 'none'}")
    print(f"  Total pixel diffs:  {total_pixel_diffs:,}")
    print(f"{'='*60}")

    # Exit code: 0 if >=95% match, 1 otherwise
    return 0 if accuracy >= 95.0 else 1

if __name__ == '__main__':
    sys.exit(main())
