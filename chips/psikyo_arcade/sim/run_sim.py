#!/usr/bin/env python3
"""
run_sim.py — Psikyo Arcade (Gunbird) Verilator simulation runner

Builds (if needed) and runs the Verilator Psikyo Arcade simulation,
dumping one PPM frame file per vertical sync (320×240 @ ~58 Hz).

Usage:
  python3 run_sim.py [options]

Options:
  --frames N          Number of frames to simulate (default: 30)
  --prog PATH         Program ROM binary (SDRAM 0x000000, 2 MB)
  --spr PATH          Sprite ROM binary  (SDRAM 0x200000, 4 MB)
  --bg PATH           BG tile ROM binary (SDRAM 0x600000, 4 MB)
  --adpcm PATH        ADPCM ROM binary   (SDRAM 0xA00000)
  --z80 PATH          Z80 sound ROM binary (SDRAM 0xA80000, 32 KB)
  --vcd               Enable VCD trace (slow)
  --out-dir DIR       Output directory for PPM frames (default: .)
  --build             Force rebuild
  --no-build          Skip build step
  --gunbird-zip ZIP   Auto-extract Gunbird ROMs from gunbird.zip

Gunbird ROM layout (from Gunbird.mra / MAME gunbird driver):
  4.u46 (262144) — program ROM even bytes  (D15:D8)
  5.u39 (262144) — program ROM odd bytes   (D7:D0)
  u14.bin (2 MB) — sprite ROM part 1  @ sprite offset 0x000000
  u24.bin (2 MB) — sprite ROM part 2  @ sprite offset 0x200000
  u15.bin (2 MB) — sprite ROM part 3  @ sprite offset 0x400000
  u25.bin (1 MB) — sprite ROM part 4  @ sprite offset 0x600000
  u33.bin (2 MB) — BG tile ROM        @ BG offset 0x000000
  3.u71  (128 KB) — Z80 sound ROM
  u3.bin (256 KB) — ADPCM ROM (jt10 ADPCM-A)
  u56.bin (1 MB) — ADPCM ROM part 2
  u64.bin (512 KB) — ADPCM ROM part 3

Examples:
  # Run 10 frames with no ROMs (CPU starts, no game logic):
  python3 run_sim.py --frames 10

  # Run 30 frames with Gunbird ROMs from zip:
  python3 run_sim.py --frames 30 --gunbird-zip ~/Projects/gunbird.zip

  # Run 30 frames with pre-extracted ROMs:
  python3 run_sim.py --frames 30 --prog gunbird_prog.bin --spr gunbird_spr.bin
"""

import argparse
import os
import subprocess
import sys
import glob
import zipfile
import tempfile
import struct
import shutil


def interleave_68k_roms(even_path, odd_path, out_path):
    """
    Interleave two 68000 ROM halves into a single word-stream binary.
    even_path: D15:D8 (upper byte, first chip)
    odd_path:  D7:D0  (lower byte, second chip)
    68000 big-endian: word[15:8] first, word[7:0] second.
    """
    with open(even_path, 'rb') as fe, open(odd_path, 'rb') as fo:
        even = fe.read()
        odd  = fo.read()
    interleaved = bytearray()
    for i in range(min(len(even), len(odd))):
        interleaved.append(even[i])   # D15:D8 (high byte)
        interleaved.append(odd[i])    # D7:D0  (low byte)
    with open(out_path, 'wb') as fp:
        fp.write(interleaved)
    print(f"  CPU ROM interleaved: {len(interleaved)} bytes → {out_path}")
    return out_path


def concatenate_roms(parts, out_path):
    """Concatenate multiple ROM binary files into one."""
    total = 0
    with open(out_path, 'wb') as fout:
        for p in parts:
            if os.path.exists(p):
                with open(p, 'rb') as fin:
                    data = fin.read()
                fout.write(data)
                total += len(data)
                print(f"  appended {os.path.basename(p)} ({len(data)} bytes)")
            else:
                print(f"  WARN: {p} not found, skipping")
    print(f"  concatenated → {out_path} ({total} bytes total)")
    return out_path


def extract_gunbird(zip_path, tmpdir):
    """
    Extract Gunbird ROMs from gunbird.zip and assemble them for simulation.
    Returns dict: {prog, spr, bg, adpcm, z80} → file paths (or None if missing)
    """
    with zipfile.ZipFile(zip_path, 'r') as zf:
        names_in_zip = set(zf.namelist())
        print(f"  ZIP contents: {sorted(names_in_zip)}")

        # Extract all files
        for name in names_in_zip:
            zf.extract(name, tmpdir)
            print(f"  extracted {name}")

    # ── Program ROM: interleave 4.u46 (even=D15:D8) + 5.u39 (odd=D7:D0) ──
    prog_path = None
    even = os.path.join(tmpdir, '4.u46')
    odd  = os.path.join(tmpdir, '5.u39')
    if os.path.exists(even) and os.path.exists(odd):
        prog_path = os.path.join(tmpdir, 'gunbird_prog.bin')
        interleave_68k_roms(even, odd, prog_path)
    else:
        print(f"  WARN: Program ROM files not found (4.u46={os.path.exists(even)}, 5.u39={os.path.exists(odd)})")

    # ── Sprite ROM: u14.bin + u24.bin + u15.bin + u25.bin (concatenated) ──
    spr_parts = [
        os.path.join(tmpdir, 'u14.bin'),
        os.path.join(tmpdir, 'u24.bin'),
        os.path.join(tmpdir, 'u15.bin'),
        os.path.join(tmpdir, 'u25.bin'),
    ]
    spr_path = None
    if any(os.path.exists(p) for p in spr_parts):
        spr_path = os.path.join(tmpdir, 'gunbird_spr.bin')
        concatenate_roms(spr_parts, spr_path)
    else:
        print("  WARN: No sprite ROM files found")

    # ── BG tile ROM: u33.bin ──────────────────────────────────────────────
    bg_path = None
    bg_file = os.path.join(tmpdir, 'u33.bin')
    if os.path.exists(bg_file):
        bg_path = bg_file
        print(f"  BG ROM: {bg_file} ({os.path.getsize(bg_file)} bytes)")
    else:
        print("  WARN: BG ROM u33.bin not found")

    # ── ADPCM ROM: u3.bin + u56.bin + u64.bin (concatenated) ────────────
    adpcm_parts = [
        os.path.join(tmpdir, 'u3.bin'),
        os.path.join(tmpdir, 'u56.bin'),
        os.path.join(tmpdir, 'u64.bin'),
    ]
    adpcm_path = None
    if any(os.path.exists(p) for p in adpcm_parts):
        adpcm_path = os.path.join(tmpdir, 'gunbird_adpcm.bin')
        concatenate_roms(adpcm_parts, adpcm_path)
    else:
        print("  WARN: No ADPCM ROM files found")

    # ── Z80 sound ROM: 3.u71 ─────────────────────────────────────────────
    z80_path = None
    z80_file = os.path.join(tmpdir, '3.u71')
    if os.path.exists(z80_file):
        z80_path = z80_file
        print(f"  Z80 ROM: {z80_file} ({os.path.getsize(z80_file)} bytes)")
    else:
        print("  WARN: Z80 ROM 3.u71 not found")

    return {
        'prog':  prog_path,
        'spr':   spr_path,
        'bg':    bg_path,
        'adpcm': adpcm_path,
        'z80':   z80_path,
    }


def main():
    parser = argparse.ArgumentParser(
        description='Psikyo Arcade (Gunbird) Verilator simulation runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--frames',      type=int, default=30,
                        help='Number of frames (default: 30)')
    parser.add_argument('--prog',        default=None,
                        help='Program ROM binary (SDRAM 0x000000)')
    parser.add_argument('--spr',         default=None,
                        help='Sprite ROM binary (SDRAM 0x200000)')
    parser.add_argument('--bg',          default=None,
                        help='BG tile ROM binary (SDRAM 0x600000)')
    parser.add_argument('--adpcm',       default=None,
                        help='ADPCM ROM binary (SDRAM 0xA00000)')
    parser.add_argument('--z80',         default=None,
                        help='Z80 sound ROM binary (SDRAM 0xA80000)')
    parser.add_argument('--vcd',         action='store_true',
                        help='Enable VCD trace (slow)')
    parser.add_argument('--out-dir',     default='.', metavar='DIR',
                        help='Output directory for PPM frames (default: .)')
    parser.add_argument('--build',       action='store_true',
                        help='Force rebuild')
    parser.add_argument('--no-build',    action='store_true',
                        help='Skip build')
    parser.add_argument('--gunbird-zip', default=None, metavar='ZIP',
                        help='Extract Gunbird ROMs from gunbird.zip and run')

    args = parser.parse_args()

    # ── Gunbird ZIP extraction ────────────────────────────────────────────────
    _tmpdir = None
    if args.gunbird_zip:
        zip_path = os.path.abspath(args.gunbird_zip)
        if not os.path.exists(zip_path):
            print(f"ERROR: ROM ZIP not found: {zip_path}")
            return 1
        print(f"Extracting Gunbird ROMs from {zip_path}...")
        _tmpdir = tempfile.mkdtemp(prefix='gunbird_sim_')
        roms = extract_gunbird(zip_path, _tmpdir)

        if not args.prog  and roms['prog']:  args.prog  = roms['prog']
        if not args.spr   and roms['spr']:   args.spr   = roms['spr']
        if not args.bg    and roms['bg']:     args.bg    = roms['bg']
        if not args.adpcm and roms['adpcm']: args.adpcm = roms['adpcm']
        if not args.z80   and roms['z80']:   args.z80   = roms['z80']

    # ── Locate sim binary ─────────────────────────────────────────────────────
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sim_binary = os.path.join(script_dir, 'sim_psikyo_arcade')
    if not os.path.exists(sim_binary):
        sim_binary = os.path.join(script_dir, 'obj_dir', 'sim_psikyo_arcade')

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
        print("Run 'make' in the sim directory, or use --build.")
        return 1

    # ── Output directory ──────────────────────────────────────────────────────
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # Musashi CPU model: no ROM files needed (CPU is software, not RTL)

    # ── Environment ───────────────────────────────────────────────────────────
    env = os.environ.copy()
    env['N_FRAMES'] = str(args.frames)
    if args.prog:  env['ROM_PROG']  = os.path.abspath(args.prog)
    if args.spr:   env['ROM_SPR']   = os.path.abspath(args.spr)
    if args.bg:    env['ROM_BG']    = os.path.abspath(args.bg)
    if args.adpcm: env['ROM_ADPCM'] = os.path.abspath(args.adpcm)
    if args.z80:   env['ROM_Z80']   = os.path.abspath(args.z80)
    if args.vcd:   env['DUMP_VCD']  = '1'

    # ── Run simulator ─────────────────────────────────────────────────────────
    print(f"Running simulation: {args.frames} frames, output → {out_dir}")
    if args.prog:  print(f"  PROG:  {env.get('ROM_PROG','(none)')}")
    if args.spr:   print(f"  SPR:   {env.get('ROM_SPR','(none)')}")
    if args.bg:    print(f"  BG:    {env.get('ROM_BG','(none)')}")
    if args.adpcm: print(f"  ADPCM: {env.get('ROM_ADPCM','(none)')}")
    if args.z80:   print(f"  Z80:   {env.get('ROM_Z80','(none)')}")

    result = subprocess.run(
        [sim_binary],
        env=env,
        cwd=out_dir,
        stdout=sys.stdout,
        stderr=sys.stderr)

    # ── Cleanup tmpdir ────────────────────────────────────────────────────────
    if _tmpdir:
        shutil.rmtree(_tmpdir, ignore_errors=True)

    if result.returncode != 0:
        print(f"Simulation exited with code {result.returncode}")
        return result.returncode

    captured = sorted(glob.glob(os.path.join(out_dir, 'frame_*.ppm')))
    print(f"\nSimulation complete. {len(captured)} frame(s) in {out_dir}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
