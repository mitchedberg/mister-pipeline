#!/usr/bin/env python3
"""
run_sim.py — NMK Arcade simulation runner

Builds (if needed) and runs the Verilator NMK Arcade simulation, dumping one
PPM frame file per vertical sync. Optionally compares frames to reference
screenshots from MAME.

Usage:
  python3 run_sim.py [options]

Options:
  --frames N       Number of frames to simulate (default: 30)
  --prog PATH      Program ROM binary (SDRAM 0x000000)
  --spr PATH       Sprite ROM binary  (SDRAM 0x0C0000)
  --bg PATH        BG tile ROM binary (SDRAM 0x140000)
  --adpcm PATH     ADPCM ROM binary   (SDRAM 0x200000)
  --z80 PATH       Z80 sound ROM binary (SDRAM 0x280000)
  --vcd            Enable VCD trace output (slow)
  --compare DIR    Compare output PPMs to reference PNGs/PPMs in DIR
  --out-dir DIR    Output directory for PPM frames (default: current dir)
  --build          Force rebuild before running
  --no-build       Skip build step

Examples:
  # Simulate 10 frames with no ROMs (NOP CPU, black output proves RTL runs):
  python3 run_sim.py --frames 10

  # Simulate 60 frames with real Thunder Dragon ROMs:
  python3 run_sim.py --frames 60 \\
      --prog roms/tdragon_prog.bin \\
      --spr  roms/tdragon_spr.bin  \\
      --bg   roms/tdragon_bg.bin

  # Compare to MAME reference frames:
  python3 run_sim.py --frames 30 --compare mame_ref/
"""

import argparse
import os
import subprocess
import sys
import glob

# ── PPM comparison helper ────────────────────────────────────────────────────

def read_ppm(path):
    """Read a P6 PPM file, return (width, height, bytes)."""
    with open(path, 'rb') as f:
        data = f.read()
    lines = data.split(b'\n', 3)
    if lines[0] != b'P6':
        raise ValueError(f"Not a P6 PPM: {path}")
    w, h = map(int, lines[1].split())
    # lines[2] is maxval (255), lines[3] is pixel data
    pixels = lines[3]
    return w, h, pixels


def compare_frames(sim_dir, ref_dir):
    """
    Compare sim PPM frames to reference images in ref_dir.
    Reference files can be PPM or PNG (requires PIL/Pillow for PNG).
    Returns (total_frames, matching_frames, total_pixel_diffs) summary.
    """
    sim_frames = sorted(glob.glob(os.path.join(sim_dir, 'frame_*.ppm')))
    if not sim_frames:
        print("No simulation frames found to compare.")
        return 0, 0, 0

    total = 0
    matching = 0
    total_diffs = 0

    for sim_path in sim_frames:
        base = os.path.basename(sim_path)
        stem = os.path.splitext(base)[0]

        # Look for reference: prefer .ppm, fallback to .png
        ref_ppm = os.path.join(ref_dir, base)
        ref_png = os.path.join(ref_dir, stem + '.png')

        ref_path = None
        if os.path.exists(ref_ppm):
            ref_path = ref_ppm
        elif os.path.exists(ref_png):
            ref_path = ref_png

        if ref_path is None:
            continue  # No reference for this frame

        total += 1

        # Load simulation frame
        try:
            sw, sh, spix = read_ppm(sim_path)
        except Exception as e:
            print(f"  WARN: cannot read sim frame {sim_path}: {e}")
            continue

        # Load reference frame
        try:
            if ref_path.endswith('.png'):
                try:
                    from PIL import Image
                    img = Image.open(ref_path).convert('RGB')
                    rw, rh = img.size
                    rpix = img.tobytes()
                except ImportError:
                    print(f"  WARN: PIL not installed, cannot read PNG {ref_path}")
                    continue
            else:
                rw, rh, rpix = read_ppm(ref_path)
        except Exception as e:
            print(f"  WARN: cannot read reference {ref_path}: {e}")
            continue

        if sw != rw or sh != rh:
            print(f"  WARN: size mismatch {sim_path} ({sw}x{sh}) vs {ref_path} ({rw}x{rh})")
            continue

        # Count differing pixels
        n_pixels = sw * sh
        diffs = sum(1 for i in range(n_pixels * 3) if spix[i] != rpix[i]) // 3

        match = (diffs == 0)
        if match:
            matching += 1
            status = 'MATCH'
        else:
            status = f'DIFF  ({diffs}/{n_pixels} pixels differ)'

        total_diffs += diffs
        print(f"  {stem}: {status}")

    return total, matching, total_diffs


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='NMK Arcade Verilator simulation runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--frames',   type=int,  default=30,
                        help='Number of frames to simulate (default: 30)')
    parser.add_argument('--prog',     default=None,
                        help='Program ROM binary (SDRAM 0x000000)')
    parser.add_argument('--spr',      default=None,
                        help='Sprite ROM binary (SDRAM 0x0C0000)')
    parser.add_argument('--bg',       default=None,
                        help='BG tile ROM binary (SDRAM 0x140000)')
    parser.add_argument('--adpcm',    default=None,
                        help='ADPCM ROM binary (SDRAM 0x200000)')
    parser.add_argument('--z80',      default=None,
                        help='Z80 sound ROM binary (SDRAM 0x280000)')
    parser.add_argument('--vcd',      action='store_true',
                        help='Enable VCD trace (slow, creates sim_nmk_arcade.vcd)')
    parser.add_argument('--compare',  default=None, metavar='DIR',
                        help='Compare output frames to reference images in DIR')
    parser.add_argument('--out-dir',  default='.', metavar='DIR',
                        help='Output directory for PPM frames (default: .)')
    parser.add_argument('--build',    action='store_true',
                        help='Force rebuild before running')
    parser.add_argument('--no-build', action='store_true',
                        help='Skip build step')

    args = parser.parse_args()

    # Resolve the sim directory (where this script lives)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Verilator 5 places the binary in obj_dir/; the Makefile symlinks it out.
    # Try the symlink first, fall back to obj_dir/ directly.
    sim_binary = os.path.join(script_dir, 'sim_nmk_arcade')
    if not os.path.exists(sim_binary):
        sim_binary = os.path.join(script_dir, 'obj_dir', 'sim_nmk_arcade')

    # ── Build step ────────────────────────────────────────────────────────────
    if not args.no_build:
        needs_build = args.build or not os.path.exists(sim_binary)
        if needs_build:
            print(f"Building simulator in {script_dir}...")
            result = subprocess.run(
                ['make', '-C', script_dir, 'all'],
                stdout=sys.stdout, stderr=sys.stderr)
            if result.returncode != 0:
                print(f"Build failed (exit {result.returncode})")
                return result.returncode
            print("Build succeeded.")

    if not os.path.exists(sim_binary):
        print(f"Simulator binary not found: {sim_binary}")
        print("Run 'make' in the sim directory first, or use --build.")
        return 1

    # ── Prepare environment ───────────────────────────────────────────────────
    env = os.environ.copy()
    env['N_FRAMES'] = str(args.frames)
    if args.prog:  env['ROM_PROG']  = os.path.abspath(args.prog)
    if args.spr:   env['ROM_SPR']   = os.path.abspath(args.spr)
    if args.bg:    env['ROM_BG']    = os.path.abspath(args.bg)
    if args.adpcm: env['ROM_ADPCM'] = os.path.abspath(args.adpcm)
    if args.z80:   env['ROM_Z80']   = os.path.abspath(args.z80)
    if args.vcd:   env['DUMP_VCD']  = '1'

    # Output directory
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # ── Run simulator ─────────────────────────────────────────────────────────
    print(f"Running simulation: {args.frames} frames...")
    result = subprocess.run(
        [sim_binary],
        env=env,
        cwd=out_dir,          # PPM files land in out_dir
        stdout=sys.stdout,
        stderr=sys.stderr)

    if result.returncode != 0:
        print(f"Simulation exited with code {result.returncode}")
        return result.returncode

    # Count captured frames
    captured = sorted(glob.glob(os.path.join(out_dir, 'frame_*.ppm')))
    print(f"\nSimulation complete. {len(captured)} frame(s) in {out_dir}")

    # ── Optional comparison ───────────────────────────────────────────────────
    if args.compare:
        ref_dir = os.path.abspath(args.compare)
        if not os.path.isdir(ref_dir):
            print(f"Reference directory not found: {ref_dir}")
        else:
            print(f"\nComparing to reference frames in {ref_dir}...")
            total, matching, diffs = compare_frames(out_dir, ref_dir)
            if total == 0:
                print("  No matching reference files found.")
            else:
                pct = 100.0 * matching / total
                print(f"\nComparison: {matching}/{total} frames match exactly ({pct:.1f}%)")
                if diffs > 0:
                    print(f"Total differing pixels across mismatched frames: {diffs}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
