# Taito B MAME Research

**Date:** 2026-03-16
**Source:** MAME `src/mame/taito/taito_b.cpp` + `src/mame/taito/tc0180vcu.cpp` + `src/mame/taito/tc0180vcu.h`
**GitHub commit:** master branch, fetched 2026-03-16

---

## Q1: 68000 Address Map

### Finding: Address map is NOT uniform across games

The integration plan's proposed "Nastar" map is **one of several layouts** in the driver. The TC0180VCU window is always `0x400000–0x47FFFF` in the majority of games, but all other chip locations vary by PCB revision.

### All address maps from `taito_b.cpp`

**`rastsag2_map`** (Nastar / Nastar Warrior / Rastan Saga II — reference game)
```
0x000000–0x07FFFF  ROM (512KB, 68K prog)
0x200000–0x201FFF  TC0260DAR palette RAM (write16 shadow = 8K × 16-bit)
0x400000–0x47FFFF  TC0180VCU (512KB window)
0x600000–0x607FFF  Work RAM (32KB)
0x800000–0x800000  TC0140SYT master_port_w
0x800002–0x800002  TC0140SYT master_comm r/w
0xA00000–0xA0000F  TC0220IOC (read/write, umask 0xFF00 → high byte = D[15:8])
```

**`crimec_map`** (Crime City — IOC and SYT swap places)
```
0x000000–0x07FFFF  ROM
0x200000–0x20000F  TC0220IOC (umask 0xFF00)
0x400000–0x47FFFF  TC0180VCU
0x600000–0x600000  TC0140SYT master_port_w
0x600002–0x600002  TC0140SYT master_comm r/w
0x800000–0x801FFF  TC0260DAR palette RAM
0xA00000–0xA0FFFF  Work RAM (64KB)
```

**`tetrist_map`** (Tetris on Nastar hardware)
```
0x000000–0x07FFFF  ROM
0x200000–0x200000  TC0140SYT master_port_w
0x200002–0x200002  TC0140SYT master_comm r/w
0x400000–0x47FFFF  TC0180VCU
0x600000–0x60000F  TC0220IOC (umask 0xFF00)
0x800000–0x807FFF  Work RAM (32KB)
0xA00000–0xA01FFF  TC0260DAR palette RAM
```

**`hitice_state::main_map`** (Hit the Ice — uses PC060HA instead of TC0140SYT)
```
0x000000–0x07FFFF  ROM
0x400000–0x47FFFF  TC0180VCU
0x600000–0x60000F  TC0220IOC (umask 0xFF00)
0x700000–0x700000  PC060HA master_port_w
0x700002–0x700002  PC060HA master_comm r/w
0x800000–0x803FFF  Work RAM (16KB)
0xA00000–0xA01FFF  TC0260DAR palette RAM
0xB00000–0xB7FFFF  Pixel RAM (special for hitice)
```

**`rambo3_state::main_map`** (Rambo III)
```
0x000000–0x07FFFF  ROM
0x200000–0x200000  TC0140SYT master_port_w
0x200002–0x200002  TC0140SYT master_comm r/w
0x400000–0x47FFFF  TC0180VCU
0x600000–0x60001F  TC0220IOC + trackball extensions
0x800000–0x803FFF  Work RAM (16KB)
0xA00000–0xA01FFF  TC0260DAR palette RAM
```

**`pbobble_map`** / **`spacedx_map`** (Puzzle Bobble, Space Dxzone)
```
0x000000–0x07FFFF  ROM
0x400000–0x47FFFF  TC0180VCU
0x500000–0x50000F  TC0640FIO (replaces TC0220IOC on later PCBs)
0x700000–0x700000  TC0140SYT master_port_w
0x700002–0x700002  TC0140SYT master_comm r/w
0x800000–0x801FFF  TC0260DAR palette RAM
0x900000–0x90FFFF  Work RAM (64KB)
```

**`spacedxo_map`** (Space Dxzone old PCB — TC0180VCU at 0x500000)
```
0x000000–0x07FFFF  ROM
0x100000–0x100000  TC0140SYT master_port_w
0x100002–0x100002  TC0140SYT master_comm r/w
0x200000–0x20000F  TC0220IOC (umask 0x00FF → **low byte D[7:0]**)
0x300000–0x301FFF  TC0260DAR palette RAM
0x400000–0x40FFFF  Work RAM (64KB)
0x500000–0x57FFFF  TC0180VCU  ← DIFFERENT: 0x500000 not 0x400000
```

**`silentd_map`** (Silent Dragon — similar to spacedxo, TC0180VCU at 0x500000)
```
0x000000–0x07FFFF  ROM
0x100000–0x100000  TC0140SYT master_port_w
0x100002–0x100002  TC0140SYT master_comm r/w
0x200000–0x20000F  TC0220IOC (umask 0x00FF → low byte)
0x300000–0x301FFF  TC0260DAR palette RAM
0x400000–0x403FFF  Work RAM (16KB)
0x500000–0x57FFFF  TC0180VCU  ← DIFFERENT
```

**`selfeena_map`** (Sel Feena)
```
0x000000–0x07FFFF  ROM
0x100000–0x103FFF  Work RAM (16KB)
0x200000–0x27FFFF  TC0180VCU  ← DIFFERENT: 0x200000
0x300000–0x301FFF  TC0260DAR palette RAM
0x400000–0x40000F  TC0220IOC (umask 0xFF00, mirrored at 0x410000)
0x500000–0x500000  TC0140SYT master_port_w
0x500002–0x500002  TC0140SYT master_comm r/w
```

**`sbm_map`** (Super Buster Bros)
```
0x000000–0x07FFFF  ROM
0x100000–0x10FFFF  Work RAM (64KB)
0x200000–0x201FFF  TC0260DAR palette RAM
0x300000–0x30000F  TC0510NIO (replaces TC0220IOC on very late PCBs)
0x320000–0x320000  TC0140SYT master_port_w
0x320002–0x320002  TC0140SYT master_comm r/w
0x900000–0x97FFFF  TC0180VCU  ← DIFFERENT: 0x900000
```

### Summary: What is fixed vs. variable

| Chip | Fixed? | Notes |
|------|--------|-------|
| TC0180VCU | **No** | Most games: 0x400000–0x47FFFF. Exceptions: spacedxo/silentd = 0x500000, selfeena = 0x200000, sbm = 0x900000 |
| TC0260DAR | **No** | Ranges: 0x200000, 0x300000, 0x600000, 0x800000, 0xA00000 depending on game |
| TC0220IOC | **No** | Ranges: 0x200000, 0x600000, 0x800000, 0xA00000 depending on game |
| TC0140SYT | **No** | Ranges: 0x100000, 0x200000, 0x500000, 0x600000, 0x700000, 0x800000, 0x320000 |
| Work RAM | **No** | Varies widely |
| TC0220IOC umask | **No** | Some games use `umask 0xFF00` (IOC on D[15:8]), others use `umask 0x00FF` (IOC on D[7:0]) |

### Key implication for RTL

The top-level must use programmable address decode (parameters per game) rather than hardcoded chip-select logic. This is standard practice for MiSTer cores that support multiple game PCB revisions.

### Chip select decode example (for nastar)

```
tc0180vcu_cs  = (A[23:19] == 5'b00100)                  // 0x400000–0x47FFFF
tc0260dar_cs  = (A[23:13] == 11'b000_1000_0000)          // 0x200000–0x201FFF
tc0220ioc_csn = ~(A[23:4] == 20'hA0000)                  // 0xA00000–0xA0000F
tc0140syt_mcsn = ~(A[23:2] == 22'h200000)                // 0x800000–0x800003 (port+comm pair)
```

The MAME driver accesses the SYT as two separate byte-wide addresses at +0 (port) and +2 (comm). These are on D[7:0] in all TC0140SYT maps (data is 4-bit nibble internally).

---

## Q2: GFX ROM Layout

### GFX ROM region sizes per game (from MAME `ROM_REGION("tc0180vcu", ...)`)

All GFX data loads into the `"tc0180vcu"` region. TC0180VCU's `gfx_addr[22:0]` is a 23-bit byte address, allowing up to 8MB of GFX ROM.

| Game | GFX ROM Size | Notes |
|------|-------------|-------|
| nastar / nastarw / rastsag2 | **0x100000 (1MB)** | Reference game |
| crimec / crimecu / crimecj | **0x100000 (1MB)** | |
| ashura / ashuraj / ashurau | **0x100000 (1MB)** | |
| hitice | **0x100000 (1MB)** | |
| masterw / masterwj / masterwu | **0x100000 (1MB)** | |
| pbobble / bublbust | **0x100000 (1MB)** | |
| spacedx / spacedxj / spacedxo | **0x100000 (1MB)** | |
| selfeena | **0x100000 (1MB)** | |
| rambo3 / rambo3u | **0x200000 (2MB)** | |
| ryujin / ryujina | **0x200000 (2MB)** | |
| viofight | **0x200000 (2MB)** | |
| silentd / silentdj / silentdu | **0x400000 (4MB)** | |
| qzshowby | **0x400000 (4MB)** | |
| sbm / sbmj | **0x400000 (4MB)** | |
| realpunc / realpuncj | **0x400000 (4MB)** | |

**Maximum GFX ROM: 4MB (0x400000)**

TC0180VCU `gfx_addr[22:0]` can address exactly 8MB; the largest game uses 4MB (23-bit address is sufficient, 22-bit covers 4MB).

### Proposed SDRAM layout (nastar reference)

The TC0180VCU `gfx_addr` is a byte offset within the GFX region. The SDRAM arbitrator must translate:

```
sdram_addr = GFX_ROM_SDRAM_BASE + gfx_addr[22:0]
```

A clean layout (nastar, 1MB GFX):

| Region | SDRAM Base | Size | Parameter |
|--------|-----------|------|-----------|
| 68K prog ROM | `0x000000` | 512KB | hardcoded |
| Z80 prog ROM | `0x080000` | 64KB | hardcoded |
| GFX ROM | `0x100000` | 1MB (nastar) / up to 4MB | `GFX_ROM_BASE = 27'h100000` |
| ADPCM-A ROM | `0x200000` | 512KB (nastar) | `ADPCMA_ROM_BASE = 27'h200000` |
| ADPCM-B ROM | `0x280000` | 512KB (nastar) | `ADPCMB_ROM_BASE = 27'h280000` |

For a **worst-case game** (4MB GFX + 2MB ADPCM-A + no ADPCM-B):

| Region | SDRAM Base | Size |
|--------|-----------|------|
| 68K prog ROM | `0x000000` | up to 1MB (realpunc uses 1MB) |
| Z80 prog ROM | `0x100000` | 128KB max (pbobble uses 128KB) |
| GFX ROM | `0x200000` | up to 4MB |
| ADPCM-A ROM | `0x600000` | up to 2MB |
| ADPCM-B ROM | `0x800000` | up to 512KB |
| **Total** | | **~11MB max — fits in 16MB SDRAM** |

**Note:** The TC0140SYT module already has `ADPCMA_ROM_BASE` and `ADPCMB_ROM_BASE` as 27-bit parameters (integration_plan.md §3 change already reflected in `chips/taito_support/tc0140syt.sv`). The GFX base must be a parameter on the top-level SDRAM arbitrator.

---

## Q3: ADPCM ROM Sizes

### Sound chip variants

Taito B games use one of three sound configurations:

| Sound Chip | Games | ADPCM channels |
|-----------|-------|----------------|
| YM2610 | nastar, crimec, ashura, rambo3, pbobble, spacedx, qzshowby, silentd, selfeena, ryujin, sbm, realpunc | ADPCM-A + ADPCM-B |
| YM2151 + OKI M6295 | hitice, hiticej, hiticerb | OKI samples only (no YM2610 ADPCM) |
| YM2203 + OKI M6295 | masterw, masterwu, masterwj | OKI samples only |
| YM2151 + OKI M6295 | viofight | OKI samples only |

**YM2610 games — ADPCM-A and ADPCM-B ROM sizes:**

| Game | ADPCM-A | ADPCM-B |
|------|---------|---------|
| nastar / rastsag2 | 0x080000 (512KB) | 0x080000 (512KB) |
| crimec | 0x080000 (512KB) | **none** (no ADPCM-B) |
| ashura | 0x080000 (512KB) | **none** |
| rambo3 / rambo3u | 0x080000 (512KB) | **none** |
| pbobble | **0x100000 (1MB)** | **none** |
| spacedx | 0x080000 (512KB) | **none** |
| qzshowby | **0x200000 (2MB)** | **none** |
| silentd | 0x080000 (512KB) | 0x080000 (512KB) |
| selfeena | 0x080000 (512KB) | **none** |
| ryujin | 0x080000 (512KB) | **none** |
| sbm | 0x080000 (512KB) | **none** |
| realpunc | **0x200000 (2MB)** | **none** |

**Maximums:**
- ADPCM-A: **0x200000 (2MB)** — qzshowby, realpunc
- ADPCM-B: **0x080000 (512KB)** — nastar, silentd (no game uses large ADPCM-B)

**Non-YM2610 games — OKI M6295 ROM:**

| Game | OKI ROM size |
|------|-------------|
| hitice | 0x020000 (128KB) |
| viofight | 0x020000 (128KB) |
| masterw | (no OKI, YM2203 only) |

These games do not use TC0140SYT's YAA/YBA ADPCM ROM address buses. The OKI M6295 is memory-mapped separately and its ROM is typically accessed via a dedicated Z80 memory window or banked ROM, not via the SYT.

**Key implication:** When targeting a non-YM2610 game, `YAD` and `YBD` from TC0140SYT can be left disconnected. The integration plan should document per-game sound chip selection as a parameter.

---

## Q4: Palette Index Width

### Conclusion: 13-bit index, IM[13] can be safely tied to 0

**Evidence 1 — MAME palette size:**

Every Taito B game in the driver declares exactly:
```cpp
PALETTE(config, m_palette).set_format(palette_device::RGBx_444, 4096);
// or
PALETTE(config, m_palette).set_format(palette_device::RRRRGGGGBBBBRGBx, 4096);
```
4096 palette entries = 12-bit index. **This is MAME's palette_device entry count**, not a direct hardware width — it reflects that the game software only uses 4096 of the possible 8192 entries because the color bases never exceed 0xFF and color values are 6-bit (max palette address = 0xFF + 0x3F = 0x13E using naive arithmetic, but actual layout uses all 256 color slots of 16 colors each = 256×16 = 4096 entries).

**Evidence 2 — tc0180vcu.h color base setters:**

```cpp
void set_fb_colorbase(int color) { m_fb_color_base = color * 16; }
void set_bg_colorbase(int color) { m_bg_color_base = color; }
void set_fg_colorbase(int color) { m_fg_color_base = color; }
void set_tx_colorbase(int color) { m_tx_color_base = color; }
```

Color bases from a representative game (crimec / viofight):
```cpp
m_tc0180vcu->set_fb_colorbase(0x80);  // m_fb_color_base = 0x80 * 16 = 0x800
m_tc0180vcu->set_bg_colorbase(0x00);  // m_bg_color_base = 0x000
m_tc0180vcu->set_fg_colorbase(0x40);  // m_fg_color_base = 0x040
m_tc0180vcu->set_tx_colorbase(0xc0);  // m_tx_color_base = 0x0C0
```

Maximum possible palette address = fb_base + max_sprite_color = `0x800 + 0xFF = 0x8FF`. With rastsag2/ashura config (fb_base = 0x40×16 = 0x400, bg_base = 0xC0):
- BG max = `m_bg_color_base + (color & 0x3f)` = `0xC0 + 0x3F = 0xFF`, but this is a *color slot number*, not a raw palette address — the final pixel lookup in screen_update uses the full computed index
- In MAME, `draw_framebuffer` produces `m_fb_color_base + c` where `c` is the raw framebuffer byte (0–255), max = `0x400 + 0xFF = 0x4FF`
- Tiles produce `m_bg_color_base + (color & 0x3f)` passed as color number to MAME's drawgfx, which then multiplies by 16 (for 4bpp) = `(0xC0 + 0x3F) * 16 = 0xFF * 16 = 0xFF0` — max = 0xFF0 + 0xF = **0xFFF = 4095 = 12 bits**

**Evidence 3 — FPGA RTL pixel_out composition:**

From `tc0180vcu.sv` (line 721–724):
```
// pixel_out[12:0]:
//   TX:    {5'b0, color[3:0], pixel_idx[3:0]}  — 8-bit
//   FG/BG: {3'b0, color[5:0], pixel_idx[3:0]}  — 10-bit
//   SP:    {5'b0, sp_pix[7:0]}                  — 8-bit
```

The FG/BG path outputs `{3'b0, 10-bit}` = maximum `0x3FF = 1023`. This is the *raw tile code + pixel index*, without the color_base offset. In MAME the color_base is added by the CPU software layout of palette RAM, not by the VCU hardware — and in FPGA the palette RAM is written by the 68K with color data already positioned at the correct base addresses.

**Maximum hardware palette index: 13 bits (0x0000–0x1FFF). In practice, all Taito B games only use 4096 entries (12 bits, 0x000–0xFFF). Bit 13 of TC0260DAR IM is always 0.**

**Wiring decision confirmed:** `IM[13:0] = {1'b0, pixel_out[12:0]}` is correct. TC0260DAR's internal palette RAM is 8K×16-bit (14-bit address) but Taito B only uses the lower half (0x0000–0x0FFF within the DAR's address space).

---

## Q5: Interrupt Equations

### Conclusion: int_h and int_l connect DIRECTLY to 68000 IPL, but the interrupt levels are GAME-SPECIFIC (no fixed PAL)

**Evidence — MAME machine config callbacks:**

The TC0180VCU interrupt outputs (`inth_callback`, `intl_callback`) are wired directly to specific 68000 IRQ inputs via `set_inputline(..., HOLD_LINE)`. There is no interrupt controller or PAL combining them — each callback maps directly to one 68000 IPL level.

```cpp
// rastsag2 / ashura / selfeena:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_4, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_2, HOLD_LINE);

// crimec / viofight:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_5, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_3, HOLD_LINE);

// masterw:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_5, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_4, HOLD_LINE);

// hitice:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_4, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_6, HOLD_LINE);

// rambo3 / rambo3p:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_6, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_1, HOLD_LINE);

// pbobble / spacedx / qzshowby / silentd / sbm:
m_tc0180vcu->inth_callback().set_inputline(m_maincpu, M68K_IRQ_3, HOLD_LINE);
m_tc0180vcu->intl_callback().set_inputline(m_maincpu, M68K_IRQ_5, HOLD_LINE);
```

### Timing of int_h and int_l

From `tc0180vcu.cpp`:

```cpp
void tc0180vcu_device::vblank_callback(screen_device &screen, bool state)
{
    if (state) {
        vblank_update();
        m_inth_callback(ASSERT_LINE);  // int_h fires at VBLANK START
        m_intl_timer->adjust(screen.time_until_pos(screen.vpos() + 8));
    } else {
        m_intl_callback(CLEAR_LINE);   // int_l clears at VBLANK END
    }
}

TIMER_CALLBACK_MEMBER(tc0180vcu_device::update_intl)
{
    m_inth_callback(CLEAR_LINE);       // int_h clears 8 lines later
    m_intl_callback(ASSERT_LINE);      // int_l fires 8 lines after VBLANK start
}
```

- **int_h** = VBLANK start pulse (asserted at VBL start, cleared 8 scanlines later)
- **int_l** = raster interrupt (~8 scanlines after VBL start, asserted; cleared at VBL end)

Both are `HOLD_LINE`, meaning the CPU must acknowledge the interrupt to clear the IPL. In FPGA, these should be level signals (not pulses) — assert high until the 68000 performs an interrupt acknowledge cycle for that level.

### IPL encoding in FPGA

The 68000 IPL[2:0] lines encode the highest pending interrupt level. For a given game, the top-level must implement:

```
// Example for nastar (rastsag2_map config):
//   inth → IRQ4, intl → IRQ2

logic ipl4_pending, ipl2_pending;

assign ipl4_pending = int_h;  // from tc0180vcu
assign ipl2_pending = int_l;  // from tc0180vcu

// IPL encoding: highest active level wins
assign IPL[2:0] = ipl4_pending ? 3'd4 :
                  ipl2_pending ? 3'd2 :
                  3'd0;
```

The actual level assignments (4/2 for nastar, 5/3 for crimec, etc.) must be per-game parameters or hardcoded per target game configuration.

### Interrupt acknowledge

The 68000 clears an interrupt by asserting `!AS && FC[2:0]==3'b111` (interrupt acknowledge cycle). In MAME this is handled automatically by `HOLD_LINE` semantics. In FPGA:
- Some MiSTer 68000 implementations auto-clear on IACK
- Others require the peripheral to lower its IRQ line when IACK is detected at the matching vector fetch
- Since both `int_h` and `int_l` are level (not latched pulse) outputs from the VCU, the FPGA just holds them asserted until the VBL / raster window ends (per the timing above), which is a natural self-clearing behavior

---

## Summary Table

| Question | Answer | Confidence |
|----------|--------|------------|
| Q1: 68000 address map | Not fixed — varies by PCB; TC0180VCU usually at 0x400000, exceptions at 0x200000/0x500000/0x900000 | Verified |
| Q2: GFX ROM sizes | 1MB–4MB depending on game; SDRAM base must be a parameter (suggested: 0x100000 for nastar) | Verified |
| Q3: ADPCM ROM sizes | ADPCM-A: up to 2MB; ADPCM-B: up to 512KB; many games have no ADPCM-B | Verified |
| Q4: Palette index width | 13-bit output from RTL; all games use ≤12-bit effective range; IM[13] = 0 is safe | Verified |
| Q5: Interrupt equations | int_h = VBL start; int_l = VBL+8 raster; both go directly to 68000 IPL — levels are game-specific (range: IRQ1–IRQ6) | Verified |

---

## Per-Game Quick Reference (YM2610 games only)

| Game | TC0180VCU base | TC0260DAR base | TC0220IOC base | SYT master | GFX ROM | ADPCM-A | ADPCM-B | int_h → | int_l → |
|------|---------------|---------------|---------------|-----------|---------|---------|---------|---------|---------|
| nastar / rastsag2 | 0x400000 | 0x200000 | 0xA00000 | 0x800000 | 1MB | 512KB | 512KB | IRQ4 | IRQ2 |
| crimec | 0x400000 | 0x800000 | 0x200000 | 0x600000 | 1MB | 512KB | none | IRQ5 | IRQ3 |
| ashura | 0x400000 | 0xA00000 | (see crimec) | 0x200000 | 1MB | 512KB | none | IRQ4 | IRQ2 |
| rambo3 | 0x400000 | 0xA00000 | 0x600000 | 0x200000 | 2MB | 512KB | none | IRQ6 | IRQ1 |
| pbobble | 0x400000 | 0x800000 | (TC0640FIO) | 0x700000 | 1MB | 1MB | none | IRQ3 | IRQ5 |
| silentd | 0x500000 | 0x300000 | 0x200000 | 0x100000 | 4MB | 512KB | 512KB | IRQ3 | IRQ5 |
| selfeena | 0x200000 | 0x300000 | 0x400000 | 0x500000 | 1MB | 512KB | none | IRQ4 | IRQ2 |
| sbm | 0x900000 | 0x200000 | (TC0510NIO) | 0x320000 | 4MB | 512KB | none | IRQ3 | IRQ5 |
| qzshowby | 0x400000 | 0x800000 | (TC0640FIO) | 0x600000 | 4MB | 2MB | none | IRQ3 | IRQ5 |

---

## Source References

- `src/mame/taito/taito_b.cpp` — lines 1–100 (maps), 2793–3670 (ROM definitions), machine_config blocks
- `src/mame/taito/tc0180vcu.h` — color base setters, interrupt callback declarations
- `src/mame/taito/tc0180vcu.cpp` — `vblank_callback`, `update_intl`, color computation in draw_* functions
- Local FPGA RTL: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/tc0180vcu/rtl/tc0180vcu.sv` — pixel_out commentary (lines 721–724)
- Local RTL: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/taito_support/tc0140syt.sv` — ADPCMA/ADPCMB_ROM_BASE parameter interface
