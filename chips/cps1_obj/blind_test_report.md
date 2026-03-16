# CPS1 OBJ Blind Test Report

Generated: 2026-03-15
RTL: `chips/cps1_obj/rtl/cps1_obj.sv`
Model: claude-sonnet-4-6

---

## RTL Summary

**Line count:** 632 lines (including comments and blank lines)

**Module:** `cps1_obj`

**Parameters:**
- `MAX_SPRITES` (default 256) — caps SPR_ENTRIES localparam at 256

**Interface ports:** 18 signals
- clk, async_rst_n
- cpu_addr[9:0], cpu_data[15:0], cpu_we (OBJ RAM write)
- hcount[8:0], vcount[8:0], hblank_n, vblank_n (timing)
- flip_screen (VIDEOCONTROL bit 15)
- rom_addr[19:0], rom_half, rom_cs, rom_data[31:0], rom_ok (B-board ROM)
- pixel_out[8:0], pixel_valid (compositor output)

**Internal substructures:**
1. Reset synchronizer (section5 inline pattern)
2. OBJ RAM live buffer (1024×16b, CPU-writeable)
3. OBJ RAM shadow buffer (1024×16b, latched at VBLANK)
4. VBLANK-triggered DMA (1024-cycle copy, live→shadow)
5. Ping-pong line buffer pair (2×512×9b)
6. Line buffer startup clear FSM
7. Sprite scan state machine (15-state FSM)
8. Combinational tile coordinate helpers
9. Line buffer readout with self-erase

---

## Gate Results

| Gate | Result | Iterations | Notes |
|------|--------|------------|-------|
| Gate 2.5 (Verilator lint, -Wall) | **PASS** | 3 | 13 warnings iter 1, 3 warnings iter 2, clean iter 3 |
| Gate 3a (Yosys synthesis + check) | **PASS** | 1 | First attempt clean; no latches, no multi-drivers |
| Gate 3b (Quartus map) | CI pending | — | Linux CI only; not blocked on macOS |

---

## Key Structural Decisions

### Line Buffer Architecture

Implemented as two 512×9-bit arrays (`linebuf[0]` and `linebuf[1]`). Bank selection uses `vcount[0]`:
- Front bank = `vcount[0]` (read during display of current line)
- Back bank = `~vcount[0]` (written during hblank for next line)

Self-erase: each pixel position in the front bank is written back to `9'h1FF` (transparent) on the clock cycle it is read out. This resets the buffer for its next role as the back bank without needing an explicit clear pass.

Startup: a 512-cycle FSM clears both banks to `9'h1FF` on reset.

### Sprite Scan

The scan is a two-pass approach within hblank:
1. **Find-end pass**: Walk entries 0..255 reading ATTR word (word 3) looking for the `0xFF00` terminator. Records `scan_idx` = last valid entry index.
2. **Render pass**: Counts down from `scan_idx` to 0, loading each entry's 4 words and iterating through all tiles in the NX×NY block.

Rendering from end to start means entry 0 is written last → it overwrites → it appears on top (correct priority model per spec section 2.4).

The combinational shadow RAM read (`sram_rdata = obj_ram_shadow[sram_addr]`) provides zero-latency access, so the state machine reads one word per clock cycle without extra wait states.

### Per-Tile Visibility

For each tile in a block, visibility is computed combinationally:
```
vy_delta = (vrender - cur_tile_y) mod 512
visible  = (vy_delta < 16)
vsub     = vy_delta[3:0]  (optionally XOR'd with 0xF if FLIPY)
```
This handles Y-wrap (sprites near Y=240+ that wrap around to scanline 0) correctly through modular 9-bit arithmetic.

### ROM Fetch Protocol

Two ROM fetches per tile (left half, right half = 8 pixels each):
- Half 0: `rom_half = 0` (or `1` if FLIPX, since we fetch right half first when flipped)
- Half 1: `rom_half = 1` (or `0` if FLIPX)

The state machine uses a handshake loop: assert `rom_cs`, hold until `rom_ok`, latch `rom_data`, write pixels, move to next half. This correctly handles slow ROMs (variable-latency rom_ok).

### Pixel Writing

For each 8-pixel half, writes into `linebuf[back_bank][px]` skipping transparent pixels (color nibble `4'hF`). Pixel positions are computed with 9-bit wrap (`& 9'h1FF`). When FLIPX is active:
- Half 0 is the right half (fetched first): pixels map to `tile_px + 15 - i`
- Half 1 is the left half (fetched second): pixels map to `tile_px + 7 - i`

### Flip Screen

Coordinate transform applied when loading ATTR (LOAD_W3 state):
- `eff_x = 496 - spr_x` (= 512 - 16 - spr_x)
- `eff_y = 240 - spr_y` (= 256 - 16 - spr_y)
- FLIPX and FLIPY bits are inverted

Arithmetic uses 10-bit operands with explicit truncation to 9 bits to avoid width warnings.

### OBJ RAM Double-Buffering

The DMA controller copies `obj_ram_live → obj_ram_shadow` at the VBLANK falling edge (vblank_n goes low), one word per clock over 1024 cycles. The DMA runs in the background during VBLANK, completing well within the ~3500-clock VBLANK window (262-240=22 lines × 512 clocks/line).

---

## Known Gaps vs the Spec

### Gap 1: Find-end pass timing

The find-end pass scans all entries sequentially, one per clock. For 256 entries this takes 256 clock cycles. Combined with up to 256 entries × 16×16 tiles × 2 ROM fetches, the hblank window (64 clocks at 512-448=64, more precisely 512-448+64=128 pixel-clocks wide) may not be sufficient to render all sprites. The spec (section 2.7) says the chip "operates during horizontal blank" but does not explicitly quantify the timing budget. The implementation is functionally correct but may not meet real hardware timing for dense sprite scenes.

### Gap 2: All-ones tile skip optimization

Section 2.7 mentions: "Blank (all-ones) tile data is detected: if all 32 bits from ROM are `0xFFFFFFFF`, the 8-pixel group is skipped without writing to the line buffer, saving time." This implementation does not skip the second half fetch when the first half is all-transparent; it always performs both fetches. This is a performance optimization gap, not a correctness gap (transparent pixels are still not written to the buffer).

### Gap 3: Captcomm bootleg terminator

Section 6, item 1 mentions the bootleg Captain Commando uses `ATTR & 0x8000` as a terminator instead of `ATTR & 0xFF00`. This implementation only supports the standard `0xFF00` convention.

### Gap 4: ROM data bit ordering

The spec (section 2.14) states "ROM data bus is 64 bits wide; fetches return two groups of 8 pixels." The exact bit ordering within the 32-bit word (MSB = pixel 0 or pixel 7?) is not definitively stated. This implementation treats `rom_data[3:0]` as pixel 0 (leftmost). If the actual hardware bit-reverses within each byte, all sprites will appear horizontally mirrored. This cannot be resolved without a reference capture.

### Gap 5: Duplicate sprite detection

The jotego reference (section 6, item 3) skips entries that are exact duplicates of the previous entry. This implementation does not include that optimization.

### Gap 6: Single-clock CPU model

This implementation assumes `cpu_clk == clk` (single 8 MHz clock domain). Real CPS1 hardware uses a 10 MHz 68000 CPU clock, which would require a proper CDC handshake on OBJ RAM writes. In jtframe this is handled at the top level; the OBJ module itself just takes synchronous writes.

---

## Questions the Spec Didn't Answer

1. **ROM data bit ordering within each 32-bit word**: Is pixel 0 at bits[3:0] or bits[31:28]? Section 2.14 describes the bus width but not the per-pixel bit layout within a fetch.

2. **Hblank duration vs sprite budget**: The spec gives hblank start at pixel 448 and end at pixel 64 (width = 512-448+64 = 128 pixel clocks). At 8 MHz this is 16 µs. Is the chip designed to render all 256 entries × up to 256 tiles within this window, or does it abort early if time runs out?

3. **DMA conflict with sprite scan**: The DMA copies live→shadow during VBLANK. Does the sprite scan FSM share the same shadow RAM read port, or does the shadow buffer have a dedicated read bus? (This implementation uses a combinational read that would conflict with DMA writes on the same cycle — on FPGA this would be a read-during-write issue.)

4. **Code nibble column wrapping**: Section 1.5 says "The lower 4 bits of CODE select the column within a 16-tile row." Does column addition wrap strictly within a nibble (mod 16) or can it carry into the upper bits of CODE? This implementation uses strict 4-bit arithmetic.

5. **X clipping**: Section 2.9 says pixels outside X=64..447 are not written. Should the chip clip at write time (skip pixels outside range) or was the original hardware's line buffer wide enough that out-of-range writes just go to off-screen positions? This implementation writes to the full 512-wide buffer and lets the compositor ignore positions outside 64-447.

6. **vrender during VBLANK**: Lines 240-261 are vertical blank. The sprite engine renders "one line ahead" — what happens when vcount is in the VBLANK region? Should the engine skip rendering entirely? This implementation still renders into the back buffer for those lines; they are never displayed due to `vblank_n` masking the readout, but cycles are consumed.
