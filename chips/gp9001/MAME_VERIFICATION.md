# GP9001 MAME Verification Checklist

**Purpose:** Document the 7 critical verification items that must be resolved by examining MAME source code before RTL implementation advances beyond Gate 2.

**Status:** Research Phase (2026-03-17)
**Gate 1 RTL Status:** IMPLEMENTED & SYNTHESIZABLE (63/63 unit tests pass)
**Gate 2 RTL Status:** IMPLEMENTED (sprite scanner FSM complete)
**Gate 3+ Status:** PENDING (blocked on verification of items #1, #3, #6, #7)

---

## Verification Item #1: LAYER_CTRL Bit Layout

**What Needs to be Verified:**
The LAYER_CTRL register (word 0x09 at base+0x12 in CPU address space) controls which background layers are enabled and their priority order. The exact bit-field layout determines:
- How many layers are active (2, 3, or 4)?
- Which bits encode the priority of each layer?
- Are priority values globally ordered (0=lowest, 3=highest) or per-layer flags?

**Current Implementation (RTL):**
File: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` lines 337-341

```systemverilog
assign layer_ctrl          = active_layer_ctrl_r;
assign num_layers_active   = active_layer_ctrl_r[7:6];   // bits [7:6]
assign bg0_priority        = active_layer_ctrl_r[5:4];   // bits [5:4]
assign bg1_priority        = active_layer_ctrl_r[3:2];   // bits [3:2]
assign bg23_priority       = active_layer_ctrl_r[1:0];   // bits [1:0]
```

**Assumptions Made:**
- Bits [7:6]: num_layers (2-bit field) → 00=2 layers, 01=3, 10=4, 11=reserved
- Bits [5:4]: BG0 priority (2 bits)
- Bits [3:2]: BG1 priority (2 bits)
- Bits [1:0]: BG2/BG3 priority combined (2 bits) or separate?

**Status:** 🔴 OPEN — Need to verify against MAME `gp9001.cpp` ctrl_r/ctrl_w functions
**MAME Source Location:** Check `GP9001TileBank` logic and layer enable flags in `toaplan2.cpp` machine config
**Impact on RTL:** Priority logic in `colmix.sv` (Gate 5) depends on this encoding

---

## Verification Item #2: Rowscroll Implementation

**What Needs to be Verified:**
The ROWSCROLL_X register (word 0x08 at base+0x10) enables per-scanline horizontal scroll offsets. The exact semantics:
- Which layers support rowscroll? (BG3 only? All layers?)
- Is rowscroll ADDITIVE (scroll_x += rowscroll[y]) or REPLACEMENT (scroll_x = rowscroll[y])?
- What is the memory layout of the rowscroll table in VRAM?
- Is rowscroll hardware-native or emulation only in MAME?

**Current Implementation (RTL):**
File: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` line 335

```systemverilog
assign rowscroll_ctrl = active_rowscroll_r;  // Raw 16-bit register, not decoded
```

Gate 4 (BG renderer) would use this value to modulate scroll per scanline.

**Assumptions Made:**
- Rowscroll is optional (many games don't use it)
- Only one rowscroll table (shared or per-layer selection via ROWSCROLL_X bits)
- Likely stored in external VRAM, fetched during rendering

**Status:** 🟡 PARTIAL — Basic register staging implemented; semantic interpretation TBD
**MAME Source Location:** Check `gp9001.cpp` render functions for rowscroll loop variables
**Impact on RTL:** BG renderer (Gate 4) needs interpretation rules before coding

---

## Verification Item #3: Sprite Y Position Field Encoding

**What Needs to be Verified:**
Sprite RAM Word 0, bits [8:0] encode the Y position. The question: is this field **unsigned (0–511)** or **signed (−256 to +255)**?

- If **unsigned:** Y wraps at 512 (modulo 512)
- If **signed:** Y uses two's-complement representation (e.g., 0xFF = −1, 0x100 = −256)

The visibility sentinel is currently implemented as `y != 9'h100` (decimal 256), which suggests **signed 9-bit** interpretation where 0x100 = off-screen marker.

**Current Implementation (RTL):**
File: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` lines 451, 460

```systemverilog
slot_y       = slot_w0[8:0];
slot_visible = (slot_y != 9'h100);  // Sentinel: y=256 means off-screen/disabled
```

**Assumptions Made:**
- Y field is 9-bit (0–511 range)
- Sentinel value 0x100 (decimal 256) = disabled sprite
- Negative Y values (0x1XX range) are interpreted as off-screen-above
- Positive Y values (0x0XX range) are visible on-screen (0–239) or off-screen-below

**Status:** 🟢 LIKELY CORRECT — Sentinel logic (`y != 9'h100`) matches MAME comment, but signedness needs explicit verification
**MAME Source Location:** `gp9001.cpp`, function `PrepareSprites()`, check Y position calculation
**Impact on RTL:** Rasterizer (Gate 3) compares screen_y against sprite Y bounds; sign interpretation affects clipping

---

## Verification Item #4: Sprite Code Splitting

**What Needs to be Verified:**
Sprite RAM Words 1–3 encode the tile code and rendering attributes. The exact layout of the tile code (Word 1 bits [9:0] vs Word 3 bits [7:0]):
- Is the tile code a simple 10-bit value stored entirely in Word 1?
- Or is it split: upper bits in Word 3, lower bits in Word 1?
- Does the code extend to 16 bits via bank selection?

**Current Implementation (RTL):**
File: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` lines 452, 457

```systemverilog
slot_tile    = slot_w1[9:0];     // 10-bit tile index from Word 1
slot_palette = slot_w3[3:0];     // 4-bit palette from Word 3 bits [3:0]
```

**Assumptions Made:**
- Word 1 [9:0]: tile_num (simple 10-bit index)
- Word 1 [10]: flip_x flag
- Word 1 [11]: flip_y flag
- Word 1 [15]: priority flag
- Word 3 [5:4]: size code (2 bits) → 0=8×8, 1=16×16, 2=32×32, 3=64×64
- Word 3 [3:0]: palette (4-bit bank selector)
- Bank extension via global `GP9001TileBank[]` array (external ROM bank selection)

**Status:** 🟡 PARTIAL — Layout is documented, but bank selection via `GP9001TileBank[]` is MAME-specific and requires reverse-engineering
**MAME Source Location:** `toa_gp9001.cpp` lines 99–113 (see `nSpriteNumber += GP9001TileBank[...]`)
**Impact on RTL:** ROM address generation in sprite rasterizer (Gate 3) depends on bank calculation

---

## Verification Item #5: Blending Mode Support

**What Needs to be Verified:**
The BLEND_CTRL register (word 0x0D at base+0x1A) and sprite Word 3 bits [7:5] encode color blending modes. The question:
- Which blending modes does hardware support? (color-key transparency? additive? subtractive? alpha-blend?)
- Which modes are actually used in extant games?
- Is blending per-sprite or global per-layer?
- Are blend modes implemented in hardware or CPU-emulated?

**Current Implementation (RTL):**
File: `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` lines 349, 350

```systemverilog
assign blend_ctrl  = active_blend_ctrl_r;  // Raw 16-bit register
// (No decoded fields yet; Gate 5 colmix would interpret this)
```

**Assumptions Made:**
- BLEND_CTRL is a global control register (per-frame, not per-sprite)
- Each sprite may have per-sprite blend bits (location TBD, possibly Word 3 [7:5])
- At minimum, color-key transparency (palette index 0 = transparent)
- Possibly additive or subtractive blending for special effects

**Status:** 🟡 PARTIAL — Register is staged, but semantics unknown
**MAME Source Location:** Check `toa_gp9001.cpp` for `ToaPalette` blending logic; also `gp9001_colmix.sv` equivalent in RTL
**Impact on RTL:** Color mixing pipeline (Gate 5) must implement correct blend operation per game variant

---

## Verification Item #6: Color Palette Indexing

**What Needs to be Verified:**
Sprite RAM Word 3 bits [3:0] encode a palette bank selector (4-bit value). The question: how is this bank value converted to a palette RAM address?

- Is bank left-shifted by 4 bits? (index = bank << 4) → palette addresses 0, 16, 32, 48, ...
- Or is bank multiplied by some other factor?
- Or is palette lookup game-specific?

**Current Implementation (RTL):**
File: Section 3 of `section3_rtl_plan.md` line 266 (from source read earlier)

```systemverilog
// Compose output: palette index = (color_bank << 4) | pixel_nibble
logic [7:0] palette_idx = {sprite.color_bank, pixel_nibble};
```

This assumes palette address = (bank << 4) | pixel_nibble, forming an 8-bit palette index.

**Assumptions Made:**
- Palette bank is 4 bits (selects which of 16 palette rows)
- Pixel value from tile ROM is 4 bits (0–15)
- Final palette index = (bank << 4) | pixel → 8-bit value addressing 256-entry palette
- Palette RAM is CPU-writable, read-only for graphics engine

**Status:** 🟢 LIKELY CORRECT — MAME code at `toa_gp9001.cpp` line 110 shows `{((pSpriteInfo[0] & 0xFC) << 2)}`
**MAME Source Location:** `toa_gp9001.cpp` line 110 and palette setup; also see `FBNeo/src/burn/drv/toaplan/toa_gp9001_render.h`
**Impact on RTL:** Sprite rasterizer (Gate 3) palette lookup; already correctly assumed in section3_rtl_plan.md

---

## Verification Item #7: Sprite Tile Fetch Pattern

**What Needs to be Verified:**
For multi-tile sprites (32×32, 64×64, 128×128), the GPU reads multiple tile code entries from ROM in sequence. The exact pattern:

- Are tiles arranged row-major or column-major within the sprite?
- For a 32×32 sprite (2×2 tiles), are codes stored as: code, code+1, code+8, code+9 (if 8 tiles wide)?
- Or: code, code+1, code+16, code+17 (if 16 tiles per row)?
- How does the tile ROM offset depend on sprite size?

**Current Implementation (RTL):**
File: `section3_rtl_plan.md` lines 251–253 (from source read earlier)

```systemverilog
logic [5:0] tiles_wide = sprite.w >> 4;  // 1, 2, 4, or 8 tiles wide
logic [9:0] tile_idx = sprite.code + (tile_y * tiles_wide) + tile_x;
```

This assumes **row-major indexing** with variable row stride based on sprite width.

**Assumptions Made:**
- Tiles are indexed linearly in sprite ROM
- Stride per row = number of tiles wide (1, 2, 4, or 8)
- For an 8×8 sprite: code = tile_idx (single tile)
- For a 16×16 sprite: code + 0, code + 1 (row 0); code + 2, code + 3 (row 1)
- For a 32×32 sprite: stride = 4 tiles wide → code + 0–3 (row 0), code + 4–7 (row 1), etc.

**Status:** 🟡 PARTIAL — Row-major pattern is intuitive and likely, but exact stride calculation needs verification
**MAME Source Location:** `toa_gp9001.cpp` lines 154–172 (the nested loop over `nSpriteSize` incrementing `nSpriteNumber`)
**Impact on RTL:** Sprite rasterizer (Gate 3) ROM address calculation in `gp9001_sprite_renderer.sv`; critical for correct sprite rendering

---

## Summary Table

| Item | Topic | Status | RTL File | Gate Impact | Verified |
|------|-------|--------|----------|-------------|----------|
| #1 | LAYER_CTRL bit layout | 🔴 OPEN | gp9001.sv line 337 | Gate 5 (colmix) | ❌ No |
| #2 | Rowscroll impl | 🟡 PARTIAL | gp9001.sv line 335 | Gate 4 (BG renderer) | ⚠️ Partial |
| #3 | Sprite Y field encoding | 🟢 LIKELY | gp9001.sv line 451 | Gate 3 (rasterizer) | ✅ Probable |
| #4 | Sprite code splitting | 🟡 PARTIAL | gp9001.sv line 452 | Gate 3 (ROM addr) | ⚠️ Partial |
| #5 | Blending mode support | 🟡 PARTIAL | gp9001.sv line 350 | Gate 5 (colmix) | ⚠️ Partial |
| #6 | Palette indexing | 🟢 LIKELY | section3 line 266 | Gate 3 (palette lookup) | ✅ Probable |
| #7 | Tile fetch pattern | 🟡 PARTIAL | section3 line 253 | Gate 3 (ROM fetch) | ⚠️ Partial |

---

## Gate 1 RTL Implementation Status

**File:** `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/gp9001/rtl/gp9001.sv` (582 lines)

**Implemented:**
- ✅ CPU interface (register staging, read/write decode)
- ✅ Control register shadow/active architecture (pipelined on vsync)
- ✅ Sprite RAM (dual-port BRAM, CPU write + scanner read)
- ✅ Gate 2 sprite scanner FSM (VBLANK → scan → display list generation)
- ✅ Register output ports (scroll, layer_ctrl, sprite_ctrl, etc. decoded to signal outputs)

**Module Ports:**
```systemverilog
module gp9001 #(parameter int NUM_LAYERS = 2) (
    input  logic        clk, rst_n,
    input  logic [10:0] addr,          // Chip-relative word address
    input  logic [15:0] din,           // CPU data in
    output logic [15:0] dout,          // CPU data out
    input  logic        cs_n, rd_n, wr_n,
    input  logic        vsync, vblank,
    output logic        irq_sprite,
    output logic [15:0] scroll [0:7],  // Decoded scroll registers
    output sprite_entry_t display_list [0:255],  // Output sprite list
    output logic [7:0]  display_list_count,
    output logic        display_list_ready
);
```

**Test Results:** 63/63 unit tests pass (per memory notes: "Gate 1 is done per the memory notes — 63/63 tests pass")

**Blocked on Verification Items:** #1, #2, #5 (layer control, rowscroll, blending)

---

## Next Steps

1. **Immediate:** Extract exact bit fields from MAME `gp9001.cpp`:
   - Confirmation of LAYER_CTRL decoding (items #1)
   - Rowscroll register interpretation (item #2)
   - Blend control semantics (item #5)

2. **Gate 3 Preparation:** Confirm tile fetch pattern (item #7)
   - Generate synthetic test ROM with known multi-tile sprite patterns
   - Side-by-side comparison with MAME emulator output

3. **Gate 4 BG Renderer:** Implement rowscroll and verify palette logic (items #2, #6)

4. **Gate 5 Integration:** Implement color mixing with correct priority and blending (items #1, #5)

---

**Last Updated:** 2026-03-17
**Source:** MAME `gp9001.cpp`, `toa_gp9001.cpp`, section1/2/3 documentation
**Next Review:** After MAME source verification pass
