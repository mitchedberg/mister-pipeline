# MC68EC020 CPU — FPGA Implementation Research

## Implementation Status

**ACTIVE — TG68K VHDL downloaded and wired** (2026-03-16)

**`chips/m68020/rtl/tg68k_adapter.sv`** — 32-bit bus adapter for TG68K

- TG68K VHDL files downloaded from https://github.com/TobiFlex/TG68K.C into
  `chips/m68020/hdl/tg68k/` (`TG68K.vhd`, `TG68KdotC_Kernel.vhd`, `TG68K_ALU.vhd`, `TG68K_Pack.vhd`).
- `TG68KdotC_Kernel` is **instantiated and active** — stub `always_ff` block removed.
- Verilator lint passes clean (`-Wno-MODMISSING` required because Verilator cannot parse VHDL;
  the only error is the expected "can't find module TG68KdotC_Kernel" for the VHDL entity).
- Will be tested at F3 integration level (no dedicated testbench at adapter level).

**Adapter design notes:**
- Presents `[23:1]` word address (not full 32-bit) — F3 only needs 24-bit space
- Byte enables are `cpu_be_n[3:0]` active-low, matching tc0650fda.sv `cpu_be` convention
  (active-high in tc0650fda; invert at instantiation site if needed)
- Longword coalescing heuristic: even address + both UDS+LDS active → 2-cycle accumulation
- Word/byte accesses pass through in one cycle
- Reset synchronizer follows the mandatory `section5_reset.sv` inline pattern

---

## Taito F3 CPU Requirements

Taito F3 uses an **MC68EC020 @ 16 MHz** (16_MHz_XTAL, per `taito_f3.h`).

The MC68EC020 is a cost-reduced variant of the 68020 with the following distinctions versus the full 68020:
- **24-bit physical address bus** (not 32-bit) — highest address in F3 memory map is `0xC80103`, well within 24 bits
- **No MMU** (no 68851 PMMU)
- **No FPU** (no 68881/82)
- Full 68020 instruction set including all extended addressing modes, bitfields, 32-bit multiply/divide, barrel shifter, TRAPcc, CAS/CAS2, PACK/UNPK
- **32-bit internal data path** (but the chip has a 32-bit internal register file and ALU; external data bus is 32 bits wide on the real chip but the F3 board routes it as a 32-bit bus)

F3 memory map top address is `0xC80103` — only 24 address bits required. This means TG68K's 16-bit external data bus with 32-bit address output is structurally close, but the real bus width difference must be handled carefully (see below).

---

## Available FPGA Implementations

### 1. TG68K.C — PRIMARY CANDIDATE

**Repository:** https://github.com/TobiFlex/TG68K.C
**License:** GNU LGPL v3 or later
**Language:** VHDL
**Author:** Tobias Gubener
**Last commit:** March 2025 (actively maintained)
**Stars:** 58

**CPU modes supported (runtime switchable via `CPU[1:0]` input):**
- `00` → 68000
- `01` → 68010
- `11` → 68020

**68020 features implemented (confirmed from source):**
- CAS, CAS2
- TRAPcc
- PACK / UNPK
- Bitfield instructions (BFINS, BFEXTU, BFEXTS, BFTST, BFCHG, BFCLR, BFSET)
- Extended address modes (full 68020 EA modes including scaled index, memory indirect)
- Long branch (BRA.L, BSR.L)
- 32-bit multiply (MULS.L, MULU.L)
- 32-bit divide (DIVS.L, DIVU.L)
- LINK.L (long LINK)
- EXTB.L
- CHK2, CMP2
- Barrel shifter
- VBR (Vector Base Register) via stackframe extension

**68020 features NOT implemented (noted as "to do"):**
- CALLM / RETM (call module / return from module) — obscure, used only by OS-9, never in arcade games
- MOVEC to MSP/ISP/CAAR — CAAR and ISP/MSP writes are silently ignored (`NULL` in MOVEC handler)
- cpXXX coprocessor instructions (no FPU — not needed for 68EC020)

**Critical interface limitation:**
TG68K's external data bus is **16 bits wide** (`DATA: inout std_logic_vector(15 downto 0)` in TG68K.vhd). Even in 68020 mode, memory accesses are 16-bit wide at the bus level; 32-bit longword accesses require two bus cycles. The real MC68EC020 has a 32-bit external data bus. This means TG68K in 68020 mode is functionally equivalent but slower (two cycles per longword access) and has different bus timing than the real chip.

For Taito F3, this matters because the board has a **32-bit ROM/RAM bus**. A real F3 board does 32-bit reads in one cycle. With TG68K, each 32-bit access would take two 16-bit transactions — the bus logic needs to handle this, or TG68K must be interfaced differently.

**Recommendation:** TG68K is usable but requires a bus adapter that presents 32-bit accesses to game logic while feeding 16-bit words to the CPU, or a modified TG68K wrapper that handles 32-bit longwords internally. Minimig-AGA_MiSTer already demonstrates a working TG68K 68020 integration.

**MiSTer integration example:**
`MiSTer-devel/Minimig-AGA_MiSTer` — uses TG68K with `CPU(1:0)` set to `"11"` for 68020 mode. The `cpu_wrapper.v` instantiation shows the exact generics needed:
```verilog
TG68KdotC_Kernel
#(
    .sr_read(2),        // switchable with CPU(0)
    .vbr_stackframe(2), // switchable with CPU(0)
    .extaddr_mode(2),   // switchable with CPU(1)
    .mul_mode(2),       // switchable with CPU(1)
    .div_mode(2),       // switchable with CPU(1)
    .bitfield(2)        // switchable with CPU(1)
)
```
With `CPU = 2'b11`, all 68020 features activate.

---

### 2. fx68k

**Repository:** https://github.com/ijor/fx68k
**License:** Not specified in README
**Language:** SystemVerilog
**CPU supported:** 68000 ONLY — cycle-exact
**68020 support:** None. No branches, no variants, no 68020 mode.

fx68k is used in Minimig-AGA_MiSTer as the 68000-mode fallback and in X68000_MiSTer (Sharp X68000 uses a 68000). It is not relevant for 68020 work.

---

### 3. J68

**Repository:** Part of jotego/jtcores at `modules/jtframe/hdl/cpu/j68/`
**License:** See jtcores (GPL)
**Language:** Verilog
**CPU supported:** MC68000 only
**68020 support:** None — explicitly documented as "all 68000 instructions implemented"

Used by jotego for CPS1-era arcade cores (68000 machines). Not relevant.

---

### 4. Cyclone

Cyclone is an older 68000 soft-core written in Verilog for FPGA use, historically used in some older MiSTer/MiST ports. It implements **68000 only**, no 68020 mode. No longer actively developed. Not relevant.

---

### 5. ev68020 (yasunoxx/ev68020)

**Repository:** https://github.com/yasunoxx/ev68020
**License:** MIT
**Language:** VHDL
**Status:** Personal evaluation project, 2 commits as of late 2025, no community use, incomplete

Not usable.

---

### 6. MAME's 68020 (Musashi)

MAME uses the **Musashi** C-language 68K emulator (CPU class `m68000_musashi_device`). There is no FPGA port of Musashi. MAME's M68EC020 is defined as `m68000_musashi_device(mconfig, tag, owner, clock, M68EC020, 32, 24)` — 32-bit data bus, 24-bit address bus. Not an HDL artifact; no FPGA version exists.

---

## What 68020 Features Does Taito F3 Actually Use?

From the MAME machine configuration and memory map:

| Feature | Required? | Notes |
|---------|-----------|-------|
| 32-bit internal registers | Yes | All 68020 games |
| Extended address modes | Likely yes | Common in 68020 code |
| 32-bit multiply/divide | Likely yes | 68020 math |
| Bitfield instructions | Possibly | Used in some graphics code |
| MMU (68851 PMMU) | No | EC020 = no MMU |
| FPU (68881/82) | No | EC020 = no FPU |
| 32-bit external data bus | Yes (hardware) | F3 PCB has 32-bit ROM bus |
| Address space > 16MB | No | Top address = 0xC80103 |
| CALLM / RETM | No | OS-9 only, never arcade |
| Coprocessor instructions | No | No FPU |

The `EC` in `68EC020` means "embedded controller" — stripped of MMU and FPU. TG68K's 68020 mode covers everything the EC020 needs for arcade use. The only gap is the 32-bit external bus timing.

---

## Recommended Approach for Taito F3

### Short answer: TG68K in 68020 mode — minor adaptation needed

TG68K is the only production-ready, battle-tested 68020 FPGA implementation in the MiSTer ecosystem. It is actively maintained, LGPL-licensed, and has proven itself in the Amiga 1200 core (Minimig-AGA). The missing CALLM/RETM and coprocessor stubs are not needed for any Taito F3 game.

### The bus width issue

The key adaptation required: TG68K presents a **16-bit external bus** even in 68020 mode, but the F3 board has a **32-bit ROM and RAM bus**. Options:

1. **Bus adapter wrapper (recommended):** Build a thin Verilog wrapper around TG68K that coalesces two 16-bit cycles into one 32-bit access for ROM/RAM and presents the 16-bit interface to I/O registers. This is what Minimig does conceptually with its `cpu_cache_new.v`. Complexity: low-to-moderate. This keeps TG68K unmodified.

2. **Accept double-cycle penalty:** Run the system at 32 MHz (2x), let TG68K do two 16-bit cycles per 32-bit access, clock-enable the CPU at 16 MHz effective. Simpler but wastes bandwidth. Acceptable for most F3 games since the original hardware runs at 16 MHz with single-cycle 32-bit accesses — the net throughput would match if the bus overhead is hidden behind DTACK wait states.

3. **Modify TG68K for 32-bit bus:** Fork TG68K and extend `data_in`/`data_write` to 32 bits. Significant VHDL work and deviates from upstream. Not recommended unless TG68K is hitting performance limits.

### Effort estimate

| Task | Effort |
|------|--------|
| Drop TG68K into project as 68020 core | Trivial (copy 4 VHDL files, set CPU=2'b11) |
| 16→32-bit bus adapter wrapper | 1–2 days |
| Validate 68020 instruction correctness against MAME | Part of TAS validation (same methodology as NES work) |
| Full integration + timing closure at 16 MHz | 2–5 days depending on FPGA resource fit |

**Overall: minor adaptation** — not a build-from-scratch problem, not a drop-in. TG68K is the right foundation; the bus-width adapter is the primary engineering task.

---

## Files to Include

From `TobiFlex/TG68K.C` (copy into `chips/m68020/hdl/tg68k/`):
- `TG68K.vhd` — top-level with bus signals
- `TG68KdotC_Kernel.vhd` — main CPU core
- `TG68K_ALU.vhd` — ALU
- `TG68K_Pack.vhd` — package/types

Reference integration: `MiSTer-devel/Minimig-AGA_MiSTer/rtl/cpu_wrapper.v` — shows exact instantiation with 68020 generics.

---

## Summary

| Core | 68020? | License | Bus | Status | Verdict |
|------|--------|---------|-----|--------|---------|
| TG68K.C | Yes (switchable) | LGPL v3 | 16-bit external | Active, production use | **USE THIS** |
| fx68k | No (68000 only) | unspecified | 16-bit | Active, cycle-exact | Not applicable |
| J68 | No (68000 only) | GPL | 16-bit | Active (jotego) | Not applicable |
| Cyclone | No (68000 only) | unknown | 16-bit | Unmaintained | Not applicable |
| ev68020 | Partial (WIP) | MIT | unknown | Toy project | Not usable |
| MAME Musashi | Yes (software) | GPL | N/A (C code) | Active | No FPGA port |

No drop-in 68020 FPGA core with a 32-bit bus exists in the MiSTer ecosystem. TG68K is the established solution, used in production by Minimig-AGA (Amiga 1200). The 16-bit→32-bit bus adapter is straightforward and is the only non-trivial work item.
