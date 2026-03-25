# Midway Y-Unit / T-Unit on MiSTer DE-10 Nano: Feasibility Analysis

**Date:** 2026-03-24
**Subject:** Can Mortal Kombat / Smash TV / NBA Jam run on the MiSTer DE-10 Nano?
**Verdict:** MAYBE -- feasible with significant architectural work, but not via the obvious approach

---

## 1. The Hardware Under Analysis

### Midway Y-Unit (Smash TV, Mortal Kombat, Total Carnage, T2: Judgment Day)

| Parameter | Value | Source |
|-----------|-------|--------|
| CPU | TMS34010 | MAME midyunit.cpp |
| Master clock | 48 MHz (MK), 40 MHz (Smash TV), 50 MHz (T2) | MAME midyunit.cpp |
| CPU clock | ~6 MHz (master/8) | MAME midyunit.cpp |
| Pixel clock | 8 MHz (master/6) | MAME midyunit.cpp, Coin-Op docs |
| Resolution | ~400x254 visible (506x289 total) | MAME midyunit.cpp |
| Refresh rate | ~54.7 Hz | Derived from timing |
| Color depth | 6 bpp (Y-Unit), 8 bpp (Z-Unit) | MAME midyunit_v.cpp |
| VRAM | 512 KB (0x80000 bytes, 262,144 x uint16_t) | MAME midyunit_v.cpp |
| Main RAM | 128 KB (mapped at 0x01000000, 1MB address space) | MAME midyunit.cpp |
| Palette RAM | 128 KB (mapped at 0x01800000) | MAME midyunit.cpp |
| CMOS/NVRAM | 64 KB | MAME midyunit.cpp |
| Graphics ROM | Up to 64 MB (0x02000000-0x05ffffff) | MAME midyunit.cpp |
| DMA timing | 41 ns per pixel | MAME midyunit_v.cpp |

### Key Architectural Feature: Four Simultaneous VRAM Access Sources

The Y-Unit VRAM is accessed simultaneously by four independent agents:

1. **TMS34010 CPU** -- reads/writes VRAM for game logic, rendering commands
2. **DMA engine** -- blits sprite data from ROM into VRAM at 41 ns/pixel
3. **Video scanout** -- reads VRAM sequentially to drive the display at pixel clock rate
4. **Autoerase PLD** -- clears scanlines to background color between frames

On the original hardware, this was solved by using **true dual-port VRAM** (DRAM + shift register). The shift register handles video scanout independently while the DRAM port serves CPU/DMA/autoerase. The TMS34010 was specifically designed to interface with VRAM chips that have this dual-port architecture.

This is the crux of the problem: on MiSTer, all four access sources must share a single-port SDRAM.

---

## 2. Actual Bandwidth Requirements

### Display Scanout Bandwidth

```
Pixel clock:     8 MHz
Bits per pixel:  6 (Y-Unit) or 8 (Z-Unit), stored as 16-bit words
Words per pixel: 1 (uint16_t per pixel)
Scanout rate:    8 MHz x 2 bytes = 16 MB/s
```

This is the continuous, non-negotiable bandwidth floor. Every pixel must be read from VRAM and sent to the display. There is zero tolerance for jitter -- if a word arrives late, you get visual artifacts.

### DMA Bandwidth (Sprite Blitting)

```
DMA timing:      41 ns per pixel (from MAME source)
DMA throughput:  1 pixel / 41 ns = 24.4 Mpixels/s
Bytes per pixel: 2 (uint16_t writes to VRAM)
DMA bandwidth:   ~48.8 MB/s peak (during active DMA)
```

DMA also reads from graphics ROM simultaneously, adding another ~48.8 MB/s of ROM read bandwidth. DMA is bursty -- it runs during VBlank and whenever the CPU initiates a blit -- but during a complex scene (Mortal Kombat fatality with multiple sprites), DMA can be active for a significant fraction of the frame.

### CPU VRAM Access

```
CPU clock:       ~6 MHz
Not every cycle is a VRAM access, but the CPU does:
  - Read/write VRAM for pixel manipulation
  - Read/write palette RAM
  - Execute from program ROM
Estimated VRAM bandwidth: 5-10 MB/s (intermittent)
```

### Autoerase

```
Clears one scanline per HBlank period
512 pixels x 2 bytes = 1024 bytes per scanline
~289 scanlines x 54.7 Hz = 15,807 scanlines/s
Autoerase bandwidth: ~16 MB/s
```

### Total VRAM Bandwidth Budget

| Source | Bandwidth | Pattern |
|--------|-----------|---------|
| Display scanout | 16 MB/s | Continuous, latency-critical |
| DMA engine | up to 48 MB/s | Bursty, during blits |
| CPU access | 5-10 MB/s | Random, intermittent |
| Autoerase | 16 MB/s | Periodic, during HBlank |
| **Total peak** | **~90 MB/s** | Worst case simultaneous |
| **Total sustained** | **~50-60 MB/s** | Typical frame |

---

## 3. What MiSTer's SDRAM Actually Provides

### Raw Numbers

```
SDRAM clock:     140 MHz (tested reliable speed)
Bus width:       16 bits (2 bytes per transfer)
Raw throughput:  140 MHz x 2 bytes = 280 MB/s
```

280 MB/s raw vs. ~90 MB/s peak demand. On paper, this should be 3x more than enough. **So why does Pramod say it is impossible?**

### The Real Constraint: Latency, Not Bandwidth

SDRAM is not a simple SRAM. Every access involves overhead:

```
Random read (no bank interleaving):
  - Row activate (tRCD):  3 cycles
  - CAS latency (CL):     3 cycles
  - Data out:             1-2 cycles (burst length 1-2)
  - Precharge (tRP):      3 cycles (if row miss)
  Total: 7-10 cycles per 2-4 byte read

At 140 MHz, 8 cycles = 57 ns per random read
Effective random-read throughput: 140M / 8 = 17.5 Mreads/s x 2 bytes = 35 MB/s
```

With bank interleaving (4 banks, pipelined):
```
Effective throughput: ~126 MB/s at 96 MHz (measured)
Scaled to 140 MHz: ~184 MB/s with perfect interleaving
Realistic with 4 independent access sources: ~100-140 MB/s
```

With burst reads (burst length 2, sequential):
```
2 words per 5 cycles = 56 MB/s per stream at 140 MHz
```

### The Multi-Port Contention Problem

The core issue is not raw bandwidth but **access pattern conflict**:

1. **Display scanout** needs sequential reads at a fixed rate -- ideally a burst stream
2. **DMA** needs sequential writes to VRAM at 48 MB/s -- another burst stream
3. **CPU** needs random reads/writes -- worst case for SDRAM
4. **Autoerase** needs sequential writes during HBlank

On the original hardware, dual-port VRAM solved this elegantly: the shift register handles scanout independently, and the DRAM port handles CPU+DMA+autoerase with time-sharing. **Two ports, not one.**

On MiSTer SDRAM, ALL FOUR must time-share a single port. The SDRAM controller must:
- Reserve a continuous read stream for scanout (cannot stall)
- Interleave DMA writes between scanout reads
- Fit CPU random accesses in remaining gaps
- Squeeze autoerase writes into HBlank

This is an arbitration nightmare, not a bandwidth problem. The effective useful bandwidth drops to 30-50% of raw due to:
- Row activation/precharge between different access regions
- CAS latency on every new access
- Refresh cycles (~7% overhead)
- Arbitration stalls

**Effective usable bandwidth with 4-way arbitration: ~60-80 MB/s**

This is tight against the ~90 MB/s peak requirement. Any DMA-heavy frame (complex sprite scenes in MK) will exceed this budget and cause visible glitches.

### What About Dual SDRAM?

MiSTer supports dual SDRAM modules (128 MB each, independent buses). In theory:

```
Module 1: VRAM (scanout + DMA writes + autoerase)
Module 2: Main RAM + ROM data + DMA reads
```

This would halve the contention on the VRAM module to 3 sources instead of 4 (CPU VRAM access could be proxied through a line buffer). But:

- Dual SDRAM uses the Digital IO board GPIO header
- The second module shares GPIO pins with analog video output
- Community consensus (including Pramod) is that dual SDRAM still does not solve the contention problem for Y-Unit, because the three remaining VRAM access sources still exceed what one SDRAM module can service with low enough latency

---

## 4. Can 512 KB VRAM Fit in Block RAM (M10K)?

### Cyclone V 5CSEBA6 (MiSTer DE-10 Nano) BRAM Capacity

```
M10K blocks:        553
Bits per block:     10,240 (10 Kbit)
Total M10K:         5,530 Kbit = 691 KB
MLAB (distributed): ~621 Kbit additional
Total embedded:     ~6,151 Kbit = ~769 KB
```

### VRAM Size: 512 KB

```
512 KB = 4,096 Kbit = 410 M10K blocks (out of 553 available)
That is 74% of ALL M10K blocks on the entire FPGA.
```

**This is technically possible but practically catastrophic.** Here is why:

A MiSTer arcade core typically needs BRAM for:
- TMS34010 CPU register files and internal state: ~5-10 blocks
- Line buffers for video output: ~10-20 blocks
- DMA FIFOs and buffers: ~5-10 blocks
- Sound CPU RAM (ADSP-2105 has internal RAM): ~10-20 blocks
- Palette lookup tables: ~5-10 blocks
- CMOS/NVRAM: ~5 blocks
- MiSTer framework (OSD, scaler input): ~20-30 blocks
- **Subtotal: ~60-105 blocks**

Remaining after VRAM: 553 - 410 = 143 blocks. After framework overhead: 143 - 80 = ~63 blocks free. That is extremely tight but might just barely fit if the core is meticulously optimized.

**However, BRAM solves the bandwidth problem completely:**

```
M10K blocks support true dual-port access:
  - Port A: CPU + DMA writes (one read/write per clock)
  - Port B: Video scanout (one read per clock)

At 100 MHz FPGA clock:
  Port A throughput: 100 MHz x 2 bytes = 200 MB/s
  Port B throughput: 100 MHz x 2 bytes = 200 MB/s
  Total: 400 MB/s dual-port
```

This is 4-5x more bandwidth than needed, with true simultaneous dual-port access. Video scanout on Port B never conflicts with CPU/DMA on Port A.

The remaining challenge: autoerase and DMA and CPU all sharing Port A. But at 200 MB/s on a single port, that is more than enough for the ~70 MB/s they need combined.

### Verdict on BRAM Approach

**Technically feasible. Uses 74% of BRAM. Leaves the core extremely tight on BRAM for everything else.** This is the kind of tradeoff that requires a master FPGA architect to pull off -- every other component must be BRAM-minimal.

Pramod's statement that he "eliminated the GPU" (TMS34010 graphics pipeline) to fit on Analogue Pocket suggests he faced similar BRAM pressure. The Pocket's Cyclone V has only 49K LEs and 3.4 Mbit BRAM (425 KB), which is LESS than the DE-10 Nano's 691 KB. So the Pocket cannot even fit the full 512 KB VRAM in BRAM -- he had to use external memory.

---

## 5. What the Analogue Pocket Does Differently

The Analogue Pocket has a fundamentally different memory topology:

| Memory Type | Size | Bus | Max Clock | Bandwidth | Access Pattern |
|-------------|------|-----|-----------|-----------|----------------|
| PSRAM (Cellular RAM) x2 | 16 MB each (32 MB total) | 16-bit each | 133 MHz sync | ~266 MB/s each | Low-latency random + burst |
| SDRAM | 64 MB | 16-bit | 166 MHz | ~332 MB/s | High bandwidth burst |
| SRAM | 256 KB | 16-bit | Async | Very low latency | True random access |
| BRAM | 425 KB (3.4 Mbit) | Dual-port | FPGA clock | Internal | Registers/buffers |

### Pramod's Architecture (from Coin-Op documentation)

Key insights from the Z-Unit development docs:

1. **Palette memory in SDRAM** (256 KB) with a custom 48-bit write controller
2. **Deferred write queue** (32 entries of 48-bit operations) to batch palette writes
3. **Statistical inferencing** to reduce SDRAM write traffic
4. **Overclocked SDRAM** at 128 MHz with CAS latency 2 (aggressive timing)
5. **Eliminated the TMS34010 GPU pipeline** to save LEs (plans to revive on MARS)

The Pocket's advantage is **four independent memory buses**:
- PSRAM #1: VRAM bitmap (low-latency, independent bus)
- PSRAM #2: Main RAM or palette (independent bus)
- SDRAM: Graphics ROM data / DMA source
- SRAM: Fast scratch / palette cache

Each bus operates independently and simultaneously. There is no arbitration conflict between scanout and DMA because they hit different physical memory buses. **This is the architectural trick -- it is not "faster SDRAM," it is "more memory buses."**

MiSTer has only one SDRAM bus (or two with dual SDRAM). Four independent access sources fighting over one bus vs. four sources spread across four buses is a fundamentally different problem.

---

## 6. HPS DDR3 via FPGA-to-HPS Bridge

The DE-10 Nano has 1 GB DDR3 accessible through the ARM HPS.

### Measured Performance

```
Natural bridge (32-bit, 28 MHz): ~7.5 MB/s
Sped-up bridge (32-bit, 196 MHz): ~15 MB/s
```

**This is catastrophically slow.** The FPGA-to-HPS bridge is designed for control-plane communication (configuration, file loading), not data-plane access. At 15 MB/s, it cannot even sustain display scanout (16 MB/s), let alone DMA.

The DDR3 also has variable, unpredictable latency due to the ARM CPU's cache coherency protocol and refresh management. Even if the bandwidth were sufficient, the latency jitter would make it unusable for real-time video scanout.

**Verdict: DDR3 via HPS is completely unsuitable for VRAM.**

It could potentially be used for bulk ROM loading at startup, but not for runtime memory access.

---

## 7. Alternative Architecture: Hybrid BRAM + SDRAM

Here is the architecture that could make this work on MiSTer:

### Memory Map

| Memory | Location | Size | Access Pattern |
|--------|----------|------|----------------|
| VRAM (bitmap) | **BRAM** (dual-port) | 256 KB | CPU/DMA on port A, scanout on port B |
| VRAM (palette) | **BRAM** (dual-port) | 8 KB (actual used entries) | CPU writes on A, scanout reads on B |
| Main RAM | **SDRAM** | 128 KB | CPU only (no contention) |
| Graphics ROM | **SDRAM** | Up to 8 MB | DMA reads (bursty) |
| Program ROM | **SDRAM** | Up to 1 MB | CPU instruction fetch |
| DCS Sound RAM/ROM | **SDRAM** | Variable | Sound CPU (low bandwidth) |

### Key Insight: The Full 512 KB VRAM Is Not All Bitmap

MAME allocates 512 KB (262,144 x uint16_t) for the full VRAM address space. But the actual visible framebuffer is much smaller:

```
Y-Unit visible area: ~400 x 256 pixels
Internal framebuffer: 512 x 512 pixels (512 entries per scanline x 510 lines)
At 16 bits per pixel: 512 x 512 x 2 = 524,288 bytes = 512 KB

But wait -- 6 bpp games only use 6 bits of each 16-bit word.
If we pack 6-bit pixels: 512 x 512 x 6/8 = 196,608 bytes = 192 KB
```

However, the TMS34010 is a bit-addressable CPU that can do arbitrary pixel field sizes. The VRAM must be byte-addressable at 16-bit granularity. We cannot pack pixels without breaking CPU addressing.

**Revised BRAM budget for 256 KB bitmap (visible area only):**

```
256 KB = 2,048 Kbit = 205 M10K blocks (37% of total)
Remaining: 553 - 205 = 348 blocks for everything else
```

This is much more reasonable. The trick: use a 256 KB dual-port BRAM for the active framebuffer region, and handle the "offscreen" VRAM addresses (which the CPU rarely touches during active rendering) via SDRAM with a cache/writeback strategy.

### Scanline Buffer Alternative

An even more efficient approach:

```
Scanline buffer:    2 x 512 x 2 bytes = 2 KB BRAM (double-buffered)
Full VRAM:          512 KB in SDRAM
Prefetch:           Read next scanline from SDRAM into buffer during HBlank
```

This needs only 2 KB of BRAM for video scanout, keeping 512 KB VRAM in SDRAM. But it requires the SDRAM controller to guarantee one full scanline read (1024 bytes) during each HBlank period (~17 us at 8 MHz pixel clock).

```
HBlank duration:    ~17.4 us (106 pixels at 8 MHz = 13.25 us; plus sync ~4 us)
Bytes to read:      1024 bytes = 512 x 16-bit words
SDRAM burst read:   512 words at 140 MHz with burst length 2 = 256 bursts
At ~5 cycles/burst: 1280 cycles = 9.1 us
```

9.1 us out of 17.4 us available HBlank time -- that is 52% utilization. The remaining 48% of HBlank is available for autoerase writes, DMA, and CPU access. During active display, no scanout reads are needed (the line buffer serves them), so SDRAM is fully available for DMA and CPU.

**This is the viable architecture.**

### Full Architecture Diagram

```
                    +------------------+
                    |    TMS34010      |
                    |   (in FPGA)      |
                    +--------+---------+
                             |
                    +--------+---------+
                    |  Memory Arbiter  |
                    +--+-----+-----+---+
                       |     |     |
              +--------+  +--+--+  +--------+
              |           |     |           |
     +--------+--+   +----+----+   +--------+--+
     |  SDRAM    |   | BRAM    |   | BRAM      |
     | (external)|   | Scanline|   | Palette   |
     |           |   | Buffer  |   | (8 KB)    |
     | VRAM 512K |   | (2 KB)  |   |           |
     | Main 128K |   | dbl-buf |   | dual-port |
     | ROM  ~8MB |   +---------+   +-----------+
     | Sound RAM |
     +-----------+

     Scanout: BRAM line buffer (port B) -> video encoder
     HBlank:  SDRAM -> BRAM line buffer (prefetch next scanline)
     DMA:     SDRAM ROM -> SDRAM VRAM (within SDRAM, bank interleaved)
     CPU:     SDRAM VRAM (random access during active scan)
     Autoerase: SDRAM VRAM (during HBlank, after scanline prefetch)
```

### Bandwidth Analysis for This Architecture

During active display (per scanline, ~53 us):
```
Scanout:     From BRAM line buffer -- zero SDRAM bandwidth
DMA:         Up to 53 us x 48 MB/s = ~2.5 KB of DMA per line (from SDRAM)
CPU:         Random SDRAM access, ~6 MHz = ~12 MB/s
Available:   Full SDRAM bandwidth (~100-140 MB/s effective)
Margin:      Huge -- 60 MB/s used out of 100+ available
```

During HBlank (~17 us):
```
Scanline prefetch:  1024 bytes in ~9 us
Autoerase write:    1024 bytes in ~9 us
Remaining:          ~0 us (tight but feasible if pipelined)
```

The HBlank period is the bottleneck. Two 1024-byte transfers in 17 us:

```
2048 bytes / 17 us = 120 MB/s sustained during HBlank
SDRAM at 140 MHz with bank interleaving: ~140 MB/s
```

This is tight (85% utilization during HBlank) but feasible with a well-optimized SDRAM controller using bank interleaving between the read (prefetch) and write (autoerase) streams.

---

## 8. Why Pramod Could Not Make It Work

Based on the available evidence, Pramod likely attempted the straightforward approach:

1. Put full 512 KB VRAM in SDRAM
2. Time-multiplex CPU/DMA/scanout/autoerase on the single SDRAM port
3. Found that the arbitration overhead + CAS latency + refresh cycles dropped effective bandwidth below the ~90 MB/s peak requirement
4. Tried dual SDRAM -- still insufficient because 3 of the 4 access sources still hit the same module
5. After 6 months, concluded it is not feasible on MiSTer

The scanline-buffer approach described above was either not attempted or had implementation issues I cannot determine from available information. It is possible that Pramod tried it and encountered edge cases (e.g., DMA writes to the current scanline that the buffer has already prefetched, requiring cache coherency between BRAM buffer and SDRAM).

It is also possible that the TMS34010 CPU implementation itself is the blocker -- if the CPU pipeline requires single-cycle VRAM access (no wait states), then SDRAM latency would stall the CPU, causing timing divergence from the original hardware. The scanline buffer only solves the scanout problem, not the CPU VRAM access latency problem.

---

## 9. Verdict

### Overall: MAYBE -- but requires non-obvious architecture

| Approach | Feasibility | Risk |
|----------|-------------|------|
| Naive: Full VRAM in SDRAM, 4-way arbitration | **NO** | Bandwidth/latency insufficient |
| Full VRAM in BRAM (512 KB) | **UNLIKELY** | Uses 74% of BRAM, leaves too little for everything else |
| Scanline buffer + SDRAM VRAM | **MAYBE** | HBlank is tight; DMA coherency is complex |
| Partial BRAM (256 KB active) + SDRAM overflow | **MAYBE** | Tricky address mapping; wastes BRAM |
| Dual SDRAM with scanline buffer | **LIKELY** | Second module for ROM relaxes contention significantly |
| DDR3 via HPS bridge | **NO** | 15 MB/s, unusable |
| Wait for MARS FPGA | **YES** | Efinix Titanium Ti180 + DDR4 + HyperRAM at 200 MHz |

### The Best-Case MiSTer Architecture

If someone were to attempt this today, the recommended approach would be:

1. **Single SDRAM module** holds VRAM (512 KB) + Main RAM (128 KB) + Program ROM + Graphics ROM
2. **BRAM scanline double-buffer** (2 KB) prefetched during HBlank -- eliminates scanout from SDRAM arbitration
3. **BRAM palette cache** (8 KB) -- eliminates palette reads from SDRAM
4. **Autoerase during HBlank** immediately after scanline prefetch (pipelined, same SDRAM bank row)
5. **Bank-interleaved SDRAM controller** that maps VRAM, RAM, and ROM into separate SDRAM banks to minimize row activation conflicts
6. **DMA write coalescing** -- batch DMA writes into bursts to maximize SDRAM efficiency
7. **CPU wait states** on VRAM access -- the TMS34010 supports wait states; use them to avoid SDRAM stalls

Total BRAM cost: ~10 KB (scanline buffers + palette) = ~8 M10K blocks. This leaves 545 blocks for everything else -- completely reasonable.

### Why This Might Still Fail

1. **HBlank budget**: Scanline prefetch (1024B) + autoerase (1024B) in 17 us requires ~120 MB/s sustained SDRAM throughput during HBlank. This is achievable with bank interleaving but leaves zero margin for DMA during HBlank.

2. **CPU VRAM latency**: If the TMS34010 game code relies on single-cycle VRAM reads (no wait states), SDRAM latency (~57 ns per random read) will cause the CPU to run slower than the original hardware, potentially breaking game timing.

3. **DMA coherency**: If DMA writes to a scanline that has already been prefetched into the BRAM buffer, the display will show stale data for that frame. This requires a DMA snoop mechanism.

4. **Refresh overhead**: SDRAM refresh steals ~7% of available bandwidth, and refresh commands cannot be deferred during HBlank critical sections.

### Bottom Line

The problem is real but not necessarily impossible. Pramod is one of the most skilled FPGA core developers in the community, and his conclusion carries significant weight. However, the analysis suggests that a scanline-buffer architecture with aggressive SDRAM controller optimization could potentially close the gap. The margin is razor-thin (~85% SDRAM utilization during HBlank), which means it would work on paper but might fail in practice due to edge cases, refresh collisions, or DMA coherency issues.

The most promising unexplored path would be **dual SDRAM + scanline buffer**: Module 1 for VRAM (bitmap + palette), Module 2 for ROM + RAM. With scanout handled by BRAM buffers, Module 1 only needs to service DMA writes + CPU access + autoerase + scanline prefetch, which drops the peak requirement to ~80 MB/s on a single module with ~140 MB/s available. That is 57% utilization -- comfortable margin.

---

## Sources

- [Coin-Op Collection Y-Unit Development Documentation](https://github.com/Coin-OpCollection/Development-Documentation/blob/main/Midway/Y-Unit/midway_yunit.md)
- [Coin-Op Collection Z-Unit Development Documentation](https://github.com/Coin-OpCollection/Development-Documentation/blob/main/Midway/Z-Unit/midway_zunit.md)
- [MAME midyunit.cpp](https://github.com/mamedev/mame/blob/master/src/mame/midway/midyunit.cpp)
- [MAME midyunit_v.cpp](https://github.com/mamedev/mame/blob/master/src/mame/midway/midyunit_v.cpp)
- [MAME midtunit.cpp](https://github.com/mamedev/mame/blob/master/src/mame/midway/midtunit.cpp)
- [Pramod on Twitter: VRAM bandwidth explanation](https://x.com/pr4m0d/status/1808173252239401306)
- [Time Extension: Mortal Kombat "Not Feasible" on MiSTer](https://www.timeextension.com/news/2024/10/coin-op-mortal-kombat-now-playable-on-analogue-pocket-mister-fpga-version-not-feasible)
- [Time Extension: Pramod interview on FPGA challenges](https://www.timeextension.com/news/2024/09/i-am-tired-of-receiving-death-threats-over-a-video-game-fpga-dev-explains-why-mortal-kombat-is-skipping-mister)
- [MiSTer FPGA Forum: Mortal Kombat feasibility](https://misterfpga.org/viewtopic.php?t=6064)
- [MiSTer FPGA Forum: Y-Unit discussion](https://misterfpga.org/viewtopic.php?t=7542)
- [Analogue Pocket Developer Docs: External Hardware](https://www.analogue.co/developer/docs/external-hardware)
- [Intel Cyclone V Embedded Memory Capacity](https://www.intel.com/content/www/us/en/docs/programmable/683375/current/embedded-memory-capacity-in-cyclone.html)
- [TMS34010 Wikipedia](https://en.wikipedia.org/wiki/TMS34010)
- [System 16: Y-Unit Hardware](https://www.system16.com/hardware.php?id=610)
- [MARS FPGA overview (RetroRGB)](https://retrorgb.com/mars-multi-arcade-retro-system.html)
- [Midway T-Unit Wikipedia](https://en.wikipedia.org/wiki/Midway_T_Unit)
- [MiSTer Dual SDRAM documentation](https://misterfpga.org/viewtopic.php?t=5562)
- [Jotego CPS3/PGM/Mortal Kombat discussion](https://misterfpga.org/viewtopic.php?t=3653)
