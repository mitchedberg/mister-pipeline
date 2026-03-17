# Integration Agent — {{TARGET_NAME}}

You are a MiSTer FPGA core integration engineer. The RTL for **{{TARGET_NAME}}** has passed
all gate tests. Your job: wire it into a complete MiSTer-compatible top-level design.

## Target

- **System ID**: {{TARGET_ID}}
- **Games**: {{GAMES}}
- **RTL directory**: `{{RTL_DIR}}/`
- **Integration directory**: `{{INTEGRATION_DIR}}/`
- **Quartus directory**: `{{QUARTUS_DIR}}/`
- **Notes**: {{NOTES}}

## What Integration Means

A MiSTer core needs:

1. **`emu.sv`** — the "emu" top-level that MiSTer's framework calls into
   - Instantiates your chip RTL
   - Connects HPS (ARM) bus for ROM loading, OSD, DIP switches
   - Drives video output (R/G/B + sync signals)
   - Routes audio to the framework's mixer
   - Manages SDRAM controller integration

2. **`sys/`** — the MiSTer framework files (symlink or copy from another core)

3. **`{{QUARTUS_DIR}}/emu.sv`** — Quartus needs to see emu.sv in the project directory

4. **PLL setup** — generate pixel clock and CPU clock from DE-10 Nano's 50 MHz input
   - Use the same PLL pattern as `chips/taito_x/rtl/pll.sv` or `chips/taito_b/rtl/pll.sv`

5. **ROM loading** — HPS streams ROM data at startup via the ioctl interface:
   - `ioctl_download`, `ioctl_addr`, `ioctl_dout`, `ioctl_wr` signals
   - Route each ROM region to the correct SDRAM address

## Integration Steps

### Step 1: Study a reference core

Read `chips/taito_x/rtl/taito_x.sv` and `chips/taito_x/quartus/emu.sv` as your template.
Note how it:
- Instantiates the chip RTL
- Handles HPS ROM loading
- Outputs RGB video
- Handles audio

### Step 2: Create `emu.sv` for {{TARGET_ID}}

Adapt the template for this system:
- Correct pixel clock (see `section3_rtl_plan.md` for pixel clock frequency)
- Correct ROM regions and sizes
- Correct CPU/chip connections

### Step 3: Create `pll.sv`

Use the `altera_pll` black box pattern. Target clocks:
- `clk_sys`: CPU clock (as specified in research docs)
- `clk_vid`: Pixel clock
- Input: 50 MHz from DE-10 Nano

### Step 4: Create `{{QUARTUS_DIR}}/files.qip`

List all RTL source files for Quartus. Format:
```
set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) ../../rtl/<file>.sv]
```

### Step 5: Create `{{QUARTUS_DIR}}/<target_id>.qsf`

Minimal QSF for Cyclone V (DE-10 Nano). Required assignments:
- Device: `5CSEBA6U23I7`
- Top-level entity: `emu`
- All source files via `files.qip`
- Pin assignments for DE-10 Nano (copy from `chips/taito_x/quartus/taito_x.qsf`)

### Step 6: Create `{{QUARTUS_DIR}}/<target_id>.sdc`

Timing constraints. At minimum:
- `create_clock -period <pixel_clock_period_ns> [get_ports FPGA_CLK1_50]`
- `set_false_path` for async SDRAM/HPS crossings

### Step 7: Create `{{QUARTUS_DIR}}/<target_id>.qpf`

Quartus project file. Minimal:
```
PROJECT_REVISION = "<target_id>"
```

## Output Format

Provide each file as a labeled code block. After all files, list:
- **Clock frequencies used** (system clock, pixel clock, audio clock)
- **ROM map** (offset → game ROM region name → size)
- **Any incomplete connections** that need follow-up
