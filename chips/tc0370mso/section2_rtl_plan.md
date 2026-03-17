# TC0370MSO + TC0300FLA — Section 2: RTL Build Plan

**Source documents:** section1_registers.md (sprite RAM format, GFX decode, algorithm),
MAME `taito_z_v.cpp` (bshark_draw_sprites_16x8, sci_draw_sprites_16x8),
TC0150ROD section2 (SDRAM arbiter pattern reference)
**Complexity:** Tier-3 (SDRAM ROM access for spritemap + GFX, per-tile zoom rendering,
line buffer, priority arbitration — more complex than TC0150ROD but simpler than TC0480SCP)
**Comparison:** TC0200OBJ (Taito F2) is architecturally similar; no existing MiSTer
implementation for the TC0370MSO variant.

---

## 1. Complexity Assessment

### What TC0370MSO does

- Scans up to 2048 sprite RAM entries each VBlank (skips entries with tilenum=0)
- For each active sprite: reads 32 chunk codes from spritemap ROM (SDRAM)
- For each non-null chunk: fetches one 16×8 tile from OBJ GFX ROM (SDRAM)
- Applies zoom (6-bit per axis), flip, and color to each 16×8 tile
- Writes rendered pixels to line buffers (one per active scanline)
- At active display time: reads line buffer and outputs palette-indexed pixel with priority

### What it does NOT do

- No rotation or per-scanline rowscroll (unlike TC0480SCP)
- No tilemap (pure sprite only)
- No palette RAM (palette lookup is external, done by the final mixer)
- No CPU-visible registers beyond sprite RAM itself

### Complexity drivers

1. **Two SDRAM regions**: spritemap ROM (512KB) + OBJ GFX ROM (4MB) — both in SDRAM,
   both require request/acknowledge arbitration. This is the dominant timing challenge.
2. **Per-sprite zoom calculation**: 32 chunks per sprite with integer-divided screen
   positions. Requires a divide-by-4 and divide-by-8 per chunk.
3. **Line buffer management**: sprites span multiple scanlines; the renderer must write
   to multiple lines per sprite during VBlank.
4. **Back-to-front scan order**: first sprite drawn into line buffer has lowest priority;
   later sprites overwrite earlier ones.

### Estimated RTL size: ~600–800 lines of SystemVerilog

This is Tier-3: between TC0150ROD (~350 lines, Tier-2) and TC0480SCP (~1200 lines, Tier-4).
The main bulk is the pixel-level zoom renderer and the SDRAM fetch state machine.

---

## 2. Module Interface

```systemverilog
module tc0370mso (
    input  logic        clk,          // system clock (48 MHz typical)
    input  logic        rst_n,

    // Sprite RAM (CPU A bus — chip select decoded externally)
    // CPU A writes during active frame; scanner reads during VBlank
    input  logic        spr_cs,       // sprite RAM chip select (active high)
    input  logic        spr_we,       // 1=write, 0=read
    input  logic [13:1] spr_addr,     // word address [13:1] (14-bit byte addr / 2)
                                      // covers 0xC00000–0xC03FFF → 0x2000 words
    input  logic [15:0] spr_din,
    output logic [15:0] spr_dout,
    input  logic  [1:0] spr_be,       // byte enables (UDS, LDS)
    output logic        spr_dtack_n,

    // Spritemap ROM (SDRAM port A — 512KB STY ROM)
    output logic [17:0] stym_addr,    // word address into spritemap region
    input  logic [15:0] stym_data,
    output logic        stym_req,     // toggle-req
    input  logic        stym_ack,     // toggle-ack

    // OBJ GFX ROM (SDRAM port B — 4MB sprite GFX ROM)
    output logic [22:0] obj_addr,     // byte address into OBJ region (4MB = 22-bit)
    input  logic [63:0] obj_data,     // 64-bit fetch (one full 16x8 tile row)
    output logic        obj_req,
    input  logic        obj_ack,

    // Video timing
    input  logic        vblank,       // active during vertical blanking (~2ms)
    input  logic        hblank,       // active during horizontal blanking
    input  logic  [8:0] hpos,         // current horizontal pixel (0..319 active)
    input  logic  [7:0] vpos,         // current scanline (0..255)

    // Rendering parameters (game-specific, tied at instantiation)
    input  logic signed [3:0] y_offs, // scanline shift (7 for dblaxle/racingb)

    // Double-buffer frame select (racingb only; tie to 0 for dblaxle)
    input  logic        frame_sel,    // 0 or 1 — selects which 0x800-word half of spr RAM

    // Pixel output (to priority mixer, one pixel per clock during active display)
    output logic [11:0] pix_out,      // palette index (color_bank*16 + pixel_value)
    output logic        pix_valid,    // 1 when pix_out contains a valid opaque pixel
    output logic        pix_priority, // 0=above road (primask 0xf0), 1=below road (0xfc)

    // Screen flip (tie to 0 for dblaxle — sprites_flipscreen=0 in MAME)
    input  logic        flip_screen
);
```

### Notes on the interface

**SDRAM bandwidth:** OBJ GFX ROM is 4MB and the sprite scanner reads one 64-bit tile row
per chunk per scanline. At 100 active sprites × 32 chunks × 8 rows = 25,600 ROM reads per
frame. At 48 MHz with SDRAM latency ~6 cycles: 25,600 × 6 = 153,600 cycles ≈ 3.2ms. One
VBlank ≈ 2ms at 60 Hz, 240 scanlines. This is tight. Optimization strategies are in §4.

**64-bit ROM fetch:** The OBJ ROM is arranged so that one tile row = 8 bytes = 64 bits.
The SDRAM arbiter should support a 64-bit burst mode (two consecutive 32-bit reads with
a single req/ack cycle). This matches the TC0480SCP's 32-bit fetch extended to 64-bit.

**Pixel output bus:** The priority mixer reads `pix_out` and `pix_priority` each clock
during active display to compose sprites over/under the road layer.

---

## 3. Internal Block Decomposition

```
tc0370mso
├── spr_ram           — 0x2000 × 16-bit dual-port BRAM
│                       (CPU write port + scanner read port)
│
├── vblank_scanner    — VBlank state machine:
│   ├── entry_reader  — reads 4 words per sprite entry from spr_ram
│   ├── stym_fetcher  — reads 32 chunk codes from spritemap ROM (SDRAM)
│   ├── zoom_calc     — computes (curx, cury, zx, zy) for each chunk
│   ├── obj_fetcher   — reads tile rows from OBJ GFX ROM (SDRAM)
│   └── pixel_writer  — writes rendered pixels into line buffers
│
├── line_buffers      — 2× (320 × 13-bit) ping-pong line buffers
│                       {priority[0], pixel[11:0]} per pixel
│                       Buffer A renders while Buffer B outputs, swap each scanline
│
└── scanline_output   — reads active line buffer pixel by pixel during hpos 0..319,
                        drives pix_out, pix_valid, pix_priority
```

---

## 4. Build Plan

### Step 1 — Sprite RAM + CPU Interface (50 lines)

Implement the 0x2000 × 16-bit sprite RAM as synchronous dual-port BRAM:
- Port A: CPU A bus (read/write, byte-enable, 1-cycle DTACK)
- Port B: internal scanner port (read-only, sequential access during VBlank)

The frame_sel input (for racingb double-buffer) gates which 0x800-word half is presented
to the scanner's Port B. For dblaxle: frame_sel=0, full 0x2000-word scan.

Verification: write sprite entries from testbench, confirm scanner reads them back.

### Step 2 — VBlank Entry Scanner + Spritemap Fetch (150 lines)

State machine that runs during VBlank:

```
IDLE → wait for vblank rising edge

SCAN_ENTRIES:
  entry_addr = frame_start_offset + 0x7FC (last entry address)
  while entry_addr >= frame_start_offset:
    read 4 words from spr_ram[entry_addr + 0..3]
    if tilenum == 0: continue
    compute: zoomx_eff = zoomx+1, zoomy_eff = zoomy+1
             y_screen = y + y_offs + (64 - zoomy_eff)
             x_screen = x
             sign_extend x_screen, y_screen (>0x140 → subtract 0x200)
    map_offset = tilenum << 5
    → FETCH_CHUNKS

FETCH_CHUNKS:
  for chunk = 0 to 31:
    px = flipx ? (3-k) : k;  py = flipy ? (7-j) : j
    issue stym_req; addr = map_offset + px + (py<<2)
    wait stym_ack; code = stym_data
    if code == 0xffff: continue
    compute: curx, cury, zx, zy (integer zoom division)
    → FETCH_TILE_ROWS

FETCH_TILE_ROWS:
  for row = 0 to 7:
    if cury+row not in [0..255]: skip
    tile_byte_addr = code * 64 + (flipy ? (7-row) : row) * 8
    issue obj_req; addr = tile_byte_addr
    wait obj_ack; tile_row_data = obj_data[63:0]
    → RENDER_ROW

RENDER_ROW:
  for col = 0 to 15:
    src_x = flipx ? (15-col) : col
    pixel = extract_4bpp(tile_row_data, src_x)
    if pixel == 0: continue  (transparent)
    screen_x = curx + (col * zx + 8) / 16  (zoom scaled)
    if screen_x not in [0..319]: skip
    palette_index = color * 16 + pixel
    write to line_buffer[cury+row][screen_x] = {priority, palette_index}

back to SCAN_ENTRIES
```

Key implementation note: the zoom column position uses integer arithmetic. The exact
formula from MAME: `curx + ((k * zoomx_eff) / 4)`. For per-pixel x within a chunk,
linear interpolation across the 16 source pixels into `zx` output pixels is used:
`screen_x = curx + (col * zx + 8) / 16`. This matches MAME's `prio_zoom_transpen`
behavior (bilinear zoom, nearest pixel).

### Step 3 — Line Buffer (double-buffered) (60 lines)

Two line buffers, each 320 × 13-bit wide (1 priority bit + 12 palette index bits):

```
line_buf_A[0..319]: {priority, pixel[11:0]}
line_buf_B[0..319]: {priority, pixel[11:0]}
```

Active/display alternation: at the start of each scanline (hblank falling edge),
swap which buffer is being written (by scanner) and which is being read (by output).

**Back-to-front transparency:** When the scanner writes a pixel to the line buffer,
it writes unconditionally (overwriting any previous pixel at that x position). Since
sprites are scanned back-to-front, the last write to any pixel position wins — this is
the frontmost sprite's pixel. Transparent pixels (pixel_value == 0) are not written,
preserving the background or lower-priority sprite pixel.

At the start of each new scanline render pass (when switching the write buffer), clear
all 320 entries to a "no sprite" sentinel (e.g., `13'h1000` = priority=1, pixel=0x000
which can be distinguished from valid pixel 0).

### Step 4 — Zoom Pixel Renderer (100 lines)

The zoom render maps 16 source pixels into `zx` output pixels. At zx=16 (1:1): direct
copy. At zx=8 (50%): every other source pixel. At zx=32 (200%): each source pixel
repeated twice.

Implementation: for each output column `ox` in `[0..zx-1]`:
```
src_x = (ox * 16) / zx        // floor division → source pixel index 0..15
```

This is a pure combinatorial lookup, feasible in RTL as a divider (constant `zx` per
tile = precomputed once per chunk). For the FPGA, a small divider or a 6-bit lookup
table (zx ∈ 1..64, ox ∈ 0..63) suffices.

Similarly for y: `src_y = (oy * 8) / zy` for `oy ∈ [0..zy-1]`.

### Step 5 — Scanline Output Stage (40 lines)

During active display (hblank deasserted, vpos in active range):

```
each clock (hpos advances):
  {pix_priority, pix_index} = read_active_line_buffer(hpos)
  if pix_index == transparent_sentinel:
    pix_valid = 0
    pix_out = 12'h000
    pix_priority = 0
  else:
    pix_valid = 1
    pix_out = pix_index
    pix_priority = stored priority bit
```

The priority mixer at the top level uses `pix_valid` to gate whether the sprite pixel
participates in the final compositing decision.

### Step 6 — SDRAM Bandwidth Optimization (50 lines)

Worst case: 100 active sprites × 32 chunks × 8 rows = 25,600 OBJ ROM reads per frame.
Each read returns 64 bits (8 bytes). At SDRAM latency of 6 cycles @ 48 MHz: 153,600
cycles ≈ 3.2ms. VBlank ≈ 2ms.

**Optimization 1: Skip off-screen tiles.**
Before issuing obj_req, check if `cury + row` is in [0..255] AND `curx + zx` > 0 AND
`curx` < 320. Off-screen tiles require no ROM fetch and no render.

**Optimization 2: Tile row cache.**
If the same tile code and row are requested within a small window, skip the SDRAM fetch
and use the cached result. A 4-entry LRU cache (tile_code + row → 64-bit data) covers
adjacent row reuses within a single sprite.

**Optimization 3: Spritemap burst.**
Fetch all 32 chunk codes for a sprite in a single 32-word burst from the spritemap ROM
(burst-read of 32 consecutive addresses). With burst support, this reduces to 1 SDRAM
latency overhead per sprite instead of 32.

With optimizations 1+2, typical game frames use 30–50% of worst-case ROM bandwidth.
Testing against dblaxle TAS will confirm whether optimizations are needed.

---

## 5. BRAM Requirements

| BRAM Block        | Size              | Purpose                               |
|-------------------|-------------------|---------------------------------------|
| spr_ram           | 8K × 16-bit       | 0x2000 words sprite RAM (dual-port)   |
| line_buf_A        | 512 × 13-bit      | Active/pending line buffer (ping)     |
| line_buf_B        | 512 × 13-bit      | Active/pending line buffer (pong)     |
| chunk_code_buf    | 32 × 16-bit       | Current sprite's 32 spritemap codes   |
| tile_row_cache    | 4 × 64-bit        | LRU cache for recent OBJ ROM rows     |

Total BRAM: ~24KB. On a Cyclone V (DE10-Nano) this is ~6 M10K blocks — well within budget.

The 4MB OBJ GFX ROM and 512KB spritemap ROM live in SDRAM.

---

## 6. Timing Budget

VBlank duration: at 60 Hz, 262 total scanlines, ~22 lines of VBlank = 22 × 1365 cycles
(at 48 MHz / 6 MHz pixel clock effective) ≈ 176,000 system cycles.

| Operation                          | Cycles/sprite | 100 sprites total |
|------------------------------------|---------------|-------------------|
| Read 4 spr_ram words               | 4             | 400               |
| Fetch 32 spritemap codes (burst)   | 32 + 6 lat    | 3,800             |
| Fetch ~16 tile rows (optimized)    | 16 × 6        | 9,600             |
| Render ~16 tiles to line buffer    | 16 × 16       | 25,600            |
| **Total (optimized)**              | **390**       | **~39,000**       |
| **Cycles available (VBlank)**      |               | **~176,000**      |

Comfortable margin at 100 active sprites. Even at 200 sprites (extreme case), ~78,000
cycles vs 176,000 available = 2.25× headroom.

---

## 7. Reuse from Other Chips

**SDRAM arbiter interface:** Same toggle-req/toggle-ack pattern as TC0480SCP and
TC0150ROD. The OBJ fetch needs a 64-bit wide path; the same arbiter can issue two
sequential 32-bit reads and assemble the 64-bit result.

**Pixel output timing:** Same hpos/vpos + hblank/vblank interface as TC0150ROD.
The priority mixer already accepts TC0150ROD's output; sprite output uses the same
convention: {priority, palette_index, valid}.

**spr_ram BRAM:** Same dual-port inferred BRAM pattern as TC0150ROD's road_ram.

---

## 8. Implementation Risk

**Medium.** The algorithm is completely documented in MAME (bshark_draw_sprites_16x8
is 70 lines of straightforward C). The main risks are:

1. **SDRAM bandwidth:** If optimizations are insufficient, VBlank will overrun. Mitigation:
   test early with TAS validation at low sprite counts, increase optimizations as needed.

2. **Zoom pixel accuracy:** Integer zoom division in RTL must exactly match MAME's
   `prio_zoom_transpen` behavior. Test vectors from MAME frame dumps will catch any
   1-pixel offset discrepancies.

3. **Line buffer clear timing:** The line buffer must be fully cleared before the first
   active-display pixel of each scanline. With 48 MHz clock and ~96 HBlank clocks,
   clearing 320 entries takes exactly 320/2 = 160 cycles (burst write) — tight but
   feasible with a dual-port burst clear.

---

## 9. Comparison with Other Chips in This Pipeline

| Chip          | Tier | Lines est. | Main complexity driver                        |
|---------------|------|------------|-----------------------------------------------|
| TC0150ROD     | 2    | ~350       | Per-scanline rasterizer, SDRAM ROM fetch      |
| TC0100SCN     | 2    | ~400       | Two-layer tilemap, scroll                     |
| TC0370MSO     | **3**| **~700**   | Spritemap lookup + zoom + line buffer + SDRAM |
| TC0200OBJ(F2) | 3    | ~700       | BigSprite groups, scroll latch, TC0360PRI     |
| TC0180VCU     | 3    | ~700       | Three-layer tilemap + zoom + rotate           |
| TC0480SCP     | 4    | ~1200      | Five layers, rowscroll, rowzoom, colscroll    |

TC0370MSO is the most complex new chip required for the Taito Z core, but is
well within the Tier-3 band. It is comparable in complexity to TC0200OBJ (Taito F2)
except it uses a spritemap ROM indirection layer instead of the BigSprite group mechanism.

---

## 10. TAS Validation Strategy

Before debugging visually, build the TAS comparison framework:

1. Run dblaxle in MAME with Lua script dumping sprite RAM + line buffer contents
   every frame (or every N frames where sprites change).
2. Run the RTL simulation with the same sprite RAM state.
3. Compare line buffer contents pixel by pixel.

Key test cases from the TAS:
- Frame with no active sprites (all tilenum=0): line buffer should be all-transparent
- Frame with one sprite at known position/zoom: verify pixel placement
- Frame with priority=0 sprite over road: verify primask effect
- Frame with priority=1 sprite under road: verify occlusion

This is the same methodology used for SMB, Metroid, Zelda, Punch-Out, and CPS1. Build
it before touching any visual debugging.
