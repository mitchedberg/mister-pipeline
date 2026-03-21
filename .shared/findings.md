# Cross-Agent Findings — Check Before Each Build

Bugs found by one agent that affect ALL cores. Read this before building/debugging.
Any agent can append. Newest entries at top.

---

## 2026-03-20 — BLOCKER: fx68k never takes interrupts in Verilator
**Found by:** Agent 2 (sim-batch2)
**Affects:** ALL cores using fx68k (Kaneko, Taito B, Taito X, NMK, Toaplan V2, Psikyo)
**Status:** UNRESOLVED — needs investigation

**Symptoms:**
- IPL signal correctly driven to level 4 (221K samples where IPL != 7)
- CPU never generates IACK cycle (FC=111, ASn=0) — 0 IACK events
- Tested with level 4 AND level 6 — same result
- enPhi1/enPhi2 alternation works for bus cycles (millions executed)
- VPAn correctly wired for autovector (VPAn = ~&{FC2,FC1,FC0,~ASn})
- Added IACK DTACK suppression to prevent open-bus interference — no effect

**What was tried:**
1. Level 4 interrupt (berlwall native) → IACK=0
2. Level 6 interrupt → IACK=0
3. Supervisor mode forced (SR=0x201F) → IACK=0
4. IACK DTACK suppression in tb_top.sv → IACK=0

**Hypothesis:** The fx68k's internal `intPend` flag might never be set, or the sequencer never reaches the state that processes it. Could be a Verilator-specific simulation issue with the `/* verilator public */` annotated signals, or a clock enable timing issue.

**Impact:** Games boot and run code, but VBlank-driven game logic never executes. Rendering works (palette, tiles visible) but display is static. ALL cores are affected since they all need VBlank interrupts for gameplay.

**Workaround ideas:**
1. Use Musashi (software 68000) instead of fx68k for simulation
2. Inject VBlank handler calls from C++ testbench via bypass mechanism
3. Debug fx68k's `intPend`/`iplStable`/`iplComp` signals with VCD trace

---

## 2026-03-20 — CROSS-CORE LESSONS LEARNED (Agent 2 session)
**Applies to:** ALL cores going forward. Hard-won rules from debugging 3 cores.

### 1. ALWAYS verify game-specific memory map from the ACTUAL init function
Each Kaneko16 game has a DIFFERENT memory map. I wasted hours using GtmrMachineInit's map for berlwall — wrong game entirely. **Rule: grep for `GameNameInit` in FBNeo, find the SekMapMemory calls in THAT function, not a shared/common init.**

### 2. Open-bus DTACK is MANDATORY for every core
Any unmapped address without DTACK hangs the CPU forever. Add a catch-all open-bus chip select that covers everything not matched by real chip selects. Costs 1 LUT, saves hours of debugging.

### 3. fx68k microrom.mem must be in the sim binary's CWD
The `$readmem` in fx68k loads from the current working directory at runtime. If `--out-dir` differs from the sim binary location, copy microrom.mem + nanorom.mem to the output directory too.

### 4. Pixel capture must use clk_pix gating
Never sample RGB on every sys_clk — the DAR/palette pipeline only produces valid pixels on pixel clock edges. Gate capture with `&& top->clk_pix`. For cores with internal video timing (no external hpos/vpos), track position from hblank/vblank edges.

### 5. ROM self-test traps are BRA.S * (0x60FE) at consecutive addresses
Games typically have 3+ `BRA.S *` instructions at 0x0B00/0B02/0B04 (or similar). BNE/BMI branches target specific trap addresses — the target tells you WHICH test failed. Patch with NOP (4E71) to skip tests during bring-up.

### 6. kaneko16 address mux: set cpu_addr[20:16] prefix for internal regions
kaneko16.sv uses `cpu_addr[20:16]` to identify internal regions (5'd18=sprites, 5'd27=GFX window). The kaneko_arcade wrapper must set these high bits based on which external chip select matched — passing `{5'b0, addr}` makes is_sprite_ram/is_gfx_window permanently false.

### 7. AY8910 DIP reads: register number encoded in CPU address
berlwall reads AY8910 via combined address/data: `reg_num = (byte_addr - 0x800000) >> 1`. Register 14 = Port A (DIP1), register 15 = Port B (DIP2). Simple stub: decode cpu_addr[4:1] and return DIP values for 14/15.

---

## 2026-03-20 — Kaneko/Berlwall: address map completely wrong for this game
**Found by:** Agent 2 (sim-batch2)
**Affects:** kaneko_arcade RTL + sim harness
**Root cause:** kaneko_arcade.sv address map was written for a different Kaneko16 game. For berlwall:
- 0x200000 should be **MCU RAM** (64KB, plain R/W), NOT Kaneko16 GPU registers
- 0x300000 should be **palette RAM**, NOT at 0x600000
- Kaneko16 GPU registers are at 0x500000 (tilemap VRAM) and via specific I/O ports
- SSP = 0x0020DFF0 (stack at top of MCU RAM at 0x200000)
**Evidence:** Game self-test at ROM 0x0AD8 writes SR to 0x0020CFFE and reads back. Since 0x200000 is mapped to kaneko16 GPU registers (not RAM), the read-back fails and the game traps at `BRA.S *` (0x0B04).
**Bugs fixed so far (3):**
1. Wrong tb_top.sv: Was using GPU-only wrapper, switched to kaneko_arcade full system
2. Missing fx68k microrom.mem: Added ensure_microrom to out-dir
3. Unmapped DTACK: Added open-bus DTACK for 0x780000 (watchdog) and all other unmapped addresses
**Files changed:** tb_system.cpp (rewrite), Makefile (new RTL list), run_sim.py (new), kaneko_arcade.sv (open-bus DTACK)
**Next:** Remap kaneko_arcade.sv parameters for berlwall address layout, or parameterize per-game.

**CORRECT berlwall memory map (from FBNeo d_kaneko16.cpp, BerlwallInit line 4724):**
**WARNING**: The map at ExplbrkrInit/GtmrMachineInit is for DIFFERENT GAMES, not berlwall!
| Address | Size | Contents |
|---------|------|----------|
| 0x000000-0x03FFFF | 256KB | Program ROM |
| 0x200000-0x20FFFF | 64KB | Work RAM (SSP = 0x0020DFF0 → stack here) |
| 0x30E000-0x30FFFF | 8KB | Sprite RAM |
| 0x400000-0x400FFF | 4KB | Palette RAM |
| 0x500000 | R/W | Brightness register (handler) |
| 0x600002-0x60003F | 64B | Sprite control registers (write-only) |
| 0x700000-0x70000F | 16B | I/O (joystick, coins, DIP, sound cmd) |
| 0x780000 | read | Watchdog (returns 0) |
| 0x800000-0x800FFF | R/W | AY8910 × 2 (PSG sound, handler) |
| 0xC00000-0xC00FFF | 4KB | Video1 RAM (tilemap) |
| 0xC01000-0xC01FFF | 4KB | Video0 RAM (tilemap) |
| 0xC02000-0xC03FFF | 8KB | Scroll RAMs (VScrl1 + VScrl0) |
| 0xD00000-0xD0001F | 32B | Layer0 control registers (write-only) |

## 2026-03-20 — Gigandes rendering non-black pixels from frame 12
**Found by:** Session 3 (continued)
**Affects:** taito_x sim harness
**Status:** After fixing ROM loading, WRAM decode, vpos width, I/O decode, DIP switches, TC0140SYT stub, player inputs at 0x900000, GFX ROM_LOAD64_WORD interleaving, and X1-001A bank latch — Gigandes produces non-black pixels starting at frame 12. Purple sprite pixels visible at top-left corner (x=1-16, y=0-1). 59 frames captured in 120-frame run. Game is in early attract mode.
**Key insight:** Gigandes does NOT use the C-Chip. 0x900000 is plain player I/O (confirmed from FBNeo source). C-Chip is Superman-only.
**Next:** Run for 300+ frames to see full attract mode. Compare against MAME reference frames.

## 2026-03-20 — Gigandes: ROM filenames wrong + WRAM CS hardcoded + vpos 8-bit overflow
**Found by:** Session 3
**Affects:** taito_x sim harness (Gigandes)
**Issues and fixes:**
1. **ROM filenames**: run_sim.py used Superman filenames (`b62_*`) instead of Gigandes (`east_*`). Fixed to 4-file, 2-pair FBNeo interleaving: east_1+east_3 (pair 0), east_2+east_4 (pair 1).
2. **WRAM chip select hardcoded**: `wram_cs` compared against `9'h010` (Superman byte 0x100000) instead of WRAM_BASE parameter. Gigandes WRAM is at 0xF00000. Fixed to `cpu_addr[23:15] == WRAM_BASE[22:14]`.
3. **vpos 8-bit overflow**: `logic [7:0] vpos` with V_TOTAL=262 caused `8'(261)` to truncate to 5. Counter wrapped every 6 lines, vblank never fired, no frames captured. Fixed to `logic [8:0] vpos`.
**Result:** Gigandes CPU boots (SSP=0x00F04000, PC=0x000100), runs 131 bus cycles, produces 3 frames (384×240, black). Stalls at C-Chip (0x900000) which is not implemented.
**Nastar and Berlwall**: ROM loading was already correct (FBNeo pairing verified against vector table). Both produce frames.
**Action for other cores:** CRITICAL — when using `ROM_LOAD16_BYTE` with `TAITO_68KROM1_BYTESWAP`, the FBNeo ROM order (ROM[0]+ROM[1], ROM[2]+ROM[3]) is NOT the same as MAME's offset-based pairing. Always verify by checking the vector table (SSP should point to WRAM, PC to ROM).

## 2026-03-19 16:00 — Taito X (gigandes) CPU reads all zeros — SDRAM sdr channel broken
**Found by:** Agent 2 (sim-batch2)
**Affects:** taito_x sim harness
**Issue:** CPU fetches vector table (addr 0x000000-0x000092) but dout=0x0000 and dtack_n=1 for every read. SDRAM toggle-handshake for `sdr` channel never completes.
**Root cause (suspected):** Address mapping bug between tb_top.sv/tb_system.cpp — sdr_addr is 27-bit but may have word/byte confusion.
**Action:** Debug sdr channel wiring. Compare against NMK prog_rom channel which works correctly.

## 2026-03-19 15:50 — Kaneko (berlwall) CPU boots but zero WRAM writes — game loop stalled
**Found by:** Agent 2 (sim-batch2)
**Affects:** kaneko_arcade sim harness
**Issue:** CPU boots OK (SSP=0x0020DFF0, PC=0x0000055E), 100K+ bus cycles, 512 palette writes (all zero data). But WRAM writes = 0 across 120 frames. Game init appears stuck in I/O poll loop.
**Root cause (suspected):** Kaneko16 chip register reads or I/O port responses may not return expected values. Also: tb_system.cpp frame buffer is 256×224 but RTL generates 320×240.
**Action:** Log reads from I/O (0x700000) and Kaneko16 regs (0x200000). Fix video capture to 320×240.

## 2026-03-19 15:30 — kaneko_arcade.sv duplicate typedef → Verilator error
**Found by:** Agent 2 (sim-batch2)
**Affects:** kaneko_arcade Verilator builds
**Issue:** `kaneko16_sprite_t` typedef defined in BOTH `kaneko_arcade.sv` (line 42) AND `kaneko16.sv` (line 19). Verilator compiles both files and flags duplicate typedef. Quartus doesn't complain.
**Fix applied:** Removed the duplicate typedef from `kaneko_arcade.sv`, kept the canonical one in `kaneko16.sv`.
**Action for other agents:** If adding new typedefs shared between top-level and submodules, define them in ONE place only.

## 2026-03-19 15:50 — ROM_LOAD16_WORD_SWAP needed for some 68K program ROMs
**Found by:** Agent 1
**Affects:** Any core where MAME uses `ROM_LOAD16_WORD_SWAP` for the 68K program ROM
**Issue:** Batsugun ROM has bytes swapped within each 16-bit word. Loading without swap → CPU executes garbage → illegal instruction → double fault after ~13 bus cycles.
**Fix:** Added `load_word_swap()` to sdram_model.h. Check MAME driver source for `ROM_LOAD16_WORD_SWAP` vs `ROM_LOAD16_BYTE` vs plain `ROM_LOAD`.
**Action for other agents:** When building a sim harness, check MAME's ROM loading macro. Use `sdram.load_word_swap()` for WORD_SWAP ROMs, interleaving for BYTE ROMs, plain `sdram.load()` for standard ROMs.

## 2026-03-19 15:45 — Batsugun uses NEC V25 sound CPU, not Z80
**Found by:** Agent 1
**Affects:** toaplan_v2 only
**Issue:** The RTL has a Z80 for sound but Batsugun actually uses a NEC V25. Game waits for V25 response at 0x21FC00 (shared RAM). Without V25, game hangs after init.
**Not a blocker for sim harness validation** — CPU boots and runs, just can't progress past sound init.

## 2026-03-19 14:45 — GFX 2-beat FSM must be ifdef VERILATOR (commit de1f8a5)
**Found by:** Agent 1
**Affects:** kaneko_arcade, toaplan_v2 (any core with 2-beat GFX FSM in emu.sv)
**Issue:** The FSM adds ~200 LABs which overflows borderline cores. Real SDRAM does burst reads — FSM only needed for Verilator's 16-bit model.
**Fix applied:** `ifdef VERILATOR` around the FSM. Synthesis path: direct 16-bit passthrough, zero overhead. Already committed to master.
**Action for other agents:** If you add a 2-beat GFX FSM to any emu.sv, wrap it in `ifdef VERILATOR`. Copy the pattern from kaneko_arcade/quartus/emu.sv.

## 2026-03-19 14:20 — Psikyo + Kaneko synthesis overflow after GFX 32-bit FSM
**Found by:** Agent 1
**Affects:** psikyo_arcade, kaneko_arcade (any core using the 2-beat GFX FSM in emu.sv)
**Issue:** The 2-beat GFX 32-bit read FSM (commit 432591f) adds ~200 LABs, pushing borderline cores over the Cyclone V LAB limit.
**Fix in progress:** Wrapping FSM in `ifdef VERILATOR` so it only compiles for simulation. Quartus path uses direct 16-bit passthrough (pre-fix behavior).
**Action for other agents:** If your core's emu.sv has a GFX 2-beat FSM, it may need the same ifdef treatment. Check synthesis after adding GFX changes.

## 2026-03-19 08:00 — Toaplan V2 SSP address wrap → double bus fault
**Found by:** Agent 1
**Affects:** Any core where the game ROM sets SSP to an address that wraps in 24-bit space
**Issue:** Batsugun SSP=0x11000000, 24-bit wrap → 0x000000. Exception stack push goes to 0xFFFFFE (unmapped) → bus error → double fault → CPU halt.
**Fix:** Added 2-cycle fallback DTACK for open-bus cycles in toaplan_v2.sv. Other cores may need the same if their games have similar SSP values.
**Action for other agents:** If CPU boots but halts after ~10 bus cycles, check the reset vector SSP. Add fallback DTACK for unmapped writes if needed.

## 2026-03-19 05:00 — enPhi1/enPhi2 must be C++-driven (GUARDRAILS Rule 13)
**Found by:** Agent 1
**Affects:** ALL fx68k Verilator simulations
**Issue:** RTL-generated phi enables cause Verilator scheduling race → CPU double-fault after first instruction.
**Fix:** enPhi1/enPhi2 as top-level inputs driven from C++ before eval(). Already in GUARDRAILS and CLAUDE.md.
**Action for other agents:** This is in the reference harness. If you copy nmk_arcade/sim/ correctly, you inherit the fix.
