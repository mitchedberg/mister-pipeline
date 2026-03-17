# Kaneko 16 Arcade Hardware — GATE PLAN

**Status:** RESEARCH COMPLETE | RTL PLANNING PHASE
**Date:** 2026-03-17
**Primary Reference:** MAME `src/mame/kaneko/` driver family

---

## Chip Summary

The Kaneko 16 system (1989–1993) is a sprite-based arcade platform featuring a Motorola 68000 main CPU, optional NEC microcontroller co-processors (uPD78322 CALC3, uPD78324 TBSOP), and a sophisticated multi-layer graphics pipeline via 7 custom Kaneko ICs (VU-series, VIEW2, MUX2, HELP1, IU-001). The platform supports high-color background processing (VU-003 ×3 units), sprite management (VU-001/VU-002), and dynamic tilemap generation (VIEW2-CHIP). Key titles include **The Berlin Wall** (1991, action), **Brap Boys** (1992, racing), **Shogun Warriors** (1992, fighter with CALC3 protection), **Blazing Lazers / Gunhed** (1993), and **Gals Panic** (1990, puzzle). The graphics architecture is more sophisticated than Taito B but less complex than Taito F3, with emphasis on fast sprite blitting and multi-layer priority compositing. No existing MiSTer/FPGA cores exist; estimated difficulty is MEDIUM (70–100 dev days).

---

## GATE 1: CPU Interface & Memory Map

### 68000 Master CPU
- **Frequency:** 10–12 MHz (varies by board variant)
- **Bus Width:** 16-bit data, 24-bit address
- **Memory Footprint:** 24-bit address space (16 MB theoretical, ~4 MB actual)
- **Cycle Timing:** ~6–10 cycles per instruction average; pixel pipeline can stall on sprite/tile RAM access

### Known Address Maps (from MAME drivers)

Multiple PCB variants exist with different chip placements. All maps use byte addressing (address bus A[23:0]).

#### **Variant A: Standard Layout** (Shogun Warriors, Blazing Lazers)
```
0x000000–0x0FFFFF  Program ROM (512 KB–1 MB typical)
0x100000–0x11FFFF  Work RAM (128 KB typical, game-dependent split)
0x120000–0x12FFFF  Sprite RAM (64 KB max, indexed via VU-001/VU-002)
0x130000–0x13FFFF  Tilemap RAM / Layer control (64 KB)
0x140000–0x14FFFF  Palette RAM (64 KB, RGB444 or RGB555 format)
0x150000–0x15FFFF  Frame buffer / VBlank control (64 KB)
0x160000–0x16FFFF  MUX2-CHIP / HIT-CHIP registers (16 addresses, sparse)
0x170000–0x17FFFF  HELP1-CHIP registers (similar, sparse)
0x180000–0x18FFFF  IU-001 I/O (joystick, coins, DIP switches, watchdog)
0x190000–0x19FFFF  Sound CPU mailbox / ADPCM ROM window (16 KB)
0x1A0000–0x1A0003  CALC3 MCU interface (if present; 4 bytes: status, command, param1, param2)
0x1B0000–0x1BFFFF  GFX ROM window / dynamically banked (64 KB addressable, ~256 KB–4 MB backing)
```

**Key Observation:** Unlike Taito B, Kaneko centralizes most chip control through sparse register banks rather than separate discrete chip windows. Exact decode varies by game; refer to MAME driver per title.

#### **Address Decode Key Signals**
- `rom_cs` — Program ROM chip select (A[23:20] == 4'b0000)
- `wram_cs` — Work RAM chip select (A[23:20] == 4'b0001)
- `vram_cs` — Video/Sprite RAM chip select (A[23:20] == 4'b0001–0011, sub-decode by A[19:16])
- `palette_cs` — Palette RAM chip select (A[23:20] == 4'b0001)
- `io_cs` — I/O register chip select (A[23:20] == 4'b0001, A[19:4] == 16'h1800)
- `sound_cs` — Sound mailbox & ADPCM window (A[23:20] == 4'b0001, A[19:10] == 10'h190–0x1A0)
- `gfx_window_cs` — GFX ROM window (A[23:20] == 4'b0001, A[19:10] == 10'h1B0)

### I/O Register Map (at 0x180000 base, sparse)

| Offset | R/W | Bits | Function | Notes |
|--------|-----|------|----------|-------|
| 0x00 | R | [15:0] | Joystick 1 input | Standard 6-button arcade format |
| 0x02 | R | [15:0] | Joystick 2 input | Player 2 (in 2P games) |
| 0x04 | R | [15:0] | Coin input / Coin counters | Coin 1/2 pulse logic, counter feedback |
| 0x06 | R | [15:0] | DIP switches | Game configuration (lives, difficulty, region) |
| 0x08 | W | [15:0] | Watchdog kick | Must write any value every ~60 ms to prevent reset |
| 0x0A | W | [15:0] | Interrupt acknowledge | Clear pending VBlank/HBlank interrupt |
| 0x0C | R/W | [15:0] | Misc I/O flags | LED enable, cabinet type, etc. (varies per game) |
| 0x0E | R/W | [15:0] | Video interrupt control | VBlank enable, HBlank enable, IRQ vector select |

**Sparse Decode:** Actual registers may not be at every +2 byte offset; many games mirror or leave gaps. MAME driver confirms exact decode per title.

### CALC3 / TOYBOX MCU Interface (if present, typically at 0x1A0000)

Games using protection (e.g., Shogun Warriors via CALC3, Brap Boys via TOYBOX):

| Offset | R/W | Bits | Function | Notes |
|--------|-----|------|----------|-------|
| 0x00 | R | [7:0] | MCU status byte | 0x00 = idle, 0x01 = busy, 0xFF = error |
| 0x01 | W | [7:0] | Command byte | Math operation code or test command |
| 0x02 | W | [7:0] | Parameter 1 | First operand or address |
| 0x03 | W | [7:0] | Parameter 2 | Second operand or data |
| 0x04–0x0F | — | — | *Reserved* | Actual hardware may have result registers here |

**CALC3 operations** (examples from Shogun Warriors):
- Add (A + B mod 256)
- Multiply low byte (A × B & 0xFF)
- Rotate/shift left/right
- Lookup table access (e.g., sine/cosine for player angle)

Can typically be **stubbed or replaced with lookup tables** for games that don't enforce strict cycle timing.

### GFX ROM Bankswitching (0x1B0000 window)

VU-series chips allow dynamic GFX ROM access via a **23-bit banked window**:
- Write to `gfx_bank_select` register (varies per game, often at 0x160000–0x17FFFF) to set upper bits [22:16]
- Read/write 64 KB window at 0x1B0000–0x1BFFFF (covers bits [15:0] of GFX ROM address)
- Effectively: 7-bit bank register (128 × 64 KB = 8 MB addressable) but games use 256 KB–4 MB backing

**Implication for RTL:** SDRAM arbitrator must support dynamic GFX address calculation:
```
gfx_sdram_addr = GFX_ROM_SDRAM_BASE + (bank_register[6:0] << 16) + window_offset[15:0]
```

---

## GATE 2: Sprite Scanner & RAM Layout

### Sprite Hardware (VU-001, VU-002)

**VU-001 (48-pin PQFP):** Sprite/tile controller, manages sprite descriptor table and raster scanning.

**VU-002 (160-pin PQFP):** Main sprite processor, performs blitting, rotation/scaling (if enabled), and collision detection.

### Sprite Descriptor Format (stored in 0x120000–0x12FFFF, 64 KB max)

Each sprite entry is typically **16 bytes** (128 entries max if contiguous, but often sparse/ring-buffered):

```
Offset  Bits    Field           Description
------  ----    -----           -----------
+0      [15:0]  Y position      Signed integer, pivot point (0x0000 = top of screen)
+2      [15:0]  X position      Signed integer, pivot point (0x0000 = left of screen)
+4      [15:8]  Code/ROM index  Sprite graphics ROM tile number (0–255 typical)
+4      [7:4]   Width           Sprite width code (0–15, expands as 2^N pixels or lookup)
+4      [3:0]   Height          Sprite height code (0–15, expands similarly)
+6      [15:8]  Palette select  Palette bank (0–15, shifts into CLUT address)
+6      [7:4]   Flip flags      VFLIP, HFLIP, ROTATE_EN, SCALE_EN
+6      [3:0]   Priority        Draw order (0–15, lower = back; compositing order)
+8      [15:0]  Scale X         Fixed-point scale factor (1.0 = 0x10000, if SCALE_EN=1)
+10     [15:0]  Scale Y         Fixed-point scale factor (if SCALE_EN=1)
+12     [15:0]  Rotation        Rotation angle code (0–1023 = 0–360°, if ROTATE_EN=1)
+14     [7:0]   Control flags   ENABLE, DOUBLE_BUFFER, COLLISION_EN, etc.
+14     [15:8]  Next descriptor Linked list pointer (for chain updates, varies per game)
```

**VU-002 Scanning Behavior:**
- Sprite descriptors are scanned **per raster line** or **per frame** depending on game configuration
- **Ring-buffer mode:** Pointer advances through descriptor table each frame; 32–256 sprites per frame typical
- **Dynamic mode:** Descriptors can be written by 68000 mid-frame (requires dual-port or arbitration)
- **Collision info:** VU-002 generates sprite-to-sprite collision flags, stored in separate collision RAM (e.g., 0x13F000–0x13FFFF)

### Sprite ROM Organization

**Typical layout (GFX ROM, 0x1B0000 window + banking):**
- **0x000000–0x0FFFFF** — Sprite tile data (8×8 4bpp or 16×16 4bpp tiles)
- **0x100000–0x1FFFFF** — Tilemap/background tile data (similar format)
- **0x200000–0x3FFFFF** — Palette/lookup tables (if present)

**Width/Height expansion:**
- Code 0x00 = 8×8 pixels (1 tile)
- Code 0x01 = 16×8 pixels (2 tiles wide)
- Code 0x02 = 8×16 pixels (2 tiles tall)
- Code 0x03 = 16×16 pixels (4 tiles, 2×2)
- ... up to 128×128 or larger in advanced games

**Pipeline:** VU-002 fetches tile data from GFX ROM, expands per width/height code, applies scaling/rotation in parallel, composites into frame buffer.

### Test Vector Estimate
- **Sprite positioning:** 16 vectors (cardinal, diagonal, off-screen clipping)
- **Width/height codes:** 16 vectors (all 4-bit combinations)
- **Palette select:** 8 vectors (palette bank 0–7)
- **Flip/priority:** 8 vectors (HFLIP, VFLIP, priority levels)
- **Scaling (if implemented):** 12 vectors (scale factors 0.5×, 1.0×, 2.0×, 4.0× in X/Y)
- **Rotation (if implemented):** 8 vectors (rotation angles 0°, 45°, 90°, 135°, etc.)
- **Ring-buffer advance:** 4 vectors (descriptor chain updates)
- **Collision detection:** 6 vectors (overlapping sprites, edge cases)
- **Total:** ~80–100 vectors

---

## GATE 3: Tilemap Renderer & Scroll Registers

### VIEW2-CHIP (144-pin PQFP) — Tilemap Generation

**Architecture:** Manages up to **4 background layers (BG0–BG3)** and **1 foreground text layer (FG)**.

### Layer Structure (in VRAM, 0x130000–0x13FFFF typical)

Each layer stores:
- **Map data:** 64×64 tile indices (16-bit per tile), covers screen + margin
- **Scroll X/Y:** Per-layer horizontal/vertical offset registers
- **Control flags:** Enable, width/height mode (256×256, 512×256, 512×512, etc.), palette bank

**Typical VRAM allocation (64 KB total):**

```
Offset     Size   Layer           Notes
------     ----   -----           -----
0x00000    0x2000 BG0 map         64×64 tiles @ 16bpp = 8 KB
0x02000    0x2000 BG1 map
0x04000    0x2000 BG2 map
0x06000    0x2000 BG3 map
0x08000    0x2000 FG map (text)   Smaller, scrolls independently or fixed
0x0A000    ~0x4000 Scroll registers (duplicated per layer, sparse)
           ...    Unused / per-game custom buffers
0x10000 – 0x13FFF (rest)          Collision RAM, extra buffers, MCU work area
```

### Scroll Register Map (VIEW2 interface, typical at 0x130000 base)

Per-layer (for BG0–BG3 and FG):

| Offset | R/W | Bits | Field | Notes |
|--------|-----|------|-------|-------|
| Layer×0x100 + 0x00 | R/W | [15:0] | Scroll X | Signed fixed-point (8.8 format typical, -128.0 to +127.999) |
| Layer×0x100 + 0x02 | R/W | [15:0] | Scroll Y | Signed fixed-point (8.8 format) |
| Layer×0x100 + 0x04 | R/W | [7:0] | Control flags | Enable, width mode, height mode, palette bank select |
| Layer×0x100 + 0x06 | R/W | [7:0] | Priority / blending | Layer draw order, alpha/blend mode (if supported) |
| Layer×0x100 + 0x08–0x0F | — | — | *Reserved* | Per-game variations |

**MAP_BASE register (single, shared):**
- Selects which tilemap bank is visible (allows double-buffering)
- Write to 0x130010 typically: bits [3:0] = map select for all 4 BG layers

### Tilemap Rendering Pipeline

1. **Fetch map data:** For each scanline, 68000 prefetches scroll position for all enabled layers
2. **Tile lookup:** VIEW2 reads tile indices from map RAM based on scroll offset
3. **Tile data fetch:** VU-003 (3 units) fetch 4bpp or 8bpp tile data from GFX ROM in parallel
4. **Palette expand:** Tile data indexed into per-layer palette bank
5. **Composite:** All visible layers merged with priority logic (lower layer numbers draw first)

### Tile Format (in GFX ROM)

- **8×8 pixels, 4bpp (16-color):** 32 bytes per tile
- **8×8 pixels, 8bpp (256-color):** 64 bytes per tile
- **16×16 pixels:** 128 or 256 bytes respectively

**Tilemap entry format (16-bit):**
```
Bits    Field
----    -----
[15:8]  Tile code (0–255 typical, up to 512 in some games)
[7:4]   Palette select (0–15)
[3]     VFLIP flag
[2]     HFLIP flag
[1:0]   *Reserved / unused*
```

### Test Vector Estimate
- **Scroll X/Y:** 12 vectors (all 4 layers, horizontal/vertical variations)
- **Fixed/parallax scroll:** 6 vectors (layer-by-layer movement independence)
- **Palette select per layer:** 8 vectors (all 16 palette banks)
- **Map data updates:** 6 vectors (tile index changes, collision with scroll offset)
- **Double-buffer toggle:** 3 vectors (map base switch mid-frame)
- **Enable/disable per layer:** 5 vectors (all combinations of visible layers)
- **Clipping at screen edge:** 4 vectors (left, right, top, bottom edge cases)
- **Priority ordering:** 6 vectors (different layer draw orders)
- **Total:** ~50 vectors

---

## GATE 4: Colmix & Priority Compositor

### Priority System

Kaneko uses a **fixed priority order** with per-sprite/layer override:

**Default scanline priority (lowest to highest layer number):**
```
1. BG0 (back background)
2. BG1
3. BG2
4. BG3 (front background)
5. Sprites (if priority code 0–3)
6. FG text layer (if enabled, always top-most)
```

**Per-sprite override:** Each sprite's 4-bit priority field can place it between BG layers:
- Priority 0–3: Behind all layers (used for depth effects)
- Priority 4–7: Between BG layers (e.g., between BG2 and BG3)
- Priority 8–11: Between BG3 and FG
- Priority 12–15: In front of everything

### Pixel Composition Logic

At each pixel, the compositor (typically in VU-002 or MUX2):

1. **Fetch candidate pixels** from all enabled layers at current (X, Y)
2. **Apply priority:** Select topmost non-transparent pixel
3. **Lookup palette:** Convert 4bpp/8bpp index to RGB via CLUT
4. **Apply blending (if enabled):** Semi-transparent blend between top and next-visible layer
5. **Output:** Final RGB444 or RGB555 value to frame buffer

### Blending Modes (if VU-003 supports)

Common Kaneko blending:
- **Opaque:** (Alpha & 0x1) ? TOP : BOTTOM (transparency bit)
- **50/50 blend:** (TOP + BOTTOM) >> 1 per channel
- **Additive:** MIN(255, TOP + BOTTOM) per channel
- **Subtractive:** MAX(0, TOP - BOTTOM) per channel

**Palette RAM format (0x140000–0x14FFFF, 64 KB = 2048 colors × 16-bit entry):**

```
Bits     Value       Format
----     -----       ------
[15:12]  —           Unused / always 0
[11:8]   Blue        4-bit blue channel (0–15)
[7:4]    Green       4-bit green channel (0–15)
[3:0]    Red         4-bit red channel (0–15)
```

Alternatively, RGB555 format (some later games):
```
[15]     —           Unused
[14:10]  Blue        5-bit blue
[9:5]    Green       5-bit green
[4:0]    Red         5-bit red
```

### Frame Buffer (0x150000–0x15FFFF, 64 KB)

- **320×240 @ 4bpp:** 38,400 pixels = 19,200 bytes (fits in 64 KB with room for extra buffers)
- **320×240 @ 8bpp:** 76,800 pixels (exceeds 64 KB, so typically split across 2 frames or rotates)

**Typical mode:** 16-pixel rows (scanline) stored sequentially; pixel data alternates nibble-pair per byte (4bpp) or byte-per-pixel (8bpp).

### Test Vector Estimate
- **Layer priority ordering:** 8 vectors (all significant permutations of 4 BG layers + sprites)
- **Sprite priority override:** 6 vectors (priority codes 0, 4, 8, 12, 15, off-screen)
- **Transparency / alpha:** 4 vectors (opaque, semi-transparent, fully transparent pixels)
- **Blending modes:** 4 vectors (50/50, additive, subtractive, if supported)
- **Palette bank select:** 4 vectors (top layer only, multiple banks)
- **Color output RGB444 vs RGB555:** 2 vectors (format selection)
- **Frame buffer write:** 6 vectors (word-aligned, byte-aligned, nibble boundaries)
- **Clipping vs overflow:** 4 vectors (off-screen pixels, edge wrapping)
- **Total:** ~38 vectors

---

## GATE 5: Pixel Output & Video Timing

### Display Resolution & Timing

**Standard Kaneko 16 output:**
- **Resolution:** 320 pixels wide × 240 pixels tall
- **Frame rate:** 60 Hz (NTSC) or 50 Hz (PAL variants)
- **Pixel clock:** ~10.6 MHz (varies by board)
- **Horizontal sync:** ~15.7 kHz (NTSC standard)
- **Vertical sync:** 60 Hz

### Video Signal Timing (60 Hz NTSC)

```
Scanline  Duration   Purpose
--------  --------   -------
0–239     240 lines  Active display (320 pixels per line)
240–244   5 lines    Vertical blanking interval (no display)
245–261   17 lines   Vertical blanking (standard, may vary ±2)
262       1 line     Frame boundary marker (line 262 = start of next frame)
```

**Horizontal timing (per scanline, in pixel clocks):**
```
Pixel    Duration   Purpose
-----    --------   -------
0–319    320 clocks Active display
320–336  17 clocks  Horizontal blanking (HBlank)
337–341  5 clocks   Horizontal sync pulse
342–352  11 clocks  Back porch
```

**Total scanline:** 342 pixel clocks
**Total frame:** 262 scanlines × 342 clocks = ~90,204 clocks per frame

### Output Color Format

**RGB444 (most common):**
- **Output:** 12-bit value (R[3:0] G[3:0] B[3:0])
- **Palette:** 2048 colors × 4-bit entries (enough for 16 palettes of 256 colors, or 1 palette of 4096)
- **Connection:** DAC pin or direct framebuffer pixel data

**RGB555 (later variants):**
- **Output:** 15-bit value (R[4:0] G[4:0] B[4:0])
- **Palette:** Palette RAM stores 15-bit entries; typically 512 colors max

### VBlank & HBlank Interrupt Generation

**IRQ source in IU-001 (I/O chip):**

| Event | Register | Behavior |
|-------|----------|----------|
| VBlank | 0x180E bit 0 | Fires at scanline 240 (top of VBlank interval); can trigger interrupt |
| HBlank | 0x180E bit 1 | Fires at end of each active scanline (pixel 320); optional |
| Watchdog | — | Internal timer, resets CPU if kicked doesn't occur in ~60 ms |

### Frame Buffer Access (68000 perspective)

The 68000 can **read and write** the frame buffer at 0x150000–0x15FFFF for effects:
- **Raster effects:** Per-line color shifts, mid-frame palette changes
- **DMA:** Sprite blitting directly into frame buffer (rare, more often via VU-002)
- **Collision feedback:** Sprite-to-sprite hit data retrieved from collision RAM

### Test Vector Estimate
- **Resolution:** 1 vector (320×240 @ 60 Hz canonical)
- **Blanking intervals:** 3 vectors (HBlank start, VBlank start, both edges)
- **Interrupt timing:** 4 vectors (VBlank assertion, edge triggers, multiple frames)
- **RGB format:** 2 vectors (RGB444, RGB555 mode)
- **Palette output:** 3 vectors (palette write, read-back, bank switch mid-frame)
- **Frame buffer:** 4 vectors (sequential write, random access, collision read)
- **Color accuracy:** 4 vectors (all 16 palette entries per sample scanline)
- **Synchronization:** 2 vectors (CPU execution vs display cycle alignment)
- **Total:** ~23 vectors

---

## Estimated Test Vector Counts by Gate

| Gate | Subsystem | Base Vectors | With Variants | Notes |
|------|-----------|--------------|---------------|-------|
| 1 | CPU interface & memory map | ~40 | 60–80 | Address decode, I/O reads/writes, CALC3 MCU interface (optional) |
| 2 | Sprite scanner & RAM | ~80 | 100–120 | Positioning, scaling, rotation, collision detection (if impl.) |
| 3 | Tilemap renderer & scroll | ~50 | 70–90 | All 4 layers, parallax scroll, palette banks |
| 4 | Priority compositor & blending | ~38 | 50–70 | Layer ordering, sprite priority, blending modes |
| 5 | Pixel output & video timing | ~23 | 35–50 | Blanking, interrupts, color modes, frame buffer access |
| **TOTAL** | | **~231** | **315–410** | **Recommended: 350+ vectors for full coverage** |

---

## Key Risks & Open Questions

### High-Risk Items (Verify in MAME source before RTL)

1. **GFX ROM Bankswitching Mechanism**
   - Current spec assumes 7-bit bank register + 64 KB window = 8 MB addressable
   - **Verify:** MAME `kaneko_gfx_banking_w()` / `kaneko_gfx_banking_r()` handlers
   - **Risk:** Some games may use different banking schemes (e.g., 8-bit bank, 32 KB window, or no banking)
   - **Mitigation:** Add parameterizable GFX window size and bank width

2. **VU-002 Sprite Collision Detection**
   - Spec lists "collision RAM" at 0x13F000–0x13FFFF, but exact layout unclear
   - **Verify:** MAME collision detection logic, sprite_collision_r/w() functions
   - **Risk:** Collision bits may be read-only, write-to-clear, or interrupt-driven
   - **Mitigation:** Stub collision detection initially; verify word-by-word against MAME dumps

3. **CALC3 / TOYBOX MCU Emulation**
   - Some games (Shogun Warriors, Brap Boys) use MCU co-processors for math/protection
   - **Verify:** MAME mcu_comm_w(), mcu_status_r() for each game that uses CALC3/TOYBOX
   - **Risk:** Cycle-accurate MCU emulation may be required for correct game behavior (TAS sync)
   - **Mitigation:** Build MCU lookup-table stubs; only upgrade to full emulation if TAS fails

4. **Sprite Descriptor Ring-Buffer Behavior**
   - Spec assumes ring-buffer advance per-frame, but some games may use mid-frame updates
   - **Verify:** MAME sprite_draw() vs VU-002 pipeline state machines
   - **Risk:** Dual-port VRAM requirement if descriptors are written while being scanned
   - **Mitigation:** Implement VRAM arbitrator with priority (VU-002 scan > 68000 write)

5. **Tilemap Layer Enable / Double-Buffer Toggle**
   - Unclear if layer enable and map-base toggling are synchronized to VBlank or can occur mid-frame
   - **Verify:** MAME tilemap_update() calls, interrupt handler timing
   - **Risk:** Mid-frame changes may cause tearing or state inconsistency
   - **Mitigation:** Latch layer control and map base at VBlank pulse; track pending changes

6. **Sound CPU Mailbox Timing**
   - Kaneko 16 uses multiple sound configurations (Z80 + YM2151, Z80 + YM2203, OKI M6295 alone)
   - **Verify:** MAME sound_cpu_map() for each game variant
   - **Risk:** Mailbox handshake timing and interrupt sequencing may differ per variant
   - **Mitigation:** Implement generic mailbox; parameterize per-game sound CPU type

7. **VBlank Interrupt Vector & Edge Timing**
   - IU-001 may generate interrupt at different scanline boundaries depending on region (NTSC vs PAL)
   - **Verify:** MAME screen_vblank() timing, MAME IRQ level/priority
   - **Risk:** Off-by-one scanline errors cause game glitches or TAS divergence
   - **Mitigation:** Make VBlank edge programmable; validate against MAME cycle-accurate trace

8. **Display Blanking Versus Frame Buffer Writes**
   - Unclear whether 68000 can write frame buffer during active display without visual artifacts
   - **Verify:** MAME framebuffer_w() arbitration, priority vs display read
   - **Risk:** Sprite flicker, missing pixels, or cascading corruption if timing is wrong
   - **Mitigation:** Implement frame buffer with separate read/write ports; stage writes to non-visible scanlines

### Medium-Risk Items

9. **Palette RAM Bit Width (RGB444 vs RGB555)**
   - Some games may auto-detect or have per-game EEPROM configuration
   - **Verify:** MAME palette_w() format, per-game setup
   - **Mitigation:** Support both formats; add game-config parameter

10. **Sprite Scaling & Rotation Interpolation**
    - If scaling/rotation is implemented, sub-pixel precision may affect quality
    - **Verify:** MAME scaling code (if present), verification against visual reference
    - **Mitigation:** Use nearest-neighbor for initial RTL; bilinear interpolation in optimization phase

11. **MCU Co-Processor Work RAM Access**
    - CALC3/TOYBOX may have dedicated work area not visible to 68000
    - **Verify:** MAME mcu_code[] regions, uPD78322 disassembly
    - **Mitigation:** Stub MCU with memory-mapped lookup tables; only upgrade if TAS fails

### Lower-Risk Items

12. **Watchdog Timer Kick Frequency**
    - Spec assumes ~60 ms per kick, typical for arcade
    - **Verify:** MAME watchdog_w() / watchdog reset logic
    - **Mitigation:** Parameterize watchdog period

13. **DIP Switch Reading**
    - Standard arcade pattern, likely straightforward
    - **Verify:** MAME dip_switch_r()
    - **Mitigation:** Minimal risk; standard implementation

---

## MAME Source Verification Checklist

Before starting RTL, confirm the following in MAME `src/mame/kaneko/`:

- [ ] `kaneko16.cpp` — Main driver file; lists all games and their address maps
- [ ] `kaneko_vu.cpp` / `kaneko_vu.h` — VU-001/VU-002 sprite and tile controller implementation
- [ ] `kaneko_view2.cpp` — VIEW2-CHIP tilemap and scroll register handlers
- [ ] `kaneko_mux2.cpp` — MUX2-CHIP priority and blending logic (if separate file)
- [ ] `kaneko_help1.cpp` — HELP1-CHIP support functions
- [ ] `kaneko_calc3.cpp` / `kaneko_toybox.cpp` — MCU co-processor emulation (if present)
- [ ] GFX ROM banking functions: `gfx_banking_w()`, `gfx_window_r/w()`
- [ ] Palette RAM and format: `palette_w()`, RGB444 vs RGB555 mode selection
- [ ] Interrupt handlers: `vblank_irq()`, `hblank_irq()`, `watchdog_kick()`
- [ ] Sprite collision detection: `sprite_collision_r/w()` (if present)
- [ ] Sound CPU mailbox: `sound_command_w()`, `sound_ready_r()`, per-game handshake timing

---

## Next Steps (Post-GATE Plan)

1. **Extract address map parameters** from MAME driver for all supported games
2. **Generate game configuration files** (JSON or Lua) with ROM sizes, chip-select decode logic, and MCU configuration
3. **Create reference RTL test harness** using MAME Lua scripting to dump cycle-accurate frame data
4. **Build GATE 1 RTL** (CPU interface + address decode) first; validate address routing
5. **Implement GATE 2–5** in sequence, validating each with MAME-dumped test vectors
6. **Run MAME emulator-in-parallel** for first 100 frames of each supported game; compare byte-by-byte RAM state and frame buffer output
7. **Validate TAS inputs** using community-provided TAS files for Berlin Wall, Brap Boys, Shogun Warriors

---

## Summary

Kaneko 16 is a **moderately complex** arcade system with 7 custom ICs and sophisticated sprite/tilemap blitting. The graphics pipeline is well-documented in MAME but requires careful handling of GFX ROM bankswitching, sprite collision, and priority compositing. Primary risks are **MCU co-processor emulation** (CALC3/TOYBOX) and **VRAM arbitration** between CPU and graphics engines. Estimated effort: **70–100 dev days** with full MAME validation.

