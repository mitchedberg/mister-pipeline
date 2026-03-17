# TC0650FDA — Section 2: RTL Implementation Plan

**Source documents:** README.md (architecture overview), section1_registers.md (register map,
blend formula, line RAM interface), taito_support/tc0260dar.sv (reference structure — no
code reuse), tc0630fdp/section3_rtl_plan.md (colmix output interface context)
**Complexity:** Tier-2 (moderate — clean data path, but dual-port BRAM + multiply-accumulate
pipeline require careful timing; no tilemap FSMs, no sprite walk, no ROM arbitration)

---

## 1. Module Interface

### 1.1 Top-Level Port List: `tc0650fda.sv`

```systemverilog
module tc0650fda (
    // -------------------------------------------------------------------------
    // Clock / Reset
    // -------------------------------------------------------------------------
    input  logic        clk,          // System clock (26.686 MHz — same as CPU and FDP)
    input  logic        ce_pixel,     // Pixel clock enable (÷4 = 6.6715 MHz)
    input  logic        rst_n,        // Active-low synchronous reset

    // -------------------------------------------------------------------------
    // CPU Interface — 32-bit write-only (68EC020 bus fragment)
    // Address decoded externally: this port is active for 0x440000–0x447FFF.
    // No read path — MAME has no documented CPU read from palette RAM.
    // -------------------------------------------------------------------------
    input  logic        cpu_cs,       // Chip select (decoded from 0x440000–0x447FFF)
    input  logic        cpu_we,       // Write enable (asserted with cpu_cs for writes)
    input  logic [12:0] cpu_addr,     // Internal palette index 0x0000–0x1FFF (13-bit)
    input  logic [31:0] cpu_din,      // 32-bit longword data from CPU
    input  logic [3:0]  cpu_be,       // Byte enables [3:0] = {D31:D24, D23:D16, D15:D8, D7:D0}
    output logic        cpu_dtack_n,  // Bus acknowledge (held low: palette RAM = zero-wait)

    // -------------------------------------------------------------------------
    // Video Input — from tc0630fdp_colmix, per-pixel, in pixel clock domain
    // -------------------------------------------------------------------------
    input  logic        pixel_valid,  // High during active display pixels only
    input  logic [12:0] src_pal,      // Source palette index (13-bit, 0x0000–0x1FFF)
    input  logic [12:0] dst_pal,      // Destination palette index (background/lower layer)
    input  logic [3:0]  src_blend,    // Source contribution factor (0–8, fixed3: 8 = 1.0)
    input  logic [3:0]  dst_blend,    // Destination contribution factor (0–8)

    // -------------------------------------------------------------------------
    // Mode Control — latched per-scanline from line RAM decode (tc0630fdp_lineram)
    // -------------------------------------------------------------------------
    input  logic        mode_12bit,   // 0 = RGB888 standard; 1 = 12-bit legacy (4 early games)

    // -------------------------------------------------------------------------
    // Video Output — RGB888 DAC
    // -------------------------------------------------------------------------
    output logic [7:0]  video_r,      // Red channel, 8-bit
    output logic [7:0]  video_g,      // Green channel, 8-bit
    output logic [7:0]  video_b       // Blue channel, 8-bit
);
```

**Design decisions:**

- **No separate Line RAM port.** The `pal_add` offset (section1 §3) is pre-computed by
  `tc0630fdp_lineram` and added to palette indices inside `tc0630fdp_tilemap` before being
  emitted as `src_pal`/`dst_pal`. TC0650FDA therefore sees already-adjusted 13-bit indices.
  This matches the logical chip boundary: the FDP produces final palette indices, the FDA
  performs lookup + blend + DAC.

- **`cpu_dtack_n` is permanently low** (zero-wait-state). Palette RAM is on-chip BRAM with
  single-cycle write. F3 hardware writes palette during VBLANK (color loading); no bus-cycle
  contention arbitration is needed beyond what the dual-port BRAM provides.

- **`mode_12bit` is a single-bit input** driven by the tc0630fdp_lineram parser decoding line
  RAM 0x6400 bit 14 (`w`). Although MAME currently uses a static game-type switch, the RTL
  models the documented per-scanline behavior. The tc0630fdp_lineram module exposes this bit
  alongside other per-scanline controls as `ls_palette_12bit`.

- **No `HBLANKn`/`VBLANKn` pass-through.** TC0260DAR propagates these for downstream modules;
  TC0650FDA sits at the end of the video pipeline and drives only RGB output.

- **Blur input omitted.** Horizontal blur (line RAM 0x6400 bit 13) is unemulated in MAME and
  is not implemented in the initial RTL. The port can be added later without interface breakage.

---

## 2. Internal Structure

### 2.1 Palette RAM: 8192 × 24-bit (RGB888)

**Logical size:** 8192 entries × 24 bits = 196,608 bits = ~24KB useful data.

**Physical storage:** The CPU writes 32-bit longwords; only bits [23:0] are meaningful
(bits [31:24] are unused per section1 §2a). The BRAM is sized 8192 × 32-bit to match the
natural write granularity and simplify byte-enable masking, then only the lower 24 bits
are extracted on the read path.

**BRAM configuration — Cyclone V M10K (see §4 for sizing):**

```
Type:         True Dual-Port (TDP) BRAM
Width × Depth: 32-bit × 8192
Port A:       CPU write port — clk domain, write on (cpu_cs & cpu_we), addr = cpu_addr
Port B:       Video read port — ce_pixel domain, read-only, addr = current palette index
Byte enables: Port A byte-enables map directly to cpu_be[3:0]
Read latency: 1 registered clock on Port B (output registered)
```

**Read pipeline consideration:** With registered output (1-cycle latency), the palette
lookup for pixel X is initiated one ce_pixel cycle before the blend MAC stage consumes it.
The blend pipeline is designed around this 1-cycle latency (see §2.2).

**12-bit mode decode:** When `mode_12bit = 1`, the stored 32-bit word uses the packed 12-bit
format (section1 §2b). The decode is applied after BRAM read, in the path between the BRAM
output register and the blend MAC:

```systemverilog
// In standard mode (mode_12bit = 0):
rgb_src = pal_data_b[23:0];   // direct {R[7:0], G[7:0], B[7:0]}

// In 12-bit mode (mode_12bit = 1):
rgb_src = {pal_data_b[15:12], pal_data_b[15:12],   // R: expand 4→8 by repeat
           pal_data_b[11:8],  pal_data_b[11:8],    // G
           pal_data_b[7:4],   pal_data_b[7:4]};    // B
```

The 4→8 expansion by nibble-repeat (`{nib, nib}`) gives a linear 0–255 mapping across
the 16 input levels: 0x0→0x00, 0xF→0xFF, consistent with MAME's `pal4bit()` helper.

### 2.2 Alpha Blend Circuit

**Inputs per pixel (after palette lookup):**

```
src_r[7:0], src_g[7:0], src_b[7:0]   — from BRAM read of src_pal
dst_r[7:0], dst_g[7:0], dst_b[7:0]   — from BRAM read of dst_pal
src_blend[3:0]                         — contribution factor 0–8
dst_blend[3:0]                         — contribution factor 0–8
```

**Formula (section1 §6):**

```
out_R = clamp((src_R * src_blend + dst_R * dst_blend) >> 3, 0, 255)
out_G = clamp((src_G * src_blend + dst_G * dst_blend) >> 3, 0, 255)
out_B = clamp((src_B * src_blend + dst_B * dst_blend) >> 3, 0, 255)
```

**Bit-width analysis:**

- Each multiply: 8-bit × 4-bit → 12-bit result (max 255 × 8 = 2040, fits in 11 bits; use
  12 bits for safety).
- Sum of two products: 12-bit + 12-bit → 13-bit (max 2040 + 2040 = 4080, fits in 12 bits;
  use 13 bits with MSB as overflow indicator).
- After `>> 3`: 13-bit → 10-bit (max 4080 >> 3 = 510, fits in 9 bits).
- Saturate to 8-bit: if result[8] set or result > 255, output = 0xFF; else output = result[7:0].

**RTL pipeline (2 registered stages, advances with ce_pixel):**

```
Stage 0 (combinational):
  Initiate BRAM reads for src_pal and dst_pal.
  (Both reads issued in the same ce_pixel cycle — requires 2 read ports or 2 cycles.)

Stage 1 (registered at ce_pixel):
  BRAM outputs registered. Apply 12-bit mode decode.
  src_rgb_r, dst_rgb_r valid.

Stage 2 (registered at ce_pixel):
  Multiply: src_R_mul = src_rgb_r[23:16] * src_blend_r   (12-bit)
            dst_R_mul = dst_rgb_r[23:16] * dst_blend_r   (12-bit)
            (repeat for G and B channels)
  src_blend_r, dst_blend_r = blend values pipelined from stage 0.

Stage 3 (registered at ce_pixel):
  Accumulate and saturate:
    sum_R = src_R_mul + dst_R_mul                        (13-bit)
    out_R = sum_R[12:3] > 8'd255 ? 8'hFF : sum_R[10:3]  (saturating shift-right-3)
    (repeat for G and B)
  video_r, video_g, video_b driven from this stage.
```

**Two BRAM reads per pixel:** The dual palette lookup (src and dst) within a single
ce_pixel cycle requires either:

- Option A: A single-port BRAM pipelined over 2 ce_pixel cycles. Issue src_pal read on
  even cycles, dst_pal read on odd cycles. Both results available one cycle later. The
  pixel clock (6.67 MHz) runs at ÷4 of system clock (26.69 MHz), so 4 system clocks exist
  per pixel — sufficient to double-pump a single-port BRAM.

- Option B: Two separate BRAM blocks, each holding the full 8192-entry palette (mirrored).
  Port A writes to both in parallel on CPU write. Port B of block 0 reads src_pal; Port B
  of block 1 reads dst_pal. Both available in the same cycle.

**Option B is recommended.** It avoids the double-pump complexity and the doubled BRAM cost
(24 M10K total vs 12) is acceptable given the Cyclone V DE10-Nano has 397 M10K and the
TC0630FDP already consumes ~259. At the system level, the F3 core will be BRAM-budget-
constrained but not beyond device capacity. See §4 for detailed sizing.

**Opaque mode fast path:** When `src_blend == 8` and `dst_blend == 0` (standard opaque,
no transparency), the multiply-accumulate collapses to `out_channel = src_channel`. A
combinational check can bypass the MAC pipeline and write `src_rgb` directly through to
output, saving one stage of latency for the common case. This is an optimization, not a
correctness requirement — implement only after the full path verifies correctly.

### 2.3 Palette-Add: Design Decision — Not in TC0650FDA

As noted in §1.1, the per-scanline `pal_add` offset (section1 §3) is applied inside the
TC0630FDP tilemap engine, not in TC0650FDA. Rationale:

1. **Logical boundary:** TC0630FDP owns all layer compositing logic including address
   formation for palette indices. TC0650FDA only performs lookup + blend + DAC.
2. **MAME implementation:** `playfield_inf::palette_adjust()` is called inside `mix_line()`,
   which is part of the F3 video driver's compositing loop — conceptually inside the FDP.
3. **Signal count reduction:** Passing a separate `pal_add[4][7:0]` array to TC0650FDA
   would require the FDA to know which layer each pixel belongs to, which is compositor-
   internal state that properly belongs in the FDP.
4. **13-bit index sufficiency:** With `pal_add` applied upstream, `src_pal`/`dst_pal` are
   already final 13-bit indices. TC0650FDA treats them as opaque addresses.

This is the one design decision that departs from a strict "chip as MAME function boundary"
interpretation. It is correct because the documented chip boundary (FDP outputs indices,
FDA performs lookup) is consistent with applying `pal_add` inside the FDP.

---

## 3. Step-by-Step Build Plan

Four steps, each with Verilator simulation tests before proceeding.

---

### Step 1 — Skeleton + Palette RAM R/W + Basic Index→RGB Lookup

**New capability:** CPU can write palette entries via 32-bit bus. A single 13-bit palette
index input (`src_pal`) produces RGB888 output by direct BRAM lookup. No blending, no dual
lookup. Opaque output for every pixel.

**Modules added:** `tc0650fda.sv` (complete skeleton with palette BRAM and single-index
lookup path). The `dst_pal`/blend inputs are present on the port list but ignored (tied off
to zero internally).

**BRAM instantiation:**
```systemverilog
// Palette RAM — 8192 × 32-bit, true dual-port
// In Quartus: altsyncram with mixed-width (Port A: 32b write, Port B: 32b read)
logic [31:0] pal_ram [0:8191];  // synthesis maps to BRAM

// Port A: CPU write (system clock, no pixel clock enable gating)
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        if (cpu_be[2]) pal_ram[cpu_addr][23:16] <= cpu_din[23:16];  // R
        if (cpu_be[1]) pal_ram[cpu_addr][15:8]  <= cpu_din[15:8];   // G
        if (cpu_be[0]) pal_ram[cpu_addr][7:0]   <= cpu_din[7:0];    // B
        // cpu_be[3] covers bits [31:24] = unused, silently accepted
    end
end

// Port B: Video read (pixel clock enable domain, registered output)
logic [31:0] pal_rd_data;
always_ff @(posedge clk) begin
    if (ce_pixel) pal_rd_data <= pal_ram[src_pal];
end
```

**Output (after BRAM latency and 12-bit decode):**
```systemverilog
always_ff @(posedge clk) begin
    if (ce_pixel && pixel_valid) begin
        if (!mode_12bit) begin
            video_r <= pal_rd_data[23:16];
            video_g <= pal_rd_data[15:8];
            video_b <= pal_rd_data[7:0];
        end else begin
            video_r <= {pal_rd_data[15:12], pal_rd_data[15:12]};
            video_g <= {pal_rd_data[11:8],  pal_rd_data[11:8]};
            video_b <= {pal_rd_data[7:4],   pal_rd_data[7:4]};
        end
    end
end
```

**Test cases:**
1. Write palette entry 0 = 0x00FF0000 (R=0xFF, G=0x00, B=0x00). Drive `src_pal` = 0.
   Assert `video_r` = 0xFF, `video_g` = 0x00, `video_b` = 0x00 after BRAM latency.
2. Write entry 0x100 = 0x000080FF. Drive `src_pal` = 0x100.
   Assert `video_b` = 0xFF, `video_r` = 0x00, `video_g` = 0x80.
3. Byte-enable test: write entry 5 with `cpu_be` = 4'b0100 (R byte only). Assert that G
   and B remain unchanged (require a prior full write to set initial values).
4. 12-bit mode: write entry 3 = 0x0000_A5C0 (bits[15:12]=A, [11:8]=5, [7:4]=C).
   Set `mode_12bit` = 1. Assert R=0xAA, G=0x55, B=0xCC.
5. Palette index sweep: write all 8192 entries with index-as-color
   (`pal_ram[i] = {8'h00, i[7:0], i[7:0], i[7:0]}`). Drive all 8192 src_pal values
   sequentially. Verify each output matches.
6. `pixel_valid` gate: when `pixel_valid` = 0, video_r/g/b hold their last value
   (BRAM output does not update — or update is masked at the output register).
7. CPU write during active pixel (`cpu_we` = 1 while `pixel_valid` = 1): write to a
   different address than the one currently being read. Verify no corruption on output.
   (This tests that TDP BRAM ports are independent.)

**Expected test count:** 40–60.
**New BRAM:** 1 M10K (single BRAM, 8192×32-bit → see §4; or 2 M10K if mirrored for step 2).

---

### Step 2 — Dual-Port Lookup + Alpha Blend MAC

**New capability:** Both `src_pal` and `dst_pal` are looked up. The 3-stage MAC pipeline
computes the final blended RGB output. All four blend modes from section1 §5 produce
correct output.

**Structural change:** Add the second palette BRAM (mirrored copy for `dst_pal` lookup).
Add the 3-stage MAC pipeline between BRAM outputs and video output registers.

**MAC pipeline (SystemVerilog sketch):**

```systemverilog
// Pipeline stage registers
logic [23:0] src_rgb_s1, dst_rgb_s1;
logic [3:0]  src_blend_s1, dst_blend_s1;
logic        valid_s1, valid_s2, valid_s3;

// 12-bit multiply products
logic [11:0] mul_r_src_s2, mul_g_src_s2, mul_b_src_s2;
logic [11:0] mul_r_dst_s2, mul_g_dst_s2, mul_b_dst_s2;

// Saturated outputs
logic [8:0]  sum_r_s3, sum_g_s3, sum_b_s3;  // 9-bit: allows overflow detection

always_ff @(posedge clk) begin
    if (ce_pixel) begin
        // Stage 1: BRAM outputs registered, apply mode decode
        src_rgb_s1   <= mode_12bit ? expand_12bit(pal_src_rd) : pal_src_rd[23:0];
        dst_rgb_s1   <= mode_12bit ? expand_12bit(pal_dst_rd) : pal_dst_rd[23:0];
        src_blend_s1 <= src_blend;
        dst_blend_s1 <= dst_blend;
        valid_s1     <= pixel_valid;

        // Stage 2: multiply (8b × 4b = 12b, 6 multipliers total)
        mul_r_src_s2 <= src_rgb_s1[23:16] * src_blend_s1;
        mul_g_src_s2 <= src_rgb_s1[15:8]  * src_blend_s1;
        mul_b_src_s2 <= src_rgb_s1[7:0]   * src_blend_s1;
        mul_r_dst_s2 <= dst_rgb_s1[23:16] * dst_blend_s1;
        mul_g_dst_s2 <= dst_rgb_s1[15:8]  * dst_blend_s1;
        mul_b_dst_s2 <= dst_rgb_s1[7:0]   * dst_blend_s1;
        valid_s2     <= valid_s1;

        // Stage 3: accumulate and saturate
        sum_r_s3 <= (mul_r_src_s2 + mul_r_dst_s2) >> 3;
        sum_g_s3 <= (mul_g_src_s2 + mul_g_dst_s2) >> 3;
        sum_b_s3 <= (mul_b_src_s2 + mul_b_dst_s2) >> 3;
        valid_s3 <= valid_s2;

        // Saturation (9-bit → 8-bit)
        video_r <= sum_r_s3[8] ? 8'hFF : sum_r_s3[7:0];
        video_g <= sum_g_s3[8] ? 8'hFF : sum_g_s3[7:0];
        video_b <= sum_b_s3[8] ? 8'hFF : sum_b_s3[7:0];
    end
end
```

**Note on multiplier resources:** 6 multipliers of 8×4 = 32-bit inputs. Cyclone V DSP
blocks (18×18 multipliers) can each accommodate two 8×4 multiplications in one block via
pre-adder or cascading. In practice, Quartus infers these as DSP18s automatically from the
`*` operator. At 6.67 MHz pixel clock with a 3-stage pipeline, timing closure is trivial.

**Test cases:**
1. Opaque (src_blend=8, dst_blend=0): out_R = src_R exactly. Verify for R=0x80, G=0x40,
   B=0xFF with any dst_pal value.
2. Opaque (src_blend=8, dst_blend=8): out_R = clamp(src_R + dst_R). Test with src_R=0x80,
   dst_R=0xA0: expect 0xFF (overflow, saturates). Test with src_R=0x40, dst_R=0x20: expect
   0x60 (no overflow, exact sum).
3. Half-blend (src_blend=4, dst_blend=4): out_R = (src_R*4 + dst_R*4) >> 3 = (src_R +
   dst_R) / 2. Test src_R=0x80, dst_R=0x40: expect (0x80*4 + 0x40*4) >> 3 = (512+256)/8
   = 96 = 0x60.
4. Transparent dst (src_blend=8, dst_blend=0): output = src. Sweep all 256 src values,
   verify output matches src exactly.
5. Reverse blend: src_blend=2, dst_blend=6 — verify formula holds asymmetrically.
6. Full saturation: src_blend=8, dst_blend=8, both channels=0xFF: expect out=0xFF.
7. Zero blend: src_blend=0, dst_blend=0: expect out_R=0x00. (Black output — valid for
   invisible layers.)
8. Pipeline latency: after asserting `pixel_valid` with valid inputs, verify output appears
   exactly 3 ce_pixel cycles later (stages 1, 2, 3).
9. Background palette entry (section1 §7): initial dst_pal set to `bg_palette` index (any
   value written to line RAM 0x6600), dst_blend=8, src_blend varies. Verify background
   color appears in fully-transparent pixels (src_blend=0, dst_blend=8).

**Expected test count:** 60–80.
**New BRAM:** +1 M10K (second mirrored palette BRAM for dst_pal lookup). Total so far: 2 M10K
(or 24 M10K per §4 analysis — see that section for the exact calculation).

---

### Step 3 — Integration with TC0630FDP Colmix

**New capability:** TC0650FDA is wired to the real colmix output interface from
`tc0630fdp_colmix.sv`. Palette indices flow from the compositor through the blend pipeline
to RGB888 output. End-to-end frame rendering with correct colors.

**Interface connection (see §5 for full signal list):**

The tc0630fdp_colmix module's current (section3 RTL plan) output is:
```
pal_rd_addr[14:0]   // palette read address (colmix → FDA)
rgb_out[23:0]       // the current plan has colmix doing its own palette lookup
pixel_valid_out
```

In the revised interface (section3 RTL plan will need updating), colmix instead outputs the
dual-index blend interface:
```
src_pal[12:0]       // from colmix priority resolution
dst_pal[12:0]       // background or lower-priority palette index
src_blend[3:0]      // from ls_alpha_a / ls_alpha_b, selected per pixel
dst_blend[3:0]
pixel_valid
```

This step validates the colmix→FDA interface for the first time. Use a simplified colmix
stub (single layer, no clip, no blend selection) with one PF layer feeding through.

**Test cases:**
1. Stub colmix drives `src_pal` = fixed value, `src_blend` = 8, `dst_blend` = 0. Write
   known color to that palette entry. Verify video_r/g/b = expected color, synchronized to
   pixel_valid.
2. Drive colmix with tile data from a checkerboard PF. Write 2 palette entries (tile 0 =
   red, tile 1 = blue). Verify output frame has alternating red/blue 16×16 blocks.
3. Blend enabled: drive src_pal=0 and dst_pal=1 (two entries with known colors), blend
   50/50 (src_blend=4, dst_blend=4). Verify output is the averaged color.
4. `pixel_valid` = 0 during HBLANK and VBLANK: verify video_r/g/b outputs do not produce
   valid pixel data (they may hold last value — that is acceptable; the display engine reads
   them only during active display).
5. Palette write during VBLANK: CPU writes 4 entries during vblank_n=0. Next frame, verify
   new colors appear. (Validates that CPU port writes complete without corruption during
   quiescent video period.)

**Expected test count:** 30–50 (incremental).
**New BRAM:** None (only interface wiring).

---

### Step 4 — Integration Tests: Frame Regression

**New capability:** Full-system frame comparison against MAME output. TC0650FDA is validated
as part of the complete TC0630FDP + TC0650FDA pipeline.

**Methodology:** Same as TC0630FDP Gate 4 regression. A Python model (`fda_model.py` or
integrated into the existing `fdp_model.py`) mirrors the blend formula exactly and generates
expected output frames. The Verilator simulation of the combined fdp+fda RTL is compared
pixel-by-pixel.

**Test progression:**

1. **Opaque frame (RayForce boot):** All layers opaque (src_blend=8, dst_blend=0). This
   tests palette correctness without blend math. Expected pass rate: >99% (palette-only
   errors are gross mismatches).

2. **Alpha blend frame (Darius Gaiden weapon glow):** One layer with blend enabled over an
   opaque background. This is the primary test for the MAC pipeline. Expected pass rate:
   >95% on first attempt (formula is simple; main risk is pipeline latency alignment).

3. **Reverse blend frame (any game with reverse blend mode):** `src_blend` and `dst_blend`
   values derived from the `b/B` pair instead of `a/A`. Verifies the coefficient selection
   logic in colmix (this is colmix logic, not FDA logic — but validated end-to-end here).

4. **Legacy 12-bit palette (RingRage or SpaceInvaders DX):** These 4 early games use the
   12-bit entry format. Write palette data as packed 12-bit. Verify output colors match
   expanded 8-bit values. Expected pass rate: 100% (format is simple and well-documented).

5. **Full 5-frame regression (RayForce + Elevator Action Returns):** Complete integration
   test including all layers, all blend modes, all clip planes. This replicates the Gate 4
   methodology from section2_behavior.md §7.2. Target: ≥95% pixel-perfect on the FDA
   portion (any remaining differences are colmix/FDP issues, not FDA issues).

**Gate criteria:** FDA is considered complete when the 5-frame regression on RayForce +
Elevator Action Returns shows no pixel differences attributable to palette lookup or blend
math. Differences from clip plane or priority bugs are FDP issues tracked separately.

---

## 4. BRAM Sizing on Cyclone V (M10K)

### Calculation

Each Cyclone V M10K block = **10,240 bits** usable (marketed as "10Kbit" blocks; the full
capacity is 10,240 bits = 1,280 bytes, usable in various width × depth configurations).

**Single palette BRAM (8192 × 32-bit):**

```
Required: 8192 entries × 32 bits/entry = 262,144 bits
Per M10K: 10,240 bits
Blocks needed: ceil(262,144 / 10,240) = ceil(25.6) = 26 M10K blocks
```

However, Cyclone V M10K blocks have fixed aspect ratio constraints. The widest supported
configuration for a single M10K is 16-bit × 640 (10,240 bits). To achieve 32-bit wide
access at 8192 depth requires:

```
One 32-bit × 8192 configuration:
  - Two M10K blocks in parallel (each 16-bit wide × 8192 deep)
  - Each 16-bit × 8192: 16 × 8192 = 131,072 bits = ceil(131,072 / 10,240) = 13 M10K

  Total for 32-bit × 8192: 2 × 13 = 26 M10K blocks
```

**Mirrored BRAM for dual lookup (Option B from §2.2):**

Two copies of the 26-M10K BRAM, one for src_pal reads and one for dst_pal reads:
```
26 M10K × 2 = 52 M10K total for TC0650FDA palette storage
```

**Summary table:**

| Component                          | Bits         | M10K blocks |
|------------------------------------|--------------|-------------|
| Palette BRAM copy A (src_pal port) | 262,144      | 26          |
| Palette BRAM copy B (dst_pal port) | 262,144      | 26          |
| **TC0650FDA total**                | **524,288**  | **52**      |

### Budget Context

| Core component               | M10K blocks |
|------------------------------|-------------|
| TC0630FDP all RAMs           | ~259        |
| TC0650FDA palette BRAM       | 52          |
| **F3 core subtotal**         | **~311**    |
| Cyclone V DE10-Nano (5CSEBA6)| **397**     |
| **Headroom remaining**       | **~86**     |

86 M10K remaining for 68EC020 CPU register file (~4), ES5506 audio buffers (~20), misc
glue logic. The budget is tight but feasible on the DE10-Nano. If BRAM pressure is too high,
Option A (double-pumping a single BRAM at system clock rate) can reduce TC0650FDA to 26 M10K
at the cost of implementation complexity. The dual-BRAM design is recommended for clarity.

### Alternative: 24-bit wide BRAM (optimization)

If bits [31:24] of each palette entry are never read on the video port, the BRAM can be
sized 24-bit × 8192 instead of 32-bit × 8192:

```
24 × 8192 = 196,608 bits
Three M10K blocks at 8-bit × 8192 per block: ceil(196,608 / 10,240) = 20 M10K per copy
Total with dual copies: 40 M10K
```

This saves 12 M10K. However, CPU writes are 32-bit wide — byte-enable masking of the upper
byte must still be supported. The 32-bit write/24-bit read mixed-width BRAM is achievable
in Quartus `altsyncram` with mixed-mode configuration. This optimization is recommended
for the final implementation but is deferred until after correctness is validated.

---

## 5. Interface to TC0630FDP

### 5.1 Current Colmix Output (Section 3 RTL Plan)

The current `tc0630fdp_colmix.sv` port list (from section3_rtl_plan.md §1.7) outputs:

```
pal_rd_addr[14:0]   // read address into shared palette RAM
rgb_out[23:0]       // final RGB after palette lookup (colmix currently owns the lookup)
pixel_valid_out
```

This design has colmix performing the palette lookup internally with a `pal_data[15:0]`
input. This was appropriate for TC0260DAR-style palette (16-bit), but for TC0650FDA with
full alpha blending, it places the MAC pipeline complexity inside colmix, which conflicts
with the chip boundary.

### 5.2 Revised Interface for TC0650FDA Integration

`tc0630fdp_colmix.sv` must be modified to output palette indices and blend coefficients
instead of performing the RGB lookup itself. The revised colmix output port additions:

```systemverilog
// Replace rgb_out[23:0] + pal_rd_addr[14:0] with:
output logic [12:0] src_pal,       // winning pixel palette index (13-bit, post-pal_add)
output logic [12:0] dst_pal,       // background/lower-priority palette index
output logic [3:0]  src_blend,     // source contribution 0–8 (from ls_alpha_a/b selection)
output logic [3:0]  dst_blend,     // destination contribution 0–8
output logic        pixel_valid    // rename of pixel_valid_out
```

The `pal_data` input and `pal_rd_addr` output in the current colmix port list are removed.
RGB output is now solely the responsibility of TC0650FDA.

### 5.3 Signals TC0630FDP Colmix Must Expose

For each pixel during active display, colmix must resolve and output:

**1. `src_pal[12:0]` — Winning layer palette index**

This is the palette index of the highest-priority non-transparent pixel that passed all
clip tests. It includes `pal_add` already applied (done in `tc0630fdp_tilemap.sv` before
the pixel enters the line buffer). The full 13-bit range (0x0000–0x1FFF) must be preserved.

**2. `dst_pal[12:0]` — Destination palette index**

The "background" palette index against which alpha blending is applied. This is:
- For an opaque top pixel: the `bg_palette` from line RAM 0x6600 (default background).
- For a blended pixel: the palette index of the layer that was the previous committed
  pixel before the current layer was composited in.
- The dual-nibble `pri_buf` in colmix (section2_behavior §5.2) tracks when a lower-
  priority layer is the blend destination — colmix must retain that layer's palette index
  in a per-pixel `dst_pal_buf[0:319]` alongside `pri_buf`.

**3. `src_blend[3:0]` and `dst_blend[3:0]` — Blend coefficients**

Resolved per pixel from `ls_alpha_a` / `ls_alpha_b` based on blend mode and blend_select:

```
// Coefficient selection inside colmix (replicated here for clarity):
//   ls_alpha_a = {A_src[3:0], A_dst[3:0]}  from line RAM 0x6200
//   ls_alpha_b = {B_src[3:0], B_dst[3:0]}
//   blend_sel (per tile for PF, per line for sprites) selects a/A vs b/B pair
//   blend_mode (2-bit) selects normal vs reverse

A_src = ls_alpha_a[7:4];   A_dst = ls_alpha_a[3:0];
B_src = ls_alpha_b[7:4];   B_dst = ls_alpha_b[3:0];

// For normal blend mode (01) with blend_sel=0: use A pair
// For normal blend mode (01) with blend_sel=1: use B pair
// For reverse blend mode (10): swap src and dst coefficients
// For opaque mode (00/11): use A or B pair (no swap)
```

Colmix must apply this selection and output the final integer coefficients 0–8 to TC0650FDA,
not the raw ABBA nibbles. The min(8, 15-N) clamping (section1 §5) is also done in colmix.

**4. `pixel_valid`**

Asserted during active display only. Derived from `hblank_n & vblank_n` after the colmix
pipeline delay is accounted for.

### 5.4 Timing Alignment

TC0650FDA adds 3 pipeline stages (1 BRAM + 2 MAC) after receiving `src_pal` from colmix.
The display system must account for this 3-cycle latency (at ce_pixel rate = 3 pixel-clock
cycles, which is 12 system clock cycles at 4:1 ratio). The video output appears 3 pixels
late relative to the colmix output.

Standard practice in FPGA display pipelines: all display control signals (HSYNC, VSYNC,
DE/pixel_valid) are delayed to match. A 3-stage shift register on `pixel_valid` provides
the aligned enable for the downstream display interface. The HDMI encoder or VGA output
stage applies this aligned `pixel_valid` to gate its own H/V sync generation.

**No synchronization issues exist** between CPU write port (system clock) and video read
port (ce_pixel, a gated version of the same system clock). Both operate in the same clock
domain; the pixel clock enable simply gates the read pipeline.

### 5.5 Summary: Signal Flow Diagram

```
tc0630fdp_tilemap (×4)
  └─ layer_pixel[19:0]  {prio, blend, palette+pen}
       ↓
tc0630fdp_colmix
  ├─ [per-pixel priority resolve + clip + blend mode decode]
  ├─ src_pal[12:0]   ────────────────────────────────────┐
  ├─ dst_pal[12:0]   ──────────────────────────────────┐ │
  ├─ src_blend[3:0]  ────────────────────────────────┐ │ │
  ├─ dst_blend[3:0]  ──────────────────────────────┐ │ │ │
  └─ pixel_valid     ────────────────────────────┐ │ │ │ │
                                                 ↓ ↓ ↓ ↓ ↓
                                           tc0650fda
                                           ├─ BRAM A: pal_ram[src_pal] → src_rgb
                                           ├─ BRAM B: pal_ram[dst_pal] → dst_rgb
                                           ├─ MAC: out = (src*src_blend + dst*dst_blend)>>3
                                           ├─ Saturate to 8-bit
                                           └─ video_r[7:0], video_g[7:0], video_b[7:0]
                                                          ↓
                                                  HDMI encoder / VGA output
```

---

## 6. Key Design Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| pal_add location | TC0630FDP tilemap, not TC0650FDA | Matches chip boundary; FDP owns address formation |
| Dual lookup method | Two mirrored BRAMs (Option B) | Simpler than double-pumping; BRAM budget is adequate |
| BRAM width | 32-bit × 8192 per copy | Matches 32-bit CPU write bus; simplifies byte enables |
| MAC pipeline depth | 3 registered stages | Timing closure at 26.686 MHz is trivial; clean data path |
| Saturating adder | 9-bit sum, clamp on bit[8] | Correct for max sum 4080>>3=510; no lookup table needed |
| 12-bit legacy mode | Per-scanline mode_12bit input | Matches documented hardware; driven by lineram parser |
| Horizontal blur | Not implemented | Unemulated in MAME; no test vectors available |
| CPU read path | Not implemented (write-only) | No MAME evidence of CPU reads; saves read mux logic |
| DTACK | Permanent zero-wait | BRAM write is single-cycle; no conflict with display reads |

---

## References

- `chips/tc0650fda/README.md` — chip overview, MAME source mapping, comparison with TC0260DAR
- `chips/tc0650fda/section1_registers.md` — register map, blend formula, line RAM interface
- `chips/taito_support/tc0260dar.sv` — structural reference only; no code reuse
- `chips/tc0630fdp/section3_rtl_plan.md` — colmix module ports (§1.7), memory budget (§6.1)
- `chips/tc0630fdp/section2_behavior.md` — blend formula context (§5.3), colmix role (§5.2)
- MAME `src/mame/taito/taito_f3_v.cpp` — `palette_24bit_w`, `render_line`, `mix_line`
- MAME `src/mame/taito/taito_f3.h` — `mix_pix` struct, `playfield_inf::pal_add`
- Intel Cyclone V Device Handbook — M10K block specs (10,240 bits, 16-bit max width per block)
