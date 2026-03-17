# Credits and Attributions

This FPGA arcade core pipeline stands on the shoulders of decades of arcade preservation work, from MAME maintainers to hardware decappers to the broader MiSTer community. We're grateful to all whose work made this possible.

## MAME Project — Behavioral Reference

**License:** GPL-2.0
**URL:** https://github.com/mamedev/mame
**Contact:** R. Belmont et al.

MAME is the gold standard of arcade emulation. Every RTL core in this pipeline starts with MAME source analysis to understand chip behavior, timing, and state machine logic. We read MAME's C implementation, extract the algorithmic essence, and write original RTL that matches its observable behavior.

**What we use:** Emulation logic, register behavior, timing specifications, state machine design patterns.
**What we don't do:** Copy code. MAME is GPL; our RTL is original and GPL-2.0-licensed, derived only from behavioral analysis.

---

## fx68k — MC68000 CPU Core

**Author:** Jorge Cwik (ijor)
**License:** MIT
**URL:** https://github.com/ijor/fx68k

fx68k is the industry-standard cycle-accurate 68000 implementation in SystemVerilog. It appears in every modern arcade FPGA core and is the foundation of our CPU integration on Taito B, Z, and X systems.

**Why it matters:** Arcade hardware timing is cycle-critical. fx68k provides the exact timing that makes game ROMs run without frame-perfect desync. Without it, we'd have to write our own 68000, a multi-month effort.

**Used in:** Taito B, F3, Z, X cores.

---

## T80 — Z80 Soft Core

**License:** LGPL
**URL:** (Open Cores, widely available)

T80 is the de facto Z80 implementation for FPGA work. Provides cycle-accurate Z80 behavior for sound CPUs across all Taito boards.

---

## TG68K — MC68020 Soft Core

**Author:** Tobias Gubener
**License:** LGPL / CC0 variant
**URL:** https://github.com/TobiFlex/TG68K.C

TG68K is the 68020 foundation used in Taito F3's processor pipeline. It's a full-featured 32-bit implementation that handles F3's 68EC020 instruction set and timing.

---

## MiSTer sys/ Framework

**License:** GPL-2.0
**Authors:** MiSTer-devel team
**URL:** https://github.com/MiSTer-devel/Template_MiSTer
**Key Maintainers:** Sorgelig, others

The MiSTer project is an open-source FPGA ecosystem that lets anyone run classic arcade and console systems on actual FPGA hardware. The `sys/` framework provides:

- **HPS Interface** (`hps_io.sv`) — Communication between the ARM CPU and FPGA logic
- **Video Scaler** (`ascal.vhd`, `hq2x.sv`) — Pixel filtering and output formatting
- **SDRAM Controller** — Memory arbiter for ROM and work RAM
- **Audio Pipeline** — Audio mixer, I2S output, filter chains
- **Video Timing** — HDMI, VGA, and composite video output generation

Without this infrastructure, arcade cores would need custom video/audio/I2C drivers from scratch. The sys/ framework is battle-tested across 100+ MiSTer cores.

**Attribution:** Every MiSTer core includes the sys/ framework unchanged, and the framework itself credits its component authors internally. We treat it as a standard platform dependency, not our code.

---

## TaitoF2_MiSTer — Taito F2 Support Chips

**Author:** wickerwaka
**License:** GPL-2.0
**URL:** https://github.com/wickerwaka/TaitoF2_MiSTer

TaitoF2_MiSTer proves out implementations of Taito-specific glue chips:
- **TC0260DAR** — Palette DAC (RGB444/RGB555 output)
- **TC0140SYT** — 68000↔Z80 sound communication + ADPCM ROM arbiter
- **TC0220IOC** — I/O controller (joysticks, coins, DIP switches)

Our Taito B implementation learned heavily from wickerwaka's architecture. We don't copy code, but we do study the wiring patterns and initialization sequences.

---

## Hardware Research & Community

### Data Crystal Wiki
**URL:** https://www.smspower.org/

Community-maintained hardware specifications, memory maps, and chip pin assignments. Invaluable for verifying address decoding and interrupt logic.

### Arcade Decap Projects
- **Silk Worm** (decap analysis, pin tracing)
- **Hardware enthusiasts** on forums and GitHub

Real silicon analysis has shaped our understanding of chip timing and state machine behavior.

### MiSTer Community
- **Jotego** (@jtcores) — High-quality arcade cores and research tools
- **Wickerwaka** — Taito systems expertise
- **Sorgelig** — MiSTer platform creator and maintainer
- **Hundreds of core authors** — Proof that quality FPGA arcade preservation is possible

---

## Authorship & License

**Original RTL:** All `.sv` and `.vhd` files in `chips/` are original implementations licensed under the **GPL-2.0** (see LICENSE file).

**Process:** Each chip is:
1. Researched via MAME source + datasheets
2. Implemented from scratch in Verilog/SystemVerilog
3. Verified against MAME behavioral output via test vectors
4. Synthesized and tested on MiSTer hardware

**Derivative Dependencies:** Components using GPL-2.0 code (e.g., MiSTer sys/, MAME reference logic) must comply with GPL-2.0 copyleft obligations. When compiling for hardware, the entire bitstream inherits GPL-2.0.

---

## Contributing

We welcome improvements, bug fixes, and new chip implementations. See `CONTRIBUTING.md` for the contribution process.

When you contribute:
- Respect existing licenses (GPL-2.0 for all code)
- Credit the sources you read (MAME, decaps, datasheets)
- Write original RTL; don't copy from other projects
- Verify against MAME test vectors before submitting

The goal is a living, community-driven arcade preservation platform. Your contributions make it better for everyone.

---

## A Note on Preservation

Arcade games are part of interactive cultural history. Making them run on modern hardware — whether via MAME, FPGA cores, or other methods — ensures they're playable for future generations.

This project is part of that larger effort. We're standing on the work of thousands of people: original game designers, MAME maintainers, hardware reverse-engineers, FPGA experts, and the global community that keeps these systems alive.

Thank you all.

