# TC0100SCN — Hardware Context Notes

---

## 1. Physical Package and Variants

The TC0100SCN is a Taito custom LSI chip, QFP package. Two variants exist:

| Part Number | Color Depth | Notes |
|-------------|-------------|-------|
| TC0100SCN   | 4 bpp (16 colors/tile) | Standard. Used in the vast majority of F2 games. |
| TC0620SCC   | 6 bpp (64 colors/tile) | Used in select games. Otherwise functionally identical to TC0100SCN. |

From the PCB layout for Ninja Kids (K11T0658A):
- TC0100SCN is physically adjacent to TC51832 SRAMs on the board.
- Two 32K×8 TC51832 SRAMs provide the 64KB tilemap RAM (connected via SCE0).
- One HM3-65764KS additional SRAM provides the optional double-width RAM expansion (connected via SCE1; absent on single-screen boards).

---

## 2. Clock Frequencies

From the Ninja Kids PCB layout notes (representative of all F2 games using 24 MHz audio oscillator):

| Signal            | Frequency     | Source                                   |
|-------------------|---------------|------------------------------------------|
| OSC1 (video)      | 26.686 MHz    | Dedicated video crystal                 |
| OSC2 (system)     | 24.000 MHz    | System clock crystal                    |
| 68000 CPU         | 12.000 MHz    | OSC2 / 2                                |
| Z80 audio CPU     | 4.000 MHz     | OSC2 / 6                                |
| YM2610            | 8.000 MHz     | OSC2 / 3                                |
| Pixel clock       | ~6.671 MHz    | OSC1 / 4 (inferred from standard 320-wide display) |
| Vertical sync     | 60 Hz         | Derived from pixel clock and line count  |

The TC0100SCN is clocked from the video oscillator domain. The chip's internal logic runs at the pixel clock rate (OSC1/4 ≈ 6.671 MHz). The CPU bus interface is asynchronous (DTACK handshake) and bridges the 12 MHz CPU domain to the pixel-clock video domain.

---

## 3. F2 System Architecture

The Taito F2 system has two main board revisions:

**Old F2 (larger board, K1100432A / J1100183A):**
- TC0100SCN — tilemap generator (this chip)
- TC0200OBJ + TC0210FBC — sprite generator pair
- TC0140SYT — sound communication and I/O

**New F2 (smaller board, K1100608A / J1100242A):**
- TC0100SCN — tilemap generator (same chip, same function)
- TC0540OBN + TC0520TBC — newer sprite generator pair
- TC0530SYC — sound communication

Both board revisions use the same TC0100SCN. The chip is board-revision-agnostic.

### Priority Mixer Connection

The TC0100SCN's 15-bit pixel output (SC0–SC14) connects to the priority mixer:

| Priority Chip | Used By |
|---------------|---------|
| TC0360PRI     | Most F2 games with TC0260DAR palette |
| TC0110PCR     | Early F2 games (Final Blow, Quiz Torimonochou, Quiz H.Q., Mahjong Quest) |

The TC0360PRI is the more common variant. It combines TC0100SCN output with the sprite generator output to produce the final display.

### Palette Connection

| Palette Chip  | Used By |
|---------------|---------|
| TC0260DAR     | Most F2 games |
| TC0110PCR     | Early F2 games (same chip doubles as priority mixer in some configurations) |
| TC0070RGB     | Very early F2 games |

---

## 4. Games Using TC0100SCN

All are Taito F2 system games. This list is derived from the MAME `taito_f2.cpp` driver and game header comments.

| Year | Game                              | Notes |
|------|-----------------------------------|-------|
| 1989 | Final Blow                        | TC0110PCR palette. Earliest F2 game. |
| 1989 | Don Doko Don                      | TC0360PRI + TC0260DAR. Includes TC0280GRD zoom/rotation layer. |
| 1989 | Mega Blast (Mega Blasters)        | TC0030CMD C-Chip protection. |
| 1990 | Quiz Torimonochou                 | TC0110PCR. |
| 1990 | Cameltry (On the Ball)            | Double-width mode. TC0280GRD zoom/rotation. |
| 1990 | Quiz H.Q.                         | TC0110PCR. |
| 1990 | Thunder Fox                       | **Two TC0100SCN chips** (main + subsidiary). |
| 1990 | Liquid Kids (Mizubaku Daibouken)  | |
| 1990 | Super Space Invaders '91 (SSI)    | Sprite-only game; TC0100SCN largely unused. |
| 1991 | Gun Frontier                      | Vertical-orientation game (rotated 90°). Colscroll used for cloud boss. |
| 1991 | Growl (Runark)                    | TC0190FMC sprite banking. Colscroll used for water and lava effects. |
| 1991 | Hat Trick Hero (Euro Football Champ) | |
| 1991 | Yuu-yu no Quiz de Go!Go!          | TC0620SCC variant? (Yuyugogo uses 1bpp layout per MAME gfxlayout). |
| 1991 | Ah Eikou no Koshien               | |
| 1991 | Ninja Kids                        | TC0190FMC sprite banking. Colscroll used for flame boss and final boss. |
| 1991 | Mahjong Quest                     | TC0110PCR. Uses tile callback for ROM banking. |
| 1991 | Quiz Quest                        | |
| 1991 | Metal Black                       | TC0480SCP additional tilemap chip. |
| 1991 | Drift Out (Visco)                 | Not standard F2 PCB. |
| 1991 | PuLiRuLa                          | TC0430GRW zoom/rotation. |
| 1992 | Quiz Chikyu Boueigun              | |
| 1992 | Dead Connection                   | TC0480SCP additional tilemap chip. |
| 1992 | Dinorex                           | |
| 1993 | Quiz Jinsei Gekijou               | |
| 1993 | Quiz Crayon Shinchan              | |
| 1993 | Crayon Shinchan Orato Asobo       | |
| 1992 | Yes.No. Shinri Tokimeki Chart     | Fortune-teller machine. |

**Games with additional tilemap chips (TC0480SCP or TC0280GRD):** The TC0100SCN provides the three standard layers; the additional chip provides extra zoom/rotation capabilities. The TC0100SCN interface is unchanged in these games.

**Footchmp (Hat Trick Hero variants) and some Dead Connection:** Use TC0480SCP instead of TC0100SCN for tilemaps. These are not TC0100SCN games.

---

## 5. CPU Bus Memory Map (Typical)

The TC0100SCN RAM and control register windows appear at different base addresses per game, set by the board's PAL/address decoder. Representative examples from `taito_f2.cpp`:

| Game         | RAM Window Base | Control Base   |
|--------------|-----------------|----------------|
| Final Blow   | `0x800000`      | `0x820000`     |
| Don Doko Don | `0x800000`      | `0x820000`     |
| Mega Blast   | `0x600000`      | `0x620000`     |
| Thunder Fox (chip 0) | `0x400000` | `0x420000`  |
| Thunder Fox (chip 1) | `0x500000` | `0x520000`  |
| Cameltry     | `0x800000` (14-bit, double-width) | `0x820000` |
| Ninja Kids   | `0x800000`      | `0x820000`     |
| Growl        | `0x800000`      | `0x820000`     |
| Mahjong Quest | `0x400000`     | `0x420000`     |

The control window is always 0x10 bytes (8 × 16-bit registers). The RAM window is 0x10000 bytes for standard games, 0x14000 bytes for double-width games.

The standard pattern is: RAM window starts at `XBASE`, control registers start at `XBASE + 0x20000`. This is the most common pairing in F2 games.

---

## 6. Interrupt Structure

From `taito_f2.cpp`:

The F2 system generates two interrupt signals to the 68000:
- **IRQ5**: Vertical blank (VBL). Primary interrupt. Games update tilemap scroll registers, palette, and game logic here.
- **IRQ6**: DMA complete signal from the sprite generator. Secondary interrupt. Games update sprite attributes here.

The TC0100SCN itself does not generate interrupts. It is a passive slave on the CPU bus. Scroll register updates and tilemap data writes happen at the CPU's discretion, typically in the IRQ5 handler.

The interrupt routing is through a PAL on the board. Some games swap IRQ5/IRQ6 via a board jumper, but this does not affect TC0100SCN operation.

---

## 7. Relationship to Other Chips in the F2 Signal Flow

```
68000 CPU
    |
    |--- TC0100SCN (tilemap RAM + ctrl registers)
    |         |
    |         |-- BG0/BG1: tile ROM (external)
    |         |-- FG0: internal char RAM
    |         |
    |         `-- SC0–SC14 pixel output (15 bits, streaming) ---> TC0360PRI
    |                                                                  |
    |--- TC0200OBJ/TC0540OBN (sprite generator)                       |
    |         |                                                        |
    |         `-- sprite pixel output ----------------------------> TC0360PRI
    |                                                                  |
    |--- TC0260DAR (palette RAM)                                       |
              |                                                        |
              `-- RGB analog output <-- TC0360PRI (priority decision) -'
```

The TC0360PRI receives pixel data from TC0100SCN and the sprite chip simultaneously. For each pixel, it applies a priority decision based on the priority register values and the priority bits embedded in the pixel data. The winning pixel's palette index is passed to TC0260DAR, which performs the index-to-RGB lookup.

The TC0100SCN's 15-bit output encodes enough information for the TC0360PRI to make priority decisions. The exact encoding of SC0–SC14 (priority bits vs. palette index bits) is inferred from schematics (Operation Thunderbolt) but not fully decoded in MAME — MAME uses a higher-level abstraction for the mixer.

---

## 8. Colbank Configuration

The `set_colbanks(bg0, bg1, tx)` function sets per-layer palette base offsets. The effective palette entry is `(tile_color + colbank) & 0xFF` for BG layers and `(tile_color + tx_colbank) & 0x3F` for FG.

Most F2 games use `set_colbanks(0, 0, 0)` (default). The WGP (Winning Post) games use non-zero colbanks to separate palette regions between layers.

---

## 9. MAME Source Reference

Primary source file: `src/mame/taito/tc0100scn.cpp`
Header: `src/mame/taito/tc0100scn.h`
F2 driver (game context): `src/mame/taito/taito_f2.cpp`

No jotego jtcores implementation of TC0100SCN or any Taito F2 game exists as of 2026-03. The MAME source is the sole available reference. Cross-verification from a second implementation is not possible for this chip.
