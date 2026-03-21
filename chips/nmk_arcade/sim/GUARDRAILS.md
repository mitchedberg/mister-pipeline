# NMK Arcade Simulation — Guardrails

**READ THIS BEFORE STARTING ANY NMK SIMULATION DEBUG SESSION.**

This file captures every hard-won insight from 1.5 days of fx68k/nmk_arcade simulation debugging.
Do not skip it. Do not skim it. Read every section.

---

## fx68k Verilator Integration Bugs (FIXED)

### 1. uaddrPla.sv MULTIDRIVEN — the silent killer

**Symptom**: CPU dispatches to microcode address 0 on every instruction fetch. All-black frames.
No errors, no warnings from Verilator at runtime. Just silence and a dead CPU.

**Root cause**: `pla_lined` in `uaddrPla.sv` has multiple `always_comb` blocks that all drive the
same outputs (`arA1`, `arA23`, `arIll`). Verilator's scheduling semantics dead-code the earlier
blocks. The result: `a1 = 0` always, so every instruction dispatches to microcode address 0.

**Fix**: Merge all `always_comb` blocks in `pla_lined` into a single `always_comb` block.
This is applied in our local copy. **Do not revert this.**

### 2. unique case(1'b1) one-hot priority muxes

**Symptom**: Verilator fires overlap errors during normal CPU execution. These are not bugs in
the RTL — they are legal one-hot priority encodings that Verilator's `unique case` checker
rejects when multiple conditions happen to be true simultaneously.

**Fix**: Change `unique case(1'b1)` to `priority case(1'b1)` in:
- `fx68k.sv` — 13 locations
- `fx68kAlu.sv` — 2 locations

This is applied in our local copy. **Do not revert this.**

**Note**: The main pipeline `GUARDRAILS.md` Iron Law 13 says "No unique case / priority case"
for Quartus synthesis. That rule applies to SYNTHESIS RTL. For SIMULATION-ONLY copies of fx68k,
`priority case` is correct and necessary. The simulation copy lives in the sim directory and
is not committed to the synthesis path.

---

## fx68k Microcode Pipeline — Mental Model

These facts prevent the #1 time-waster: misreading VCD traces.

### microAddress 0 is NOT a halt state

microAddress 0 is the **instruction DISPATCH entry point**. Seeing `microAddr = 0` in VCD is
**completely normal** — it means the CPU is fetching and dispatching the next instruction.

### The actual halt indicator

`oHALTEDn = 0` (active low). If this signal is low, the CPU is halted. If it's high, the CPU
is running, regardless of what microAddr shows.

### Ir vs Ird — know the difference

| Signal | Purpose | When to watch |
|--------|---------|---------------|
| `Ir` | Instruction Register — used by PLA to generate a1/a2/a3 dispatch addresses | Dispatch correctness |
| `Ird` | Instruction Register for Display — updated later, used for external debugging | Not reliable for dispatch analysis |

VCD signal path: `TOP...u_fx68k.Ir` (NOT `Ird`).

### Key microcode addresses

| Address | Decimal | What happens |
|---------|---------|--------------|
| 0x363 | 867 | `Ir <= Irc` fires (enT1 when microLatch[0]=1 and !Nanod.Ir2Ird) |
| 0x34C | 844 | Dispatch: `uNma = A0Sel ? grp1Nma : a1` — a1 comes from PLA using Ir |

### Two-phase clock timing

- `enPhi1` / `enPhi2` alternate each `cpu_ce` pulse
- `cpu_ce` = `clk_sys / 2` = 20 MHz
- Effective CPU clock = 10 MHz
- One bus cycle = 4 clock phases minimum (2 enPhi1 + 2 enPhi2)

---

## DTACK Timing (Verified Working)

The current SDRAM model produces correct DTACK timing. Do not change it without re-verifying
the full reset sequence.

- **SDRAM ACK latency**: req toggle -> 3 system clocks -> ack toggle
- **DTACK fires**: 4-5 system clocks after AS asserts
- **Reset sequence**: All 6 bus cycles complete correctly:
  1. Read SSP high word (0x000000)
  2. Read SSP low word (0x000002)
  3. Read PC high word (0x000004)
  4. Read PC low word (0x000006)
  5. Prefetch at PC
  6. Prefetch at PC+2

### prog_rom_cs address decode

`cpu_addr[23:17] == 7'b0` covers byte range `0x000000 - 0x01FFFF`.
Thunder Dragon PC = 0x0092E0 is within this range. If you see bus cycles going to the wrong
chip select, check this decode first.

---

## Thunder Dragon ROM Details

| Item | Value |
|------|-------|
| ZIP location | `/Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/tdragon.zip` |
| Even bytes | `91070_68k.8` |
| Odd bytes | `91070_68k.7` |
| Interleaved output | `tdragon_prog.bin` |
| Reset vector SSP | `0x000C0000` |
| Reset vector PC | `0x0092E0` |
| First instruction | `0x007C` = `ORI #0x0700, SR` (set interrupt mask = 7, privileged mode) |

ROM interleaving: even file provides bytes at addresses 0, 2, 4, ... and odd file provides
bytes at addresses 1, 3, 5, ... Standard 68000 word-interleave.

---

## nanorom.mem / microrom.mem

These files **must be in the current working directory** when running the simulation binary.
The Python runner (`run_sim.py`) handles this automatically by running from the sim directory.

Source location: `chips/m68000/hdl/fx68k/`

If simulation produces garbage or immediate halt, verify these files are present and non-empty
in the CWD before investigating anything else.

---

## VCD Debugging Workflow

### Generating VCD

Set `DUMP_VCD=1` environment variable when running the simulation:

```bash
DUMP_VCD=1 python3 run_sim.py --frames 2
```

### Signal hierarchy

| Path prefix | Contains |
|-------------|----------|
| `TOP.tb_top.u_cpu.u_fx68k.*` | CPU internals (microAddr, Ir, Irc, oHalted, tState) |
| `TOP.tb_top.u_nmk.*` | Bus signals, DTACK, chip selects |

### Key signals to extract

```
TOP...u_fx68k.sequencer.microAddr   — current microcode address
TOP...u_fx68k.Ir                    — instruction register (dispatch input)
TOP...u_fx68k.Irc                   — prefetched instruction
TOP...u_fx68k.oHalted               — CPU halt status (active low)
TOP...u_fx68k.dbg_cpu_halted_n      — debug halt mirror
TOP...u_fx68k.sequencer.tState      — bus cycle T-state
```

### Rule: write a reusable extraction script

Write `sim/vcd_extract.py` once with all relevant signal paths. Reuse it every session.
**Never write throwaway VCD parsing scripts inline.** The signal paths don't change between
sessions, but you will forget them.

---

## NMK16 Sprite Coordinate Convention (CRITICAL)

NMK16 hardware stores sprite positions as `(256 - screen_pos) & 0x1FF`.

To recover screen coordinates:
```
screen_x = (256 - spriteram[offs+4]) & 0x1FF   (matches MAME nmk16.cpp)
screen_y = (256 - spriteram[offs+6]) & 0x1FF
```

This is applied in nmk16.sv:
```sv
sprite_y_pos = (9'd256 - sprite_y_cached) & 9'h1FF;
sprite_x_pos = (9'd256 - sprite_word_x[8:0]) & 9'h1FF;
```

Raw values like X=482, Y=48 → screen X=286 (visible), screen Y=208 (visible).

---

## G3 Rasterizer scan_trigger — Fixed 2026-03-20

The G3 sprite rasterizer requires `scan_trigger` = 1-cycle pulse at the start of each
active scanline, plus `current_scanline` = the current Y position.

Without this, G3 stays in G3_IDLE forever and no sprites render.

**Fix in nmk_arcade.sv**:
```sv
logic scan_trigger_w;
assign scan_trigger_w = (hpos == 9'd0) && hblank_n_in;
```
Connected to the nmk16 instance as:
```sv
.scan_trigger     (scan_trigger_w),
.current_scanline ({1'b0, vpos}),
```

This fires exactly once per active scanline (when hpos transitions to 0 while hblank is
inactive). During hblank, hblank_n_in=0 prevents false triggers even though hpos=0 during
hblank (the testbench drives hpos=0 during blanking).

---

## RAM Dump Format (89100 bytes/frame — NOT 87052)

The `dump_frame_ram()` function writes 89100 bytes per frame despite reporting "87052"
in its stderr log. The log message is wrong; the file is correct.
Use these offsets for analysis scripts:

```python
FRAME_SIZE  = 89100
WRAM_OFF    = 4                           # 64KB work RAM (32768 words)
PAL_OFF     = 4 + 65536                   # 512-entry palette (1024 bytes)
SPR_OFF     = 4 + 65536 + 1024           # 2048-word sprite storage (4096 bytes)
BG_OFF      = 4 + 65536 + 1024 + 4096   # 2048-word tilemap + padding to 16KB
TX_OFF      = 4 + 65536 + 1024 + 4096 + 16384   # 2KB TX VRAM stub
SCROLL_OFF  = 4 + 65536 + 1024 + 4096 + 16384 + 2048  # 8 bytes scroll regs
```

## MAME RAM Dump Format (86028 bytes/frame)

The MAME Lua script `mame_ram_dump.lua` produces a DIFFERENT layout:

```python
MAME_FRAME  = 86028
M_WRAM_OFF  = 4                                         # 64KB MainRAM (0x080000-0x08FFFF)
M_PAL_OFF   = 4 + 65536                                 # 2KB Palette (1024 entries × 2B)
M_BG_OFF    = 4 + 65536 + 2048                          # 16KB BGVRAM (0x0CC000-0x0CFFFF)
M_TX_OFF    = 4 + 65536 + 2048 + 16384                  # 2KB TXVRAM (0x0D0000-0x0D07FF)
M_SCROLL_OFF = 4 + 65536 + 2048 + 16384 + 2048         # 8B scroll regs
```

Key differences vs SIM format:
- MAME palette: 2048 bytes (1024 entries); NMK16 only uses first 512 (1024 bytes)
- MAME has NO separate sprite RAM section; sprites live in main RAM (0x087000-0x08BFFF)
- MAME BGVRAM: 16KB, but hardware mirrors tilemap: only first 4KB is active data,
  blocks 1-3 read as 0xFFFF (uninitialized SRAM in unimplemented sub-pages)
- MAME scroll regs: appear as 0 if read before VBlank latch fires

## Format-Aware Comparison Script

Use `chips/validate/compare_ram_dumps.py` for byte-accurate MAME vs SIM comparison:

```bash
python3 chips/validate/compare_ram_dumps.py \
    --mame results/tdragon/tdragon_frames.bin \
    --sim  results/tdragon/tdragon_sim_v3.bin \
    --frames 200
```

Baseline results (88eba67, 200 frames, cold boot):
- MainRAM: 95.73% byte match (0 exact frames due to persistent WRAM drift)
- Palette: 54.78% byte match (MAME palette loads ~10-15 frames later than SIM)
- BGVRAM:   8.43% byte match (game-state divergence by frame ~12)
- Scroll:  56.56% byte match (MAME scroll always reads 0; SIM scroll increments)

Root causes identified (NOT translator bugs):
1. Frame 0: 15 byte diffs at 0x089000 = sound/timer register init difference
2. Frame 12: SIM CPU writes 0x0020 to sprite table at 0x08B000-0x08B7FF;
   MAME captures same range as 0x0000 (timing of snapshot vs DMA)
3. By frame ~30: game diverges because MAME scroll stays at 0 (audio CPU slower?)
4. The 95.73% MainRAM accuracy across 200 frames confirms 68000 execution is correct

---

## Common Failure Modes (Checklist)

If simulation produces all-black frames, check in this order:

1. Are `nanorom.mem` and `microrom.mem` in the CWD? (missing = immediate halt)
2. Is the uaddrPla.sv MULTIDRIVEN fix applied? (missing = a1=0 always)
3. Is `oHALTEDn` high after reset? (low = CPU never started)
4. Do all 6 reset bus cycles complete with DTACK? (check VCD)
5. Does `Ir` load a valid opcode after reset? (0x007C for Thunder Dragon)
6. Does microAddr advance past dispatch (address 0)? (stuck at 0 with valid Ir = PLA bug)

If simulation produces frames but they look wrong:

1. Check palette RAM writes (are colors being written?)
2. Check VRAM tile writes (is the CPU populating video memory?)
3. Check scroll register writes
4. Check layer enable bits
5. Is scan_trigger connected? (1'b0 = sprites never render)
6. Use correct RAM dump offsets (see section above)

---

## Session Startup Checklist

Before doing anything else in an NMK simulation session:

- [ ] Read this file completely
- [ ] Read `chips/GUARDRAILS.md` Assembly Line Reset section
- [ ] Verify `nanorom.mem` and `microrom.mem` exist in `sim/`
- [ ] Run a quick 2-frame simulation to confirm baseline still works
- [ ] Only then begin new work
