#!/bin/bash
# run_test.sh — Extract Thunder Dragon ROM and run minimal fx68k test
#
# Usage: ./run_test.sh /path/to/tdragon.zip
#
# The script:
#  1. Extracts the two program ROM halves from the zip
#  2. Interleaves them (even=.8, odd=.7) into a flat binary
#  3. Runs sim_minimal with ROM_FILE pointing at the interleaved binary

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 /path/to/tdragon.zip"
    exit 1
fi

ZIP_FILE="$1"
INTERLEAVED_ROM="/tmp/tdragon_prog.bin"

echo "==> Extracting and interleaving Thunder Dragon program ROM..."
python3 - "$ZIP_FILE" "$INTERLEAVED_ROM" <<'EOF'
import sys
import zipfile
import os

zip_path = sys.argv[1]
out_path = sys.argv[2]

# List contents so we can find the right filenames
with zipfile.ZipFile(zip_path) as z:
    names = z.namelist()
    print(f"  ZIP contents: {names}")

    # Thunder Dragon program ROMs:
    #   91070_68k.8  — even bytes (addr bit 0 = 0)
    #   91070_68k.7  — odd  bytes (addr bit 0 = 1)
    # Try to find them by suffix; fall back to first two candidates.
    even_name = None
    odd_name  = None
    for n in names:
        if n.endswith('_68k.8') or n == '91070_68k.8':
            even_name = n
        if n.endswith('_68k.7') or n == '91070_68k.7':
            odd_name = n

    # Fallback: look for any pair of files that look like prog ROMs
    if even_name is None or odd_name is None:
        prog_roms = [n for n in names if '68k' in n or 'prg' in n.lower() or 'prog' in n.lower()]
        print(f"  Candidate prog ROMs: {prog_roms}")
        if len(prog_roms) >= 2:
            prog_roms.sort()
            even_name = prog_roms[1]  # higher name = even (by convention)
            odd_name  = prog_roms[0]  # lower  name = odd
            print(f"  Fallback: using even={even_name}, odd={odd_name}")

    if even_name is None or odd_name is None:
        print("ERROR: Could not identify program ROM files in zip.")
        print(f"  Available: {names}")
        sys.exit(1)

    print(f"  Even bytes: {even_name}")
    print(f"  Odd  bytes: {odd_name}")

    even = z.read(even_name)
    odd  = z.read(odd_name)

    n_words = min(len(even), len(odd))
    rom = bytearray(n_words * 2)
    for i in range(n_words):
        rom[i*2]     = even[i]
        rom[i*2 + 1] = odd[i]

    with open(out_path, 'wb') as f:
        f.write(rom)

    print(f"  Written {len(rom)} bytes to {out_path}")
    sp  = (rom[0]<<24)|(rom[1]<<16)|(rom[2]<<8)|rom[3]
    pc  = (rom[4]<<24)|(rom[5]<<16)|(rom[6]<<8)|rom[7]
    print(f"  Reset vector: SP=0x{sp:08X}  PC=0x{pc:08X}")
EOF

echo ""
echo "==> Building sim_minimal (if needed)..."
cd "$SCRIPT_DIR"
make --no-print-directory

echo ""
echo "==> Running minimal fx68k test..."
ROM_FILE="$INTERLEAVED_ROM" ./sim_minimal
