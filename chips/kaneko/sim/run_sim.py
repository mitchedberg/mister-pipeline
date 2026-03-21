#!/usr/bin/env python3
"""
run_sim.py — Kaneko16 (Berlin Wall) Verilator simulation runner

Extracts ROMs from berlwall.zip, interleaves CPU program ROM,
concatenates GFX ROMs, builds the simulator if needed, and runs it.

Usage:
    python3 run_sim.py --berlwall-zip /path/to/berlwall.zip --frames 30
    python3 run_sim.py --prog prog.bin --gfx gfx.bin --frames 30  # pre-extracted

ROM layout in berlwall.zip (FBNeo d_kaneko16.cpp):
    CPU Program (256KB interleaved):
        bw100e_u23-01.u23  (even bytes, 128KB)
        bw101e_u39-01.u39  (odd bytes,  128KB)
    Sprite ROM (1.25MB concatenated):
        bw000.u46  (256KB)
        bw001.u84  (512KB)
        bw002.u83  (512KB)
    BG Tile ROM (512KB):
        bw003.u77  (512KB)
    BG Bitmap (4MB, 4 interleaved planes):
        bw004.u73 + bw005.u74  (plane 1, even/odd, 512K each)
        bw006.u75 + bw007.u76  (plane 2, even/odd, 512K each)
        bw008.u65 + bw009.u66  (plane 3, even/odd, 512K each)
        bw00a.u67 + bw00b.u68  (plane 4, even/odd, 512K each)
    Sound: none (berlwall uses YM2149 PSG, no digital samples)
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROMS_DIR = os.path.join(SCRIPT_DIR, "roms")

# fx68k microcode ROMs
MICROROM_SRC = os.path.join(SCRIPT_DIR, "..", "..", "..", "chips", "m68000", "hdl", "fx68k")


def interleave_16bit(even_data, odd_data):
    """Interleave two byte streams into 16-bit big-endian words.
    even_data provides the high byte (D15-D8), odd_data the low byte (D7-D0).
    Output: [even[0], odd[0], even[1], odd[1], ...]
    """
    size = min(len(even_data), len(odd_data))
    result = bytearray(size * 2)
    for i in range(size):
        result[i * 2]     = even_data[i]
        result[i * 2 + 1] = odd_data[i]
    return bytes(result)


def interleave_bitmap_plane(even_data, odd_data):
    """Interleave bitmap plane: even/odd bytes into 16-bit words."""
    return interleave_16bit(even_data, odd_data)


def extract_berlwall(zip_path, out_dir):
    """Extract and prepare berlwall ROMs from ZIP."""
    os.makedirs(out_dir, exist_ok=True)

    with zipfile.ZipFile(zip_path, 'r') as zf:
        names = {n.lower(): n for n in zf.namelist()}

        def read_rom(filename):
            key = filename.lower()
            if key not in names:
                # Try without path prefix
                for k, v in names.items():
                    if k.endswith(filename.lower()):
                        return zf.read(v)
                print(f"WARNING: {filename} not found in ZIP", file=sys.stderr)
                return b''
            return zf.read(names[key])

        # ── CPU Program ROM (256KB interleaved) ─────────────────────────
        even = read_rom("bw100e_u23-01.u23")
        odd  = read_rom("bw101e_u39-01.u39")
        if even and odd:
            prog = interleave_16bit(even, odd)
            prog_path = os.path.join(out_dir, "prog.bin")
            with open(prog_path, 'wb') as f:
                f.write(prog)
            print(f"CPU prog: {len(prog)} bytes -> {prog_path}", file=sys.stderr)
        else:
            print("ERROR: CPU ROM files missing!", file=sys.stderr)
            return False

        # ── GFX ROM (sprites + BG tiles + BG bitmap) ────────────────────
        # Concatenate: sprites first, then BG tiles, then bitmap planes
        gfx = bytearray()

        # Sprites (sequential concatenation)
        for name in ["bw000.u46", "bw001.u84", "bw002.u83"]:
            data = read_rom(name)
            gfx.extend(data)
            print(f"  Sprite: {name} = {len(data)} bytes", file=sys.stderr)

        spr_size = len(gfx)
        print(f"  Total sprites: {spr_size} bytes", file=sys.stderr)

        # BG tiles (sequential)
        bg_tile = read_rom("bw003.u77")
        gfx.extend(bg_tile)
        print(f"  BG tiles: bw003.u77 = {len(bg_tile)} bytes", file=sys.stderr)

        # BG bitmap (4 interleaved planes)
        bitmap_pairs = [
            ("bw004.u73", "bw005.u74"),
            ("bw006.u75", "bw007.u76"),
            ("bw008.u65", "bw009.u66"),
            ("bw00a.u67", "bw00b.u68"),
        ]
        for even_name, odd_name in bitmap_pairs:
            even_data = read_rom(even_name)
            odd_data  = read_rom(odd_name)
            if even_data and odd_data:
                plane = interleave_bitmap_plane(even_data, odd_data)
                gfx.extend(plane)
                print(f"  Bitmap: {even_name}+{odd_name} = {len(plane)} bytes", file=sys.stderr)

        gfx_path = os.path.join(out_dir, "gfx.bin")
        with open(gfx_path, 'wb') as f:
            f.write(gfx)
        print(f"GFX total: {len(gfx)} bytes -> {gfx_path}", file=sys.stderr)

        # No Z80 or ADPCM ROMs for berlwall
        # Create empty stubs so the Makefile "run" target doesn't error
        for name in ["z80.bin", "adpcm.bin"]:
            path = os.path.join(out_dir, name)
            if not os.path.exists(path):
                with open(path, 'wb') as f:
                    pass  # empty file

    return True


def ensure_microrom(sim_dir):
    """Copy fx68k microrom.mem and nanorom.mem to sim directory."""
    for name in ["microrom.mem", "nanorom.mem"]:
        dst = os.path.join(sim_dir, name)
        if not os.path.exists(dst):
            src = os.path.join(MICROROM_SRC, name)
            if os.path.exists(src):
                shutil.copy2(src, dst)
                print(f"Copied {name} from fx68k", file=sys.stderr)
            else:
                print(f"WARNING: {name} not found at {src}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Kaneko16 (berlwall) simulation runner")
    parser.add_argument("--berlwall-zip", help="Path to berlwall.zip for auto-extraction")
    parser.add_argument("--prog", help="Pre-extracted CPU program ROM binary")
    parser.add_argument("--gfx", help="Pre-extracted GFX ROM binary")
    parser.add_argument("--z80", help="Pre-extracted Z80 sound ROM binary")
    parser.add_argument("--adpcm", help="Pre-extracted ADPCM ROM binary")
    parser.add_argument("--frames", type=int, default=30, help="Frames to simulate (default: 30)")
    parser.add_argument("--vcd", action="store_true", help="Enable VCD trace")
    parser.add_argument("--out-dir", default=".", help="Output directory for PPM frames")
    parser.add_argument("--timeout", type=int, default=0, help="Timeout in seconds (0=auto)")
    parser.add_argument("--build", action="store_true", default=True, help="Build before running")
    parser.add_argument("--no-build", action="store_false", dest="build")
    args = parser.parse_args()

    os.chdir(SCRIPT_DIR)

    # ── Extract ROMs if ZIP provided ──────────────────────────────────────
    if args.berlwall_zip:
        if not os.path.exists(args.berlwall_zip):
            print(f"ERROR: ZIP not found: {args.berlwall_zip}", file=sys.stderr)
            return 1
        if not extract_berlwall(args.berlwall_zip, ROMS_DIR):
            return 1
        args.prog  = os.path.join(ROMS_DIR, "prog.bin")
        args.gfx   = os.path.join(ROMS_DIR, "gfx.bin")
        args.z80   = os.path.join(ROMS_DIR, "z80.bin")
        args.adpcm = os.path.join(ROMS_DIR, "adpcm.bin")

    if not args.prog:
        print("ERROR: --prog or --berlwall-zip required", file=sys.stderr)
        return 1

    # ── Ensure fx68k microrom files ───────────────────────────────────────
    ensure_microrom(SCRIPT_DIR)
    # Also copy to out-dir since sim binary's CWD = out-dir
    ensure_microrom(args.out_dir)

    # ── Build ─────────────────────────────────────────────────────────────
    if args.build:
        print("Building sim_kaneko16...", file=sys.stderr)
        result = subprocess.run(["make", "-j4"], capture_output=False)
        if result.returncode != 0:
            print("ERROR: Build failed", file=sys.stderr)
            return 1

    # ── Run simulation ────────────────────────────────────────────────────
    env = os.environ.copy()
    env["N_FRAMES"] = str(args.frames)
    env["ROM_PROG"] = args.prog
    if args.gfx:   env["ROM_GFX"]   = args.gfx
    if args.z80:   env["ROM_Z80"]   = args.z80
    if args.adpcm: env["ROM_ADPCM"] = args.adpcm
    if args.vcd:   env["DUMP_VCD"]  = "1"

    # Calculate timeout
    timeout = args.timeout if args.timeout > 0 else max(30 * args.frames, 60)

    sim_bin = os.path.join(SCRIPT_DIR, "sim_kaneko16")
    if not os.path.exists(sim_bin):
        print(f"ERROR: {sim_bin} not found — build first", file=sys.stderr)
        return 1

    os.makedirs(args.out_dir, exist_ok=True)

    print(f"Running: {args.frames} frames, timeout={timeout}s", file=sys.stderr)
    try:
        result = subprocess.run(
            [sim_bin],
            env=env,
            cwd=args.out_dir,
            timeout=timeout,
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT after {timeout}s", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
