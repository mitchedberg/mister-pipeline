# Taito X Gate4 Integration Test Framework

Full-frame sprite→colmix integration tests for the Taito X graphics pipeline.

## Overview

**Gate4** = Complete pipeline test: X1-001A sprite scanning + rendering + taito_x_colmix palette lookup and priority compositing.

This framework validates the entire foreground rendering path:
1. **X1-001A Phase 2** — sprite scanner reads YRAM/CRAM, fetches GFX ROM tiles, renders to line buffer
2. **taito_x_colmix** — palette mixer resolves sprite/background priority and performs xRGB_555 palette lookup

## Architecture

### gate4_model.py — Python Reference Model

Software model of the gate4 pipeline that serves as the ground truth for expected outputs.

**Inputs:**
- Sprite Y-coordinate RAM (0x180 words, 768 bytes)
- Sprite code/attribute RAM (0x2000 words, 8 KB)
- GFX ROM (0x40000 words, 256 KB of 16-bit tile data)
- Palette RAM (0x800 words, 2 KB of xRGB_555)
- Control registers (4 × 8-bit)

**Output:**
- Per-pixel (x, y, r, g, b) tuples for all visible pixels

**Key features:**
- Wraps X1001APhase2 (sprite rendering) from `../x1001a_model.py`
- Performs palette lookup on sprite pixel output
- Supports COLOR_BASE offset (game-specific palette base)
- Produces ground-truth pixel values for testbench verification

### generate_gate4.py — Test Vector Generator

Generates `gate4_integration_vectors.jsonl` with 5 comprehensive test cases:

1. **Simple sprite** — Single 16×16 sprite at center, solid color
2. **Multi-sprite priority** — Two overlapping sprites; lower index wins (higher priority)
3. **Clipped sprite** — Sprite at screen edge with partial visibility
4. **Palette check** — Striped sprite with color attributes; tests palette lookup
5. **Transparent pixels** — Checkerboard sprite (pen=0 transparent, pen=15 opaque)

**Test vector format (JSONL):**
```json
{"op": "reset"}
{"op": "yram_write", "addr": 0, "data": 0x1234, "be": 3}
{"op": "cram_write", "addr": 0, "data": 0x5678, "be": 3}
{"op": "load_gfx_word", "addr": 64, "data": 0xABCD}
{"op": "palette_write", "addr": 87, "data": 0x03FF, "be": 3}
{"op": "render_frame"}
{"op": "check_pixel", "x": 100, "y": 112, "exp_r": 0, "exp_g": 31, "exp_b": 31}
```

### tb_gate4.cpp — Verilator Testbench

C++ testbench that:
- Instantiates `Vx1_001a` (X1-001A RTL)
- Loads test vectors from JSONL file
- Drives sprite RAM writes, GFX ROM loads
- Executes frame rendering (vblank + active video timing)
- Compares pixel outputs against expected values

**Note:** Currently tests **X1-001A alone** (sprite scanning + rendering). Full gate4 integration (sprite → colmix → RGB output) would require:
- Instantiating `taito_x_colmix.sv` module
- Adding palette BRAM to testbench
- Capturing rgb_r/rgb_g/rgb_b outputs at each (x, y) position
- Comparing against Python model pixel tuples

### Makefile

**Targets:**
```bash
make              # Generate vectors, build testbench, run tests
make vectors      # Generate gate4_integration_vectors.jsonl only
make build        # Compile testbench with Verilator
make run          # Execute compiled testbench
make clean        # Remove build artifacts
```

## Test Cases

### Test 1: Simple Sprite
- **Input:** Tile 1 (solid color 7), color attribute 5, at screen position (100, 112)
- **Expected:** 16×16 block of cyan pixels (palette[87] = xRGB_555 cyan)
- **Validates:** Basic sprite rendering, palette lookup

### Test 2: Multi-Sprite Priority
- **Input:**
  - Sprite 0: Tile 1 (solid 7), color 3 (red), at (50, 100)
  - Sprite 1: Tile 2 (solid 11), color 4 (blue), at (60, 105)
  - Overlap region at (60–64, 105–109)
- **Expected:** Overlap shows red (sprite 0 wins due to lower index)
- **Validates:** Sprite priority, multi-layer compositing

### Test 3: Clipped Sprite
- **Input:** Tile 3 (gradient rows), at screen right edge (right clipping)
- **Expected:** Only visible portion of sprite appears; clipped pixels absent
- **Validates:** Edge clipping, boundary conditions

### Test 4: Palette Check
- **Input:** Tile 4 (striped: each column = column number), color 2 (green)
- **Expected:** Pixels vary by column, each with distinct palette color
- **Validates:** Palette lookup correctness, color attribute encoding

### Test 5: Transparent Pixels
- **Input:** Tile 5 (checkerboard: alternating pen=0 and pen=15), color 6
- **Expected:** Opaque pixels (pen=15) show magenta; transparent pixels (pen=0) show background
- **Validates:** Transparency (pen=0), background visibility

## Running Tests

### Generate vectors:
```bash
python3 generate_gate4.py
# Produces: gate4_integration_vectors.jsonl
```

### Build and run testbench:
```bash
make
# Or step-by-step:
make vectors
make build
make run
```

### Run with specific vector file:
```bash
./obj_dir/Vx1_001a custom_vectors.jsonl
```

## Future Improvements

1. **Full taito_x_colmix integration** — Add colmix module to testbench, capture RGB outputs
2. **Background tile test cases** — Test sprite-over-background compositing
3. **Screen flip tests** — Validate flip_screen control register behavior
4. **Multiple test files** — Separate gate4_simple.jsonl, gate4_advanced.jsonl, etc.
5. **Cycle-accurate validation** — Check pixel outputs per-scanline during active video
6. **Performance metrics** — Measure rendering time, memory bandwidth

## References

- `../x1001a_model.py` — X1-001A Phase 1/2 Python model
- `../../rtl/x1_001a.sv` — X1-001A RTL (Phase 1 + Phase 2)
- `../../rtl/taito_x_colmix.sv` — Color mixer / palette lookup module
- `../../ARCHITECTURE.md` — Taito X chip architecture overview
- `../../section2_x1001a_detail.md` — X1-001A sprite scanner detailed spec

## Directory Structure

```
chips/taito_x/vectors/gate4_integration/
├── README.md                          (this file)
├── Makefile
├── gate4_model.py                    (Python reference model)
├── generate_gate4.py                 (test vector generator)
├── tb_gate4.cpp                      (Verilator testbench)
├── gate4_integration_vectors.jsonl   (generated test vectors)
└── obj_dir/                          (Verilator build artifacts)
    ├── Vx1_001a                      (compiled testbench executable)
    └── ...
```

## Exit Codes

- **0** — All tests passed
- **1** — One or more tests failed, or setup error

## Notes

- GFX ROM model in testbench is zero-latency (mirrors `gfx_ack = gfx_req`)
- Palette BRAM would require additional integration (not yet implemented)
- Test timing matches RTL: VBLANK_LINES=8, SCREEN_H=240, SCREEN_W=384
- All sprite coordinates in screen-relative (not ROM-relative); yoffs = -0x12 applied by model
