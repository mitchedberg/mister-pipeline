#!/usr/bin/env python3
"""
run_sim.py — Taito X (Gigandes) simulation runner

Builds (if needed) and runs the Verilator Taito X simulation, dumping one
PPM frame file per vertical sync. Optionally compares frames to reference
screenshots from MAME.

Usage:
  python3 run_sim.py [options]

Options:
  --frames N       Number of frames to simulate (default: 30)
  --prog PATH      68000 program ROM binary (SDRAM 0x000000, 512KB)
  --z80 PATH       Z80 audio ROM binary     (SDRAM 0x080000, 128KB)
  --gfx PATH       Sprite/GFX ROM binary    (SDRAM 0x100000, up to 4MB)
  --vcd            Enable VCD trace output (slow)
  --compare DIR    Compare output PPMs to reference PNGs/PPMs in DIR
  --out-dir DIR    Output directory for PPM frames (default: current dir)
  --build          Force rebuild before running
  --no-build       Skip build step
  --gigandes-zip ZIP  Auto-extract Gigandes ROMs from gigandes.zip and run

SDRAM layout:
  0x000000 — 68000 program ROM (512KB)
  0x080000 — Z80 audio ROM    (128KB)
  0x100000 — Sprite/GFX ROM  (up to 4MB, X1-001A tile data)

Examples:
  # Simulate 10 frames with no ROMs (black output — proves RTL runs):
  python3 run_sim.py --frames 10

  # Simulate 60 frames with real Gigandes ROMs from ZIP:
  python3 run_sim.py --frames 60 --gigandes-zip /path/to/gigandes.zip

  # Compare to MAME reference frames:
  python3 run_sim.py --frames 30 --compare mame_ref/
"""

import argparse
import os
import subprocess
import sys
import glob
import zipfile
import tempfile

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

        ref_ppm = os.path.join(ref_dir, base)
        ref_png = os.path.join(ref_dir, stem + '.png')

        ref_path = None
        if os.path.exists(ref_ppm):
            ref_path = ref_ppm
        elif os.path.exists(ref_png):
            ref_path = ref_png

        if ref_path is None:
            continue

        total += 1

        try:
            sw, sh, spix = read_ppm(sim_path)
        except Exception as e:
            print(f"  WARN: cannot read sim frame {sim_path}: {e}")
            continue

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
        description='Taito X (Gigandes) Verilator simulation runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--frames',       type=int, default=30,
                        help='Number of frames to simulate (default: 30)')
    parser.add_argument('--prog',         default=None,
                        help='68000 program ROM binary (SDRAM 0x000000)')
    parser.add_argument('--z80',          default=None,
                        help='Z80 audio ROM binary (SDRAM 0x080000)')
    parser.add_argument('--gfx',          default=None,
                        help='Sprite/GFX ROM binary (SDRAM 0x100000)')
    parser.add_argument('--vcd',          action='store_true',
                        help='Enable VCD trace (slow, creates sim_taito_x.vcd)')
    parser.add_argument('--compare',      default=None, metavar='DIR',
                        help='Compare output frames to reference images in DIR')
    parser.add_argument('--out-dir',      default='.', metavar='DIR',
                        help='Output directory for PPM frames (default: .)')
    parser.add_argument('--build',        action='store_true',
                        help='Force rebuild before running')
    parser.add_argument('--no-build',     action='store_true',
                        help='Skip build step')
    parser.add_argument('--gigandes-zip', default=None, metavar='ZIP',
                        help='Auto-extract Gigandes ROMs from gigandes.zip and run')

    args = parser.parse_args()

    # ── Gigandes ZIP extraction ───────────────────────────────────────────────
    _tmpdir = None
    if args.gigandes_zip:
        zip_path = os.path.abspath(args.gigandes_zip)
        if not os.path.exists(zip_path):
            print(f"ERROR: ROM ZIP not found: {zip_path}")
            return 1
        print(f"Extracting Gigandes ROMs from {zip_path}...")
        _tmpdir = tempfile.mkdtemp(prefix='gigandes_sim_')

        # Gigandes (gigandes.zip) ROM file layout.
        # CPU ROM: two 128KB files interleaved on the 16-bit bus.
        #   east_1.10a = D15:D8 (high byte)
        #   east_3.5a  = D7:D0  (low byte)
        #   Interleaved: [hi[0], lo[0], hi[1], lo[1], ...] = 256KB merged
        # Z80 sound ROM: east_5.17d (64KB)
        # GFX ROMs: X1-001A sprite data — four 512KB files concatenated = 2MB
        GIGANDES_FILES = {
            'prog_hi':   ('east_1.10a',),    # 68000 program ROM, D15:D8 (high byte)
            'prog_lo':   ('east_3.5a',),     # 68000 program ROM, D7:D0  (low byte)
            'z80':       ('east_5.17d',),    # Z80 sound ROM (64KB)
            # GFX ROMs: X1-001A sprite data — concatenate in order
            'gfx':       ('east_6.3k', 'east_7.3h', 'east_8.3f', 'east_9.3j'),
        }

        with zipfile.ZipFile(zip_path, 'r') as zf:
            names_in_zip = zf.namelist()
            # Extract all known ROM files
            for slot, files in GIGANDES_FILES.items():
                for fname in files:
                    if fname in names_in_zip:
                        zf.extract(fname, _tmpdir)
                        print(f"  extracted {fname}")
                    else:
                        print(f"  WARN: {fname} not found in ZIP")

        # Interleave CPU ROMs: hi (D15:D8) and lo (D7:D0) into one binary
        hi_path   = os.path.join(_tmpdir, GIGANDES_FILES['prog_hi'][0])
        lo_path   = os.path.join(_tmpdir, GIGANDES_FILES['prog_lo'][0])
        prog_path = os.path.join(_tmpdir, 'gigandes_prog.bin')
        if os.path.exists(hi_path) and os.path.exists(lo_path):
            with open(hi_path, 'rb') as fh, open(lo_path, 'rb') as fl:
                hi_data = fh.read()
                lo_data = fl.read()
            interleaved = bytearray()
            for i in range(min(len(hi_data), len(lo_data))):
                interleaved.append(hi_data[i])  # D15:D8
                interleaved.append(lo_data[i])  # D7:D0
            with open(prog_path, 'wb') as fp:
                fp.write(interleaved)
            print(f"  CPU ROM interleaved: {len(interleaved)} bytes -> {prog_path}")
        else:
            prog_path = None
            print("  WARN: CPU ROMs not found for interleaving")

        # Concatenate GFX ROMs in order
        gfx_path = os.path.join(_tmpdir, 'gigandes_gfx.bin')
        gfx_parts = []
        for fname in GIGANDES_FILES['gfx']:
            p = os.path.join(_tmpdir, fname)
            if os.path.exists(p):
                gfx_parts.append(p)
        if gfx_parts:
            with open(gfx_path, 'wb') as fout:
                for p in gfx_parts:
                    with open(p, 'rb') as fin:
                        fout.write(fin.read())
            print(f"  GFX ROM concatenated: {len(gfx_parts)} files -> {gfx_path}")
        else:
            gfx_path = None
            print("  WARN: GFX ROM files not found")

        # Z80 sound ROM
        z80_path = os.path.join(_tmpdir, GIGANDES_FILES['z80'][0])
        if not os.path.exists(z80_path):
            z80_path = None

        # Set args from extracted files (don't override explicit --prog/--z80/--gfx)
        if not args.prog and prog_path:
            args.prog = prog_path
        if not args.z80 and z80_path:
            args.z80 = z80_path
        if not args.gfx and gfx_path:
            args.gfx = gfx_path

    # Resolve the sim directory (where this script lives)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sim_binary = os.path.join(script_dir, 'sim_taito_x')
    if not os.path.exists(sim_binary):
        sim_binary = os.path.join(script_dir, 'obj_dir', 'sim_taito_x')

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
    if args.prog: env['ROM_PROG'] = os.path.abspath(args.prog)
    if args.z80:  env['ROM_Z80']  = os.path.abspath(args.z80)
    if args.gfx:  env['ROM_GFX']  = os.path.abspath(args.gfx)
    if args.vcd:  env['DUMP_VCD'] = '1'

    # Output directory
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # fx68k requires nanorom.mem and microrom.mem in the CWD of the simulation.
    # Copy them from the HDL source tree into out_dir before running.
    fx68k_dir = os.path.join(script_dir, '..', '..', '..', 'chips', 'm68000', 'hdl', 'fx68k')
    for mem_name in ('nanorom.mem', 'microrom.mem'):
        src = os.path.normpath(os.path.join(fx68k_dir, mem_name))
        dst = os.path.join(out_dir, mem_name)
        if os.path.exists(src) and not os.path.exists(dst):
            import shutil
            shutil.copy2(src, dst)

    # ── Run simulator ─────────────────────────────────────────────────────────
    print(f"Running simulation: {args.frames} frames...")
    result = subprocess.run(
        [sim_binary],
        env=env,
        cwd=out_dir,
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

    # Cleanup temp dir
    if _tmpdir:
        import shutil
        shutil.rmtree(_tmpdir, ignore_errors=True)

    return 0


if __name__ == '__main__':
    sys.exit(main())
