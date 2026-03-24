#!/usr/bin/env python3
"""
extract_bgaregga.py — Extract Battle Garegga ROMs for Raizing sim.

ROM source: bgaregga.zip

Program ROM (1MB = 512K × 2):
  prg0.bin = 512KB (even words)
  prg1.bin = 512KB (odd words)
  Interleave: out[i*2]=prg0[i], out[i*2+1]=prg1[i]
  Output: bgaregga_prog.bin (1MB)

Graphics ROM (8MB total):
  rom1.bin (2MB)
  rom2.bin (2MB)
  rom3.bin (2MB)
  rom4.bin (2MB)
  rom5.bin (1MB)
  Output: bgaregga_gfx.bin (8MB, zero-padded)

Sound ROM (128KB):
  snd.bin
  Output: bgaregga_snd.bin

OKI ADPCM (1MB):
  oki.bin or empty
  Output: bgaregga_oki.bin (1MB, zero-padded if missing)

Usage:
  python3 extract_bgaregga.py <path_to_bgaregga.zip>
"""

import sys
import zipfile
import os
import struct

def interleave_prog(bank0, bank1):
    """Interleave two 512KB program ROM banks into 1MB."""
    n = min(len(bank0), len(bank1))
    out = bytearray(n * 2)
    for i in range(n):
        out[i*2]   = bank0[i]
        out[i*2+1] = bank1[i]
    return bytes(out)

def combine_gfx(rom1, rom2, rom3, rom4, rom5):
    """Combine 5 graphics ROMs into 8MB."""
    out = bytearray(8 * 1024 * 1024)
    # rom1: 0x000000 (2MB)
    out[0x000000:0x000000+len(rom1)] = rom1
    # rom2: 0x200000 (2MB)
    out[0x200000:0x200000+len(rom2)] = rom2
    # rom3: 0x400000 (2MB)
    out[0x400000:0x400000+len(rom3)] = rom3
    # rom4: 0x600000 (2MB)
    out[0x600000:0x600000+len(rom4)] = rom4
    # rom5: 0x800000 (1MB)
    out[0x800000:0x800000+len(rom5)] = rom5
    return bytes(out)

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <bgaregga.zip>")
        sys.exit(1)

    zip_path = sys.argv[1]
    out_dir  = os.path.dirname(os.path.abspath(sys.argv[0]))

    with zipfile.ZipFile(zip_path, 'r') as z:
        names = z.namelist()
        
        # Helper to read ROM (try multiple locations)
        def read_rom(filename, required=True):
            # Try root first, then subdirs
            candidates = [filename] + [n for n in names if n.endswith(filename)]
            for candidate in candidates:
                if candidate in names:
                    return bytearray(z.read(candidate))
            if required:
                raise KeyError(f"ROM not found: {filename}")
            return bytearray()

        try:
            # --- Program ROM ---
            print("Extracting program ROM...")
            prg0 = read_rom("prg0.bin", required=True)
            prg1 = read_rom("prg1.bin", required=True)
            prog_data = interleave_prog(prg0, prg1)
            prog_out = os.path.join(out_dir, "bgaregga_prog.bin")
            with open(prog_out, "wb") as f:
                f.write(prog_data)
            print(f"  Written: {prog_out} ({len(prog_data)//1024}KB)")

            # --- Graphics ROM ---
            print("Extracting graphics ROM...")
            rom1 = read_rom("rom1.bin", required=True)
            rom2 = read_rom("rom2.bin", required=True)
            rom3 = read_rom("rom3.bin", required=True)
            rom4 = read_rom("rom4.bin", required=True)
            rom5 = read_rom("rom5.bin", required=True)
            gfx_data = combine_gfx(rom1, rom2, rom3, rom4, rom5)
            gfx_out = os.path.join(out_dir, "bgaregga_gfx.bin")
            with open(gfx_out, "wb") as f:
                f.write(gfx_data)
            print(f"  Written: {gfx_out} ({len(gfx_data)//1024}KB)")

            # --- Sound ROM ---
            print("Extracting sound ROM...")
            snd = read_rom("snd.bin", required=True)
            snd_out = os.path.join(out_dir, "bgaregga_snd.bin")
            with open(snd_out, "wb") as f:
                f.write(snd)
            print(f"  Written: {snd_out} ({len(snd)//1024}KB)")

            # --- OKI ADPCM (optional, pad with zeros if missing) ---
            print("Extracting OKI ADPCM...")
            oki_data = bytearray(1024 * 1024)  # 1MB, zero-padded
            # Try to find OKI ROM (not in standard bgaregga, but check anyway)
            try:
                oki = read_rom("oki.bin", required=False)
                if oki:
                    oki_data[0:len(oki)] = oki
                    print(f"  Found OKI: {len(oki)} bytes")
            except:
                pass
            oki_out = os.path.join(out_dir, "bgaregga_oki.bin")
            with open(oki_out, "wb") as f:
                f.write(oki_data)
            print(f"  Written: {oki_out} ({len(oki_data)//1024}KB) [zero-padded]")

            print("\nDone. ROM files ready for simulation.")
            print(f"Usage: cd {out_dir}")
            print("       ROM_PROG=bgaregga_prog.bin ROM_GFX=bgaregga_gfx.bin \\")
            print("       ROM_SND=bgaregga_snd.bin ROM_ADPCM=bgaregga_oki.bin \\")
            print("       make run N_FRAMES=1000")

        except KeyError as e:
            print(f"Error: {e}")
            sys.exit(1)

if __name__ == "__main__":
    main()
