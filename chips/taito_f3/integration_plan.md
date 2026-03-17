# Taito F3 System — MiSTer Core Integration Plan

**Date:** 2026-03-16
**Status:** Pre-RTL (TC0630FDP and TC0650FDA research complete; all support chips audited)
**MAME reference:** `src/mame/taito/taito_f3.cpp` + `src/mame/taito/taito_en.cpp`
**RTL ready:** TC0630FDP (complete), TC0650FDA (complete), tg68k_adapter (stub/active),
              TC0220IOC (drop-in reuse), TC0140SYT (drop-in reuse, parameterized)

---

## 1. System Architecture Diagram

```
                  +--------------------------------------------------------------+
                  |                  Taito F3 Package System                     |
                  |                                                              |
  +------------+  |  +----------------------------------------------------------+|
  | MiSTer HPS |  |  |          MC68EC020 @ 26.686 MHz                          ||
  | (ARM/Linux)|  |  |  Data[31:0]   Addr[23:1]   AS/DTACK/IPL                 ||
  |            |  |  +-----+----+----+----+----+----+----+----+--+--------------+|
  | ROM images |  |        |    |    |    |    |    |    |    |  |               |
  | in SDRAM   |  |        |    |    |    |    |    |    |    |  | ipl_n[2:0]    |
  +-----+------+  |  +-----+  +-+--+ +---+-+ +-+--+ +--+-+ +-+-+-+             |
        |         |  |        |RAM | |     | |      |      | |TC  |             |
        |         |  |TC0630  |128K| |PAL  | |TC0640|      | |0140|             |
  +-----+------+  |  |FDP     |@   | |RAM  | |FIO   |      | |SYT |             |
  |  SDRAM     |  |  |(+FDA   |40  | |32KB | |I/O   |      | |snd |             |
  |            |  |  | fused) |0000| |@    | |@     |      | |com |             |
  | [68020 ROM]|<-+--+        |    | |4400 | |4A000 |      | |m   |             |
  | [GFX lo]   |<-+--+  GFX  |    | |00   | |0     |      | |    |             |
  | [GFX hi]   |<-+--+  ROM  +----+ +-----+ +------+      | +----+             |
  | [snd CPU]  |<-+--+  via  |                             |                   |
  | [Ensoniq]  |<-+--+  SDRAM|        +--------------------+                   |
  +------------+  |  |       |        | F3 RAM block (on-board)                |
                  |  |  spr  |  +-----+-----------+                             |
                  |  |  /tile|  | TC0630FDP / FDA  |                            |
                  |  |  ROM  |  | video area       |                            |
                  |  |  arb  |  | 0x600000-0x66001F|                            |
                  |  |       |  | Sprite 64KB      |                            |
                  |  |       |  | Playfield 48KB   |                            |
                  |  |       |  | Line RAM 64KB    |                            |
                  |  |       |  | Pivot RAM 64KB   |                            |
                  |  |       |  | Text/Char 16KB   |                            |
                  |  |       |  | Palette 32KB     |                            |
                  |  |       |  |   (0x440000)     |                            |
                  |  |       |  | Ctrl regs 32B    |                            |
                  |  |       |  |   (0x660000)     |                            |
                  |  |       +--+                  |                            |
                  |  |          | video_r/g/b[7:0] |                            |
                  |  |          | hsync/vsync/blank|                            |
                  |  +----------+------------------+                            |
                  |                                                              |
                  |  +----------------------------------------------------------+|
                  |  |         Taito EN Sound Module                            ||
                  |  |   68000 sound CPU @ ~16 MHz                              ||
                  |  |   ES5505 wavetable synth                                 ||
                  |  |   MB87078 volume control                                 ||
                  |  |   MC68681 DUART                                          ||
                  |  |   MB8421 dual-port RAM (@ 0x140000 sound / 0xC00000 main)||
                  |  +----------------------------------------------------------+|
                  +--------------------------------------------------------------+
```

---

## 2. Q1: 68020 Address Map

**Source:** `taito_f3.cpp` — `void taito_f3_state::f3_map(address_map &map)`

The map is **uniform across all F3 games** (unlike Taito B where addresses shifted per PCB).
The bubsympb bootleg variant differs only at `0x4a001d/f` (OKI sound).

| Address Range       | Size   | Contents                                | FPGA Chip          |
|---------------------|--------|-----------------------------------------|--------------------|
| `0x000000–0x1FFFFF` | 2MB    | 68EC020 Program ROM (SDRAM)             | ROM arbiter        |
| `0x300000–0x30007F` | 128B   | Sound bankswitch write (Kirameki only)  | glue logic         |
| `0x400000–0x41FFFF` | 128KB  | Main RAM (mirror at `+0x20000`)         | BRAM 128KB         |
| `0x440000–0x447FFF` | 32KB   | Palette RAM / TC0650FDA                 | tc0650fda          |
| `0x4A0000–0x4A001F` | 32B    | TC0640FIO — I/O (inputs, EEPROM, WDog)  | tc0640fio (new)    |
| `0x4C0000–0x4C0003` | 4B     | Timer control (pseudo-hblank init)      | glue logic         |
| `0x600000–0x60FFFF` | 64KB   | Sprite RAM                              | tc0630fdp          |
| `0x610000–0x61BFFF` | 48KB   | Playfield RAM (PF1–PF4)                 | tc0630fdp          |
| `0x61C000–0x61DFFF` | 8KB    | Text RAM                                | tc0630fdp          |
| `0x61E000–0x61FFFF` | 8KB    | Character RAM (CPU-writable tile GFX)   | tc0630fdp          |
| `0x620000–0x62FFFF` | 64KB   | Line RAM (per-scanline control)         | tc0630fdp          |
| `0x630000–0x63FFFF` | 64KB   | Pivot RAM                               | tc0630fdp          |
| `0x660000–0x66001F` | 32B    | Display control registers (scroll/mode) | tc0630fdp          |
| `0xC00000–0xC007FF` | 2KB    | MB8421 dual-port RAM (→ sound CPU)      | dpram (MB8421)     |
| `0xC80000–0xC80003` | 4B     | Sound CPU reset line 0 (assert)         | glue logic         |
| `0xC80100–0xC80103` | 4B     | Sound CPU reset line 1 (clear)          | glue logic         |

### Address Decode (chip-select logic)

All comparisons on `cpu_addr[23:1]` (word address = byte_addr >> 1):

```
prog_rom_cs     = (cpu_addr[23:21] == 3'b000)              // 0x000000–0x1FFFFF
main_ram_cs     = (cpu_addr[23:17] == 7'b001_0000)         // 0x400000–0x41FFFF (+ mirror)
palette_cs      = (cpu_addr[23:15] == 9'b0100_0100_0)      // 0x440000–0x447FFF
ioc_cs_n        = ~(cpu_addr[23:5]  == 19'h25000)          // 0x4A0000–0x4A001F
timer_cs        = (cpu_addr[23:2]   == 22'h130000)         // 0x4C0000–0x4C0003
fdp_video_cs    = (cpu_addr[23:17] == 7'b011_0000)         // 0x600000–0x63FFFF
fdp_ctrl_cs     = (cpu_addr[23:5]  == 19'h33000)           // 0x660000–0x66001F
dpram_cs        = (cpu_addr[23:10] == 14'h300)             // 0xC00000–0xC007FF
snd_rst0_cs     = (cpu_addr[23:2]  == 22'h320000)          // 0xC80000–0xC80003
snd_rst1_cs     = (cpu_addr[23:2]  == 22'h320040)          // 0xC80100–0xC80103
```

**Key difference from Taito B:** F3 has a fixed address map — no per-game parameter variation
is needed for chip-select base addresses. All 32+ F3 titles use identical `f3_map` layout.

---

## 3. Q2: Interrupt Levels

**Source:** `taito_f3.cpp` — `interrupt2()` and `trigger_int3()` callbacks.

```cpp
// Fires at VBLANK start:
INTERRUPT_GEN_MEMBER(taito_f3_state::interrupt2) {
    device.execute().set_input_line(2, HOLD_LINE);           // INT2 = VBLANK
    m_interrupt3_timer->adjust(m_maincpu->cycles_to_attotime(10000));
}

// Fires ~10,000 68EC020 cycles after INT2:
TIMER_CALLBACK_MEMBER(taito_f3_state::trigger_int3) {
    m_maincpu->set_input_line(3, HOLD_LINE);                 // INT3 = pseudo-hblank
}
```

| Signal   | 68EC020 IPL Level | Trigger                            | Usage                         |
|----------|-------------------|------------------------------------|-------------------------------|
| `int2`   | IRQ2              | VBLANK start                       | Frame sync, sprite DMA start  |
| `int3`   | IRQ3              | 10,000 CPU cycles after VBLANK     | Mid-frame palette/scroll load |

**INT3 is not a real hblank.** It is a software timer. The MAME comment states:
"Find how this HW drives the CRTC" — the exact cycle count is an approximation.
At 26.686 MHz, 10,000 cycles ≈ 375 µs ≈ 22 scanlines. Games use INT3 for second
palette bank loads or per-frame scroll updates that must occur mid-frame.

**IPL encoding for tg68k_adapter:**

```
ipl_n[2:0] = 3'b101  when int3 active (level 3 → ~level = 3'b100 wait... see below)
```

TG68K uses active-low IPL encoding. Level 2 = `ipl_n = ~2 = 3'b101`. Level 3 = `ipl_n = ~3 = 3'b100`.
When both are active, level 3 takes priority (higher level wins):

```systemverilog
// IPL encoder (in taito_f3.sv top level):
always_comb begin
    if      (int3_active) ipl_n = 3'b100;  // IRQ3 active-low
    else if (int2_active) ipl_n = 3'b101;  // IRQ2 active-low
    else                  ipl_n = 3'b111;  // no interrupt
end
```

Both interrupts use **HOLD_LINE** semantics. Latch on pulse from TC0630FDP vblank
output; hold until the 68EC020 performs an interrupt acknowledge cycle (IACK).
IACK detection: `FC[2:0] == 3'b111 && AS_N == 0` (autovector IACK).

**Contrast with Taito B:** Taito B has game-specific IPL level assignments (IRQ1–IRQ6
vary by PCB). F3 is fixed: INT2 always = IRQ2, INT3 always = IRQ3, no exceptions.

---

## 4. Q3: SDRAM Layout

**Source:** ROM_REGION declarations in `taito_f3.cpp` (all games), `taito_en.cpp`

### Maximum ROM sizes across all 30+ F3 titles

| Region               | Max size     | Typical     | Game with max      |
|----------------------|--------------|-------------|--------------------|
| `maincpu` (prog ROM) | 0x200000 (2MB)  | 2MB      | all games          |
| `sprites` (GFX lo)   | 0x800000 (8MB)  | 4–6MB    | Command W          |
| `sprites_hi` (GFX hi)| 0x400000 (4MB)  | 2–3MB    | Command W          |
| `tilemap` (tile lo)  | 0x400000 (4MB)  | 1–2MB    | Light Bringer      |
| `tilemap_hi` (tile hi)| 0x200000 (2MB) | 0.5–1MB  | Light Bringer      |
| `taito_en:audiocpu`  | 0x180000 (1.5MB)| 0.5–1MB  | Gun Lock           |
| `taito_en:ensoniq`   | 0x800000 (8MB)  | 8MB      | most games         |

**Total worst case: ~28MB** (Command W + Ensoniq 8MB). Fits in 32MB SDRAM.

### Proposed SDRAM Layout (MiSTer DE10-Nano — 32MB)

```
SDRAM Offset    Size     Region                  Tag
--------------------------------------------------------------
0x000000        2MB      68EC020 prog ROM        maincpu
0x200000        8MB      Sprite GFX (low 4bpp)   sprites
0xA00000        4MB      Sprite GFX (high 2bpp)  sprites_hi
0xE00000        4MB      Tilemap GFX (low 4bpp)  tilemap
0x1200000       2MB      Tilemap GFX (high 2bpp) tilemap_hi
0x1400000       1.5MB    Sound CPU prog ROM      taito_en:audiocpu
0x1580000      (0.5MB)   (padding / alignment)   —
0x1600000       8MB      Ensoniq sample ROMs     taito_en:ensoniq
--------------------------------------------------------------
Total:          ~27.5MB  (fits in 32MB)
```

**GFX ROM arbiter parameters:**

```systemverilog
// In taito_f3.sv top-level instantiation:
parameter logic [26:0] GFX_SPR_LO_BASE   = 27'h0200000;  // sprites
parameter logic [26:0] GFX_SPR_HI_BASE   = 27'h0A00000;  // sprites_hi
parameter logic [26:0] GFX_TILE_LO_BASE  = 27'h0E00000;  // tilemap
parameter logic [26:0] GFX_TILE_HI_BASE  = 27'h1200000;  // tilemap_hi
parameter logic [26:0] SND_CPU_ROM_BASE  = 27'h1400000;  // taito_en:audiocpu
parameter logic [26:0] ENSONIQ_ROM_BASE  = 27'h1600000;  // taito_en:ensoniq
```

TC0630FDP needs to read from four GFX ROM streams (spr_lo, spr_hi, tile_lo, tile_hi)
via the SDRAM arbiter. These are separate ROM regions requiring separate read ports or
time-multiplexed access. See §6 (open questions) for arbiter design.

**Note on Taito B comparison:** Taito B has 1 GFX stream (TC0180VCU `gfx_addr[22:0]`).
F3 has 4 separate GFX streams — the SDRAM arbitration is significantly more complex.

---

## 5. Q4: TC0220IOC / TC0140SYT Usage

### TC0220IOC — NOT present in Taito F3

Taito F3 uses **TC0640FIO** instead of TC0220IOC for all I/O. The TC0640FIO is newer
and appears on later Taito PCBs (also seen on late Taito B, e.g., pbobble_map).

**TC0640FIO address:** `0x4A0000–0x4A001F` (32 bytes, 16-word register window).

**TC0640FIO register layout** (from `f3_control_r/w` in MAME):

| Offset | R/W | Description                                                        |
|--------|-----|--------------------------------------------------------------------|
| 0x00   | W   | Watchdog reset (write any value to reset timer)                    |
| 0x01   | W   | Coin lockout/counters P1/P2 — bits[27:24]=counters, bits[3:0]=lock |
| 0x04   | W   | EEPROM control — DI, CLK, CS in specific bits                      |
| 0x05   | W   | Coin lockout/counters P3/P4 (mirror of 0x01 for 4-player games)    |
| 0x00   | R   | `IN.0` — P1+P2 buttons, test, service, EEPROM DOUT                 |
| 0x01   | R   | `IN.1` — P1+P2 joystick (active-low 8-way)                         |
| 0x02   | R   | `IN.2` — analog channel 1 (dial/spinner; 0 for non-analog games)   |
| 0x03   | R   | `IN.3` — analog channel 2                                          |
| 0x04   | R   | `IN.4` — P3+P4 buttons (4-player games only)                       |
| 0x05   | R   | `IN.5` — P3+P4 joystick (4-player games only)                      |

**Standard F3 joystick bit layout (IN.1, active-low):**

```
Bits [3:0] = P1: bit0=UP, bit1=DOWN, bit2=LEFT, bit3=RIGHT
Bits [7:4] = P2: bit4=UP, bit5=DOWN, bit6=LEFT, bit7=RIGHT
```

**Implication for FPGA:** TC0220IOC cannot be reused for F3. A new **tc0640fio.sv**
module is needed, or the TC0640FIO function can be implemented inline in `taito_f3.sv`
(it is much simpler than TC0220IOC — no rotary encoder logic, no paddle tracking).
The minimal implementation is a registered read mux over 6 input ports with 4 write
registers for coin/EEPROM. Estimated 50–80 lines of RTL.

### TC0140SYT — NOT present in Taito F3

F3 uses a **MB8421 dual-port RAM** for main↔sound CPU communication, not TC0140SYT.

| Aspect              | Taito B (TC0140SYT)               | Taito F3 (MB8421)                  |
|---------------------|-----------------------------------|------------------------------------|
| Comm protocol       | 4-bit nibble handshake, indexed   | 2KB shared memory, direct R/W      |
| Main CPU address    | 4 bytes (2 registers)             | 0xC00000–0xC007FF (2KB window)     |
| Sound CPU address   | Decoded by SYT from Z80 addr      | 0x140000–0x140FFF (4KB, sound side)|
| Sound CPU type      | Z80                               | 68000 (in Taito EN module)         |
| ADPCM ROM arbiter   | Built into TC0140SYT              | Not in MB8421 — ES5505 handles it  |
| FPGA status         | Drop-in ready (tc0140syt.sv)      | New: mb8421.sv (simple dual-port)  |

**Sound reset:** Main CPU writes to `0xC80000` (assert reset) and `0xC80100` (deassert
reset) to control the sound 68000's reset line. This is two separate address-decoded
write strobe outputs from `taito_f3.sv` → sound CPU `reset_n` pin.

---

## 6. Q5: F3-Specific Differences from Taito B

### Architecture-level differences

| Aspect               | Taito B                                | Taito F3                               |
|----------------------|----------------------------------------|----------------------------------------|
| Main CPU             | MC68000 @ 12 MHz (16-bit bus)          | MC68EC020 @ 26.686 MHz (32-bit bus)    |
| CPU adapter          | Direct (TG68000 or fx68k)              | tg68k_adapter.sv (16→32-bit coalescer) |
| Video chip           | TC0180VCU                              | TC0630FDP (far more capable)           |
| Palette/DAC          | TC0260DAR (RGB444, 8K entries)         | TC0650FDA (RGB888, 8K entries, alpha)  |
| Palette RAM          | External BRAM in top level             | Embedded in TC0650FDA (or shared BRAM) |
| I/O chip             | TC0220IOC                              | TC0640FIO (simpler, newer)             |
| Sound comms          | TC0140SYT (nibble protocol)            | MB8421 dual-port RAM (direct memory)   |
| Sound CPU            | Z80 @ 4 MHz                            | 68000 @ ~16 MHz (Taito EN module)      |
| Audio synthesis      | YM2610 (FM + ADPCM-A + ADPCM-B)        | ES5505 wavetable (no FM)               |
| GFX ROM streams      | 1 (TC0180VCU gfx_addr[22:0])           | 4 (spr_lo, spr_hi, tile_lo, tile_hi)  |
| Address map          | Per-game variable (parameters needed)  | Fixed across all 30+ games             |
| Interrupt levels     | Game-specific (IRQ1–IRQ6)              | Fixed: IRQ2=VBLANK, IRQ3=timer         |
| Alpha blending       | None                                   | Per-scanline, per-layer (TC0650FDA)    |
| Max GFX ROM          | 4MB                                    | 8MB sprites + 4MB tiles = 12MB         |
| SDRAM total          | ~11MB worst case                       | ~28MB worst case                       |

### Integration implications

1. **No TC0140SYT.** tc0140syt.sv is not instantiated. Instead, instantiate an
   `mb8421.sv` dual-port RAM module (2KB, simple). This is ~30 lines.

2. **No TC0220IOC.** tc0220ioc.sv is not instantiated. Implement TC0640FIO inline
   or as a minimal new module. The core logic is a read mux + 4 write registers.

3. **tg68k_adapter required.** The MC68EC020 requires the 16→32-bit bus coalescer
   from `chips/m68020/rtl/tg68k_adapter.sv`. This is not needed for Taito B's 68000.

4. **TC0650FDA vs TC0260DAR.** TC0650FDA has a 3-stage alpha blend MAC pipeline.
   TC0260DAR does not. The video output timing is 3 pixel-cycles later from the FDA.

5. **Fixed address map = simpler top level.** No per-game parameters for chip addresses.
   Only SDRAM ROM base addresses need parameterization.

6. **ES5505 / Taito EN module.** This is a self-contained sound subsystem. For initial
   FPGA implementation, the sound CPU and ES5505 can be stubbed (silence). The MB8421
   dual-port RAM must still be present so the main CPU can write sound commands without
   hanging on bus arbitration.

---

## 7. Port-by-Port Wiring

### 7.1 tg68k_adapter (MC68EC020 CPU)

| Port              | Dir | Width | Connects To                                          |
|-------------------|-----|-------|------------------------------------------------------|
| `clk`             | in  | 1     | System clock (26.686 MHz)                            |
| `reset_n`         | in  | 1     | System reset (active low)                            |
| `ipl_n[2:0]`      | in  | 3     | IPL encoder output (see §3)                          |
| `cpu_addr[23:1]`  | out | 23    | Word address → chip-select decode + all chip addr ports |
| `cpu_dout[31:0]`  | out | 32    | Write data → all chip write ports                    |
| `cpu_din[31:0]`   | in  | 32    | Read data mux (from all chips)                       |
| `cpu_rw`          | out | 1     | 1=read, 0=write                                      |
| `cpu_as_n`        | out | 1     | Address strobe (active low)                          |
| `cpu_be_n[3:0]`   | out | 4     | Byte enables active-low (D31:D24..D7:D0)             |
| `cpu_dtack_n`     | in  | 1     | DTACK from bus arbiter (active low)                  |
| `cpu_reset_n_out` | out | 1     | CPU reset output (drives sound module reset)         |

### 7.2 TC0630FDP (video — CPU-facing ports)

| Port                | Dir | Width | Connects To                                        |
|---------------------|-----|-------|----------------------------------------------------|
| `clk`               | in  | 1     | System clock (26.686 MHz)                          |
| `ce_pixel`          | in  | 1     | Pixel clock enable (÷4 = 6.6715 MHz)               |
| `rst_n`             | in  | 1     | System reset                                       |
| `cpu_cs`            | in  | 1     | `fdp_video_cs` (0x600000–0x63FFFF) OR `fdp_ctrl_cs` |
| `cpu_we`            | in  | 1     | `!cpu_rw`                                          |
| `cpu_addr[16:1]`    | in  | 16    | `cpu_addr[16:1]` (word address within FDP window)  |
| `cpu_din[31:0]`     | in  | 32    | `cpu_dout[31:0]` from tg68k_adapter                |
| `cpu_be_n[3:0]`     | in  | 4     | `cpu_be_n[3:0]` from tg68k_adapter                 |
| `cpu_dout[31:0]`    | out | 32    | → read data mux                                    |
| `cpu_dtack_n`       | out | 1     | → DTACK mux (for video RAM reads)                  |
| `int2`              | out | 1     | VBLANK pulse → IPL encoder (IRQ2)                  |
| `int3_trigger`      | out | 1     | Mid-frame pulse → 10K-cycle timer (IRQ3)           |
| `hblank_n`          | out | 1     | Horizontal blank                                   |
| `vblank_n`          | out | 1     | Vertical blank                                     |
| `hpos[8:0]`         | out | 9     | Horizontal pixel counter                           |
| `vpos[7:0]`         | out | 8     | Vertical scanline counter                          |
| `spr_rom_addr[...]` | out | —     | Sprite GFX ROM address → SDRAM arbiter             |
| `spr_lo_data[...]`  | in  | —     | Sprite GFX low 4bpp data ← SDRAM                   |
| `spr_hi_data[...]`  | in  | —     | Sprite GFX high 2bpp data ← SDRAM                  |
| `tile_rom_addr[...]`| out | —     | Tile GFX ROM address → SDRAM arbiter               |
| `tile_lo_data[...]` | in  | —     | Tile GFX low 4bpp data ← SDRAM                     |
| `tile_hi_data[...]` | in  | —     | Tile GFX high 2bpp data ← SDRAM                    |
| `src_pal[12:0]`     | out | 13    | → TC0650FDA `src_pal`                              |
| `dst_pal[12:0]`     | out | 13    | → TC0650FDA `dst_pal`                              |
| `src_blend[3:0]`    | out | 4     | → TC0650FDA `src_blend`                            |
| `dst_blend[3:0]`    | out | 4     | → TC0650FDA `dst_blend`                            |
| `pixel_valid`       | out | 1     | → TC0650FDA `pixel_valid`                          |

### 7.3 TC0650FDA (palette DAC)

| Port             | Dir | Width | Connects To                                          |
|------------------|-----|-------|------------------------------------------------------|
| `clk`            | in  | 1     | System clock (26.686 MHz)                            |
| `ce_pixel`       | in  | 1     | Pixel clock enable                                   |
| `rst_n`          | in  | 1     | System reset                                         |
| `cpu_cs`         | in  | 1     | `palette_cs` (0x440000–0x447FFF)                     |
| `cpu_we`         | in  | 1     | `!cpu_rw`                                            |
| `cpu_addr[12:0]` | in  | 13    | `cpu_addr[13:1]` (13-bit palette index)              |
| `cpu_din[31:0]`  | in  | 32    | `cpu_dout[31:0]` (32-bit longword write)             |
| `cpu_be[3:0]`    | in  | 4     | `~cpu_be_n[3:0]` (active-high byte enables)          |
| `cpu_dtack_n`    | out | 1     | Permanently low (zero-wait palette write)            |
| `pixel_valid`    | in  | 1     | ← TC0630FDP `pixel_valid`                            |
| `src_pal[12:0]`  | in  | 13    | ← TC0630FDP `src_pal`                                |
| `dst_pal[12:0]`  | in  | 13    | ← TC0630FDP `dst_pal`                                |
| `src_blend[3:0]` | in  | 4     | ← TC0630FDP `src_blend`                              |
| `dst_blend[3:0]` | in  | 4     | ← TC0630FDP `dst_blend`                              |
| `mode_12bit`     | in  | 1     | ← TC0630FDP lineram decoder (0=RGB888, 1=12-bit)     |
| `video_r[7:0]`   | out | 8     | → HDMI encoder red channel                           |
| `video_g[7:0]`   | out | 8     | → HDMI encoder green channel                         |
| `video_b[7:0]`   | out | 8     | → HDMI encoder blue channel                          |

### 7.4 TC0640FIO (I/O controller — inline or minimal module)

| Port              | Dir | Width | Connects To                                         |
|-------------------|-----|-------|-----------------------------------------------------|
| `clk`             | in  | 1     | System clock                                        |
| `cs_n`            | in  | 1     | `ioc_cs_n` (0x4A0000–0x4A001F)                      |
| `we`              | in  | 1     | `!cpu_rw`                                           |
| `addr[3:0]`       | in  | 4     | `cpu_addr[4:1]` (offset 0–15, byte/word granularity)|
| `din[31:0]`       | in  | 32    | `cpu_dout[31:0]`                                    |
| `dout[31:0]`      | out | 32    | → read data mux                                     |
| `in0[31:0]`       | in  | 32    | P1+P2 buttons + test/service/EEPROM DOUT            |
| `in1[31:0]`       | in  | 32    | P1+P2 joystick directions (active-low)              |
| `in2[31:0]`       | in  | 32    | Analog 1 (tie 0 for digital-only games)             |
| `in3[31:0]`       | in  | 32    | Analog 2                                            |
| `in4[31:0]`       | in  | 32    | P3+P4 buttons (tie 0 for 2-player games)            |
| `in5[31:0]`       | in  | 32    | P3+P4 joystick (tie 0 for 2-player games)           |
| `eeprom_do`       | out | 1     | EEPROM serial data out → EEPROM chip                |
| `eeprom_di`       | in  | 1     | EEPROM serial data in ← EEPROM chip                 |
| `eeprom_cs`       | out | 1     | EEPROM chip select                                  |
| `eeprom_clk`      | out | 1     | EEPROM serial clock                                 |
| `coin_lock[1:0]`  | out | 2     | Coin lockout solenoids (leave unconnected)           |
| `coin_ctr[1:0]`   | out | 2     | Coin counters (leave unconnected)                   |

**Input bit layout (IN.1 — joystick, read at addr=1):**

```
[31:16] = (unused / open)
[15:8]  = P2: bit11=UP, bit10=DOWN, bit9=LEFT, bit8=RIGHT (active-low)
[7:0]   = P1: bit3=UP, bit2=DOWN, bit1=LEFT, bit0=RIGHT   (active-low)
```

**Input bit layout (IN.0 — buttons):**

```
[23:16] = EEPROM DOUT + test/service bits
[15:8]  = P2 buttons [3:0] active-low
[7:0]   = P1 buttons [3:0] active-low
```

### 7.5 MB8421 Dual-Port RAM (main↔sound CPU comms)

| Port             | Dir | Width | Connects To                                          |
|------------------|-----|-------|------------------------------------------------------|
| `clk`            | in  | 1     | System clock                                         |
| `left_cs`        | in  | 1     | `dpram_cs` (0xC00000–0xC007FF, main CPU side)        |
| `left_we`        | in  | 1     | `!cpu_rw`                                            |
| `left_addr[9:0]` | in  | 10    | `cpu_addr[10:1]` (1KB word-addressed, 2KB byte)      |
| `left_din[31:0]` | in  | 32    | `cpu_dout[31:0]`                                     |
| `left_be_n[3:0]` | in  | 4     | `cpu_be_n[3:0]`                                      |
| `left_dout[31:0]`| out | 32    | → read data mux                                      |
| `right_cs`       | in  | 1     | Decoded from sound 68000 address 0x140000–0x140FFF   |
| `right_we`       | in  | 1     | Sound CPU write enable                               |
| `right_addr[9:0]`| in  | 10    | Sound CPU address[10:1]                              |
| `right_din[15:0]`| in  | 16    | Sound CPU write data (16-bit bus)                    |
| `right_dout[15:0]`| out| 16    | → sound CPU data bus                                 |

**Note:** MB8421 is symmetric dual-port. Both sides may read and write independently.
The main CPU uses a 32-bit bus (2KB window = 512 longwords); the sound CPU uses a
16-bit bus (maps the same 2KB as 1024 words). On FPGA: implement as a simple true
dual-port BRAM (2KB, ~1 M10K). No interrupt line between ports is needed for F3
(MAME shows no INT from MB8421 to main CPU; polling is used).

### 7.6 Sound CPU Reset Control

```
snd_rst0_cs (0xC80000) write → assert sound_cpu_reset_n = 0
snd_rst1_cs (0xC80100) write → deassert sound_cpu_reset_n = 1
```

Implemented in `taito_f3.sv` as two address-decoded write strobes connected directly
to the Taito EN sound module's reset input. No separate chip needed.

---

## 8. DTACK Generation

| Region             | DTACK source                                       |
|--------------------|-----------------------------------------------------|
| Program ROM        | 1-cycle registered DTACK (SDRAM must be pre-loaded)|
| Main RAM           | 1-cycle registered DTACK (BRAM)                   |
| Palette RAM        | TC0650FDA `cpu_dtack_n` (always 0 = zero-wait)    |
| TC0640FIO          | 1-cycle registered DTACK                          |
| TC0630FDP video    | TC0630FDP `cpu_dtack_n` (may stall during display)|
| MB8421 DPRAM       | 1-cycle registered DTACK (BRAM)                   |
| Timer control      | 1-cycle registered DTACK                          |
| Sound reset regs   | 1-cycle registered DTACK                          |

The DTACK mux priority: `fdp_video_cs ? fdp_dtack_n : palette_cs ? 1'b0 : !dtack_r`
(same pattern as taito_b.sv §DTACK Generation, adapted for F3 chip set).

---

## 9. Summary: What Is Ready vs What Is Needed

| Component                 | Status                        | Action Required                            |
|---------------------------|-------------------------------|--------------------------------------------|
| `tg68k_adapter.sv`        | Stub, ports complete          | Drop in TG68K VHDL files                  |
| `tc0630fdp.sv` (FDP)      | RTL complete                  | Wire up; confirm GFX ROM arbiter interface |
| `tc0650fda.sv` (FDA)      | RTL complete                  | Wire up per §7.3                           |
| `tc0220ioc.sv`            | **NOT used in F3**            | Do not instantiate                         |
| `tc0140syt.sv`            | **NOT used in F3**            | Do not instantiate                         |
| `tc0640fio.sv` (I/O)      | Does not exist                | Implement new (~60 lines inline)           |
| `mb8421.sv` (dual-port)   | Does not exist                | Implement new (~30 lines, simple BRAM)     |
| `taito_f3.sv` (top level) | Does not exist                | Create after open questions resolved       |
| Main RAM (BRAM)           | Not instantiated              | 128KB BRAM, 32-bit wide                   |
| SDRAM arbiter             | Not designed                  | 4-stream GFX arbiter (complex — see §10)  |
| EEPROM (93C46)            | Not present                   | Implement 93C46 3-wire serial model        |
| Taito EN / ES5505         | Not present                   | Stub initially (silence); full later       |

---

## 10. Open Questions

### Critical (blocks top-level RTL)

| # | Question | Where to Look |
|---|----------|---------------|
| 1 | **GFX ROM arbiter design** — TC0630FDP needs 4 independent GFX ROM streams (spr_lo, spr_hi, tile_lo, tile_hi). Each stream may have different bandwidth requirements. How are these time-multiplexed on the single SDRAM bus? Does the FDP have a built-in burst-fetch mechanism? | `tc0630fdp/section3_rtl_plan.md` §GFX; MAME `taito_f3_v.cpp` sprite/tile render loops |
| 2 | **TC0630FDP GFX ROM port interface** — The exact FDP port list for GFX ROM access is not yet defined. Does the FDP expose separate address/data/req/ack per stream, or a single multiplexed bus? | `tc0630fdp` RTL plan section 3 |
| 3 | **INT3 timer implementation** — MAME fires INT3 as a software timer (10,000 cycles). In FPGA with a real pixel clock, how should INT3 be generated? Option A: fixed scanline counter (fire at line N); Option B: cycle counter from vblank. The MAME `cycles_to_attotime(10000)` at 26.686 MHz ≈ 375 µs ≈ 22 scanlines. A scanline counter is more hardware-accurate. | MAME `interrupt2()` + game-specific INT3 handler disassembly |
| 4 | **TC0640FIO EEPROM interface** — The 93C46 EEPROM stores game settings. MiSTer typically maps EEPROM to HPS-accessible NVRAM. Exact bit positions for DI/CLK/CS in the write register at offset 0x04 need verification from MAME `f3_control_w`. | `taito_f3.cpp` `f3_control_w` case 0x04 |
| 5 | **Main RAM size and mirroring** — The address map shows 128KB at 0x400000–0x41FFFF with a mirror at 0x420000–0x43FFFF. MAME handles this via `mirror(0x20000)`. Confirm the mirror is passive (same BRAM, high address bit ignored) vs active (separate). | `taito_f3.cpp` `f3_map` RAM declaration |

### Important (affects correctness)

| # | Question | Where to Look |
|---|----------|---------------|
| 6 | **INT2 / INT3 IACK clearing** — TG68K autovectors these interrupts. Does the FDP hardware clear its interrupt output when the CPU acknowledges, or does it hold until end of vblank? MAME uses HOLD_LINE which releases on IACK. | TG68K VHDL interrupt acknowledge handling |
| 7 | **TC0650FDA pixel pipeline delay** — FDA adds 3 pixel-clock stages. The HDMI encoder's HSYNC/VSYNC/DE signals must be delayed to match. What is the current TC0630FDP output timing, and does it already account for FDA delay? | `tc0650fda/section2_rtl_plan.md` §5.4 |
| 8 | **Sound bankswitch at 0x300000** — Only Kirameki Star Road uses this. Write handler selects one of several 128KB ROM banks. Where does the banked ROM live in SDRAM? | `taito_f3.cpp` `sound_bankswitch_w` |
| 9 | **bubsympb variant** — One bootleg uses OKI6295 instead of ES5505/Taito EN. This requires a separate machine config path and different sound SDRAM layout. Is supporting this variant in scope? | `taito_f3.cpp` `bubsympb_map`, `bubsympb()` config |
| 10 | **F3_MAIN_CLK exact value** — MAME references `F3_MAIN_CLK` as a constant. From screen timing (26.686 MHz / 4 = pixel clock), the CPU likely runs at 26.686 MHz / 1 = 26.686 MHz or / 2 = 13.343 MHz. The section1 document states 26.686 MHz. Confirm the actual CPU divider. | `taito_f3.cpp` `#define F3_MAIN_CLK` or machine config CPU frequency |

### Minor / Can Defer

| # | Question |
|---|----------|
| 11 | Does any F3 game use the TC0660FCM control module in a way that requires RTL? MAME mentions it in comments but never instantiates a device for it — it may be glue logic already handled by TC0630FDP. |
| 12 | 4-player games (Arabian Magic, etc.) need IN.4/IN.5 wired. How does MiSTer's OSD expose 4-player inputs? |
| 13 | The ES5505 (not ES5506 as documented) is the correct chip. Does an existing FPGA ES5505 core exist (jotego/jtcores)? |
| 14 | Bubble Symphony (bubsymph) uses a different sprite ROM layout (5bpp planar) per section1 §11.7. Does this affect the GFX arbiter, or is it handled entirely within TC0630FDP? |

---

## 11. Per-Game Quick Reference (F3 titles)

All games use the fixed `f3_map`. Differences are ROM sizes and optional 4-player I/O only.

| Game               | Prog ROM | Sprite lo+hi      | Tile lo+hi        | Ensoniq | Notes                  |
|--------------------|----------|-------------------|-------------------|---------|------------------------|
| ringrage           | 2MB      | 4MB + 2MB         | 1MB + 512KB       | 8MB     |                        |
| arabianm           | 2MB      | ~4MB + ~2MB       | ~2MB + ~1MB       | 8MB     | 4-player                |
| rayforce/gunlock   | 2MB      | 2MB + 1MB         | 2MB + 1MB         | 8MB     |                        |
| dariusg            | 2MB      | ~4MB + ~2MB       | ~2MB + ~1MB       | 8MB     | Wide screen             |
| elvactr            | 2MB      | ~4MB + ~2MB       | ~2MB + ~1MB       | 8MB     |                        |
| lightbringer       | 2MB      | 6MB + 3MB         | 4MB + 2MB         | 8MB     | Largest tile ROM        |
| commandw           | 2MB      | 8MB + 4MB         | ~4MB + ~2MB       | 8MB     | Largest sprite ROM      |
| bubsymph           | 2MB      | ~4MB + ~2MB       | ~2MB + ~1MB       | 8MB     | Alt sprite decode       |
| pbobble2           | 2MB      | ~2MB + ~1MB       | ~1MB + ~512KB     | 8MB     |                        |
| cleopatr           | 2MB      | ~2MB + ~1MB       | ~1MB + ~512KB     | 8MB     |                        |

---

## 12. Source References

- `src/mame/taito/taito_f3.cpp` — `f3_map`, interrupt callbacks, ROM regions, machine config
- `src/mame/taito/taito_en.cpp` — sound module: 68000 map, ES5505, MB8421 right-side map
- `chips/tc0630fdp/section1_registers.md` — full F3 CPU address map (§2), interrupts (§14)
- `chips/tc0650fda/section1_registers.md` — palette format, blend interface (§4–6)
- `chips/tc0650fda/section2_rtl_plan.md` — FDA integration notes (§5), BRAM budget (§4)
- `chips/m68020/rtl/tg68k_adapter.sv` — 16→32-bit bus coalescer, IPL port definition
- `chips/taito_support/tc0220ioc.sv` — NOT used in F3 (TC0640FIO replaces it)
- `chips/taito_support/tc0140syt.sv` — NOT used in F3 (MB8421 replaces it)
- `chips/taito_b/rtl/taito_b.sv` — reference integration pattern
- `chips/taito_b/integration_plan.md` — reference document structure
- `chips/taito_b/mame_research.md` — reference MAME research methodology
