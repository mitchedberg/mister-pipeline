#!/usr/bin/env python3
"""
run_sim.py — Toaplan V2 (Truxton II) simulation runner

Extracts ROMs from truxton2.zip, builds (if needed), and runs the
Verilator Toaplan V2 simulation, dumping one PPM frame file per vertical sync.

Truxton II ROM layout (from Truxton2.mra and MAME toaplan2 driver):
  SDRAM 0x000000: tp024_1.bin (512KB CPU program ROM, standard ROM_LOAD)
  SDRAM 0x100000: GFX ROMs — tp024_3.bin + tp024_4.bin concatenated
  SDRAM ADPCM:    tp024_2.bin (512KB MSM6295 ADPCM sample ROM)
  ROM_Z80:        empty (Truxton II has no Z80 — 68K drives YM2151+MSM6295 directly)

Usage:
  python3 run_sim.py [options]

Options:
  --frames N        Number of frames to simulate (default: 30)
  --zip PATH        Path to truxton2.zip (default: auto-detect)
  --vcd             Enable VCD trace output (very slow)
  --out-dir DIR     Output directory for PPM frames (default: current dir)
  --build           Force rebuild before running
  --no-build        Skip build step

Examples:
  # Simulate 30 frames with Truxton II ROMs (auto-detect zip):
  python3 run_sim.py --frames 30

  # With explicit zip path:
  python3 run_sim.py --frames 30 --zip /path/to/truxton2.zip
"""

import argparse
import os
import subprocess
import sys
import struct
import zipfile
import tempfile

# =============================================================================
# ROM Extraction — Truxton II
#
# ROM files inside truxton2.zip:
#   tp024_1.bin — 512KB CPU program ROM (standard ROM_LOAD, no word swap)
#   tp024_2.bin — 512KB MSM6295 ADPCM sample ROM
#   tp024_3.bin — GFX ROM part 1
#   tp024_4.bin — GFX ROM part 2
#
# GFX ROM construction:
#   Concatenate tp024_3.bin + tp024_4.bin in order into SDRAM starting at
#   0x100000.  This matches the MRA <part> order exactly.
#
# Audio:
#   Truxton II has NO Z80 — the 68K drives YM2151 + MSM6295 directly.
#   tp024_2.bin is the MSM6295 ADPCM sample ROM → ROM_ADPCM.
#   ROM_Z80 is left empty.
# =============================================================================

# Search paths for truxton2.zip
ROM_SEARCH_PATHS = [
    '/Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/truxton2.zip',
    os.path.expanduser('~/ROMs/truxton2.zip'),
    '/tmp/truxton2.zip',
]

GFX_FILES_ORDERED = [
    'tp024_3.bin',
    'tp024_4.bin',
]


def find_zip(explicit_path=None):
    if explicit_path:
        if os.path.exists(explicit_path):
            return explicit_path
        print(f'ERROR: zip not found at {explicit_path}', file=sys.stderr)
        sys.exit(1)
    for p in ROM_SEARCH_PATHS:
        if os.path.exists(p):
            return p
    print('ERROR: truxton2.zip not found.  Use --zip to specify path.',
          file=sys.stderr)
    sys.exit(1)


def extract_roms(zip_path, out_dir):
    """
    Extract and prepare ROM binaries into out_dir.
    Returns a dict: {env_var: path}
    """
    z = zipfile.ZipFile(zip_path, 'r')
    names_in_zip = set(z.namelist())

    def extract(name):
        dest = os.path.join(out_dir, name)
        if name not in names_in_zip:
            print(f'WARNING: {name} not found in zip', file=sys.stderr)
            return None
        with z.open(name) as src, open(dest, 'wb') as dst:
            dst.write(src.read())
        return dest

    print(f'Extracting ROMs from {zip_path}...', file=sys.stderr)

    # CPU program ROM (standard ROM_LOAD, no word swap for Truxton II)
    prog_path = extract('tp024_1.bin')
    if prog_path:
        print(f'  CPU ROM: tp024_1.bin ({os.path.getsize(prog_path)//1024}KB)',
              file=sys.stderr)

    # MSM6295 ADPCM sample ROM (no Z80 in Truxton II)
    z80_path = extract('tp024_2.bin')
    if z80_path:
        print(f'  ADPCM ROM: tp024_2.bin ({os.path.getsize(z80_path)//1024}KB)',
              file=sys.stderr)

    # GFX ROMs — concatenate in MRA order
    gfx_path = os.path.join(out_dir, 'gfx_combined.bin')
    gfx_total = 0
    with open(gfx_path, 'wb') as gfx_out:
        for name in GFX_FILES_ORDERED:
            if name not in names_in_zip:
                print(f'  WARNING: GFX file {name} missing!', file=sys.stderr)
                continue
            data = z.read(name)
            gfx_out.write(data)
            gfx_total += len(data)
            print(f'  GFX:     {name} ({len(data)//1024}KB)', file=sys.stderr)
    print(f'  GFX combined: {gfx_total//1024}KB at SDRAM 0x100000', file=sys.stderr)

    z.close()

    return {
        'ROM_PROG':  prog_path  or '',
        'ROM_GFX':   gfx_path,
        'ROM_ADPCM': z80_path or '',   # tp024_2.bin is actually ADPCM data
        'ROM_Z80':   '',                # No Z80 in Truxton II
    }


def build(force=False):
    """Build the sim binary using make."""
    sim_dir = os.path.dirname(os.path.abspath(__file__))
    sim_bin = os.path.join(sim_dir, 'sim_toaplan_v2')

    if not force and os.path.exists(sim_bin):
        print('sim_toaplan_v2 already built (use --build to force rebuild).',
              file=sys.stderr)
        return sim_bin

    print('Building sim_toaplan_v2...', file=sys.stderr)
    try:
        result = subprocess.run(['make', '-j4'], cwd=sim_dir, timeout=600)
    except subprocess.TimeoutExpired:
        print(f"\nTIMEOUT: Build exceeded 600s — killed.", file=sys.stderr)
        sys.exit(124)
    if result.returncode != 0:
        print('Build FAILED', file=sys.stderr)
        sys.exit(1)
    print('Build SUCCESS', file=sys.stderr)
    return sim_bin


def run_sim(sim_bin, rom_env, n_frames, out_dir, vcd=False, sim_timeout=None):
    """Run the simulation binary."""
    env = os.environ.copy()
    env['N_FRAMES'] = str(n_frames)
    if vcd:
        env['DUMP_VCD'] = '1'
    for k, v in rom_env.items():
        if v:
            env[k] = v

    print(f'\nRunning simulation: {n_frames} frames...', file=sys.stderr)
    print(f'  ROM_PROG  = {env.get("ROM_PROG","(none)")}', file=sys.stderr)
    print(f'  ROM_GFX   = {env.get("ROM_GFX","(none)")}', file=sys.stderr)
    print(f'  ROM_ADPCM = {env.get("ROM_ADPCM","(none)")}', file=sys.stderr)
    print(f'  ROM_Z80   = {env.get("ROM_Z80","(none)")}', file=sys.stderr)

    if sim_timeout is None:
        sim_timeout = max(300, n_frames * 30)

    # Always run from the sim directory so that $readmem (nanorom.mem,
    # microrom.mem) can be found by Verilator's VL_READMEM_N with relative path.
    sim_dir = os.path.dirname(os.path.abspath(sim_bin))
    try:
        result = subprocess.run(
            [sim_bin],
            env=env,
            cwd=sim_dir,
            timeout=sim_timeout
        )
    except subprocess.TimeoutExpired:
        print(f"\nTIMEOUT: Simulation exceeded {sim_timeout}s — killed to prevent system overload.",
              file=sys.stderr)
        return 124
    # Move output PPMs to out_dir if different from sim_dir
    if os.path.abspath(out_dir) != sim_dir:
        import glob
        for ppm in glob.glob(os.path.join(sim_dir, 'frame_*.ppm')):
            dest = os.path.join(out_dir, os.path.basename(ppm))
            os.replace(ppm, dest)
    return result.returncode


def analyze_frames(out_dir, n_frames):
    """Check PPM frames for non-black pixels."""
    print(f'\nAnalyzing {n_frames} frames in {out_dir}...', file=sys.stderr)
    nonblack_frames = 0
    for i in range(n_frames):
        path = os.path.join(out_dir, f'frame_{i:04d}.ppm')
        if not os.path.exists(path):
            print(f'  frame_{i:04d}.ppm: MISSING', file=sys.stderr)
            continue
        with open(path, 'rb') as f:
            data = f.read()
        # Skip PPM header
        lines = data.split(b'\n', 3)
        if len(lines) < 4:
            continue
        pixels = lines[3]
        nonblack = sum(1 for j in range(0, len(pixels), 3)
                      if pixels[j] or pixels[j+1] or pixels[j+2])
        if nonblack > 0:
            nonblack_frames += 1
            print(f'  frame_{i:04d}.ppm: {nonblack} non-black pixels',
                  file=sys.stderr)
    print(f'\nSummary: {nonblack_frames}/{n_frames} frames with non-black pixels',
          file=sys.stderr)
    return nonblack_frames


def main():
    parser = argparse.ArgumentParser(
        description='Toaplan V2 (Truxton II) simulation runner')
    parser.add_argument('--frames', type=int, default=30,
                        help='Number of frames to simulate (default: 30)')
    parser.add_argument('--zip', default=None,
                        help='Path to truxton2.zip')
    parser.add_argument('--vcd', action='store_true',
                        help='Enable VCD trace (very slow)')
    parser.add_argument('--out-dir', default='.',
                        help='Output directory for PPM frames')
    parser.add_argument('--build', action='store_true',
                        help='Force rebuild before running')
    parser.add_argument('--no-build', action='store_true',
                        help='Skip build step')
    parser.add_argument('--timeout', type=int, default=0,
                        help='Max seconds for simulation (0=auto: 30s per frame)')
    args = parser.parse_args()

    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # Step 1: Build
    if not args.no_build:
        sim_bin = build(force=args.build)
    else:
        sim_dir = os.path.dirname(os.path.abspath(__file__))
        sim_bin = os.path.join(sim_dir, 'sim_toaplan_v2')

    # Step 2: Extract ROMs
    zip_path = find_zip(args.zip)
    with tempfile.TemporaryDirectory() as rom_dir:
        rom_env = extract_roms(zip_path, rom_dir)

        # Step 3: Run simulation
        sim_timeout = args.timeout if args.timeout > 0 else max(300, args.frames * 30)
        rc = run_sim(sim_bin, rom_env, args.frames, out_dir, vcd=args.vcd,
                     sim_timeout=sim_timeout)

    # Step 4: Analyze results
    if rc == 0:
        nonblack = analyze_frames(out_dir, args.frames)
        print(f'\n=== RESULT ===', file=sys.stderr)
        print(f'  Exit code: {rc}', file=sys.stderr)
        print(f'  Non-black frames: {nonblack}/{args.frames}', file=sys.stderr)
    else:
        print(f'\nSimulation exited with code {rc}', file=sys.stderr)

    return rc


if __name__ == '__main__':
    sys.exit(main())
