# CPS1 OBJ Chip — Discrepancies: MAME vs jotego jtcps1

Comparison between MAME `cps1_v.cpp` behavioral model and jotego `jtcores` structural Verilog implementation.

---

## D1. Duplicate Sprite Entry Skip Logic

**jotego**: The `jtcps1_obj_line_table` module explicitly tracks the previous sprite entry's (X, Y, CODE, ATTR) values and skips rendering any entry that is an exact repeat of the immediately preceding entry:

```
wire repeated = (obj_x==last_x) && (obj_y==last_y) &&
                (obj_code==last_code) && (obj_attr==last_attr);
...
if( (repeated && !first ) || !inzone ) begin
    st <= 1; // try next one
end
```

**MAME**: No equivalent logic. MAME renders every non-terminated entry unconditionally.

**Implication**: The real hardware likely has the skip logic (jotego's implementation is based on hardware measurement). Games probably never intentionally place two adjacent identical entries, but hardware protection against this would explain the chip design. Test vectors should include a case with two identical consecutive entries to determine correct hardware behavior.

---

## D2. One-Scanline Lookahead

**jotego**: The object processor operates on `vrender`, which is defined as one scanline ahead of the currently displayed scanline (`vdump`). The module comment states "1 line ahead of vdump." The line buffer is written one line ahead and read one line later.

**MAME**: MAME renders sprites at frame granularity (entire frame rendered at screen_update time), not scanline by scanline. MAME has no scanline-level OBJ timing model. The MAME comment "CPS1 sprites have to be delayed one frame" refers to the VBLANK latch, not to the one-line lookahead.

**Implication**: The one-scanline lookahead is a real hardware detail captured by jotego but absent from MAME. For RTL generation, the one-line lookahead must be implemented: the chip writes to line buffer N during the horizontal blank period after scanline N-1, so that the data is ready when scanline N is displayed. MAME's frame-level rendering model is an approximation that works for full-frame emulation but would be incorrect in a cycle-accurate implementation.

---

## D3. Per-Scanline vs Per-Frame Sprite Processing

**jotego**: The sprite table is scanned once per scanline (once during each horizontal blank period). All 256 sprite entries are checked against the current scanline's Y range on every HBlank. This consumes the full HBlank period; the DMA module comments measure typical HBlank durations of 604ns–2.06us for different workloads.

**MAME**: The entire sprite table is rendered once per frame at `screen_update` time. MAME iterates over all entries and calls `gfx->prio_transpen()` for each tile, which writes directly to the full-frame bitmap. There is no per-scanline granularity.

**Implication**: The per-scanline scan is the correct hardware model. The RTL must check all sprite entries against each scanline's Y window during HBlank. A sprite that spans 16 scanlines will trigger 16 separate tile fetches (one per scanline, for the appropriate vsub row). MAME's model collapses these 16 fetches into a single `prio_transpen` call.

---

## D4. ROM Address Construction

**jotego** (`jtcps1_obj_draw.v`):
```
rom_addr <= { obj_code, vsub };  // 20 bits: code[15:0], vsub[3:0]
```
The obj_code at this stage is already the processed `code_mn` (base code + block offsets), and vsub is the 4-bit vertical sub-row index.

**MAME**: MAME uses `m_gfxdecode->gfx(2)->prio_transpen()` which internally handles all addressing. MAME's `gfx(2)` for CPS1 sprites uses the 23-bit address format `000ccccccccccccccccyyyy` as documented in the driver comments, which is equivalent: top 3 bits = 0 (sprite), 16-bit code, 4-bit row. The 23-bit encoding and jotego's 20-bit `{code, vsub}` are equivalent for the OBJ chip; the top 3 type-select bits are implicit in the ROM bank routing.

**Implication**: No meaningful discrepancy. MAME's 23-bit format and jotego's 20-bit format are the same information. The type field (top 3 bits = 000 for sprites) is handled by B-board routing, not by the OBJ chip itself.

---

## D5. Sprite Table Scan Direction and Priority Implementation

**jotego**: The line_table module scans from entry 0 forward. It writes each matching tile into the line buffer via `jtcps1_obj_draw`. The line buffer write does NOT overwrite existing non-transparent data (jotego's `jtcps1_obj_line` writes only if `buf_data[3:0] != 4'hf`):

```
wire wr1 = buf_wr && buf_data[3:0]!=4'hf;
```

This means: the first sprite written to a given pixel position wins. Since entries are scanned 0 forward, entry 0 wins over entries 1, 2, etc.

**MAME**: MAME iterates from the last valid entry toward entry 0 (`for (int i = m_last_sprite_offset; i >= 0; i -= 4)`), and unconditionally writes (`prio_transpen` with transparent pen = 15). Since MAME writes last-entry first and entry-0 last, entry 0 also ends up on top (last write wins in MAME's model).

**Result**: Both models produce the same priority ordering (entry 0 on top), but via opposite mechanisms. jotego scans 0-first and writes first-wins; MAME scans last-first and overwrites (last write wins). These are functionally equivalent for correct implementations.

**Implication**: The RTL must implement either the "first-wins" write policy (scanning 0 to last) or the "overwrite" policy (scanning last to 0). For a minimal line buffer implementation, first-wins is simpler. The correct hardware behavior is "first-wins" based on jotego's analysis.

---

## D6. vsub for Multi-Row Sprites

**jotego** (`jtcps1_obj_tile_match.v`):
```
ycross = vs - objy_ext;
m      = ycross[7:4];    // which tile row within the block
vd     = vrenderf - obj_y[8:0];
vsub   <= vd[3:0] ^ {4{vflip}};  // sub-row within tile, with flip
code_mn <= obj_code + { 8'd0, vflip ? mflip : m, n};
```

The `vsub` is `(vrender - obj_y) & 0xF` (lower 4 bits of the total vertical offset), XOR'd with 0xF when FLIPY is set. The tile row selector `m` is bits 7:4 of the same offset (upper 4 bits, selecting which 16-pixel tile row).

**MAME**: MAME computes Y offsets implicitly within the `prio_transpen` gfx call. The tile row offset (`m`) and vsub are combined in the final tile code and sub-tile Y passed to the GFX decoder. MAME's gfx decoder handles the same math internally. There is no explicit discrepancy in the result.

**Implication**: The RTL must correctly separate the 8-bit `(vrender - Y)` value into `m` (bits 7:4, tile row selector) and `vsub` (bits 3:0, pixel row within tile). FLIPY inverts vsub as `vsub ^ 0xF`.

---

## D7. Y Coordinate Sign Extension

**jotego** (CPS1 mode):
```
assign ext_y = { obj_y[8], obj_y[8:0]};  // 10-bit sign extension of 9-bit Y
```

The Y value is sign-extended from 9 bits to 10 bits using bit 8 as the sign. This allows sprites at Y values 256–511 (which are equivalent to -256 to -1 in 9-bit two's-complement) to be positioned above the top of the screen.

**MAME**: MAME uses `y & 0x1FF` (simple 9-bit mask) and computes the start Y directly. MAME does not explicitly model the sign extension; it relies on the DRAWSPRITE macro passing the wrapped 9-bit Y value directly to the tile renderer.

**Implication**: For sprites that wrap from below the bottom edge back to the top, the visibility check (`inzone`) must use the sign-extended Y comparison. The RTL should implement the 9-to-10-bit sign extension for the Y coordinate when performing the scanline visibility check.

---

## D8. DMA Timing (VBLANK Latch)

**jotego** (DMA module comments): The DMA controller copies OBJ RAM one entry per scanline during VBLANK+active video, interleaved with palette DMA. The total copy time for 256 OBJ entries at 1 entry per HBlank = ~262 scanlines × 604ns/line ≈ 158us. The entire OBJ copy completes within one frame.

**MAME**: MAME performs an instantaneous `memcpy` of the entire OBJ RAM at VBLANK start. No timing model.

**Implication**: The real hardware performs OBJ DMA incrementally during HBlank periods, not as an instantaneous bulk copy. For RTL, the OBJ shadow buffer fill is pipelined: during each HBlank, the DMA fetches one or more OBJ entries from VRAM into the frame buffer used by the line-table scanner. The scanner reads from the frame buffer while the DMA simultaneously writes new data for a different scanline (double-buffering of the frame-level OBJ table, separate from the line-level double-buffering). This is a significant structural difference from MAME's instantaneous latch.

---

## D9. X Position Offset in jotego

**jotego** (`jtcps1_obj_line_table.v`):
```
dr_hpos <= eff_x[8:0] - 9'd1;
```

The effective X position passed to the draw module is the sprite X minus 1. This is an implementation detail of jotego's coordinate mapping (possibly to account for pipeline delay).

**MAME**: Uses the X value directly (`x & 0x1ff`).

**Implication**: The -1 offset is an internal pipeline correction in jotego's implementation, not a chip behavior difference. The RTL must adjust pixel output timing to match: if adopting jotego's approach, the -1 must be included to produce correct screen alignment. This is a clocking/pipeline choice, not a functional change.

---

## Summary Table

| Item | MAME Model | jotego Model | RTL Implication |
|------|-----------|--------------|-----------------|
| D1 Duplicate skip | Not implemented | Implemented | Real hardware likely skips; implement for accuracy |
| D2 Scanline lookahead | Not modeled | 1-line ahead | Required for cycle-accurate RTL |
| D3 Scan granularity | Per-frame | Per-scanline (HBlank) | RTL must be per-scanline |
| D4 ROM address | Same info, 23-bit | Same info, 20-bit | No difference |
| D5 Priority mechanism | Backward scan + overwrite | Forward scan + first-wins | Same result; forward + first-wins preferred for RTL |
| D6 vsub for multi-row | Implicit | Explicit formula | RTL must implement vsub formula explicitly |
| D7 Y sign extension | Not explicit | 9→10-bit sign extend | Required for correct wrap-from-top behavior |
| D8 DMA timing | Instantaneous | Pipelined per-HBlank | RTL needs HBlank-pipelined DMA model |
| D9 X offset -1 | Not present | -1 pipeline correction | Account for pipeline delay in hpos routing |
