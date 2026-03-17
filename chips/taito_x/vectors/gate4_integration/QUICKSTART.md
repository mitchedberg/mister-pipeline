# Gate4 Integration Test Framework — Quick Start

## 60-Second Setup

```bash
cd chips/taito_x/vectors/gate4_integration/

# Generate test vectors
python3 generate_gate4.py

# Full build and test (requires Verilator)
make

# Or compile and run separately:
make build
make run
```

## What You Get

- **gate4_integration_vectors.jsonl** — 642-line test vector file with 5 tests, 72 pixel checks
- **tb_gate4** — Compiled Verilator testbench (in obj_dir/)
- **Test results** — PASS/FAIL per test case with detailed diagnostics

## File Overview

| File | What It Does |
|------|--------------|
| `gate4_model.py` | Python model: X1-001A + colmix (ground truth) |
| `generate_gate4.py` | Creates test vectors from Python model |
| `tb_gate4.cpp` | Verilator testbench: runs RTL against vectors |
| `Makefile` | Build automation (vectors → compile → test) |
| `README.md` | Complete documentation |
| `gate4_integration_vectors.jsonl` | Generated test vectors (642 lines) |

## Test Cases (5 Total)

1. **Simple sprite** — Single 16×16 sprite, solid color
2. **Multi-sprite priority** — Two overlapping sprites (priority test)
3. **Clipped sprite** — Sprite at screen edge
4. **Palette check** — Striped sprite with color attributes
5. **Transparent pixels** — Checkerboard (pen=0 vs. pen=15)

## Running Tests

### Option 1: Full automation
```bash
make              # Generate vectors, build, run
make clean && make  # Clean rebuild
```

### Option 2: Step-by-step
```bash
make vectors      # Generate gate4_integration_vectors.jsonl
make build        # Compile testbench with Verilator
make run          # Execute compiled testbench
make clean        # Remove build artifacts
```

### Option 3: Manual
```bash
python3 generate_gate4.py              # Generate vectors
verilator --cc --exe tb_gate4.cpp --top-module x1_001a \
  ../../rtl/x1_001a.sv -Mdir obj_dir -CFLAGS "-O2"
cd obj_dir && make -f Vx1_001a.mk
./Vx1_001a gate4_integration_vectors.jsonl
```

## Examining Test Vectors

### View test structure:
```bash
grep '"op"' gate4_integration_vectors.jsonl | sort | uniq -c
```

**Output shows distribution of operations:**
- `reset` (5) — one per test case
- `load_gfx_word` (~320) — tile data
- `palette_write` (~80) — palette RAM entries
- `cram_write` (~80) — sprite attributes
- `yram_write` (~25) — sprite Y coordinates
- `ctrl_write` (~10) — control registers
- `render_frame` (5) — one per test
- `check_pixel` (72) — pixel verification checks

### View specific test:
```bash
awk '/^{"op": "reset"}/ {count++} {if (count == 1) print}' \
  gate4_integration_vectors.jsonl | head -50
```

### Count pixel checks per test:
```bash
awk '/^{"op": "reset"}/ {if (count) print "Test", count ":", checks, "checks"; count++; checks=0} \
    /^{"op": "check_pixel"}/ {checks++} \
    END {print "Test", count ":", checks, "checks"}' \
  gate4_integration_vectors.jsonl
```

## Expected Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Test 1] reset
  load_gfx_word(0x00040, 0x7777) [tile 1 start]
  ...
  palette_write(0x057, 0x03FF, be=3)
  ctrl_write(0x0, 0x0000, be=1)
  ctrl_write(0x1, 0x0040, be=1)
  cram_write(0x0000, 0x0001, be=3)
  cram_write(0x0200, 0xA864, be=3)
  yram_write(0x0000, 0x0070, be=1)
  render_frame()
  check_pixel(100, 112) → expected R=31 G=31 B=31
  check_pixel(108, 120) → expected R=31 G=31 B=31
  check_pixel(115, 127) → expected R=31 G=31 B=31

[Test 2] reset
  ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total checks: 72
Failures: 0
✓ PASS: all tests passed
```

## Key Concepts

### Gate4 = Full pipeline
```
Sprite Y RAM (0x180 words)
Sprite Code/Attr RAM (0x2000 words)
GFX ROM (0x40000 words)
    ↓
X1-001A Phase 2 (sprite scanner + renderer)
    ↓
Per-pixel (valid, color_idx)
    ↓
Palette RAM (0x800 words, xRGB_555)
    ↓
taito_x_colmix (palette lookup)
    ↓
Final RGB (5 bits per channel)
```

### Sprite coordinate system
- **X coordinate:** Screen-relative (0..383)
- **Y coordinate:** Sprite-relative; raw_y = (screen_h - screen_y - yoffs) & 0xFF
- **yoffs:** -0x12 (Superman game default)

### Palette addressing
- **Sprite pixel:** palette_index = {color_attr[4:0], gfx_nibble[3:0]} (9-bit)
- **Final address:** pal_addr = COLOR_BASE + palette_index (11-bit)
- **Format:** xRGB_555 — [15]=unused, [14:10]=R, [9:5]=G, [4:0]=B

### Transparency
- **Pen=0:** Transparent (sprite pixel not drawn)
- **Pen!=0:** Opaque (sprite pixel drawn with palette color)

## Troubleshooting

### Verilator not found
```bash
# Install Verilator
brew install verilator    # macOS
apt-get install verilator # Linux
```

### Vector file not found
```bash
# Regenerate vectors
python3 generate_gate4.py
```

### Testbench compilation errors
```bash
# Check RTL sources exist
ls -la ../../rtl/x1_001a.sv

# Clean rebuild
make clean
make build
```

### Python import errors
```bash
# Ensure path includes parent directory
cd chips/taito_x/vectors/gate4_integration
python3 generate_gate4.py
```

## Next Steps

1. **Run the tests** — `make`
2. **Review results** — Check PASS/FAIL and any diagnostics
3. **Read documentation** — See `README.md` for architecture details
4. **Extend tests** — Modify `generate_gate4.py` to add custom test cases
5. **Integrate colmix** — Add palette BRAM and taito_x_colmix module to testbench (see README.md Future Improvements)

## References

- **Full documentation:** `README.md`
- **Framework summary:** `FRAMEWORK_SUMMARY.md`
- **X1-001A architecture:** `chips/taito_x/section2_x1001a_detail.md`
- **Python model:** `chips/taito_x/vectors/x1001a_model.py`
- **RTL sources:** `chips/taito_x/rtl/x1_001a.sv`, `taito_x_colmix.sv`
