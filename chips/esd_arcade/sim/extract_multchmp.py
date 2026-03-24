#!/usr/bin/env python3
"""
extract_multchmp.py — Extract and interleave Multi Champ ROMs for ESD sim.

ROM source: multchmp.zip (multchmpk set)

Program ROM (512KB):
  multchmp.u02 = 256KB even bytes (byte_addr 0,2,4,...)
  multchmp.u03 = 256KB odd bytes  (byte_addr 1,3,5,...)
  Interleave: out[i*2]=u02[i], out[i*2+1]=u03[i]
  Output: multchmp_prog.bin (512KB)

BG Tile ROM (4MB total, 8 ROMs interleaved 32-bit wide):
  ROM_LOAD32_BYTE layout from MAME esd16.cpp:
    ROM_LOAD32_BYTE("u31", 0x000000, 0, 4)
    ROM_LOAD32_BYTE("u29", 0x000001, 0, 4)
    ROM_LOAD32_BYTE("u33", 0x000002, 0, 4)
    ROM_LOAD32_BYTE("u27", 0x000003, 0, 4)
    ROM_LOAD32_BYTE("u32", 0x200000, 0, 4)
    ROM_LOAD32_BYTE("u30", 0x200001, 0, 4)
    ROM_LOAD32_BYTE("u34", 0x200002, 0, 4)
    ROM_LOAD32_BYTE("u28", 0x200003, 0, 4)
  Each ROM is 512KB, output is 4MB.
  Output: multchmp_bg.bin (4MB)

Usage:
  python3 extract_multchmp.py <path_to_multchmp.zip>
"""

import sys
import zipfile
import os
import struct

def interleave_prog(even_data, odd_data):
    """Interleave even/odd byte ROMs into word-wide program ROM."""
    n = min(len(even_data), len(odd_data))
    out = bytearray(n * 2)
    for i in range(n):
        out[i*2]   = even_data[i]
        out[i*2+1] = odd_data[i]
    return bytes(out)

def interleave_bg_32bit(roms_512k):
    """
    Interleave 8 ROMs using ROM_LOAD32_BYTE pattern.
    roms_512k: list of 8 bytearray, each 512KB
    Returns 4MB output.
    First 4 ROMs fill bytes 0,1,2,3 of each 4-byte word in first 2MB.
    Last 4 ROMs fill bytes 0,1,2,3 of each 4-byte word in second 2MB.
    """
    size = 512 * 1024  # 512KB each
    out = bytearray(4 * 1024 * 1024)  # 4MB
    # First 2MB: roms 0..3
    for rom_idx in range(4):
        rom = roms_512k[rom_idx]
        byte_lane = rom_idx  # 0=byte0, 1=byte1, 2=byte2, 3=byte3
        for i in range(size):
            out[i * 4 + byte_lane] = rom[i]
    # Second 2MB (offset 0x200000): roms 4..7
    for rom_idx in range(4):
        rom = roms_512k[4 + rom_idx]
        byte_lane = rom_idx
        for i in range(size):
            out[0x200000 + i * 4 + byte_lane] = rom[i]
    return bytes(out)

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <multchmp.zip>")
        sys.exit(1)

    zip_path = sys.argv[1]
    out_dir  = os.path.dirname(os.path.abspath(sys.argv[0]))

    with zipfile.ZipFile(zip_path, 'r') as z:
        names = z.namelist()
        # Helper: read a file from the zip (try with and without subdir prefix)
        def read_rom(filename):
            # Try multchmpk/ prefix first
            for candidate in [f"multchmpk/{filename}", filename]:
                if candidate in names:
                    return bytearray(z.read(candidate))
            raise KeyError(f"ROM not found in zip: {filename}")

        # --- Program ROM ---
        print("Extracting program ROM...")
        u02 = read_rom("multchmp.u02")
        u03 = read_rom("multchmp.u03")
        prog_data = interleave_prog(u02, u03)
        prog_out = os.path.join(out_dir, "multchmp_prog.bin")
        with open(prog_out, "wb") as f:
            f.write(prog_data)
        print(f"  Written: {prog_out} ({len(prog_data)//1024}KB)")

        # --- BG Tile ROM ---
        print("Extracting BG tile ROM...")
        # Order per MAME ROM_LOAD32_BYTE:
        # byte0: u31, byte1: u29, byte2: u33, byte3: u27
        # byte0: u32, byte1: u30, byte2: u34, byte3: u28
        bg_rom_names = ["multchmp.u31", "multchmp.u29", "multchmp.u33", "multchmp.u27",
                        "multchmp.u32", "multchmp.u30", "multchmp.u34", "multchmp.u28"]
        bg_roms = [read_rom(n) for n in bg_rom_names]
        bg_data = interleave_bg_32bit(bg_roms)
        bg_out = os.path.join(out_dir, "multchmp_bg.bin")
        with open(bg_out, "wb") as f:
            f.write(bg_data)
        print(f"  Written: {bg_out} ({len(bg_data)//1024}KB)")

    print("Done.")

if __name__ == "__main__":
    main()
