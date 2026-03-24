# MiSTer Community Patterns Reference

Compiled from source-code analysis of 10+ production MiSTer cores (jotego/jtcps1, jotego/jtframe,
Cave_MiSTer, NeoGeo_MiSTer, va7deo/IremM72, va7deo/MegaSys1_A, atrac17/Toaplan2,
psomashekar/Raizing_FPGA, Template_MiSTer, ijor/fx68k, jtfpga/fx68k, gyurco/fx68k).

**Purpose:** This document captures patterns that community devs discovered over 6+ years of
MiSTer core development. Agents MUST consult this before writing new RTL or debugging issues.
Every pattern here was validated by synthesis and hardware testing on real DE-10 Nano boards.

---

## 1. fx68k Integration (THE Critical Path)

### 1.1 Clock Enable Generation

fx68k uses two single-cycle enable pulses (enPhi1, enPhi2) on a shared posedge clock.
They must NEVER both be high simultaneously. First enable after reset MUST be enPhi1.

**Synthesis pattern (all community cores):**
```verilog
// Simple toggle — Cave, va7deo
reg phi_toggle;
always_ff @(posedge clk or posedge rst)
    if (rst) phi_toggle <= 1'b0;
    else if (cpu_ce) phi_toggle <= ~phi_toggle;

assign enPhi1 = cpu_ce & ~phi_toggle;
assign enPhi2 = cpu_ce &  phi_toggle;
```

**jotego pattern (fractional with DTACK + cycle recovery):**
```verilog
// cpu_cenb must be ONE CYCLE AFTER cpu_cen, not simultaneous
always @(posedge clk) begin
    cpu_cen  <= cen10;          // from jtframe_frac_cen
    cenx     <= cpu_cen;
    cpu_cenb <= cenx;           // delayed by 1 cycle
end
```

**Verilator simulation pattern (MUST use this, not RTL generation):**
```cpp
// Drive from C++ BEFORE eval() — RTL generation causes delta-cycle race
if (top->clk == 1) {  // rising edge
    top->enPhi1 = phi_toggle ? 0 : 1;
    top->enPhi2 = phi_toggle ? 1 : 0;
    phi_toggle  = !phi_toggle;
} else {              // falling edge
    top->enPhi1 = 0;
    top->enPhi2 = 0;
}
top->eval();
```

### 1.2 Interrupt Handling — The Complete Pattern

**Every production core uses this exact pattern. Deviations cause silent failures.**

```verilog
// Step 1: IACK detection — combinational, checks FC AND address bus
wire inta_n = ~&{FC[2], FC[1], FC[0], ~ASn};

// Step 2: IPL latch — SET on event, CLEAR on IACK only
// NEVER use a timer. NEVER clear before IACK.
always @(posedge clk, posedge rst) begin
    if (rst) begin
        int1 <= 1'b1;  // inactive (active-low)
    end else begin
        if (!inta_n)                    int1 <= 1'b1;  // clear on IACK
        else if (!LVBL && last_LVBL)    int1 <= 1'b0;  // set on VBLANK falling edge
    end
end

// Step 3: Wire to fx68k
fx68k u_cpu (
    .VPAn  (inta_n),       // autovector on IACK — NEVER tie to 1'b1
    .IPL0n (1'b1),
    .IPL1n (int1),         // level 2 VBLANK (most arcade games)
    .IPL2n (1'b1),
    ...
);
```

**Why timer-based IPL clear is wrong:**
- fx68k requires IPL stable for TWO consecutive phi2 edges (`rIpl -> iIpl` pipeline)
- `intPend` only sets when `iplStable` (both stages agree) AND `iIpl > pswI`
- A timer that expires before IACK deasserts the interrupt too early
- The CPU may miss the interrupt entirely if timer < 2 phi2 periods during init
- IACK-based clear guarantees the CPU has acknowledged before clearing

**Why `VPAn = 1'b1` hangs the CPU:**
- During IACK, CPU asserts FC=111 and waits for DTACKn=0 OR VPAn=0
- If neither ever asserts, CPU waits forever
- VPAn must go low during IACK to trigger autovector lookup

**IPL level encoding (active-low):**
```
IPL[2:0] = 3'b111  → no interrupt
IPL[2:0] = 3'b110  → level 1
IPL[2:0] = 3'b101  → level 2 (most common VBLANK level)
IPL[2:0] = 3'b011  → level 4
IPL[2:0] = 3'b000  → level 7 (NMI, non-maskable)
```

### 1.3 DTACK Generation

```verilog
// Minimum pattern — 1 wait state required by 68000 protocol
wire bus_cs   = |{rom_cs, ram_cs, vram_cs, io_cs};
wire bus_busy = |{rom_cs & ~rom_ok, ram_cs & ~ram_ok};

// jtframe_68kdtack handles:
// - 1 idle cycle after ASn falls (wait1) for CS propagation
// - DTACKn held high until bus_busy clears
// - DSn monitoring for read-modify-write (TAS instruction)
// - Cycle recovery when SDRAM stalls
jtframe_68kdtack u_dtack(
    .clk(clk), .rst(rst),
    .cpu_cen(cpu_cen),
    .ASn(ASn), .DSn({UDSn, LDSn}),
    .bus_cs(bus_cs), .bus_busy(bus_busy),
    .DTACKn(DTACKn)
);
```

**Critical: DTACKn is sampled on enPhi2.** It must be stable before enPhi2 fires.

### 1.4 Address Decode

**Register CS signals, never use raw combinational decode:**
```verilog
// jotego pattern: decode in clocked block, gated by ASn + BGACKn
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pre_sel_rom <= 0;
        pre_sel_ram <= 0;
    end else if (!ASn && BGACKn) begin  // bus not stolen by DMA
        pre_sel_rom <= addr >= 0 && addr <= 'h80000;
        pre_sel_ram <= addr >= 'hFF0000;
    end else begin
        pre_sel_rom <= 0;  // clear all when AS deasserts
        pre_sel_ram <= 0;
    end
end
```

**Do NOT gate chip selects with ~BUSn** — causes false SDRAM requests at trailing edge of AS.

### 1.5 Open Bus

**Unmapped reads return 16'hFFFF (not 0x0000):**
```verilog
cpu_din <= rom_cs ? rom_data :
           ram_cs ? ram_data :
           io_cs  ? io_data  :
           16'hFFFF;  // pull-up behavior on undriven bus
```
Games probe for this pattern during hardware detection. 0x0000 causes wrong hardware ID.

### 1.6 Write Byte Mask

```verilog
// Derive from RnW + UDS/LDS — raw UDSn/LDSn causes spurious writes on reads
assign UDSWn = RnW | UDSn;
assign LDSWn = RnW | LDSn;
```

### 1.7 SDC Multicycle Paths (MANDATORY for synthesis)

```tcl
# fx68k internal paths — span two phi phases
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|microAddr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|microAddr[*]}] 1
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|nanoAddr[*]}]  2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|nanoAddr[*]}]  1
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]   -to [get_keepers {*|alu|pswCcr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]   -to [get_keepers {*|alu|pswCcr[*]}] 1
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}] 1

# T80 Z80 — required or synthesis fails timing
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 1
```

### 1.8 Complete Port Map

```verilog
fx68k u_cpu (
    .clk        (clk_sys),
    .extReset   (rst),         // active-HIGH, synchronous
    .pwrUp      (rst),         // ALWAYS tie to extReset
    .enPhi1     (cpu_cen),     // 1-cycle pulse, rising phase
    .enPhi2     (cpu_cenb),    // 1-cycle pulse, falling phase
    .HALTn      (1'b1),        // tie high (no single-step)
    .ASn        (ASn),
    .eRWn       (RnW),
    .UDSn       (UDSn),
    .LDSn       (LDSn),
    .DTACKn     (DTACKn),
    .VPAn       (inta_n),      // NEVER 1'b1
    .BERRn      (1'b1),
    .BRn        (1'b1),        // or connect DMA arbiter
    .BGACKn     (1'b1),        // or connect DMA arbiter
    .IPL0n      (ipl_n[0]),
    .IPL1n      (ipl_n[1]),
    .IPL2n      (ipl_n[2]),
    .FC0        (FC[0]),
    .FC1        (FC[1]),
    .FC2        (FC[2]),
    .iEdb       (cpu_din),     // 16-bit read data
    .oEdb       (cpu_dout),    // 16-bit write data
    .eab        (A[23:1]),     // WORD address — byte addr = {eab, 1'b0}
    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (),            // 0 = double bus fault halted
    .VMAn       (),
    .E          ()
);
```

---

## 2. Verilator Simulation

### 2.1 uaddrPla.sv MULTIDRIVEN — Silent CPU Killer

**Problem:** `pla_lined` module has 7 `always @*` blocks that each drive overlapping entries
of the same arrays (`arA1[15:0]`, `arA23[15:0]`, `arIll[15:0]`). Verilator assigns each
signal to exactly one always block and silently dead-codes the rest. Result: `plaA1 = 0`
always, CPU dispatches to microcode address 0 on every instruction. No errors, no warnings.

**`-Wno-MULTIDRIVEN` does NOT fix this.** It only suppresses the warning. The behavior is
unchanged — Verilator still picks one block and ignores the rest.

**Fix:** Merge all 7 `always @*` blocks into a SINGLE `always @*` block with a `case(line)`
on `opcode[15:12]`. This was done for the NMK sim but the fix is NOT in the shared
`chips/m68000/hdl/fx68k/uaddrPla.sv`. Every core using the shared copy has a broken CPU.

### 2.2 Verilator-Specific Workarounds Catalog

| Issue | File | Fix |
|-------|------|-----|
| SV structs | fx68k.sv | Use jtfpga `hdl/verilator/` version (structs flattened to wires) |
| `unique case(1'b1)` | fx68k.sv (13), fx68kAlu.sv (2) | Change to `priority case(1'b1)` |
| enPhi1/enPhi2 race | tb_top | Drive from C++, not RTL (delta-cycle scheduling artifact) |
| uaddrPla MULTIDRIVEN | uaddrPla.sv | Merge 7 always blocks into 1 (NOT just lint suppression) |
| SDRAM inout | sdram controller | Add `output sdram_din` port under `ifdef VERILATOR` |
| CPU trace size | fx68k wrapper | `tracing_off` by default; `VERILATOR_KEEP_CPU` to opt-in |
| X-propagation in ALU | fx68k.sv | `SIMULBUGX32` splits 32-bit add to prevent X spread |
| T80 4-state compare | Z80 wrapper | Skip `===` checks under `ifdef VERILATOR` |

### 2.3 SDRAM in Simulation

**Bypass SDRAM entirely for initial CPU bring-up:**
```verilog
`ifdef SIMULATION
reg [7:0] prg [0:2**19-1];
initial $readmemh("rom/68kprg.hex", prg, 0, 'h7FFFF);
assign ROM68K_OK = 1'b1;
assign ROM68K_DOUT = {prg[(ROM68K_ADDR<<1)+1], prg[ROM68K_ADDR<<1]};
`else
jtframe_rom_3slots ... // real SDRAM path
`endif
```

This eliminates SDRAM timing as a variable during CPU debugging.

---

## 3. SDRAM Controller

### 3.1 SDRAM_CLK Output (MANDATORY on Cyclone V)

```verilog
// NEVER use: assign SDRAM_CLK = ~clk_sys;  // WRONG
// ALWAYS use altddio_out:
altddio_out #(
    .intended_device_family("Cyclone V"),
    .extend_oe_disable("OFF"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
) sdramclk_ddr (
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk_sys),
    .dataout(SDRAM_CLK)
);
```

This creates a 180-degree phase-shifted clock so data is stable on SDRAM's rising edge.
Every community core uses this exact pattern.

### 3.2 MiSTer SDRAM Electrical Reality

SDRAM modules on MiSTer exhibit 2.4V-4.0V VDD ripple (way outside spec).
Fix: slow slew rates on DQ bus. This is set in the QSF, not RTL.

On MiSTer, `DQMH` and `DQML` are physically shorted to `SDRAM_A[12:11]`.
Controllers must place DQM values in A[12:11] during write cycles.

### 3.3 Multi-Channel Arbitration

**Toggle-flag handshake** for cross-domain requests:
```verilog
// Requestor: toggle req to signal new request
always @(posedge clk) if (need_data) req <= ~req;
// Controller: compare req vs ack
wire pending = (req != ack);
// Controller: toggle ack when complete
always @(posedge clk) if (transfer_done) ack <= req;
```

**Priority order (consensus):** Video channels > CPU > Refresh.
Video channels must never stall or you get screen tearing.
CPU stalls via DTACK stretching (clock gating is equivalent).

### 3.4 SDC for 96MHz SDRAM

```tcl
set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers {*|dq_ff[*]}] 2
set_multicycle_path -hold -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers {*|dq_ff[*]}] 2
```

---

## 4. Clock Architecture

### 4.1 Single Clock Domain + Enables (NeoGeo pattern, PREFERRED)

```verilog
// All logic on 48MHz, sub-frequencies via clock enables
always @(posedge CLK) begin
    if (CLK_EN_24M_P) CLK_68KCLK <= ~CLK_68KCLK;  // 12 MHz toggle
end
assign CLK_EN_68K_P = ~CLK_68KCLK & CLK_EN_24M_P;  // rising edge
assign CLK_EN_68K_N =  CLK_68KCLK & CLK_EN_24M_P;  // falling edge
```

**Why preferred:** Only one design frequency to meet timing. No clock-crossing synchronizers.
No `set_clock_groups` needed. NeoGeo — the most complex MiSTer core — uses this approach.

### 4.2 Multi-Clock Domain (Cave pattern)

When pixel clock must differ from system clock:
- Separate PLLs: `pll` (clk_sys, clk_cpu) + `pll_video` (clk_video)
- MUST add `set_clock_groups -exclusive` between PLL outputs in SDC
- MUST add per-domain reset synchronizers:
```verilog
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
reg r1 = 1'b1, r2 = 1'b1;
always @(posedge clk) begin r1 <= rst_i; r2 <= r1; end
assign rst_o = r2;
```

### 4.3 PLL Lock-Loss Recovery

```verilog
// Cave pattern: hold reset for 256 cycles after PLL lock drops
always @(posedge clk_sys or posedge RESET) begin
    if (RESET) begin rst_pll <= 0; rst_cnt <= 8'h00; end
    else begin
        old_locked <= pll_sys_locked;
        if (old_locked && !pll_sys_locked) begin
            rst_cnt <= 8'hff;
            rst_pll <= 1;
        end else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1;
        else rst_pll <= 0;
    end
end
```

### 4.4 Separate rst_cpu from rst_sys

OSD "reset" should reset the CPU but NOT the memory controller:
```verilog
wire rst_sys = RESET | ~pll_locked;           // power/PLL only
wire rst_cpu = status[0] | buttons[1] | rst_sys;  // OSD + power
```

---

## 5. Video Timing

### 5.1 Blanking and Sync

- `VGA_DE = ~(VBlank | HBlank)` — sys_top requires this
- Sync polarity must match hardware (check MAME's `MCFG_SCREEN_RAW_PARAMS`)
- `CE_PIXEL` is a clock enable strobe, not a clock — sys_top's video_mixer generates it
- `LHBL` / `LVBL` — active-low blanking (CAPCOM convention, used by jtframe)

### 5.2 Line Buffer (preferred over frame buffer)

All modern cores use per-scanline line buffers:
- Dual ping-pong BRAM, swap on LHBL falling edge
- Write port fills next line during HBlank
- Read port outputs current line to video mixer
- Much less memory than frame buffer (1 line vs 1 frame)

### 5.3 Render Pipeline

Community consensus: render ONE scanline ahead of output.
This gives the SDRAM time to deliver tile/sprite data:
- `vrender` = current render line (1-2 ahead of display)
- `vdump` = current display line
- DMA operations trigger at specific `hdump` values during HBlank

### 5.4 Simulation Start

Initialize V counter in VBLANK region (e.g., `vdump = 9'hf0`) so first sim frames
are complete. Partial first frames cause false divergence in validation.

---

## 6. ROM Loading (ioctl_download)

### 6.1 Standard Pattern

```verilog
// Use WIDE=1 for 16-bit transfers
hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
    .clk_sys(clk_sys),
    .ioctl_download(downloading),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait),
    ...
);
```

### 6.2 Throttle When SDRAM Busy

```verilog
// Assert ioctl_wait when downstream SDRAM write cannot complete
assign ioctl_wait = downloading & ~sdram_ready;
```

### 6.3 ROM Reorganization at Load Time

NeoGeo reorders sprite bitplanes during loading for efficient burst access.
This is better than runtime address remapping:
```verilog
// During ioctl_wr: reorganize data into SDRAM-friendly layout
// so a single 16-bit SDRAM read gives 4 adjacent horizontal pixels
```

---

## 7. GP9001 (Toaplan V2) Specifics

From Raizing_FPGA analysis:

- **Internal RAM:** 8192 words, 4 regions: SCR0 (2048w), SCR1 (2048w), SCR2 (2048w), SPR (1024w)
- **Scroll tiles are 16x16 pixels** (not 8x8)
- **VINT fires at scanline 0xE6** (line 230), cleared by writing register 0x0F/0x8F/0x0E
- **Sprite double-buffering:** 4-slot rotating buffer, cur_buf increments at VBlank start
- **Scroll X hardware offsets:** BG=-0x1D6, FG=-0x1D8, Text=-0x1DA, Sprites=+0x024
- **Pixel format in line buffers:** `[14:11]=priority, [10:4]=palette, [3:0]=color`
- **GFX ROM decode:** 4 bytes -> 8 4-bit pixels (interleaved bitplane format)
- **Object bank switching:** 8-slot table (3-bit index -> 4-bit bank value)
- **Priority mixing:** numeric (0-15), iterate i=0..15, last write wins = highest priority

---

## 8. Quartus 17.0 Specific

### 8.1 What to Avoid

- `unique case` / `priority case` — Warning 10280 (use in sim only, not synthesis)
- SystemVerilog `interface`, `struct`, `enum` — limited support
- 3D arrays — cannot infer M10K
- Array assignments inside reset — M10K has no hardware reset
- Synchronous reset for M10K — use async reset (`always @(posedge clk, posedge rst)`)

### 8.2 QSF Optimization Flags (from production cores)

```tcl
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON
set_global_assignment -name PHYSICAL_SYNTHESIS_EFFORT EXTRA
set_global_assignment -name FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS
set_global_assignment -name ECO_OPTIMIZE_TIMING ON
set_global_assignment -name AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS ON
set_global_assignment -name QII_AUTO_PACKED_REGISTERS "SPARSE AUTO"
```

### 8.3 .qsf Pollution

Quartus IDE may inline settings from included files directly into `.qsf`.
Always diff `.qsf` before committing. Revert if it has grown unexpectedly.

---

## 9. What Naive Automated Pipelines Get Wrong

1. **Not using altddio_out for SDRAM_CLK** — register assign creates uncontrolled phase
2. **Forgetting per-domain reset synchronizers** — metastability across clock domains
3. **Using real clocks instead of clock enables** — Quartus can't analyze gated clocks
4. **VPA tied to 1'b1** — CPU hangs on every interrupt acknowledge cycle
5. **Missing Z80 multicycle path SDC** — synthesis fails or produces wrong behavior
6. **Missing `set_clock_groups`** — false timing failures between unrelated PLLs
7. **Using ioctl_download polling instead of ioctl_wr pulses** — misses words
8. **Tying rst_cpu to rst_sys** — OSD reset kills in-flight SDRAM transactions
9. **SDRAM_DQML/DQMH always 0** — works for 16-bit reads but corrupts byte writes
10. **Ignoring ioctl_index routing** — all ROMs dumped to same SDRAM address
11. **Timer-based interrupt clear** — race condition with CPU init code
12. **Combinational chip selects** — false SDRAM requests at bus cycle trailing edge
13. **Unregistered IPL lines** — Verilator evaluates after fx68k, sample is one cycle late
14. **Missing fx68k SDC multicycle paths** — timing failures on instruction decode paths

---

## 10. Validation Methodology

### 10.1 Bring-Up Sequence (community consensus)

1. CPU boots (reset vector, first instructions) — verify via register trace
2. RAM contents match MAME after N frames — byte-by-byte
3. VRAM/palette/scroll match — isolates graphics to specific subsystem
4. Pixel comparison LAST — just confirmation

### 10.2 MAME Golden Dump Generation

Run MAME Lua once offline, store dumps as static golden reference:
```lua
emu.register_frame_done(function()
    local frame = manager.machine.video.frame_number
    local mem = manager.machine.devices[":maincpu"].spaces["program"]
    -- dump work RAM, palette RAM, VRAM, scroll regs per frame
end)
```
Launch: `mame game -autoboot_script dump.lua -nothrottle -str 10000`

Verilator CI compares against static files — no MAME in the CI hot path.

### 10.3 Verilator Simulation Bypass

For CPU bring-up, bypass SDRAM entirely:
```verilog
`ifdef SIMULATION
initial $readmemh("rom/prog.hex", prog_rom);
assign rom_ok = 1'b1;
assign rom_dout = prog_rom[rom_addr];
`endif
```

---

## Sources

All patterns derived from source-code analysis of production cores, March 2026:
- jotego/jtcps1 (CPS1 FPGA core)
- jotego/jtframe (MiSTer framework)
- jotego/jtcores (20+ arcade cores)
- MiSTer-devel/Arcade-Cave_MiSTer (Cave 68k)
- MiSTer-devel/NeoGeo_MiSTer (Neo Geo)
- MiSTer-devel/Template_MiSTer (canonical starting point)
- va7deo/MegaSys1_A (Jaleco MegaSystem 1)
- atrac17/Toaplan2 (GP9001-based cores)
- psomashekar/Raizing_FPGA (Armed Police Batrider, Battle Garegga)
- ijor/fx68k, jtfpga/fx68k, gyurco/fx68k (all three 68000 forks)
