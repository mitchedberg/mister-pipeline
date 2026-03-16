# TC0110PCR — Section 1: Chip Target & Register Map

## Chip Identification

```
Target chip:       TC0110PCR (Taito Custom)
Arcade system:     Taito F2 (early boards: K1100432A / J1100183A)
Chip function:     Palette RAM with CPU address latch interface (palette DAC controller)
Clock frequency:   ~16 MHz system clock (writes synchronous; reads registered on pixel clock)
Package / process: PLCC or QFP custom ASIC, ~1988
MAME source file:  src/mame/taito/tc0110pcr.cpp
FBNeo source:      src/burn/drv/taito/tc0110pcr.cpp
Games using it:    Final Blow, Quiz Torimonochou, Quiz H.Q., Mahjong Quest
                   (early Taito F2 boards before TC0260DAR became standard)
```

Known signals (from MAME source + FBNeo emulation):
```
  - CLK (in, 1-bit): master clock
  - /RST (in, 1-bit): active-low async reset
  - CS (in, 1-bit): CPU chip select (active-high)
  - WR (in, 1-bit): CPU write strobe
  - A0 (in, 1-bit): register select (0 = address latch, 1 = data)
  - D[15:0] (in, 16-bit): CPU data bus (word-wide access)
  - Q[15:0] (out, 16-bit): CPU read data bus
  - PXLIN[11:0] (in, 12-bit): pixel color index from sprite/tilemap compositor
  - R[4:0] (out, 5-bit): red DAC output
  - G[4:0] (out, 5-bit): green DAC output
  - B[4:0] (out, 5-bit): blue DAC output
  - PXLVLD (in, 1-bit): pixel input valid (color_out registered one cycle later)
```

## Register Map

The TC0110PCR exposes a 2-register CPU interface (selected by A0):

| A0 | Access | Name       | Description                                      |
|----|--------|------------|--------------------------------------------------|
| 0  | W      | ADDR_LATCH | Sets palette RAM address: addr = (data >> 1) & 0xFFF |
| 0  | R      | DATA_READ  | Returns current entry: PalRam[addr]             |
| 1  | W      | DATA_WRITE | Writes color entry: PalRam[addr] = data[15:0]  |
| 1  | R      | DATA_READ  | Returns current entry: PalRam[addr] (same as A0=0 read) |

**Address latch decode (standard mode):**
- `addr = (cpu_data >> 1) & 0xFFF`
- Range: 0 to 4095 (0x000..0xFFF)
- The shift-by-1 aligns 16-bit word addresses to the chip's internal 12-bit address space

## Palette RAM

- **Size:** 4096 entries × 16 bits = 8 KB
- **Address:** 12-bit (0x000..0xFFF)
- **Color format:** `{B[4:0], G[4:0], R[4:0]}` = 15-bit color packed in 16-bit word
  - bits [4:0]  = R (red, 5-bit)
  - bits [9:5]  = G (green, 5-bit)
  - bits [14:10] = B (blue, 5-bit)
  - bit [15]    = unused (always 0)

## Color Index Mapping

For Taito F2 games using TC0110PCR:
- Sprites: 6-bit COLOR attribute (bits [13:8] in ATTR word) selects which palette (0..63), plus 4-bit pixel nibble
  → 12-bit index = {COLOR[5:0], pixel_nibble[3:0], 2'b00} or similar game-specific mapping
- Tilemap (TC0100SCN BG layers): 3-bit color × 4-bit pixel → game-specific index

The exact mapping from sprite/tilemap pixel to palette index is game-specific and handled
by the compositor (TC0360PRI or CPU-side blitting). The TC0110PCR just stores colors and
provides indexed lookup.

## Timing Parameters

```
  Palette RAM write latency: 1 clock cycle (synchronous write)
  Color lookup latency:      1 clock cycle (registered output, pxl_in→color_out)
  CPU read latency:          1 clock cycle (registered output)
```

## Hardware Notes

1. **No auto-increment:** Each CPU write to DATA_WRITE writes to the current address.
   The CPU must manually re-latch the address to advance.
2. **Address latch persists:** addr is held until the next write to ADDR_LATCH (A0=0).
3. **No priority logic:** TC0110PCR is purely palette storage + color DAC. Priority
   mixing is handled externally (TC0360PRI or TC0110PCR companion functions — see notes).
4. **In early F2 games, TC0110PCR also has priority mixer functionality** exposed via
   separate address ranges (not yet documented; not needed for basic sprite rendering).
5. **Address-latch variant:** Some games (Asuka) use "Step 1" addressing where
   `addr = data & 0xFFF` (no shift). Implemented as parameter `STEP_MODE`.
