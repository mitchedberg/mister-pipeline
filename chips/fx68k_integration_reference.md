# fx68k Integration Reference — Consensus Patterns from Community MiSTer Cores

**Sources:** jotego (jtcps1, jts16, jtoutrun), va7deo (ArmedF, Alpha68k), Cave MiSTer (nullobject),
psomashekar (Raizing/Batrider), jtframe framework. All patterns verified across 10+ production cores.

**Purpose:** This document is the "lantern" — the proven integration patterns that eliminate the need to
re-derive bus timing for every new 68000-based arcade system. Every new core MUST follow these patterns.

---

## 1. Canonical fx68k Port Map

```verilog
fx68k u_cpu (
    .clk        ( clk_sys    ),   // system master clock (all regs clock on posedge)
    .enPhi1     ( cpu_cen    ),   // 1-cycle pulse: rising edge of CPU clock
    .enPhi2     ( cpu_cenb   ),   // 1-cycle pulse: falling edge of CPU clock

    .extReset   ( rst        ),   // active-HIGH synchronous reset
    .pwrUp      ( rst        ),   // tie to extReset (all cores do this)

    // Bus outputs (active-LOW)
    .ASn        ( ASn        ),   // address strobe
    .eRWn       ( RnW        ),   // 1=read, 0=write
    .UDSn       ( UDSn       ),   // upper byte strobe
    .LDSn       ( LDSn       ),   // lower byte strobe

    // Bus inputs (active-LOW)
    .DTACKn     ( DTACKn     ),   // data transfer ack
    .VPAn       ( inta_n     ),   // *** MUST use autovector, NOT 1'b1 ***
    .BERRn      ( 1'b1       ),   // no bus error
    .BRn        ( 1'b1       ),   // no DMA (or connect to DMA arbiter)
    .BGACKn     ( 1'b1       ),   // no DMA (or connect to DMA arbiter)

    // Interrupts (active-LOW; IPL encoding: 111=none, 110=level 1, ..., 000=level 7)
    .IPL0n      ( ipl_n[0]   ),
    .IPL1n      ( ipl_n[1]   ),
    .IPL2n      ( ipl_n[2]   ),

    // Function codes (for IACK detection)
    .FC0        ( FC[0]      ),
    .FC1        ( FC[1]      ),
    .FC2        ( FC[2]      ),

    // Address / data
    .eab        ( A[23:1]    ),   // word address (bit 0 not present)
    .iEdb       ( cpu_din    ),   // 16-bit read data
    .oEdb       ( cpu_dout   ),   // 16-bit write data

    // Unused outputs — leave open
    .HALTn      ( 1'b1       ),   // or connect to pause DIP
    .BGn        (            ),
    .oRESETn    (            ),
    .oHALTEDn   (            ),
    .VMAn       (            ),
    .E          (            )
);
```

---

## 2. VPAn / Interrupt Acknowledge — CRITICAL

**Every community core** uses this pattern. Without it, the CPU hangs on IACK:

```verilog
// Interrupt acknowledge: FC[2:0]=111 + ASn=0 = IACK cycle
wire inta_n = ~&{ FC[2], FC[1], FC[0], ~ASn };
// Connect: .VPAn(inta_n)
```

**NEVER tie VPAn to 1'b1.** When the CPU generates an IACK cycle, it waits indefinitely for
either DTACKn or VPAn. If neither asserts, the CPU hangs.

Our fx68k_adapter.sv now handles this internally — no per-core wiring needed.

---

## 3. DTACK Generation

### Pattern A: jtframe_68kdtack (recommended for new cores)

The jtframe approach generates BOTH clock enables AND DTACKn in a unified module.
When SDRAM is busy, it **stalls the clock enables entirely** — the CPU freezes in place.

```verilog
// Key signals:
wire bus_cs   = |{ rom_cs, ram_cs, vram_cs };
wire bus_busy = |{ rom_cs & ~rom_ok, ram_cs & ~ram_ok, vram_cs & ~vram_ok };

jtframe_68kdtack #(.W(5)) u_dtack (
    .rst        ( rst       ),
    .clk        ( clk_sys   ),
    .cpu_cen    ( cpu_cen   ),    // OUTPUT — feed to fx68k enPhi1
    .cpu_cenb   ( cpu_cenb  ),    // OUTPUT — feed to fx68k enPhi2
    .bus_cs     ( bus_cs    ),    // any SDRAM access pending
    .bus_busy   ( bus_busy  ),    // SDRAM hasn't returned data yet
    .bus_legit  ( 1'b0      ),    // 0 = recover lost cycles
    .ASn        ( ASn       ),
    .DSn        ( {UDSn, LDSn} ),
    .num        ( 5'd5      ),    // fractional divider: num/den * clk_sys = CPU freq
    .den        ( 5'd24     ),    // e.g., 5/24 * 48MHz = 10MHz
    .DTACKn     ( DTACKn    ),
    .wait2      ( 1'b0      ),
    .wait3      ( 1'b0      ),
    .fave       (           ),
    .fworst     (           ),
    .frst       ( rst       )
);
```

**DTACK state machine rules:**
1. DTACKn = 1 during reset, or while ASn is high
2. After ASn goes low, **one cpu_cen must pass** before DTACK can assert (wait1 state)
3. For fast devices (BRAM, I/O): bus_cs=0 → DTACK asserts after wait1
4. For SDRAM: bus_cs=1, bus_busy=1 → halt=1 → cpu_cen stops → CPU frozen until bus_busy=0
5. DSn rising edge resets DTACKn (for read-modify-write TAS instruction)

### Pattern B: Simple registered DTACK (our current approach, acceptable)

```verilog
// Fast chip selects: DTACK after 1 pipeline cycle
always_ff @(posedge clk_sys) dtack_r <= any_fast_cs;

// ROM: wait for SDRAM handshake
always_comb begin
    if (cpu_as_n)         cpu_dtack_n = 1'b1;
    else if (rom_cs)      cpu_dtack_n = (prog_rom_req != prog_rom_ack);  // pending
    else                  cpu_dtack_n = !dtack_r;
end
```

This keeps cpu_cen running and holds DTACKn high during waits. Works but doesn't recover
lost clock cycles. Acceptable for cores that don't need cycle-exact timing.

---

## 4. Clock Enable Generation

### Fractional divider (jtframe pattern)

```verilog
// Accumulate counter, fire cen when overflow
// cpu_cen and cpu_cenb alternate (phi1/phi2)
// Common ratios:
//   10 MHz from 48 MHz: num=5, den=24
//   16 MHz from 32 MHz: num=1, den=2 (or simple toggle)
//   10 MHz from 40 MHz: num=1, den=4
//    8 MHz from 32 MHz: num=1, den=4
```

### Simple toggle (our adapter)

```verilog
always_ff @(posedge clk or negedge reset_n)
    if (!reset_n)    phi_toggle <= 0;
    else if (cpu_ce) phi_toggle <= ~phi_toggle;

assign enPhi1 = cpu_ce & ~phi_toggle;
assign enPhi2 = cpu_ce &  phi_toggle;
```

**Constraint:** enPhi1 and enPhi2 must NEVER overlap. First enable after reset must be enPhi1.

---

## 5. Address Decoding

**All community cores register CS signals on the clock edge:**

```verilog
always @(posedge clk, posedge rst) begin
    if (rst) begin
        rom_cs <= 0; ram_cs <= 0; io_cs <= 0;
    end else if (!ASn && BGACKn) begin   // *** BGACKn guard prevents decode during DMA ***
        rom_cs <= A[23:22] == 2'b00;
        ram_cs <= &A[23:18];
        io_cs  <= A[23:20] == 4'b1000;
    end else begin
        rom_cs <= 0; ram_cs <= 0; io_cs <= 0;
    end
end
```

**Rules:**
- Always gate with `BGACKn` (even if no DMA — harmless and forward-compatible)
- CS is registered (1 cycle behind ASn) — jtframe_68kdtack's wait1 compensates for this
- Open bus (no CS) returns `16'hFFFF` on data bus

---

## 6. Data Bus Muxing

```verilog
// Registered at cpu_cen edge — priority chain:
always_ff @(posedge clk) if (cpu_cen) begin
    cpu_din <= rom_cs   ? rom_data   :
               ram_cs   ? ram_dout   :
               io_cs    ? io_data    :
                          16'hFFFF;  // open bus
end
```

---

## 7. SDRAM Handshake

**Toggle protocol (our convention):**

```verilog
// CPU issues request by toggling req:
if (rom_cs && !rom_pending) begin
    prog_rom_req <= ~prog_rom_req;   // toggle
    rom_pending  <= 1;
end

// SDRAM controller mirrors ack when data is ready:
wire rom_ok = (prog_rom_req == prog_rom_ack);   // request completed

// bus_busy for DTACK:
wire bus_busy = rom_cs & ~rom_ok;
```

**Write byte-mask:**
```verilog
assign UDSWn = RnW | UDSn;   // active-low: upper byte write enable
assign LDSWn = RnW | LDSn;   // active-low: lower byte write enable
```

### dsn_dly false-request prevention

CS can drop before DS during bus cycle termination, causing spurious SDRAM requests:

```verilog
always @(posedge clk) if(cpu_cen) dsn_dly <= &{UDSWn, LDSWn};
assign ram_cs = dsn_dly ? reg_ram_cs : pre_ram_cs;
```

---

## 8. VBlank Interrupt

**Universal pattern (edge-detect + IACK clear):**

```verilog
wire inta_n = ~&{FC[2], FC[1], FC[0], ~ASn};

always @(posedge clk) begin
    last_LVBL <= LVBL;
    if (!inta_n)                          int1 <= 1'b1;  // clear on acknowledge
    else if (!LVBL && last_LVBL)          int1 <= 1'b0;  // set on VBLANK falling edge
end

// IPL encoding: level 2 interrupt (most common for arcade VBLANK)
assign IPL0n = 1'b1;
assign IPL1n = int1;    // active-low: 0 = level 2 IRQ pending
assign IPL2n = 1'b1;
```

---

## 9. Critical Gotchas

1. **VPAn must be LOW during IACK** — CPU hangs without it (see section 2)
2. **DTACKn is sampled on enPhi2** — drive changes between enPhi1 and enPhi2
3. **IPLn is sampled on enPhi2** — stable at that edge
4. **eab is [23:1]** — word address only, A[0] doesn't exist
5. **phi1/phi2 must never overlap** — undefined behavior
6. **First enable after reset must be enPhi1**
7. **dsn_dly needed** for CS signals that decode using DS strobes
8. **BGACKn guard** on address decode even if no DMA
9. **pwrUp and extReset always tied together** in practice
10. **Verilator MULTIDRIVEN** — uaddrPla.sv must have all always_comb blocks merged (see GUARDRAILS.md)

---

## 10. Known Bugs in Our Cores (from audit)

| Core | Bug | Severity |
|------|-----|----------|
| ~~all 7~~ | ~~VPAn = 1'b1~~ | ~~CRITICAL~~ — **FIXED** in fx68k_adapter.sv |
| taito_b | CPU ROM SDRAM channel wired but unused (TODO comment) | CRITICAL — CPU can't execute |
| taito_x | CPU ROM SDRAM channel driven as 0 (TODO comment) | CRITICAL — CPU can't execute |
| taito_x | Z80 WAIT_n = 1'b1 always — reads stale SDRAM data | HIGH |
| toaplan_v2 | GFX SDRAM upper 16 bits always zero | MEDIUM — verify if GP9001 needs 32-bit |
| kaneko | GFX SDRAM upper 16 bits always zero | MEDIUM — same issue |

---

## 11. Validation Methodology

**Phase 1 — Per-frame RAM dump (implement FIRST):**
- MAME Lua: `space:read_range()` dumps main RAM + VRAM + palette per frame
- Verilator: dump same addresses from sim after each VBlank
- Binary diff → first divergent frame → first divergent address

**Phase 2 — Bus transaction taps (when divergence needs tracing):**
- MAME Lua: `install_read_tap` / `install_write_tap` on RAM regions
- Log: frame, cycle (via `time:as_ticks(CPU_HZ)`), addr, data, mask
- Compare transaction streams between MAME and Verilator

**Each step is a checkpoint.** Don't proceed to the next until the current one passes:
1. CPU boots (reads reset vector correctly)
2. CPU executes first ~100 instructions (register trace matches)
3. Main RAM matches MAME after N frames
4. VRAM / palette / scroll match
5. Pixel output matches (final confirmation only)
