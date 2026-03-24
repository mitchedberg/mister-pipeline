#!/usr/bin/env python3
"""
run_sim.py — Taito B (Nastar Warrior) simulation runner

Builds (if needed) and runs the Verilator Taito B simulation, dumping one PPM
frame file per vertical sync. Optionally compares frames to reference
screenshots from MAME.

MAME driver: rastsag2 (MAME name) / nastar (western release name)
ROM ZIP: nastar.zip (from MAME rastsag2 set)

ROM files in nastar.zip:
  b81-08.50  — CPU even ROM (128KB, D[15:8])
  b81-13.31  — CPU odd  ROM (128KB, D[7:0])  -- pair 0 (0x000000-0x03FFFF)
  b81-10.49  — CPU even ROM (128KB, D[15:8])
  b81-09.30  — CPU odd  ROM (128KB, D[7:0])  -- pair 1 (0x040000-0x07FFFF)
  b81-11.37  — Z80 audio ROM (64KB)
  b81-03.14  — GFX ROM low  512KB  (0x000000-0x07FFFF within GFX window)
  b81-04.15  — GFX ROM high 512KB  (0x080000-0x0FFFFF within GFX window)
  b81-02.2   — ADPCM-A samples (512KB)
  b81-01.1   — ADPCM-B samples (512KB)

SDRAM layout (nastar.mra):
  0x000000  CPU program ROM (512KB interleaved, two 128KB even/odd pairs)
  0x080000  Z80 audio ROM (64KB)
  0x100000  TC0180VCU GFX ROM (1MB = b81-03 + b81-04)
  0x200000  ADPCM-A samples (b81-02, 512KB)
  0x280000  ADPCM-B samples (b81-01, 512KB)

Usage:
  python3 run_sim.py [options]

Options:
  --frames N        Number of frames to simulate (default: 30)
  --prog PATH       CPU program ROM binary (SDRAM 0x000000, pre-interleaved)
  --gfx PATH        GFX ROM binary (SDRAM 0x100000)
  --adpcm PATH      ADPCM ROM binary (SDRAM 0x200000, A+B concatenated)
  --z80 PATH        Z80 audio ROM binary (SDRAM 0x080000)
  --nastar-zip ZIP  Auto-extract and interleave from nastar.zip
  --vcd             Enable VCD trace output (slow)
  --compare DIR     Compare output PPMs to reference PNGs/PPMs in DIR
  --out-dir DIR     Output directory for PPM frames (default: current dir)
  --build           Force rebuild before running
  --no-build        Skip build step

Examples:
  # 10 frames, no ROMs (proves RTL compiles and runs, blank output):
  python3 run_sim.py --frames 10

  # 60 frames with nastar.zip auto-extraction:
  python3 run_sim.py --frames 60 --nastar-zip /path/to/nastar.zip

  # 30 frames with pre-extracted binaries:
  python3 run_sim.py --frames 30 \\
      --prog roms/nastar_prog.bin \\
      --gfx  roms/nastar_gfx.bin \\
      --adpcm roms/nastar_adpcm.bin \\
      --z80  roms/nastar_z80.bin
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
    pixels = lines[3]
    return w, h, pixels


def compare_frames(sim_dir, ref_dir):
    """
    Compare sim PPM frames to reference images in ref_dir.
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


# ── Nastar ZIP extraction ────────────────────────────────────────────────────

def extract_nastar_zip(zip_path, tmpdir):
    """
    Extract nastar.zip ROMs and build the SDRAM-ready binaries.

    CPU ROM: 4 files interleaved as two 256KB even/odd pairs → 512KB flat binary.
      Pair 0: b81-08.50 (even, 128KB) + b81-13.31 (odd, 128KB) → 256KB at SDRAM 0x000000
      Pair 1: b81-10.49 (even, 128KB) + b81-09.30 (odd, 128KB) → 256KB at SDRAM 0x040000

    GFX ROM: b81-03.14 (512KB low) + b81-04.15 (512KB high) → 1MB concatenated.
      Loaded to SDRAM 0x100000.

    ADPCM: b81-02.2 (512KB ADPCM-A) + b81-01.1 (512KB ADPCM-B) → 1MB concatenated.
      Loaded to SDRAM 0x200000 (A) and 0x280000 (B) — pass as single binary.

    Z80: b81-11.37 (64KB) → loaded directly to SDRAM 0x080000.

    Returns dict: {prog, gfx, adpcm, z80} with None if files not found.
    """
    print(f"Extracting Nastar ROMs from {zip_path}...")

    NASTAR_FILES = [
        'b81-08.50', 'b81-13.31',   # CPU pair 0 (even/odd, FBNeo ROM[0]+ROM[1])
        'b81-10.49', 'b81-09.30',   # CPU pair 1 (even/odd, FBNeo ROM[2]+ROM[3])
        'b81-11.37',                  # Z80 audio
        'b81-03.14', 'b81-04.15',   # GFX low/high
        'b81-02.2',                   # ADPCM-A
        'b81-01.1',                   # ADPCM-B
    ]

    with zipfile.ZipFile(zip_path, 'r') as zf:
        names_in_zip = zf.namelist()
        for fname in NASTAR_FILES:
            if fname in names_in_zip:
                zf.extract(fname, tmpdir)
                print(f"  extracted {fname}")
            else:
                print(f"  WARN: {fname} not found in ZIP")

    result = {}

    # ── CPU program ROM: interleave two even/odd pairs ────────────────────────
    # Each pair: even byte (D[15:8]) interleaved with odd byte (D[7:0])
    prog_path = os.path.join(tmpdir, 'nastar_prog.bin')
    pairs = [
        ('b81-08.50', 'b81-13.31'),   # pair 0: 0x000000-0x03FFFF (FBNeo ROM[0]+ROM[1])
        ('b81-10.49', 'b81-09.30'),   # pair 1: 0x040000-0x07FFFF (FBNeo ROM[2]+ROM[3])
    ]
    prog_data = bytearray()
    prog_ok = True
    for even_name, odd_name in pairs:
        even_path = os.path.join(tmpdir, even_name)
        odd_path  = os.path.join(tmpdir, odd_name)
        if os.path.exists(even_path) and os.path.exists(odd_path):
            with open(even_path, 'rb') as fe, open(odd_path, 'rb') as fo:
                even = fe.read()
                odd  = fo.read()
            n = min(len(even), len(odd))
            for i in range(n):
                prog_data.append(even[i])  # D[15:8]
                prog_data.append(odd[i])   # D[7:0]
            print(f"  interleaved {even_name}+{odd_name}: {2*n} bytes")
        else:
            print(f"  WARN: missing CPU ROM pair ({even_name}, {odd_name})")
            prog_ok = False
    if prog_ok and prog_data:
        with open(prog_path, 'wb') as f:
            f.write(prog_data)
        print(f"  CPU ROM: {len(prog_data)} bytes → {prog_path}")
        result['prog'] = prog_path
    else:
        result['prog'] = None

    # ── Z80 audio ROM ─────────────────────────────────────────────────────────
    z80_src = os.path.join(tmpdir, 'b81-11.37')
    if os.path.exists(z80_src):
        result['z80'] = z80_src
        print(f"  Z80 ROM: {os.path.getsize(z80_src)} bytes")
    else:
        result['z80'] = None

    # ── GFX ROM: concatenate low + high halves ────────────────────────────────
    gfx_path = os.path.join(tmpdir, 'nastar_gfx.bin')
    gfx_low  = os.path.join(tmpdir, 'b81-03.14')
    gfx_high = os.path.join(tmpdir, 'b81-04.15')
    if os.path.exists(gfx_low) and os.path.exists(gfx_high):
        with open(gfx_low, 'rb') as fl, open(gfx_high, 'rb') as fh:
            gfx_data = fl.read() + fh.read()
        with open(gfx_path, 'wb') as f:
            f.write(gfx_data)
        print(f"  GFX ROM: {len(gfx_data)} bytes → {gfx_path}")
        result['gfx'] = gfx_path
    else:
        print("  WARN: GFX ROM files not found")
        result['gfx'] = None

    # ── ADPCM: concatenate A + B (1MB total, loaded at 0x200000) ─────────────
    adpcm_path = os.path.join(tmpdir, 'nastar_adpcm.bin')
    adpcm_a = os.path.join(tmpdir, 'b81-02.2')
    adpcm_b = os.path.join(tmpdir, 'b81-01.1')
    if os.path.exists(adpcm_a) and os.path.exists(adpcm_b):
        with open(adpcm_a, 'rb') as fa, open(adpcm_b, 'rb') as fb:
            adpcm_data = fa.read() + fb.read()
        with open(adpcm_path, 'wb') as f:
            f.write(adpcm_data)
        print(f"  ADPCM: {len(adpcm_data)} bytes → {adpcm_path}")
        result['adpcm'] = adpcm_path
    elif os.path.exists(adpcm_a):
        result['adpcm'] = adpcm_a
        print(f"  ADPCM-A only: {os.path.getsize(adpcm_a)} bytes")
    else:
        print("  WARN: ADPCM ROM files not found")
        result['adpcm'] = None

    return result


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Taito B (Nastar Warrior) Verilator simulation runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--frames',     type=int, default=30,
                        help='Number of frames to simulate (default: 30)')
    parser.add_argument('--prog',       default=None,
                        help='CPU program ROM binary (SDRAM 0x000000, pre-interleaved)')
    parser.add_argument('--gfx',        default=None,
                        help='GFX ROM binary (SDRAM 0x100000)')
    parser.add_argument('--adpcm',      default=None,
                        help='ADPCM ROM binary (SDRAM 0x200000, A+B concatenated)')
    parser.add_argument('--z80',        default=None,
                        help='Z80 audio ROM binary (SDRAM 0x080000)')
    parser.add_argument('--nastar-zip', default=None, metavar='ZIP',
                        help='Auto-extract Nastar ROMs from nastar.zip and run')
    parser.add_argument('--vcd',        action='store_true',
                        help='Enable VCD trace (slow, creates sim_taito_b.vcd)')
    parser.add_argument('--compare',    default=None, metavar='DIR',
                        help='Compare output frames to reference images in DIR')
    parser.add_argument('--out-dir',    default='.', metavar='DIR',
                        help='Output directory for PPM frames (default: .)')
    parser.add_argument('--build',      action='store_true',
                        help='Force rebuild before running')
    parser.add_argument('--no-build',   action='store_true',
                        help='Skip build step')
    parser.add_argument('--timeout', type=int, default=0,
                        help='Max seconds for simulation (0=auto: 30s per frame)')

    args = parser.parse_args()

    # ── Nastar ZIP extraction ─────────────────────────────────────────────────
    _tmpdir = None
    if args.nastar_zip:
        zip_path = os.path.abspath(args.nastar_zip)
        if not os.path.exists(zip_path):
            print(f"ERROR: ROM ZIP not found: {zip_path}")
            return 1
        _tmpdir = tempfile.mkdtemp(prefix='nastar_sim_')
        roms = extract_nastar_zip(zip_path, _tmpdir)

        # Set args from extracted files (don't override explicit --prog/--gfx etc.)
        if not args.prog  and roms.get('prog'):  args.prog  = roms['prog']
        if not args.gfx   and roms.get('gfx'):   args.gfx   = roms['gfx']
        if not args.adpcm and roms.get('adpcm'): args.adpcm = roms['adpcm']
        if not args.z80   and roms.get('z80'):   args.z80   = roms['z80']

    # Resolve the sim directory (where this script lives)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sim_binary = os.path.join(script_dir, 'sim_taito_b')
    if not os.path.exists(sim_binary):
        sim_binary = os.path.join(script_dir, 'obj_dir', 'sim_taito_b')

    # ── Build step ────────────────────────────────────────────────────────────
    if not args.no_build:
        needs_build = args.build or not os.path.exists(sim_binary)
        if needs_build:
            print(f"Building simulator in {script_dir}...")
            try:
                result = subprocess.run(
                    ['make', '-C', script_dir, 'all'],
                    stdout=sys.stdout, stderr=sys.stderr,
                    timeout=600)
            except subprocess.TimeoutExpired:
                print(f"\nTIMEOUT: Build exceeded 600s — killed.", file=sys.stderr)
                return 124
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
    if args.z80:   env['ROM_Z80']   = os.path.abspath(args.z80)
    if args.gfx:   env['ROM_GFX']   = os.path.abspath(args.gfx)
    if args.adpcm: env['ROM_ADPCM'] = os.path.abspath(args.adpcm)
    if args.vcd:   env['DUMP_VCD']  = '1'

    # Output directory
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # fx68k requires nanorom.mem and microrom.mem in the CWD of the simulation.
    fx68k_dir = os.path.join(script_dir, '..', '..', '..', 'chips', 'm68000', 'hdl', 'fx68k')
    for mem_name in ('nanorom.mem', 'microrom.mem'):
        src = os.path.normpath(os.path.join(fx68k_dir, mem_name))
        dst = os.path.join(out_dir, mem_name)
        if os.path.exists(src) and not os.path.exists(dst):
            import shutil
            shutil.copy2(src, dst)
            print(f"  Copied {mem_name} to {out_dir}")

    # ── Run simulator ─────────────────────────────────────────────────────────
    print(f"Running simulation: {args.frames} frames...")
    sim_timeout = args.timeout if args.timeout > 0 else max(300, args.frames * 30)
    try:
        result = subprocess.run(
            [sim_binary],
            env=env,
            cwd=out_dir,
            stdout=sys.stdout,
            stderr=sys.stderr,
            timeout=sim_timeout)
    except subprocess.TimeoutExpired:
        print(f"\nTIMEOUT: Simulation exceeded {sim_timeout}s — killed to prevent system overload.",
              file=sys.stderr)
        if _tmpdir and os.path.exists(_tmpdir):
            import shutil
            shutil.rmtree(_tmpdir, ignore_errors=True)
        return 124

    if result.returncode != 0:
        print(f"Simulation exited with code {result.returncode}")
        if _tmpdir and os.path.exists(_tmpdir):
            import shutil
            shutil.rmtree(_tmpdir, ignore_errors=True)
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
    if _tmpdir and os.path.exists(_tmpdir):
        import shutil
        shutil.rmtree(_tmpdir, ignore_errors=True)

    return 0


if __name__ == '__main__':
    sys.exit(main())
