#!/usr/bin/env bash
# Extract and prepare berlwall ROMs for the Kaneko16 simulation.
set -e
mkdir -p roms
unzip -o /Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/berlwall.zip -d roms/

# Interleave even/odd program ROMs into prog.bin
# bw100e_u23-01.u23 = even bytes (131072 bytes)
# bw101e_u39-01.u39 = odd  bytes (131072 bytes)
python3 -c "
even = open('roms/bw100e_u23-01.u23','rb').read()
odd  = open('roms/bw101e_u39-01.u39','rb').read()
out  = bytearray()
for i in range(min(len(even), len(odd))):
    out.append(even[i])
    out.append(odd[i])
open('roms/prog.bin','wb').write(out)
print(f'prog.bin: {len(out)} bytes')
"

# Concatenate sprite ROMs bw000-bw00b in order (12 × 512KB = 6MB)
cat roms/bw000.u46 roms/bw001.u84 roms/bw002.u83 roms/bw003.u77 \
    roms/bw004.u73 roms/bw005.u74 roms/bw006.u75 roms/bw007.u76 \
    roms/bw008.u65 roms/bw009.u66 roms/bw00a.u67 roms/bw00b.u68 > roms/spr.bin

# BG tile ROM is the same as sprite ROM for berlwall (no separate BG ROM)
cp roms/spr.bin roms/bg.bin

echo "ROMs prepared: $(ls -sh roms/*.bin)"
