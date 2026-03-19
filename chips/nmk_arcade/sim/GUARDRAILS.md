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

---

## Session Startup Checklist

Before doing anything else in an NMK simulation session:

- [ ] Read this file completely
- [ ] Read `chips/GUARDRAILS.md` Assembly Line Reset section
- [ ] Verify `nanorom.mem` and `microrom.mem` exist in `sim/`
- [ ] Run a quick 2-frame simulation to confirm baseline still works
- [ ] Only then begin new work
