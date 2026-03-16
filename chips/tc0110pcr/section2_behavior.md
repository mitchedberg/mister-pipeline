# TC0110PCR — Section 2: Behavioral Specification

## Source Reference

- FBNeo: `src/burn/drv/taito/tc0110pcr.cpp` (Nicola Salmoria, ported by dink)
- MAME: `src/mame/taito/tc0110pcr.cpp`

## Core Function

The TC0110PCR is a palette RAM chip. It stores 4096 × 15-bit RGB color entries and provides:
1. **CPU write path:** The CPU writes palette entries via a 2-register address-latch + data interface.
2. **Video read path:** The video compositor passes a 12-bit pixel color index; the chip returns the corresponding RGB color for DAC output.

The chip has NO sprite generation, NO tilemap logic, and NO priority mixing.

## CPU Interface Behavior

### Address Latch (A0 = 0, write)

```
// Standard mode (STEP_MODE = 0, used by most F2 games):
addr_reg <= (cpu_data >> 1) & 12'hFFF;

// Step-1 mode (STEP_MODE = 1, used by Asuka/Mofflott):
addr_reg <= cpu_data & 12'hFFF;
```

The address is latched and held. It does NOT auto-increment after data writes.

### Data Write (A0 = 1, write)

```
pal_ram[addr_reg] <= cpu_data[15:0];
```

The lower 15 bits encode the color. Bit 15 is stored but ignored by the DAC.

### Data Read (A0 = 0 or A0 = 1, read)

```
cpu_dout <= pal_ram[addr_reg];
```

Registered output, 1-cycle latency. Returns the full 16-bit word at addr_reg.

## Color Format

```
pal_ram[addr][14:10] = Blue  (5-bit)
pal_ram[addr][ 9: 5] = Green (5-bit)
pal_ram[addr][ 4: 0] = Red   (5-bit)
pal_ram[addr][15]    = unused (read back as stored)
```

### DAC expansion (5-bit to 8-bit):
MAME `pal5bit()` formula: `(bits & 0x1F) << 3 | (bits & 0x1F) >> 2`
This scales 0..31 to 0..255 with proper rounding.

For FPGA DAC output (5-bit), the palette entry is used directly as the 5-bit per-channel output.

## Video Color Lookup

When a video pixel arrives:
1. `pxl_in[11:0]` is the 12-bit palette index (from sprite or tilemap compositor).
2. Next clock: `color_out[14:0] = pal_ram[pxl_in][14:0]` = {B[4:0], G[4:0], R[4:0]}.
3. The color is split into `r[4:0]`, `g[4:0]`, `b[4:0]` for DAC output.

**Transparent pixel handling:** Pixel index 0 is conventionally transparent (mapped to
background color). The compositor decides which pixels to pass to the palette chip —
TC0110PCR renders ALL indices it receives. The transparency decision is upstream.

## State Machines

The TC0110PCR has no state machine. It is purely combinational/single-cycle registered:
- Write path: 1 clock write to palette RAM
- Read path: 1 clock registered output
- Lookup path: 1 clock registered lookup

## Palette RAM Organization (4096 entries × 16 bits)

For Taito F2, palette indices are typically organized as:
```
Index [11:6] = color_code (6 bits = 64 palettes of 16 colors each)
Index [5:2]  = pixel nibble (4 bits = 16 colors per palette)
Index [1:0]  = layer (2 bits — optional, game-specific)
```
This gives 64 × 16 = 1024 entries per usage (sprites, bg0, bg1, fg0), 4 usages = 4096 total.

## No Auto-Increment (verified from FBNeo)

The address register does NOT increment. The CPU explicitly sets address before each write.

## Reset Behavior

On reset:
- `addr_reg` → 0
- `pal_ram` is NOT cleared (retains indeterminate values; CPU must initialize)
- `cpu_dout` → 0
- `color_out` → 0

## Interaction with Adjacent Chips

```
CPU (68000) --[A0, CS, WR, D[15:0]]--> TC0110PCR --[R,G,B DAC 5-bit each]--> Video output
TC0100SCN --[layer pixel 12-bit]--> TC0110PCR
TC0200OBJ --[sprite pixel 12-bit]--> TC0110PCR
TC0360PRI --[composited pixel 12-bit]--> TC0110PCR (in later F2 games)
```

In early F2 (no TC0360PRI), the compositor may be embedded in CPU code or a simpler
priority scheme where layers are blended in a fixed order.

## Implementation Notes for RTL

1. **Palette RAM** uses `altsyncram` (section4b pattern) — size: 4096 × 16-bit = 32KB → fits
   in M10K (each M10K is 10Kbits; 3.27 M10Ks needed → use 4 M10Ks or one 32K simple DP RAM).
   For Verilator simulation, use a flat `logic [15:0] pal_ram [0:4095]`.

2. **Dual port:** CPU write port (synchronous to `clk`) + video read port (registered, also
   on `clk`). Single clock domain — no CDC needed.

3. **CPU read:** Mux between pal_ram registered read and a registered latch of cpu_dout.
   Since palette RAM is single-cycle, cpu_dout registered from the RAM read pipeline is fine.

4. **Color output:** Split the registered palette entry into r[4:0], g[4:0], b[4:0] outputs
   (combinational split from the registered `color_out` register).
