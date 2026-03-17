# GP9001 — Section 3: FPGA RTL Architecture & Implementation Plan

**Design Goal:** Cycle-accurate re-implementation of GP9001 sprite/background graphics in synthesizable Verilog/SystemVerilog

**Target Platforms:** MiSTer FPGA (DE10-Nano, Cyclone V), generic Artix-7 for lab testing

---

## 1. Top-Level Module Hierarchy

```
gp9001_top.sv (main interface)
├── gp9001_cpu_interface.sv
│   └── Register staging + address decoder
├── gp9001_sprite_scanner.sv
│   ├── Sprite list parser (during VBLANK)
│   └── Sprite evaluator (per-scanline active sprite detection)
├── gp9001_sprite_renderer.sv
│   ├── Sprite tile fetcher (ROM interface)
│   └── Sprite rasterizer (16×16 to 128×128 expansion)
├── gp9001_bg_renderer.sv
│   ├── Tilemap indexer (ROM lookup)
│   ├── Character tile fetcher
│   └── Per-scanline walker (tile → pixels)
├── gp9001_colmix.sv
│   └── Priority mixing (sprite vs BG priority logic)
├── gp9001_rom_mux.sv
│   └── Arbitrates ROM access between sprite/BG fetchers
└── gp9001_palette.sv
    └── External palette RAM interface (write-only from CPU)
```

---

## 2. Signal Definitions

### 2.1 Top-Level gp9001_top.sv Port List

```systemverilog
module gp9001_top (
    input  logic        clk,              // Pixel clock (8 MHz)
    input  logic        rst_n,            // Active-low async reset

    // CPU interface (16-bit data bus)
    input  logic [15:0] cpu_addr,        // CPU address (word-granular)
    input  logic [15:0] cpu_din,         // CPU write data
    output logic [15:0] cpu_dout,        // CPU read data
    input  logic        cpu_cs_n,        // Chip select (active low)
    input  logic        cpu_we_n,        // Write enable (active low)
    input  logic        cpu_oe_n,        // Output enable (active low)

    // Video timing inputs
    input  logic        hsync,            // Horizontal sync (active-low pulse)
    input  logic        vsync,            // Vertical sync (active-low pulse)
    input  logic        hblank,           // Horizontal blanking
    input  logic        vblank,           // Vertical blanking

    // Pixel output (320 pixels/line, 224 lines/frame)
    output logic [15:0] pixel_out,        // 16-bit pixel (palette index + priority)
    output logic        pixel_valid,      // 1 when pixel_out is valid
    output logic [8:0]  pixel_x,          // Current X position (0–319)
    output logic [8:0]  pixel_y,          // Current Y position (0–239)

    // ROM interface (sprite + character tiles)
    output logic [20:0] rom_addr,         // ROM address (up to 2 MB)
    input  logic [31:0] rom_data,         // ROM data (32-bit, four 8-bit pixels)
    output logic        rom_ce_n,         // ROM chip enable
    output logic        rom_oe_n,         // ROM output enable

    // Interrupts
    output logic        irq_sprite,       // Sprite list done (pulsed)

    // Debug outputs (optional)
    output logic [7:0]  dbg_sprite_idx,   // Current sprite being rendered
    output logic [8:0]  dbg_scan_line,    // Current scanline
    output logic [4:0]  dbg_state         // FSM state
);
```

### 2.2 CPU Interface Signals

```systemverilog
// Register staging (shadow copy of control registers)
logic [15:0] shadow_scroll[0:3];   // SCROLL0_X/Y, SCROLL1_X/Y
logic [15:0] shadow_layer_ctrl;    // LAYER_CTRL
logic [15:0] shadow_sprite_ctrl;   // SPRITE_CTRL
logic [15:0] shadow_color_key;     // COLOR_KEY (transparent color)

// Active registers (used for current frame rendering)
logic [15:0] active_scroll[0:3];
logic [15:0] active_layer_ctrl;
logic [15:0] active_sprite_ctrl;
logic [15:0] active_color_key;
```

### 2.3 Sprite RAM & Sprite State

```systemverilog
// Dual-port sprite RAM (256 sprites × 4 words)
logic [15:0] sprite_ram[0:1023];   // 256 entries, 4 words each
                                    // sprite_ram[i*4+0] = attr0 (code_lo, color, flip)
                                    // sprite_ram[i*4+1] = attr1 (code_hi, y_pos)
                                    // sprite_ram[i*4+2] = attr2 (x_pos, size)
                                    // sprite_ram[i*4+3] = attr3 (priority, blend)

// Parsed sprite list (from VBLANK evaluation)
typedef struct packed {
    logic [15:0] code;              // 16-bit tile index
    logic [5:0]  color_bank;        // Palette bank selector
    logic        flip_x, flip_y;
    logic signed [11:0] x;           // Signed 12-bit X position
    logic signed [7:0]  y;           // Signed 8-bit Y position
    logic [7:0]  w, h;              // Width/height in pixels (16/32/64/128)
    logic        priority;           // 1 = above foreground, 0 = below
    logic [2:0]  blend;              // Blending mode
    logic        enabled;
} sprite_entry_t;

sprite_entry_t sprite_list[0:255];  // Internal evaluation list
logic [7:0] active_sprite_count;    // How many sprites are active
```

---

## 3. Rendering Pipeline Architecture

### 3.1 Overall Pipeline Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                    ONE PIXEL CLOCK (8 MHz)                    │
├──────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌─────────────────┐    ┌──────────────┐    ┌────────────┐  │
│  │  Sprite Scanner │───→│ Sprite Rend  │───→│  ColMix    │  │
│  │  (per-scanline) │    │ (tile fetch) │    │ (priority) │  │
│  └─────────────────┘    └──────────────┘    └────────────┘  │
│                                                    │           │
│  ┌─────────────────┐    ┌──────────────┐        │           │
│  │ BG Layer Engine │───→│ Tile Fetcher │────────┤           │
│  │ (per-scanline)  │    │ (ROM access) │        │           │
│  └─────────────────┘    └──────────────┘        │           │
│                                                  │           │
│                                                  ↓           │
│                                            [pixel_out]       │
│                                                                │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Sprite Scanner State Machine

**Purpose:** During VBLANK, parse sprite RAM and identify which sprites are active for each scanline.

```
State VBLANK_IDLE:
  Wait for vsync rising edge
  → SPRITE_PARSE

State SPRITE_PARSE:
  for i = 0 to 255:
    Read sprite_ram[i*4:i*4+3]
    Decode: code, x, y, size, color, flip, priority
    If code != 0 (enabled):
      Compute y_min = y, y_max = y + height
      Store in sprite_list[i]
  After all 256 sprites:
    irq_sprite ← 1 (pulse interrupt)
    → SPRITE_SORT (if sort enabled) or RENDER

State SPRITE_SORT:
  If SPRITE_CTRL[bit 6:7] != 0 (sort enabled):
    Sort sprite_list by X position (or priority)
  → RENDER

State RENDER:
  Wait for hblank (H counter at 0)
  For each scanline Y = 0–271:
    Compute active_sprites for this Y
    → SPRITE_RENDER_LINE

State SPRITE_RENDER_LINE:
  For each pixel X = 0–319:
    For each active sprite (in list order):
      Check if (X, Y) within sprite bounds
      If yes: fetch tile pixel, output to colmix
  → next scanline or END_FRAME

State END_FRAME:
  When Y = 271 (last scanline):
    Copy shadow_regs → active_regs (pipelined)
    → VBLANK_IDLE
```

### 3.3 ROM Fetch Arbitration (gp9001_rom_mux.sv)

Both sprite and BG renderers need ROM access. Arbitrate fairly:

```
Priority scheme:
  1. Sprite tile prefetch has highest priority (must complete before scanline render)
  2. BG character tile fetch (lower priority, can be interleaved)

Each renderer requests:
  - rom_req (request bus)
  - rom_addr[20:0] (address)
  - rom_type ('SPRITE or 'BG)

Mux selects one per cycle:
  if sprite_req and not bg_req:
    grant to sprite
  elif bg_req and not sprite_req:
    grant to bg
  elif both_req:
    alternate: round-robin or priority to sprite

ROM response (next cycle):
  rom_data[31:0] → back to requester (FIFO-based or direct feedback)
```

### 3.4 Sprite Rasterizer (gp9001_sprite_renderer.sv)

**Per-scanline operation:**

```systemverilog
function logic [15:0] rasterize_sprite_pixel(
    sprite_entry_t sprite,
    logic [8:0] screen_x,
    logic [8:0] screen_y
);
    // Check if (screen_x, screen_y) within sprite bounds
    if (screen_x < sprite.x || screen_x >= sprite.x + sprite.w ||
        screen_y < sprite.y || screen_y >= sprite.y + sprite.h)
        return 16'h0000;  // Out of bounds, transparent

    // Compute position within sprite
    logic [7:0] in_sprite_x = screen_x - sprite.x;
    logic [7:0] in_sprite_y = screen_y - sprite.y;

    // Apply flip
    if (sprite.flip_x)
        in_sprite_x = sprite.w - 1 - in_sprite_x;
    if (sprite.flip_y)
        in_sprite_y = sprite.h - 1 - in_sprite_y;

    // Which tile within the sprite?
    logic [3:0] tile_x = in_sprite_x[7:4];  // 0–7 for 128×128 (8 tiles wide)
    logic [3:0] tile_y = in_sprite_y[7:4];
    logic [3:0] in_tile_x = in_sprite_x[3:0];
    logic [3:0] in_tile_y = in_sprite_y[3:0];

    // Tile index
    logic [5:0] tiles_wide = sprite.w >> 4;  // 1, 2, 4, or 8
    logic [9:0] tile_idx = sprite.code + (tile_y * tiles_wide) + tile_x;

    // Fetch tile from sprite ROM
    logic [20:0] rom_addr = tile_idx * 128;  // 128 bytes per 16×16 tile
    logic [31:0] tile_data = sprite_rom[rom_addr : rom_addr+127];

    // Unpack 4bpp pixel
    logic [3:0] pixel_nibble = unpack_4bpp(tile_data, in_tile_y, in_tile_x);

    if (pixel_nibble == 4'h0)
        return 16'h0000;  // Transparent (color key)

    // Compose output: palette index = (color_bank << 4) | pixel_nibble
    logic [7:0] palette_idx = {sprite.color_bank, pixel_nibble};
    logic [15:0] output_pixel = {
        palette_idx,              // [15:8]
        sprite.priority,          // [7]
        sprite.blend,             // [6:4]
        4'b0000                   // [3:0] reserved
    };

    return output_pixel;
endfunction
```

### 3.5 BG Layer Renderer (gp9001_bg_renderer.sv)

**Per-scanline operation (similar to sprite, but from tilemap ROM):**

```systemverilog
function logic [15:0] render_bg_layer_line(
    logic [2:0] layer_id,
    logic [8:0] screen_y,
    logic [8:0] screen_x
);
    // Fetch scroll values from active registers
    logic signed [15:0] scroll_x = active_scroll[layer_id*2 + 0];
    logic signed [15:0] scroll_y = active_scroll[layer_id*2 + 1];

    // Compute source coordinates in tilemap
    logic [8:0] src_y = (screen_y + scroll_y) & 9'h1FF;  // 512-pixel height
    logic [8:0] src_x = (screen_x + scroll_x) & 9'h1FF;  // 512-pixel width

    logic [4:0] tile_x = src_x[8:4];  // 0–31 (32 tiles wide)
    logic [4:0] tile_y = src_y[8:4];
    logic [3:0] in_tile_x = src_x[3:0];
    logic [3:0] in_tile_y = src_y[3:0];

    // Fetch tilemap entry
    logic [11:0] tilemap_addr = (tile_y * 32) + tile_x;
    logic [14:0] tile_code = tilemap_rom[tilemap_addr];

    // Fetch character tile from ROM
    logic [20:0] char_rom_addr = (layer_char_rom_base) + (tile_code * 128);
    logic [31:0] tile_data = char_rom[char_rom_addr : char_rom_addr+127];

    // Unpack 4bpp pixel
    logic [3:0] pixel_nibble = unpack_4bpp(tile_data, in_tile_y, in_tile_x);

    if (pixel_nibble == 4'h0)
        return 16'h0000;  // Transparent

    // Palette lookup: layer-specific palette bank
    logic [7:0] palette_idx = {layer_palette_base[layer_id], pixel_nibble};

    logic [15:0] output_pixel = {
        palette_idx,              // [15:8]
        layer_id[2:0],            // [7:5] layer ID for priority
        3'b000                    // [4:0] reserved
    };

    return output_pixel;
endfunction
```

---

## 4. Top-Level Signal Connections

### 4.1 Register Staging Pipeline

```systemverilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        shadow_scroll[0:3] <= 0;
        shadow_layer_ctrl <= 0;
        shadow_sprite_ctrl <= 0;
    end else if (!cpu_cs_n && !cpu_we_n) begin
        // CPU write: update shadow registers
        case (cpu_addr[5:0])
            6'h00: shadow_scroll[0] <= cpu_din;
            6'h01: shadow_scroll[1] <= cpu_din;
            6'h02: shadow_scroll[2] <= cpu_din;
            6'h03: shadow_scroll[3] <= cpu_din;
            6'h09: shadow_layer_ctrl <= cpu_din;
            6'h0A: shadow_sprite_ctrl <= cpu_din;
            // ... other registers
        endcase
    end

    // On VSYNC rising edge, copy shadow → active
    if (vsync_r[0] && !vsync_r[1]) begin
        active_scroll[0:3] <= shadow_scroll[0:3];
        active_layer_ctrl <= shadow_layer_ctrl;
        active_sprite_ctrl <= shadow_sprite_ctrl;
    end
end
```

### 4.2 Video Sync Extraction

```systemverilog
logic [1:0] hsync_r, vsync_r;

always @(posedge clk) begin
    hsync_r <= {hsync_r[0], hsync};
    vsync_r <= {vsync_r[0], vsync};
end

logic hsync_edge = hsync_r[0] && !hsync_r[1];  // falling edge
logic vsync_edge = vsync_r[0] && !vsync_r[1];  // falling edge
```

---

## 5. Build Stages (Gate1 → Gate5)

### Gate 1: CPU Interface & Register Staging

**Scope:** CPU reads/writes to control registers and sprite RAM, no rendering

**Tests:**
- Verify control register writes (scroll, layer_ctrl, sprite_ctrl) are captured in shadow registers
- Verify CPU can read back sprite RAM entries
- Verify register values transfer to active registers on VSYNC

**Files:**
- gp9001_cpu_interface.sv
- gp9001_top.sv (register staging logic)

**Validation:**
- Testbench writes pattern (0xAAAA, 0x5555) to each register, verifies read-back
- VSYNC pulse, verify shadow → active transfer

---

### Gate 2: Sprite Scanner & List Parsing

**Scope:** During VBLANK, read sprite RAM and populate internal sprite_list

**Tests:**
- Populate sprite RAM with known sprite entries (different x/y/sizes)
- Assert VBLANK, verify sprite_list[i] populated correctly
- Verify disabled sprites (code=0) are marked enabled=0
- Verify irq_sprite pulsed after sprite list complete

**Files:**
- gp9001_sprite_scanner.sv
- Testbench: sprite list verification

**Validation:**
- Sprite evaluator outputs matching MAME reference sprite_list
- Sprite sort (if enabled) reorders by X position

---

### Gate 3: Sprite Rasterizer (Single-Scanline)

**Scope:** For a fixed scanline, rasterize all active sprites

**Tests:**
- Pre-populate sprite_list with known sprites
- Manually set screen_y = 100 (arbitrary scanline)
- For each screen_x (0–319):
  - Invoke rasterize_sprite_pixel()
  - Verify output matches MAME's sprite pixel

**Files:**
- gp9001_sprite_renderer.sv (rasterize_sprite_pixel function)
- Testbench: single-scanline sprite render validation

**Validation:**
- Side-by-side comparison: MAME dump vs RTL output
- Check color_bank blending, flip_x/flip_y transformations
- Verify transparent pixels (color_key) are handled

---

### Gate 4: BG Layer Renderer + ROM Mux

**Scope:** Render BG layers from tilemap/character ROM, handle ROM bus arbitration

**Tests:**
- Load tilemap ROM + character tile ROM with known data
- Set scroll_x = 0, scroll_y = 0
- For each scanline Y (0–239):
  - Render both BG layers (if active)
  - Verify tilemap lookup → character fetch → pixel output
- Verify ROM arbiter correctly schedules sprite vs BG ROM accesses

**Files:**
- gp9001_bg_renderer.sv
- gp9001_rom_mux.sv
- Testbench: BG layer validation

**Validation:**
- Pixel-by-pixel comparison with MAME (BG only, no sprites)
- ROM access trace: verify addresses and 32-bit data widths

---

### Gate 5: Full Integration (Sprite + BG + ColMix)

**Scope:** Sprite and BG layers rendered simultaneously with priority mixing

**Tests:**
- Run full 272-line frame:
  - VBLANK (0–15): sprite list fetch
  - Rendering (16–271): sprite + BG composite
- Verify final pixel matches priority logic:
  - If sprite.priority=1 and sprite pixel opaque: sprite pixel
  - Else if BG0 opaque: BG0 pixel
  - Else: BG1 pixel

**Files:**
- All modules integrated
- gp9001_colmix.sv (priority logic)
- Testbench: frame-level comparison

**Validation:**
- Full-frame video output vs MAME reference
- Frame-by-frame TAS validation (if available)

---

## 6. Resource Estimates (Cyclone V)

| Resource | Gate1 | Gate2 | Gate3 | Gate4 | Gate5 |
|----------|-------|-------|-------|-------|-------|
| **LUTs** | 500 | 1500 | 3000 | 5000 | 8000 |
| **Block RAM** | 64KB | 128KB | 256KB | 256KB | 256KB |
| **Multipliers** | 0 | 0 | 2 | 4 | 6 |
| **Est. Timing** | 100 MHz | 100 MHz | 80 MHz | 80 MHz | 75 MHz |

*(Cyclone V has ~110K LUTs, 4600 KB BRAM; well within budget)*

---

## 7. Known Risks & Mitigations

| Risk | Probability | Mitigation |
|------|-------------|-----------|
| Sprite tile ROM prefetch stall | HIGH | Dual-port BRAM, 32-bit data path |
| Timing closure at 8 MHz | LOW | Design is not aggressive; 8 MHz easily achievable |
| Sprite code calculation (tile fetch pattern) | MEDIUM | Verify against MAME, detailed unit tests |
| Rowscroll ROM addressing (if implemented) | MEDIUM | Start without rowscroll (most games don't use it); add later |
| Priority encoding mismatch | MEDIUM | Extract exact priority logic from MAME, side-by-side test vectors |
| Color palette indexing | LOW | Straightforward palette address = (bank << 4) \| nibble |

---

## 8. Synthesis & Verification

### 8.1 Build Flow

```bash
# Synthesis
quartus_sh -t script.tcl              # Quartus project
yosys -m ghdl gp9001.ys              # Yosys (alternative)

# Simulation
modelsim -do simulate.do              # ModelSim testbench
iverilog -o sim gp9001_top.v ...     # Icarus Verilog (free)

# Implementation
quartus_map gp9001 ...                # Place & Route
quartus_fit gp9001 ...
quartus_assemble gp9001 ...           # Generate .rbf
```

### 8.2 Testbench Approach

```systemverilog
// gp9001_tb.sv
module gp9001_tb;
    logic clk, rst_n;
    // ... instantiate gp9001_top, drive video sync signals

    // Test vectors (from MAME dump)
    logic [15:0] expected_pixel[0:271][0:319];  // Full frame reference
    logic [15:0] actual_pixel[0:271][0:319];

    always @(posedge clk) begin
        if (pixel_valid)
            actual_pixel[pixel_y][pixel_x] <= pixel_out;
    end

    final begin
        // Compare frame
        compare_frame(expected_pixel, actual_pixel);
    end
endmodule
```

---

## 9. Testing Against MAME Reference

### 9.1 Capture MAME Frame Dump

```bash
# In MAME:
mame batsugun -vv -frameskip 0 | tee mame_output.log

# Extract sprite_list, BG pixels at specific scanlines:
# Write custom MAME debug output plugin to dump:
#   - sprite_ram contents every VBLANK
#   - pixel output every scanline
#   - layer enable state
```

### 9.2 Compare Methodology

```
For each scanline Y (16–239):
  For each pixel X (0–319):
    MAME_pixel = expected_pixel[Y][X]
    FPGA_pixel = actual_pixel[Y][X]

    if (MAME_pixel != FPGA_pixel):
        log_difference(Y, X, MAME_pixel, FPGA_pixel)

Check difference statistics:
  - 100% match: complete success
  - >99% match: likely timing/cache effects (acceptable for gate1–4)
  - >95% match: possible priority or color encoding bug
  - <95% match: logic error; debug gate-by-gate
```

---

## 10. Post-Implementation Plans

Once Gate 5 is validated:

1. **Rowscroll Support** (if used in target games)
   - Implement optional per-scanline scroll offset
   - Add rowscroll RAM port to BG renderer

2. **Zoom Effects** (if used in target games)
   - Add global zoom X/Y scaling to BG layers
   - Verify against FixEight / Grindstormer

3. **Blending Modes** (verify usage)
   - Implement semi-transparent, additive, subtractive modes
   - Test against any games using these effects

4. **Performance Optimization**
   - Pipeline tile fetch for back-to-back sprites
   - Cache frequently-used tiles in fast SRAM
   - Reduce ROM access latency

5. **Integration with Toaplan V2 Board**
   - Connect M68000 CPU bus to gp9001_top
   - Integrate YM2610 sound chip
   - Validate with full arcade board emulation

---

**Last Updated:** 2026-03-17
**Target Completion:** Gate 1 (4 days), Gate 2 (5 days), Gate 3 (7 days), Gate 4 (8 days), Gate 5 (10 days)
**Total Estimated Effort:** ~35 engineering days
