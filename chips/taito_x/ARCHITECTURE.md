# Taito X System — Deep Architecture Notes

This document captures architectural details extracted from MAME source and research, organized for FPGA implementation.

---

## Block Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    TAITO X SYSTEM (1987)                    │
└─────────────────────────────────────────────────────────────┘

                        ┌─────────────┐
                        │   16 MHz    │
                        │    Osc      │
                        └──────┬──────┘
                               │
                    ┌──────────┼──────────┐
                    │          │          │
                    ÷2         ÷2         (other)
                    │          │          │
             ┌──────▼─────┐   │      ┌────▼─────┐
             │   8 MHz    │   │      │ 4 MHz    │
             │  (68000)   │   │      │  (Z80)   │
             └─────┬──────┘   │      └────┬─────┘
                   │          │           │
        ┌──────────┴──────┐   │    ┌──────┴────────┐
        │                 │   │    │               │
      ┌─▼──────────────────────────────────────┐  │
      │         68000 CPU (8 MHz)               │  │
      │  TMP68000N-8 @ 8 MHz (÷2 from 16 MHz) │  │
      │                                        │  │
      │  Address Bus: A0–A23 (16 MB space)     │  │
      │  Data Bus: D0–D15 (16-bit)             │  │
      │  Interrupts: IPL0–IPL2 (3 vectors)     │  │
      └──────────────┬──────────────┬──────────┘  │
                     │              │             │
                     ▼              ▼             ▼
    ┌────────────────────────────────────────────────┐
    │           68000 Memory Decoder / Glue Logic    │
    │      (handles ROM, RAM, I/O demultiplexing)    │
    └────────────────────────────────────────────────┘
             │              │              │
             ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ Program ROM  │ │  Work RAM    │ │   Palette    │
    │  0x000000    │ │  0x100000    │ │  0xB00000    │
    │  512 KB max  │ │   64 KB      │ │  2048×16bit  │
    └──────────────┘ └──────────────┘ └──────────────┘
             │              │              │
             │              │              ▼
             │              │    ┌─────────────────┐
             │              │    │  X1-007 (Video) │
             │              │    │  RGB Latch+Sync │
             │              │    └────┬────────────┘
             │              │         │
             │              │    ┌────▼─────┐
             │              │    │ Video Out│
             │              │    │ 384×240  │
             │              │    └──────────┘
             │              │
             │              ├────────────────────┐
             │              │                    │
             │              ▼                    ▼
             │    ┌──────────────────┐ ┌────────────────┐
             │    │  Sprite Attr RAM │ │ Sprite Data RAM│
             │    │  0xD00000-0xDxxx │ │ 0xE00000–0xExxx│
             │    │   (Y coords)     │ │  (sprite attrs)│
             │    └──────┬───────────┘ └────┬───────────┘
             │           │                  │
             ▼           ▼                  ▼
    ┌─────────────────────────────────────────────┐
    │        X1-001A + X1-002A Sprite Engine      │
    │                                             │
    │  • Sprite fetcher (reads object RAM)        │
    │  • Graphics ROM address generator           │
    │  • Flip flag logic (H/V)                    │
    │  • Color palette selector (5 bits)          │
    │  • Raster line compositor                   │
    │  • Priority/Z-order handling                │
    └─────────┬───────────────────────────────────┘
              │
              ▼
    ┌─────────────────────────────────────────┐
    │        Sprite/Tile Graphics ROM         │
    │     0xC00000 + (banked, 4 MB max)      │
    │                                         │
    │  Format: 16×16 pixel sprites, 4 bpp    │
    │  (Compression TBD)                      │
    └─────────────────────────────────────────┘
              │
              ▼
    ┌─────────────────────────────────────────┐
    │          Video Output Pipeline          │
    │                                         │
    │  • Framebuffer (384×240, 15-bit RGB)   │
    │  • Horizontal blanking logic            │
    │  • Vertical blanking logic              │
    │  • Sync signal generation (X1-007)      │
    │  • CRT timing (60 Hz)                   │
    └────────────────┬────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
        ▼                         ▼
    (RGB out)              (HSYNC/VSYNC)


    ┌─────────────────────────────────────┐
    │      Z80 Sound CPU (4 MHz)          │
    │     (Sharp LH0080A @ 4 MHz)         │
    │                                     │
    │  • 64 KB sound RAM (0x080000)      │
    │  • Sound ROM (0x090000, 256 KB)    │
    │  • YM2610 or YM2151 registers      │
    │  • Interrupt from 68000 (NMI)      │
    └────────┬────────────────────────────┘
             │
        ┌────┴──────────────────┐
        │                       │
        ▼                       ▼
    ┌──────────────────┐  ┌───────────────┐
    │    YM2610 OPNB   │  │  YM2151 OPM   │
    │  (Superman, etc) │  │ (Twin Hawk)   │
    │                  │  │               │
    │  • 6 FM + 3 SSG  │  │  • 8 FM chs   │
    │  • 8 MHz clock   │  │  • 3.58 MHz   │
    │  • YM3016 DAC    │  │  • YM3012 DAC │
    └────────┬─────────┘  └───────┬───────┘
             │                    │
             └────────┬───────────┘
                      │
                      ▼
            (Stereo analog audio)
```

---

## Memory Map (Detailed)

```
0x000000 - 0x07FFFF    Program ROM (bank 0)
  0x000000 - 0x01FFFF    Bank 0 (128 KB) — Always visible
  0x020000 - 0x07FFFF    Bank 1+ (384 KB) — Banked via control register

0x080000 - 0x08FFFF    Sound RAM (Z80 address space, not 68000)
0x090000 - 0x0FFFFF    Sound ROM (Z80 address space)

0x100000 - 0x10FFFF    Work RAM (68000)
  0x100000 - 0x10FFFF    64 KB RAM (main work area)
  0x110000 - 0x1FFFFF    (unmapped)

0xB00000 - 0xB00FFF    Palette RAM (15-bit RGB)
  0xB00000 - 0xB00FFF    2048 entries (16 × 128-color palettes)
  (each entry: xRRRRRGGGGGBBBBB)

0xC00000 - 0xCFFFFF    Sprite/Tile Graphics ROM (banked)
  0xC00000 - 0xCFFFFF    Sprite ROM window (1 MB visible at a time?)
  (actual ROM 2-4 MB, bank-switched via control register)

0xD00000 - 0xD005FF    Sprite Y-Coordinate Attribute RAM
  0xD00000 - 0xD003FF    Y-coords for sprites 0–255
  0xD00400 - 0xD005FF    (extended attribute or padding)
  0xD00600 - 0xD00607    Sprite generator control registers
    (exact layout TBD; possibly:
     0xD00600 — sprite bank select
     0xD00602 — sprite ROM bank
     0xD00604 — (reserved)
     0xD00606 — (reserved))

0xE00000 - 0xE03FFF    Sprite Object RAM (frame 0)
  0xE00000 - 0xE003FF    Sprite code (14-bit index, 256 entries)
  0xE00400 - 0xE007FF    Sprite X-coordinate + color (256 entries)
  0xE00800 - 0xE0BFFF    Sprite tile number (256 entries)
  0xE00C00 - 0xE0FFFF    Sprite tile color (256 entries)

0xE02000 - 0xE02FFF    Sprite Object RAM (frame 1, double-buffer)
  (same structure as 0xE00000 block, 4 KB reserved)

0xF00000 - 0xFEFFFF    (unmapped, internal ROM possibly?)
0xFF0000 - 0xFFFFFF    (unmapped)
```

---

## 68000 CPU Interface

### Interrupt Routing

```
IPL2–IPL0 vectors (3 bits):
  %000 = no interrupt
  %001 = level 1
  %010 = level 2
  %011 = level 3
  %100 = level 4
  %101 = level 5
  %110 = level 6
  %111 = level 7 (NMI equivalent)
```

**Likely interrupt sources:**
- Level 4 or 5: Vblank (60 Hz, ~16.7 ms period)
- Level 1: Z80 sound CPU finished sequence (polling-based)

### Timing

- **CPU:** 8 MHz (÷2 from 16 MHz master clock)
- **Bus cycle:** 125 ns (1/8 MHz)
- **One frame:** ~16.67 ms @ 60 Hz
- **Cycles per frame:** ~134K cycles @ 8 MHz
- **Instruction mix (68000):** avg 6–8 cycles per instruction
  - MOVE: 4–6 cycles
  - ADDI: 8 cycles
  - JSR: 16 cycles
  - Typical game loop: 20–40K instructions/frame

---

## X1-001A Sprite Engine (Reverse-Engineered from MAME)

### Rendering Pipeline

```
┌──────────────────────────────────────────┐
│  Each Scanline (raster line 0–239)       │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  1. Fetch active sprite list for line Y  │
│     (from Y-coordinate attribute RAM)    │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  2. For each active sprite (0–255):      │
│     - Read sprite code from 0xE00000     │
│     - Read X coordinate from 0xE00400    │
│     - Read color palette from 0xE00400   │
│     - Decode flip flags (H/V) from code  │
│     - Apply Y-clip (sprite 16 px tall)   │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  3. Graphics ROM Lookup:                 │
│     ROM_addr = sprite_code * 32 + Y_off  │
│     (assumes 16×16, 4 bpp = 32 bytes/row)│
│     (actual formula TBD from ROM dump)   │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  4. Fetch sprite row data (16 pixels)    │
│     Format: 4 bpp (nibbles) → palette    │
│     Apply X-flip if set                  │
│     Apply Y-flip if set (adjust offset)  │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  5. Color Lookup:                        │
│     For each pixel (4-bit index):        │
│     palette_base = (color_attr & 0xF800)│
│     final_color = palette_base + index   │
│     rgb = palette_ram[final_color]       │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  6. Composite into Framebuffer:          │
│     X_screen = X_coord + pixel_offset    │
│     if (pixel != 0) && (X_screen < 384)  │
│        framebuffer[X_screen] = rgb       │
│     (back-to-front order = later sprite  │
│      overwrites earlier = top priority)  │
└──────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  7. Next scanline                        │
└──────────────────────────────────────────┘
```

### Key Unknowns

1. **Graphics ROM addressing:** Is sprite code directly multiplied by bytes/sprite, or is there indirection?
   - Hypothesis A: `ROM_offset = sprite_code * 128` (16 rows × 8 bytes)
   - Hypothesis B: `ROM_offset = (sprite_code >> 4) * 2048 + (sprite_code & 15) * 128`
   - **Action:** Dump Superman sprite ROM, reverse-map sprite 0 position → ROM address

2. **Color palette selection:** How does the 5-bit `color_attr` field map to palette?
   - Hypothesis A: Direct 5-bit offset (0–31) → palette 0–31
   - Hypothesis B: `palette_base = color_attr * 16` (32 selections × 16 colors each)
   - **Action:** Disassemble Superman palette-loading code (likely JSR in graphics init)

3. **Sprite priority/Z-order:** Is order determined by sprite RAM address or attribute bits?
   - Hypothesis A: Higher sprite numbers = higher priority (later in RAM)
   - Hypothesis B: Z-order bits in sprite code or X-coordinate field
   - **Action:** Intentionally draw overlapping sprites, observe which is on top

4. **Clipping:** Does X1-001A clip sprites to 384-pixel screen width, or does CPU?
   - **Action:** Place sprite with X-coord = 376, verify it draws partially or clips

5. **Y-coordinate latching:** Does sprite Y-RAM latch at vblank, or continuously?
   - Impact: If latched, sprite updates are synchronous; if continuous, race conditions possible
   - **Action:** Monitor Y-RAM writes vs. vblank timing in MAME debugger

---

## 68000 ↔ Z80 Communication

### Command/Response Model (Hypothesis)

```
68000 (main)                    Z80 (sound)
  │
  ├─ Write 0xZZZZZZ to 0x088000
  │  (command byte)
  │                                │
  │                                ▼
  │                        Trigger Z80 NMI (?)
  │                                │
  │                                ▼
  │                        (Z80 reads command)
  │                                │
  │                                ├─ Update YM2610 registers
  │                                │  (load sound effects,
  │                                │   start sequences)
  │                                │
  │                                ├─ Write result to result register
  │                                │
  │                                ▼
  │                        (Z80 NMI exit, or polling)
  │
  ├─ Poll result register until != 0 (or interrupt-driven ACK)
  │
  └─ Proceed (sound playing asynchronously)
```

**Unknowns:**
- Is Z80 interrupt (NMI) used, or does Z80 poll?
- What registers/addresses for command and result?
- What is the command protocol (single byte, word, or multi-byte sequence)?

**Action:** Monitor 68000 → Z80 memory writes in MAME debugger during game startup (music first play).

---

## YM2610 Audio Synthesis (Superman, Gigandes, etc.)

### Register Map (Yamaha OPN specification)

```
Port A ($088000):  FM channel selector + data
Port B ($088002):  SSG (AY-3-8910) channel selector + data

FM Voices (6 channels):
  CH0–CH3:  Full 4-operator FM
  CH4:      3-operator FM (one feedback slot)
  CH5:      Drum channel (9-voice percussion ROM)

Algorithm Selection:
  0: (1→2→3→4 series)
  1: (1→2, 2→3→4, 1→3→4)
  2: (1→2, 1→3→4, 2→3→4)
  3: (1→2→3, 4)
  etc.

Envelope (EG):
  AR (attack rate): 0–31 (fast → slow)
  DR (decay rate):  0–31
  SR (sustain rate): 0–31
  RR (release rate): 0–31
```

**Typical initialization sequence (pseudo-code):**
```c
// Set overall volume/pan
ym2610_write(0x08, volume_table[vol_idx]);

// Load instrument 0 (CH0)
ym2610_write(0x30, operator0_DT1_MUL);   // DT1, MUL
ym2610_write(0x34, operator0_TL);        // TL
ym2610_write(0x38, operator0_KS_AR);     // KS, AR
ym2610_write(0x3C, operator0_DR);        // D1R
ym2610_write(0x40, operator0_SR);        // D2R
ym2610_write(0x44, operator0_RR_RR);     // RR, DR

// Start note
ym2610_write(0xA0, freq_low);            // Frequency (low byte)
ym2610_write(0xA4, freq_high | key_on);  // Frequency (high) + key ON
```

---

## Video Timing (384×240 @ 60 Hz)

### Standard CRT Timing (estimated for 60 Hz)

```
Horizontal (per scanline):
  Visible:      384 pixels
  Front porch:  ~16 pixels
  Hsync:        ~32 pixels (typical)
  Back porch:   ~32 pixels
  Total:        ~464 pixels per line (~50 µs @ 9.2 MHz pixel clock)

Vertical (per frame):
  Visible:      240 lines
  Front porch:  ~12 lines
  Vsync:        ~2 lines
  Back porch:   ~20 lines
  Total:        ~274 lines @ 60 Hz
  Refresh rate: ~60 Hz (59.94 Hz NTSC)
```

### Blanking & Interrupt Timing

```
Vblank interrupt (68000, likely level 4):
  • Triggered at end of visible frame (after scanline 240)
  • Gives ~1 ms window for sprite RAM updates
  • Must complete before next vblank (16.67 ms total)

Sprite 0 hit (if implemented):
  • Would trigger when sprite #0 overlaps non-background pixel
  • Used for fine timing in some 6502 NES games
  • Unknown if Taito X implements this
  • Test: Monitor IPL pins during sprite 0 area
```

---

## Power Supply & Voltages

```
Standard arcade (JAMMA):
  +5V   — Logic, CPU, RAM, ROM, sound chips
  +12V  — (not used on Taito X?)
  -5V   — (not used on Taito X?)
  GND   — Reference
```

---

## JAMMA Connector (Standard)

```
Joystick (player 1 & 2):
  UP, DOWN, LEFT, RIGHT (4-bit per player)
  Button A, B, C (3 buttons)

Coins & Controls:
  COIN1, COIN2 (coin meters)
  START1, START2 (game start)
  (Some games add 4th button → map to button C)

Test/Service:
  TEST (diagnostics)
  (Specific test mode behavior TBD per game)
```

---

## Sprite ROM Format (Hypothesis)

### Superman Sprite ROM Structure (estimated)

Given typical 16×16 sprite = 256 pixels = 128 bytes @ 4 bpp:

```
Sprite ROM layout:
  [Sprite 0]
    [Row 0 (16 pixels @ 4 bpp)] = 8 bytes
    [Row 1]                     = 8 bytes
    ...
    [Row 15]                    = 8 bytes
    Total: 16 rows × 8 bytes = 128 bytes
  [Sprite 1]
    (same structure)
    Offset = 128
  [Sprite N]
    Offset = N × 128

Pixel format (4 bpp, 2 pixels per byte):
  High nibble = pixel 0 (left)
  Low nibble  = pixel 1 (right)
  Value 0     = transparent (color palette entry 0)
  Value 1–15  = opaque pixels
```

**Validation test:**
1. Load Superman ROM
2. Extract sprite code 0 from object RAM (should be in range 0–255 typically)
3. Seek to offset `sprite_code * 128` in sprite ROM
4. Extract 128 bytes (16 rows × 8 bytes)
5. Decompress each row into 16 pixels, 4 bpp
6. Lookup in palette to generate 16×16 RGB image
7. Compare against MAME's rendered output (should match)

---

## Z80 Sound CPU Instruction Timing

**For modeling vblank interrupt & sound timing:**

```
Z80 @ 4 MHz:
  Instruction cycle time: 250 ns (1/4 MHz)
  Typical instruction: 4–15 cycles = 1–4 µs

One frame (16.67 ms) @ 4 MHz:
  ~66.7K cycles available for sound CPU

Typical sound routine (estimated):
  • Read command (1–2 cycles)
  • Parse command & select voice (10–20 cycles)
  • Loop: write YM2610 registers (6–8 writes × 10 cycles = 60–80 cycles)
  • Update envelope/timer state (20–50 cycles)
  • Return (5 cycles)

  Total: ~150–200 cycles per command
  → Leaves ~66K - 200 = 65K+ cycles for background music/sound synthesis
```

---

## Clock Derivation from 16 MHz Master

```
16 MHz master crystal
  │
  ├─ ÷2 → 8 MHz (68000 CPU clock)
  │
  ├─ ÷4 → 4 MHz (Z80 CPU clock, not explicitly in diagram)
  │
  └─ ÷2 → 8 MHz (sound chip clock reference, fed to YM2610/2151 variants)
          (though YM2610 may run at divided 8 MHz = 4 MHz derived)
```

**Uncertainty:** Does YM2610 clock at 8 MHz or 4 MHz? MAME source will clarify.

---

## Control Register Map (Estimated)

At 0xD00600–0xD00607 (or similar):

```
0xD00600 (or 0xZZZ000):
  [15:8]  Reserved
  [7:4]   Sprite object RAM bank select (0 = 0xE00000, 1 = 0xE02000)
  [3:0]   Reserved

0xD00602 (or 0xZZZ002):
  [15:8]  Sprite graphics ROM bank select (upper address bits for 0xC00000 window)
  [7:0]   Reserved

0xD00604, 0xD00606:
  (Unknown — possibly VBlank flag, sprite 0-hit, or reserved)
```

**Validation:**
- Modify register at start of game, observe if sprite graphics change
- Monitor MAME CPU debugger at game boot for writes to 0xD00000 region

---

## Known Debugging Breakpoints (for MAME)

1. **Sprite upload (0xE00000 writes):**
   ```
   Set watchpoint on 0xE00000–0xE02FFF for write
   Observe sprite code, X-coordinate, color attribute
   ```

2. **Palette update (0xB00000 writes):**
   ```
   Monitor palette ROM loads during title screen, level transitions
   ```

3. **Y-coordinate update (0xD00000 writes):**
   ```
   Trace which sprites are active per frame
   ```

4. **Sound command (0x088000 writes):**
   ```
   Trap 68000 writes to sound CPU command register
   Observe command sequence for music & SFX
   ```

5. **Vblank interrupt:**
   ```
   Set breakpoint on vector exception 0x1C (level 4)
   or trace IPL2–IPL0 pin state changes
   ```

---

## Next Research Actions

- [ ] Extract MAME source: `taito_x.cpp` → identify exact register addresses
- [ ] Extract MAME source: `x1_001.cpp` → reverse-engineer sprite rendering loop
- [ ] Dump Superman ROM (program + sprite graphics)
- [ ] Trace in MAME debugger: 68000 memory accesses during level 1
- [ ] Identify Y-coordinate attribute RAM exact bit layout
- [ ] Identify sound CPU command protocol
- [ ] Create ROM analysis script: sprite_rom_viewer.py
  - Input: sprite ROM binary + sprite index
  - Output: 16×16 PNG image (for visual validation)

