# SETA 1 — Hardware Profile

*Auto-generated from MAME `seta/seta.cpp` — 2026-03-20*

## Games: 66 (35 unique)

| Name | Title | Year |
|------|-------|------|
| setaroul | Visco | 1989 |
| drgnunit | Athena / Seta | 1989 |
| wits | Athena (Visco license) | 1989 |
| thunderl | Seta | 1990 |
| wiggie | Promat | 1994 |
| jockeyc | Seta (Visco license) | 1990 |
| rezon | Allumer | 1992 |
| stg | Athena / Tecmo | 1991 |
| pairlove | Athena / Nihon System | 1991 |
| blandia | Allumer | 1992 |
| blockcar | Visco | 1992 |
| qzkklogy | Tecmo | 1992 |
| neobattl | Banpresto | 1992 |
| umanclub | Banpresto | 1992 |
| zingzip | Allumer / Tecmo | 1992 |
| atehate | Athena | 1993 |
| daioh | Athena | 1993 |
| jjsquawk | Athena / Able | 1993 |
| kamenrid | Banpresto | 1993 |
| madshark | Allumer | 1993 |
| msgundam | Banpresto / Allumer | 1993 |
| oisipuzl | Sunsoft / Atlus | 1993 |
| qzkklgy2 | Tecmo | 1993 |
| utoukond | Banpresto | 1993 |
| wrofaero | Yang Cheng | 1993 |
| eightfrc | Tecmo | 1994 |
| krzybowl | American Sammy | 1994 |
| magspeed | Allumer | 1994 |
| orbs | American Sammy | 1994 |
| keroppi | American Sammy | 1995 |
| ... | *5 more* | |

## CPUs
| Type | Tag | Clock | Status |
|------|-----|-------|--------|
| m68000 | maincpu | 16.000 MHz | HAVE |
| z80 | audiocpu | 4.000 MHz | HAVE |

## Sound Chips
| Type | Tag | Clock | Status |
|------|-----|-------|--------|
| ym2151 | ymsnd | 4.000 MHz | HAVE |
| okim6295 | oki | ? | HAVE |
| ym3438 | ymsnd | 8.000 MHz | HAVE |
| ym3812 | ymsnd | 4.000 MHz | HAVE |
| x1_010 | x1snd | 16.000 MHz | NEED |

## Memory Map: seta_state::atehate_map
| Start | End | Access | Handler |
|-------|-----|--------|---------|
| 0x000000 | 0x0FFFFF | r |  |
| 0x900000 | 0x9FFFFF | rw |  |
| 0x100000 | 0x103FFF | rw | m_x1snd, FUNC(x1_010_device::word_r), FU |
| 0x200000 | 0x200001 | nopw |  |
| 0x300000 | 0x300001 | nopw |  |
| 0x500000 | 0x500001 | nopw |  |
| 0x600000 | 0x600003 | r | FUNC(seta_state::seta_dsw_r) |
| 0x700000 | 0x7003FF | rw | ).share("paletteram1 |
| 0xA00000 | 0xA005FF | rw | ).rw(m_spritegen, FUNC(x1_001_device::sp |
| 0xA00600 | 0xA00607 | rw | ).rw(m_spritegen, FUNC(x1_001_device::sp |
| 0xB00000 | 0xB00001 | portr | P1 |
| 0xB00002 | 0xB00003 | portr | P2 |
| 0xB00004 | 0xB00005 | portr | COINS |
| 0xC00000 | 0xC00001 | rw |  |
| 0xE00000 | 0xE03FFF | rw | ).rw(m_spritegen, FUNC(x1_001_device::sp |

## Memory Map: seta_state::blandia_map
| Start | End | Access | Handler |
|-------|-----|--------|---------|
| 0x000000 | 0x1FFFFF | r |  |
| 0x200000 | 0x20FFFF | rw |  |
| 0x210000 | 0x21FFFF | rw |  |
| 0x300000 | 0x30FFFF | rw |  |
| 0x400000 | 0x400001 | portr | P1 |
| 0x400002 | 0x400003 | portr | P2 |
| 0x400004 | 0x400005 | portr | COINS |
| 0x500001 | 0x500001 | w | FUNC(seta_state::seta_coin_counter_w) |
| 0x500003 | 0x500003 | w | FUNC(seta_state::seta_vregs_w) |
| 0x500004 | 0x500005 | nopw |  |
| 0x600000 | 0x600003 | r | FUNC(seta_state::seta_dsw_r) |
| 0x700000 | 0x7003FF | rw |  |
| 0x700400 | 0x700FFF | rw | ).share("paletteram1 |
| 0x703C00 | 0x7047FF | rw | ).share("paletteram2 |
| 0x800000 | 0x8005FF | rw | ).rw(m_spritegen, FUNC(x1_001_device::sp |

## Chip Status Summary
- **HAVE (FPGA exists):** 6
- **NEED (must build):** 64
- **COMMUNITY (available):** 0
- **INFEASIBLE:** 0

**Feasible:** YES