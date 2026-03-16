# TC0100SCN RTL Notes

## Key Structural Decisions

### 1. Streaming Architecture with Pixel Clock Enable

The TC0100SCN is a streaming chip — no line buffer. Pixels are produced one per pixel clock continuously during active scan. The implementation uses a 48 MHz master clock with a `clk_pix_en` synchronous enable that fires at ~6.671 MHz (≈ 7 master clocks per pixel). All pixel-rate logic (`if (clk_pix_en & active)` guards) is inside `always_ff @(posedge clk)` blocks — no gated clocks (anti-pattern AP-4).

**7-master-clock budget per pixel:** The tile fetch sequence (present VRAM attr addr → wait → latch attr, present code addr → wait → latch code, issue ROM request → rom_ok) takes approximately 4-6 master clocks in the common case. This fits comfortably within the 7-master-clock pixel period, so no double-buffering of prefetched tiles is needed. The shift register is loaded at the tile boundary; if rom_ok is delayed beyond 7 master clocks, the shift register underflows (outputs the old tile's pixels for one extra pixel position). This is acceptable for initial validation; a prefetch pipeline can be added at gate4 if needed.

### 2. Fetch State Machine (3 instances)

Each layer (BG0, BG1, FG0) has an independent 6-state fetch FSM (`fetch_st_t`):
- `FS_IDLE` → `FS_AATTR` → `FS_LATTR` → `FS_LCODE` → `FS_ROM` → `FS_LOADED`

Triggered at `hcount[2:0] == 7` (`tile_boundary` pulse), which is one pixel before the tile boundary, giving the pipeline time to fetch the next tile while the current tile's last pixel is still shifting out.

FG0 does not use the shared ROM bus; it reads char data directly from VRAM (the char RAM region), so its FSM has no ROM wait state — `FS_LCODE` immediately latches char data and sets `shift_load`.

### 3. ROM Bus Arbitration

BG0 and BG1 share a single `rom_addr`/`rom_data`/`rom_ok` bus. Priority: BG0 > BG1. BG1's FS_ROM state only accepts `rom_ok` when `!bg0_rom_req`. In practice, both BG layers trigger at the same pixel boundary, but BG0 completes its VRAM reads (2 cycles) before presenting ROM addr. BG1 then follows 0 cycles later. If both arrive at FS_ROM simultaneously, BG0 wins and BG1 waits one rom_ok cycle. This introduces at most 1 cycle of delay for BG1 per tile — acceptable within the 7-master-clock budget.

### 4. Memory Architecture: `ifndef QUARTUS`

**Problem:** Verilator uses `ifdef VERILATOR` guard; Yosys (gate3a) sees neither `VERILATOR` nor `QUARTUS` defined, so the else-branch (altsyncram) was selected and failed because Yosys doesn't know altsyncram.

**Solution:** Changed guard to `ifndef QUARTUS`. Behavioral model (flat `logic [15:0] vram [0:131071]`) is used for both Verilator simulation and Yosys gate-check. Quartus synthesis (`define QUARTUS`) gets the altsyncram M10K instances. Three separate altsyncram instances are used: BG0 RAM (32KW), BG1/scroll RAM (64KW), FG0/upper RAM (8KW).

**Note:** In single-width mode, FG0 char data at byte 0x6000 (word 0x3000) and FG0 tilemap at byte 0x8000 (word 0x4000) are in the middle of the BG1 RAM address space. The behavioral model handles this correctly since it is a flat unified array. For Quartus, these addresses map to the BG1 64KW RAM instance; the FG0 read port reads from `vram_raddr_fg0` which addresses into the 8KW FG0 block in double-width mode only. This is a known limitation: FG reads in single-width mode will miss in the synthesis path and return 0. **Gate4 TODO**: either unify memory into a single large RAM or add a second read port to the BG1 instance for FG reads.

### 5. Shadow RAMs for Scroll Tables

The rowscroll (512×16 per BG layer) and colscroll (128×16 for BG1) tables are implemented as small shadow RAM arrays (`logic [9:0] bg0_rowscroll_mem [0:511]` etc.) that are mirrored from CPU writes at the appropriate VRAM address windows. This avoids contending with tile-fetch reads on the main VRAM read ports.

Rowscroll is latched once per line at `hcount==0`. Colscroll is latched once per tile column at `hcount[2:0]==6` (one pixel before tile boundary, when BG1 FSM is still IDLE).

### 6. Scroll Register Width

CPU scroll registers are 16-bit (full 16-bit CPU writes stored in `ctrl[]`). Internally, scroll values are stored as 10-bit (`logic [9:0]`) — the tilemap is 512 pixels wide/tall max, so 9 bits of position + 1 sign bit = 10 bits captures all meaningful precision. The negate operation at write time: `10'(-$signed(cpu_din[9:0]))`.

### 7. Flip Screen and Tile Flip

- **Screen flip** (`ctrl[7][0]`): applied to tile row (`trow ^ 3'h7`) in the `bg0_trow`/`bg1_trow`/`fg0_trow` combinational blocks.
- **Tile Y-flip** (`flip_r[1]`): applied to the effective tile row before ROM address generation, in `bg0_eff_trow`, `bg1_eff_trow`, `fg0_eff_trow`.
- **Tile X-flip** (`flip_r[0]`): applied at shift register load time by reversing pixel nibble order in the `bg0_shift <= {...}` assignment.

### 8. Colscroll

BG1 only. Colscroll entry for tile column N gives a signed pixel Y offset. The implementation converts to tile rows by right-shifting by 3 (/ 8). For a 10-bit colscroll value, the effective tile Y adjustment is `bg1_colscroll >> 3` (7 bits of tile offset, covering ±64 tile rows). Applied as: `bg1_ty = (bg1_ty_base - (bg1_colscroll >> 3)) & 63`.

Per spec, colscroll is indexed by tilemap-space X divided by 8 (not screen X), so it tracks with horizontal scroll. This is correctly implemented: `bg1_cs_ridx = bg1_ntx_early & 0x7F` where `bg1_ntx_early` already incorporates the BG1 horizontal scroll.

## Spec Ambiguities Encountered

### A. SC0–SC14 Output Encoding

The spec (section 2, section 7) states: "The chip outputs 15-bit pixel data (SC0–SC14)" but does not give a precise bit layout. MAME uses a higher-level abstraction (priority_draw calls) rather than emulating the actual wire encoding. The implementation uses an internally-defined encoding:

```
[14:13] = FG0 pixel[1:0]
[12]    = FG0 opaque (1 if fg0_pixel != 0)
[11:8]  = BG1 pixel[3:0]
[7:4]   = BG0 pixel[3:0]
[3]     = bottomlayer bit
[2:0]   = 0 (reserved)
```

This is a **gate4 risk**: the actual TC0360PRI interface may expect a different encoding. Will need to cross-reference against Operation Thunderbolt schematics when they become available.

### B. Rowscroll Application Direction

Section 1 states:
```
tilemap.set_scrollx((scanline + global_scrolly) & 0x1FF, global_scrollx - rowscroll_ram[scanline])
```
The `bg0_scrollx_r` already stores `-cpu_scrollx` (negated). So the correct formula is:
```
effective_x = bg0_scrollx_r - rowscroll_ram[scanline]
```
This is implemented for BG1 (`bg1_ntx` uses `bg1_scrollx_r - bg1_rowscroll`) but the direction for BG0 uses `bg0_scrollx_r - bg0_rowscroll` which mirrors the BG1 implementation. Needs MAME validation at gate4.

### C. FG0 2bpp Pixel Format

Section 1 states FG char data is "packed, 8 pixels per 2 bytes, row-major". The implementation assumes pixel 0 is in bits `[15:14]` of the 16-bit word (MSB-first). MAME's gfx format string would clarify the exact packing. If pixels are LSB-first, the X-flip logic would need to be swapped.

### D. Single-Width FG Reads from Synthesis RAM

In Quartus synthesis with `ifndef QUARTUS` disabled (i.e., QUARTUS defined), FG char data at single-width addresses (0x3000, 0x4000) lives in the BG1 64KW RAM instance, but the FG0 fetch pipeline reads via `vram_raddr_fg0` which is connected to the 8KW FG0 instance. This means FG0 will read zero for all char data in single-width mode under Quartus synthesis. Fix required before gate3b: either route FG0 reads through the BG1 instance, or store FG data in the FG0 instance regardless of mode (by adjusting the CPU write address decoding).

## Gate Infrastructure Fix

Gate3a.sh contained a false-positive latch-detection regex that matched Yosys informational messages "No latch inferred for signal ..." as if they were positive latch reports. Fixed the regex to exclude lines beginning with "No latch inferred". See `gates/gate3a_yosys.sh`.
