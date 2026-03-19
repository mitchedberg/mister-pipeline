#!/usr/bin/env python3
"""
run_sim.py — Kaneko16 Arcade (Berlin Wall) simulation runner

Builds (if needed) and runs the Verilator Kaneko16 Arcade simulation, dumping
one PPM frame file per vertical sync. Optionally compares frames to reference
screenshots from MAME.

Usage:
  python3 run_sim.py [options]

Options:
  --frames N          Number of frames to simulate (default: 30)
  --prog PATH         Program ROM binary (SDRAM 0x000000)
  --gfx PATH          GFX ROM binary — sprites + BG tiles (SDRAM 0x100000)
  --adpcm PATH        ADPCM ROM binary — OKI M6295 (SDRAM 0x500000)
  --z80 PATH          Z80 sound ROM binary (SDRAM 0x580000)
  --berlwall-zip ZIP  Auto-extract Berlin Wall ROMs from berlwall.zip
  --vcd               Enable VCD trace output (slow)
  --compare DIR       Compare output PPMs to reference PNGs/PPMs in DIR
  --out-dir DIR       Output directory for PPM frames (default: current dir)
  --build             Force rebuild before running
  --no-build          Skip build step

Examples:
  # Simulate 10 frames with no ROMs (proves RTL compiles and clocks):
  python3 run_sim.py --frames 10

  # Simulate 60 frames with real Berlin Wall ROMs:
  python3 run_sim.py --frames 60 \\
      --prog roms/berlwall_prog.bin \\
      --gfx  roms/berlwall_gfx.bin

  # Auto-extract from berlwall.zip and simulate 30 frames:
  python3 run_sim.py --berlwall-zip /path/to/berlwall.zip --frames 30

  # Compare to MAME reference frames:
  python3 run_sim.py --frames 30 --compare mame_ref/

Berlin Wall ROM layout (berlwall.zip, MAME mame/kaneko/kaneko16.cpp):
  CPU program ROM (interleaved, 512KB total):
    berlwall.u23  — even bytes (D15:D8), 256KB
    berlwall.u24  — odd  bytes (D7:D0),  256KB
    → interleave to produce prog ROM binary
  GFX ROM (sprites + BG tiles, 2MB total):
    berlwall.u1  — GFX bank 0  (512KB)
    berlwall.u2  — GFX bank 1  (512KB)
    berlwall.u3  — GFX bank 2  (512KB)
    berlwall.u4  — GFX bank 3  (512KB)
    → concatenate in order
  ADPCM ROM (OKI M6295, 512KB):
    berlwall.u7  — ADPCM samples (512KB)
  Z80 ROM (32KB):
    berlwall.u13 — Z80 sound program (32KB)

Note: Exact filenames inside berlwall.zip may vary by MAME version.
The --berlwall-zip option will list all files found and attempt to
identify them by size; adjust as needed for your ROM set.

SDRAM layout used by this simulation:
  0x000000 – 0x0FFFFF   CPU program ROM (1MB)
  0x100000 – 0x4FFFFF   GFX ROM (4MB; 32-bit = two consecutive 16-bit words)
  0x500000 – 0x57FFFF   ADPCM ROM (512KB)
  0x580000 – 0x587FFF   Z80 ROM (32KB)
"""

import argparse
import os
import subprocess
import sys
import glob
import zipfile
import tempfile
import shutil


# ── PPM comparison helper ─────────────────────────────────────────────────────

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


# ── ROM extraction helpers ────────────────────────────────────────────────────

def interleave_roms(even_path, odd_path, out_path):
    """
    Interleave two ROM halves into a single 68000 program ROM binary.
    even_path: D15:D8 (upper byte, even addresses)
    odd_path:  D7:D0  (lower byte, odd addresses)
    """
    with open(even_path, 'rb') as fe, open(odd_path, 'rb') as fo:
        even_data = fe.read()
        odd_data  = fo.read()
    n = min(len(even_data), len(odd_data))
    interleaved = bytearray()
    for i in range(n):
        interleaved.append(even_data[i])  # D15:D8
        interleaved.append(odd_data[i])   # D7:D0
    with open(out_path, 'wb') as fp:
        fp.write(interleaved)
    print(f"  CPU ROM interleaved: {len(interleaved)} bytes -> {out_path}")
    return out_path


def extract_berlwall(zip_path, tmpdir):
    """
    Extract Berlin Wall ROMs from berlwall.zip.
    Returns dict with keys: prog, gfx, adpcm, z80 (or None if not found).
    """
    result = {'prog': None, 'gfx': None, 'adpcm': None, 'z80': None}

    if not os.path.exists(zip_path):
        print(f"ERROR: ROM ZIP not found: {zip_path}")
        return result

    print(f"Extracting Berlin Wall ROMs from {zip_path}...")

    with zipfile.ZipFile(zip_path, 'r') as zf:
        names_in_zip = zf.namelist()
        print(f"  Files in ZIP: {', '.join(sorted(names_in_zip))}")

        # Extract all files
        zf.extractall(tmpdir)

    # Identify ROMs by known filenames (MAME berlwall set)
    # Supports two naming conventions found in the wild:
    #   Old MAME: u23.bin / u24.bin / u1.bin-u4.bin / u7.bin / u13.bin
    #   New MAME: bw100e_u23-01.u23 / bw101e_u39-01.u39 / bw000.u46–bw00b.u68
    #
    # Berlin Wall MAME ROM layout (kaneko16.cpp):
    #   Program ROM: bw100e_u23-01.u23 (even D15:D8, 128KB) + bw101e_u39-01.u39 (odd D7:D0, 128KB)
    #                → interleave to 256KB total
    #   GFX ROM:     bw001.u84 … bw00b.u68  (11 × 512KB = 5.5MB, concatenate in order)
    #                OR: u1.bin … u4.bin    (4 × 512KB = 2MB, older set)
    #   ADPCM ROM:   bw000.u46 (256KB OKI M6295 samples) OR u7.bin
    #   Z80 ROM:     Not present in all sets (sound CPU may be absent)

    # CPU program ROM: even + odd halves, interleaved
    PROG_EVEN_CANDIDATES = [
        'bw100e_u23-01.u23',           # new MAME naming
        'u23.bin', 'berlwall.u23', 'bw_u23.bin', '7.u23',
    ]
    PROG_ODD_CANDIDATES  = [
        'bw101e_u39-01.u39',           # new MAME naming (u39 is the odd/low byte)
        'u24.bin', 'berlwall.u24', 'bw_u24.bin', '8.u24',
    ]

    # GFX ROM: concatenate all banks in order
    # New MAME naming: bw001–bw00b (11 banks × 512KB)
    # Old MAME naming: u1–u4 (4 banks × 512KB)
    GFX_CANDIDATES = [
        ['bw001.u84', 'u1.bin', 'berlwall.u1', 'bw_u1.bin'],
        ['bw002.u83', 'u2.bin', 'berlwall.u2', 'bw_u2.bin'],
        ['bw003.u77', 'u3.bin', 'berlwall.u3', 'bw_u3.bin'],
        ['bw004.u73', 'u4.bin', 'berlwall.u4', 'bw_u4.bin'],
        ['bw005.u74'],
        ['bw006.u75'],
        ['bw007.u76'],
        ['bw008.u65'],
        ['bw009.u66'],
        ['bw00a.u67'],
        ['bw00b.u68'],
    ]

    # ADPCM ROM (OKI M6295)
    ADPCM_CANDIDATES = ['bw000.u46', 'u7.bin', 'berlwall.u7', 'bw_u7.bin', 'adpcm.bin']

    # Z80 sound ROM (optional — may be absent in some sets)
    Z80_CANDIDATES   = ['u13.bin', 'berlwall.u13', 'bw_u13.bin', 'sound.bin']

    def find_file(candidates):
        for name in candidates:
            p = os.path.join(tmpdir, name)
            if os.path.exists(p):
                return p
            # Also try case-insensitive match
            for extracted in os.listdir(tmpdir):
                if extracted.lower() == name.lower():
                    return os.path.join(tmpdir, extracted)
        return None

    # CPU program ROM
    even_path = find_file(PROG_EVEN_CANDIDATES)
    odd_path  = find_file(PROG_ODD_CANDIDATES)
    if even_path and odd_path:
        prog_path = os.path.join(tmpdir, 'berlwall_prog.bin')
        result['prog'] = interleave_roms(even_path, odd_path, prog_path)
    else:
        # Fallback: if only one file found, assume it's already interleaved
        fallback = find_file(['prog.bin', 'berlwall_prog.bin'])
        if fallback:
            result['prog'] = fallback
            print(f"  CPU ROM (pre-interleaved): {fallback}")
        else:
            print(f"  WARN: CPU program ROM not found (even={even_path}, odd={odd_path})")

    # GFX ROM: concatenate all banks in order
    gfx_parts = []
    for candidates in GFX_CANDIDATES:
        p = find_file(candidates)
        if p:
            gfx_parts.append(p)
            print(f"  GFX bank: {os.path.basename(p)}")
    if gfx_parts:
        gfx_out = os.path.join(tmpdir, 'berlwall_gfx.bin')
        with open(gfx_out, 'wb') as fout:
            for part in gfx_parts:
                with open(part, 'rb') as fin:
                    fout.write(fin.read())
        total_gfx = sum(os.path.getsize(p) for p in gfx_parts)
        print(f"  GFX ROM concatenated: {total_gfx:,} bytes ({len(gfx_parts)} banks) -> {gfx_out}")
        result['gfx'] = gfx_out
    else:
        print("  WARN: GFX ROM not found (tried bw001-bw00b and u1-u4 banks)")

    # ADPCM ROM
    adpcm_path = find_file(ADPCM_CANDIDATES)
    if adpcm_path:
        result['adpcm'] = adpcm_path
        print(f"  ADPCM ROM: {os.path.basename(adpcm_path)} ({os.path.getsize(adpcm_path):,} bytes)")
    else:
        print("  WARN: ADPCM ROM not found")

    # Z80 ROM (optional — not present in all ROM sets)
    z80_path = find_file(Z80_CANDIDATES)
    if z80_path:
        result['z80'] = z80_path
        print(f"  Z80 ROM: {os.path.basename(z80_path)} ({os.path.getsize(z80_path):,} bytes)")
    else:
        print("  NOTE: Z80 ROM not found (may be absent in this ROM set — sound will be silent)")

    return result


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Kaneko16 Arcade (Berlin Wall) Verilator simulation runner',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--frames',   type=int,  default=30,
                        help='Number of frames to simulate (default: 30)')
    parser.add_argument('--prog',     default=None,
                        help='Program ROM binary (SDRAM 0x000000)')
    parser.add_argument('--gfx',      default=None,
                        help='GFX ROM binary — sprites + BG tiles (SDRAM 0x100000)')
    parser.add_argument('--adpcm',    default=None,
                        help='ADPCM ROM binary (SDRAM 0x500000)')
    parser.add_argument('--z80',      default=None,
                        help='Z80 sound ROM binary (SDRAM 0x580000)')
    parser.add_argument('--berlwall-zip', default=None, metavar='ZIP',
                        help='Auto-extract Berlin Wall ROMs from berlwall.zip')
    parser.add_argument('--vcd',      action='store_true',
                        help='Enable VCD trace (slow, creates sim_kaneko_arcade.vcd)')
    parser.add_argument('--compare',  default=None, metavar='DIR',
                        help='Compare output frames to reference images in DIR')
    parser.add_argument('--out-dir',  default='.', metavar='DIR',
                        help='Output directory for PPM frames (default: .)')
    parser.add_argument('--build',    action='store_true',
                        help='Force rebuild before running')
    parser.add_argument('--no-build', action='store_true',
                        help='Skip build step')

    args = parser.parse_args()

    # ── Berlin Wall ZIP extraction ─────────────────────────────────────────────
    _tmpdir = None
    if args.berlwall_zip:
        zip_path = os.path.abspath(args.berlwall_zip)
        _tmpdir = tempfile.mkdtemp(prefix='berlwall_sim_')
        roms = extract_berlwall(zip_path, _tmpdir)

        # Apply extracted ROM paths (don't override explicit --prog/--gfx etc.)
        if not args.prog  and roms['prog']:  args.prog  = roms['prog']
        if not args.gfx   and roms['gfx']:   args.gfx   = roms['gfx']
        if not args.adpcm and roms['adpcm']: args.adpcm = roms['adpcm']
        if not args.z80   and roms['z80']:   args.z80   = roms['z80']

    # Resolve the sim directory (where this script lives)
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Verilator 5 places the binary in obj_dir/; the Makefile symlinks it out.
    sim_binary = os.path.join(script_dir, 'sim_kaneko_arcade')
    if not os.path.exists(sim_binary):
        sim_binary = os.path.join(script_dir, 'obj_dir', 'sim_kaneko_arcade')

    # ── Build step ─────────────────────────────────────────────────────────────
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

    # ── Prepare environment ────────────────────────────────────────────────────
    env = os.environ.copy()
    env['N_FRAMES'] = str(args.frames)
    if args.prog:  env['ROM_PROG']  = os.path.abspath(args.prog)
    if args.gfx:   env['ROM_GFX']   = os.path.abspath(args.gfx)
    if args.adpcm: env['ROM_ADPCM'] = os.path.abspath(args.adpcm)
    if args.z80:   env['ROM_Z80']   = os.path.abspath(args.z80)
    if args.vcd:   env['DUMP_VCD']  = '1'

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
            shutil.copy2(src, dst)
            print(f"Copied {mem_name} to {out_dir}")

    # ── Run simulator ──────────────────────────────────────────────────────────
    print(f"Running simulation: {args.frames} frames...")
    if args.prog:  print(f"  ROM_PROG  = {env['ROM_PROG']}")
    if args.gfx:   print(f"  ROM_GFX   = {env['ROM_GFX']}")
    if args.adpcm: print(f"  ROM_ADPCM = {env['ROM_ADPCM']}")
    if args.z80:   print(f"  ROM_Z80   = {env['ROM_Z80']}")

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

    # ── Optional comparison ────────────────────────────────────────────────────
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
        shutil.rmtree(_tmpdir, ignore_errors=True)

    return 0


if __name__ == '__main__':
    sys.exit(main())
