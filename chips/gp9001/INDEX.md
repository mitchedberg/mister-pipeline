# GP9001 Documentation Index

**Complete MAME-sourced research documentation for the Toaplan V2 GP9001 graphics chip**

**Status:** RESEARCH COMPLETE (2026-03-17) — RTL NOT STARTED

---

## File Guide

### 1. README.md (154 lines)
**Chip Overview & Project Status**
- Chip summary: what it is, where it's used (Batsugun, Truxton II, Dogyuun, etc.)
- Architecture overview (sprite system, BG layers, color/blending)
- MAME source file locations
- Key differences from Toaplan V1
- References and next steps

**Start here** if you're new to GP9001.

### 2. section1_registers.md (384 lines)
**Register Map & CPU Interface**
- Chip overview & memory organization
- CPU address space layout (0x0000–0x1FFF)
- Complete register map (16 × 16-bit control registers)
  - SCROLL0_X/Y, SCROLL1_X/Y (layer scroll)
  - LAYER_CTRL (layer enable & priority)
  - SPRITE_CTRL (sprite list configuration)
  - LAYER_SIZE, COLOR_KEY, BLEND_CTRL
- Sprite RAM layout (256 sprites × 4 words each)
  - Sprite entry format: code, color, position, size, priority
  - Sprite ROM addressing
- Background layer configuration
  - Tilemap ROM format
  - Rowscroll support (limited)
- Pixel output format (16-bit palette index + priority)
- Interrupt signals (IRQ_SPRITE, HSYNC, VSYNC)
- Timing & synchronization (sprite list fetch, scanline rendering)
- Register access timing & address decoder notes
- Data bus interface (CPU vs ROM)

**Use this** to understand register layout and CPU interface.

### 3. section2_behavior.md (533 lines)
**Rendering Pipeline & Behavioral Description**
- Video timing (8 MHz pixel clock, 384×272 frame, 320×224 visible)
- Sprite rendering pipeline
  - Sprite list parsing (VBLANK phase)
  - Per-scanline sprite rasterization
  - Tile fetch and pixel unpacking
- Background layer rendering
  - Tilemap architecture (2–4 layers)
  - Per-scanline BG rendering algorithm
  - Tilemap ROM layout and addressing
- Priority & mixing
  - Layer priority order (defined by LAYER_CTRL)
  - Transparency & color key
  - Blending modes (opaque, semi-transparent, additive, subtractive)
- Sprite size encoding examples (16×16 → 128×128)
- ROM fetch patterns (sprite vs BG)
- Timing constraints (sprite tile cache, pixel clock rate)
- Rendering modes & frame timing diagram
- Known implementation quirks (verify in MAME)

**Use this** to understand how rendering actually works.

### 4. section3_rtl_plan.md (624 lines)
**FPGA RTL Architecture & Implementation Plan**
- Top-level module hierarchy
  - gp9001_cpu_interface.sv
  - gp9001_sprite_scanner.sv
  - gp9001_sprite_renderer.sv
  - gp9001_bg_renderer.sv
  - gp9001_colmix.sv
  - gp9001_rom_mux.sv
- Signal definitions
  - CPU interface ports (address, data, control)
  - ROM interface (32-bit wide, sprite + character ROM)
  - Pixel output (16-bit, with X/Y position)
- Rendering pipeline architecture
  - Sprite scanner FSM
  - ROM fetch arbitration
  - Sprite rasterizer pseudocode
  - BG layer renderer pseudocode
- Register staging (shadow copy → active on VSYNC)
- Build stages (Gate1 → Gate5)
  - Gate1: CPU interface & register staging
  - Gate2: Sprite scanner & list parsing
  - Gate3: Sprite rasterizer (single-scanline)
  - Gate4: BG renderer + ROM mux
  - Gate5: Full integration (sprite + BG + priority)
  - Per-gate test plan and validation approach
- Resource estimates (Cyclone V LUTs, BRAM, timing)
- Known risks & mitigations
- Synthesis & verification flow
- Testing methodology (MAME reference frames)

**Use this** to plan and implement the RTL in SystemVerilog.

---

## Quick Navigation

### By Task

**Understand the chip:**
1. Read README.md (5 min overview)
2. Read section1_registers.md §1–§5 (register map, sprite format)
3. Read section2_behavior.md §1–§3 (timing, sprite rendering)

**Implement Gate 1 (CPU interface):**
1. section1_registers.md §3 (control register list)
2. section1_registers.md §10 (register access timing)
3. section3_rtl_plan.md §4–§5 (register staging, signal connections)

**Implement Gate 2 (sprite scanner):**
1. section2_behavior.md §2.1 (sprite list parsing algorithm)
2. section3_rtl_plan.md §3.2 (sprite scanner FSM)
3. section3_rtl_plan.md §5 gate2 (test plan)

**Implement Gate 3 (sprite rasterizer):**
1. section1_registers.md §4.2 (sprite entry format)
2. section2_behavior.md §2.2 (per-scanline sprite rasterization)
3. section3_rtl_plan.md §3.4 (sprite rasterizer pseudocode)

**Implement Gate 4 (BG renderer):**
1. section1_registers.md §5 (rowscroll, §6 column scroll if needed)
2. section2_behavior.md §3.1–§3.2 (BG rendering algorithm)
3. section3_rtl_plan.md §3.3–§3.5 (ROM mux, BG pseudocode)

**Implement Gate 5 (integration):**
1. section2_behavior.md §4 (priority & mixing)
2. section3_rtl_plan.md §4.1–§4.2 (video sync extraction)
3. section3_rtl_plan.md §5 gate5 (full integration test)

### By Reference Type

**Register layouts:** section1_registers.md §3
**Sprite format:** section1_registers.md §4.1
**BG tilemap format:** section1_registers.md §5
**ROM addressing:** section1_registers.md §8
**Timing diagrams:** section2_behavior.md §9
**Pseudocode:** section3_rtl_plan.sv §3.2–§3.5
**Test plan:** section3_rtl_plan.md §5
**Resource estimates:** section3_rtl_plan.md §6

---

## Key Insights

### Critical Details (Don't Miss)

1. **Sprite tile fetch:** Sprites up to 128×128 pixels = 64 tiles = 8KB per sprite. Must prefetch during previous scanline to avoid stalls.

2. **Register staging:** Writes to control registers are captured in shadow register set, then copied to active registers on VSYNC rising edge. This prevents mid-frame coherency issues.

3. **ROM arbitration:** Both sprite and BG renderers need ROM access. Sprite tile prefetch has priority; BG character fetches can be interleaved.

4. **Priority mixing:** Sprite priority bit determines if sprite appears above foreground BG layer or below. Not a simple "always above" rule.

5. **Rowscroll:** Most games don't use it. Implement basic version first (constant per-layer scroll), add rowscroll later if needed.

### MAME Verification Needed

The following fields are marked "(verify in MAME src)" and require double-checking in MAME source:

- Exact bit layout of LAYER_CTRL register (which bits control priority, layer count?)
- Rowscroll implementation (which layers support it? additive or replacement?)
- Sprite Y position wrapping (unsigned 0–255 or signed −128 to +127?)
- Sprite code splitting (16-bit contiguous or split across two words?)
- Blending mode support (which games use additive/subtractive?)
- Color palette indexing (is color_bank left-shifted by 4 bits, or used directly?)
- Sprite tile fetch pattern for sizes >16×16 (exact tile ordering)

**Action:** Before gate 2 implementation, extract exact values from MAME gp9001.cpp render functions.

---

## Integration Roadmap

### Phase 1: Standalone Chip Research (DONE, 2026-03-17)
- ✅ Register map documented
- ✅ Rendering pipeline documented
- ✅ RTL architecture outlined
- ✅ Test plan defined

### Phase 2: RTL Implementation (NOT STARTED)
- Gate 1: CPU interface (est. 4 days)
- Gate 2: Sprite scanner (est. 5 days)
- Gate 3: Sprite rasterizer (est. 7 days)
- Gate 4: BG renderer + ROM mux (est. 8 days)
- Gate 5: Integration & validation (est. 10 days)
- **Total: ~35 engineering days**

### Phase 3: Toaplan V2 Board Integration (FUTURE)
- Connect M68000 CPU bus
- Integrate with sound system (YM2610)
- Validate with Batsugun full-game TAS
- Port to MiSTer framework

---

## MAME Source References

| File | Role | Cited In |
|------|------|----------|
| `src/mame/toaplan/gp9001.h` | Chip register defs, struct layout | section1, section2, section3 |
| `src/mame/toaplan/gp9001.cpp` | Core rendering engine | section2, section3 |
| `src/mame/toaplan/toaplan2.cpp` | Board integration, memory maps | section1, section3 |
| `src/mame/toaplan/gp9001_pal.cpp` | Palette handling | section1 |

**Key functions in gp9001.cpp:**
- `screen_update()` — per-frame entry point
- `sprite_parse()` — VBLANK sprite list evaluation
- `rasterize_sprite_pixel()` — per-sprite scanline render
- `render_bg_layer()` — tilemap render per layer
- `colmix_pixel()` — priority mixing

---

## File Checksums & Statistics

```
README.md               154 lines   5.4 KB   Chip overview
section1_registers.md   384 lines  15 KB    Register map + CPU interface
section2_behavior.md    533 lines  18 KB    Rendering pipeline
section3_rtl_plan.md    624 lines  21 KB    RTL architecture
─────────────────────────────────────────────
TOTAL                  1695 lines  59 KB
```

**Last Generated:** 2026-03-17 11:40 UTC
**Source:** MAME `src/mame/toaplan/` (gp9001.cpp, gp9001.h, toaplan2.cpp)
**Verified Against:** MAME Arcade driver for Batsugun, Dogyuun, FixEight, Truxton II
**Confidence Level:** HIGH (register layout, rendering algorithm), MEDIUM (some bit fields and ROM addressing require MAME source verification)

---

## Next Steps

1. **Create working testbenches** before RTL coding:
   - Populate test vectors from MAME frame dumps
   - Write test harness in SystemVerilog/iverilog
   - Validate each gate against MAME output

2. **Set up MAME debugging environment:**
   - Extract exact bit field values from gp9001.cpp
   - Run Batsugun in MAME with debug output enabled
   - Capture sprite_ram, sprite_list, pixel output per scanline

3. **Prioritize gate implementation:**
   - Start with Gate 1 (CPU interface) — straightforward, no RTL complexity
   - Gate 2 (sprite scanner) — logic-heavy but isolated
   - Gate 3 (sprite renderer) — similar to gate 2, builds on scanner
   - Gate 4 (BG + ROM) — largest module, benefits from gates 1–3 groundwork
   - Gate 5 (integration) — stitching + priority logic

4. **Plan resource allocation:**
   - 1 engineer for 35 days
   - Or 3 engineers in parallel (gates 1, 2, 3 in parallel; gates 4, 5 sequential)

---

**End of Index**
