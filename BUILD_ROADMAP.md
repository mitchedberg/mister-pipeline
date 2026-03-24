# MiSTer Factory — Build Roadmap

25+ cores organized by dependency chain. Each phase builds on the previous.
Total coverage: **~400+ arcade games** newly playable on MiSTer.

---

## Currently Building (Phase 0)

| Core | CPU | Status | Games |
|------|-----|--------|-------|
| NMK16 | 68000+Z80 | Sim rendering, CI green | Thunder Dragon, Hacha Mecha Fighter |
| Toaplan V2 (GP9001) | 68000+Z80 | CI green | Batsugun, Truxton 2 |
| Psikyo 68EC020 | 68EC020+Z80 | CI green | Gunbird, Strikers 1945 |
| Kaneko16 | 68000+Z80 | CI green | Berlwall, Blood Warrior |
| Taito B | 68000+Z80 | CI green | Crime City, Nastar |
| Taito X | 68000+Z80 | CI green | Superman, Gigandes |
| Taito F3 | 68EC020 | FROZEN (ALM) | Puzzle Bobble 2, Arkanoid Returns |
| Taito Z | 68000+Z80 | FROZEN (2x fx68k) | Chase HQ, Continental Circus |

---

## Phase 1: Zero Friction — GP9001 Variants (~15 boards, minimal new work)

Our GP9001 VDP is already built. These boards are variants with minor banking/priority differences.

| # | Core | MAME Driver | New Work | Key Games |
|---|------|-------------|----------|-----------|
| 1 | Raizing / Battle Garegga | raizing.cpp | GAL banking | Battle Garegga, Sorcer Striker, Kingdom GP |
| 2 | Batrider / Bakraid | raizing_batrider.cpp | Object bank switch + YMZ280B | Armed Police Batrider, Battle Bakraid |
| 3 | Dual GP9001 | batsugun.cpp, dogyuun.cpp | Dual-VDP mixing | Batsugun, Dogyuun, V-Five, Knuckle Bash, Snow Bros 2 |

**Games added: ~15-20**

---

## Phase 2: NMK16 Derivatives (~15 games, nearly free)

NMK16 is already building. These boards are derived from the same hardware.

| # | Core | MAME Driver | New Work | Key Games |
|---|------|-------------|----------|-----------|
| 4 | Afega | nmk16.cpp variants | Minimal address map changes | Red Hawk, Stagger I, Sen Jin |
| 5 | Comad/ESD | esd16.cpp | Minor I/O differences | Multi Champ, Head Panic |

**Games added: ~15**

---

## Phase 3: SETA Family (~65 games, X1-001 chip already in Taito X)

The Taito X system uses SETA's X1-001 sprite chip. Our work carries over.

| # | Core | MAME Driver | New Chips | Key Games |
|---|------|-------------|-----------|-----------|
| 6 | SETA 1st Gen | seta.cpp | X1-010 PCM audio, X1-012 tilemaps | Castle of Dragon, Strike Gunner, Blandia, Zombie Raid (~50 games) |
| 7 | SETA 2nd Gen | seta2.cpp | X1-020 video (enhanced X1-001) | Guardians/Denjin Makai II, Penguin Brothers (~15 games) |

**Games added: ~65**

---

## Phase 4: New 68K Platforms (~80 games)

All use fx68k (done) + standard sound chips (mostly done).

| # | Core | MAME Driver | New Chips | Key Games |
|---|------|-------------|-----------|-----------|
| 8 | Video System | aerofgt.cpp + 4 | VS9209, VSYSTEM_SPR | Aero Fighters 1/2/3, Sonic Wings, Power Spikes, F-1 GP (~35 games) |
| 9 | DECO 16-bit | dec0.cpp, cninja.cpp | DECO16IC tilemap, BAC06 | RoboCop, Bad Dudes, Midnight Resistance, Caveman Ninja (~20 games) |
| 10 | SNK Alpha 68K | alpha68k.cpp | Alpha sprite chip | Time Soldiers, Sky Soldiers, Gang Wars (~15 games) |
| 11 | Seibu 68K | raiden.cpp, legionna.cpp | V30 CPU, RAIDEN2COP | Raiden, Raiden DX, Blood Bros, Legionnaire (~10 games) |

**Games added: ~80**

---

## Phase 5: Kaneko Extensions + Metro (~45 games)

Builds on Kaneko16 VIEW2 chip already done.

| # | Core | MAME Driver | New Chips | Key Games |
|---|------|-------------|-----------|-----------|
| 12 | Kaneko Gals Panic | galpanic.cpp, galpani2.cpp | PANDORA sprite | Gals Panic series (~14 sets) |
| 13 | Metro / Imagetek | metro.cpp, hyprduel.cpp | Imagetek I4100/I4220 | Hyper Duel, Last Fortress (~28 games) |
| 14 | Fuuki FG-2 | fuukifg2.cpp | FI-002K/FI-003K | Go Go Mile Smile (~12 games) |
| 15 | Fuuki FG-3 | fuukifg3.cpp | YMF278B only (rest from FG-2) | Asura Blade, Asura Buster (~5 games) |

**Games added: ~45** (FG-3 is nearly free after FG-2)

---

## Phase 6: Konami GX + IGS PGM (~40 games)

Both 68000-family, high community demand.

| # | Core | MAME Driver | New Chips | Key Games |
|---|------|-------------|-----------|-----------|
| 16 | Konami System GX | konamigx.cpp | K054156/K056832, K053246/K055673, TMS57002 DSP | Sexy Parodius, Salamander 2, Twinbee Yahho (~20 games) |
| 17 | IGS PGM | pgm.cpp | IGS023 video, ICS2115 wavetable | Knights of Valour, DoDonPachi II, Oriental Legend (~20 games) |

**Games added: ~40**

---

## Phase 7: Z80 Platforms (~130 games)

Huge game libraries. Z80 is simpler than 68000.

| # | Core | MAME Driver | New Chips | Key Games |
|---|------|-------------|-----------|-----------|
| 18 | Sega System 1 | system1.cpp | 315-5049 sprite, MC8123 | Flicky, Wonder Boy, Pitfall II, Choplifter (~50 games) |
| 19 | Sega System 2 | system2.cpp | Enhanced 315-5049 | Further Sega classics (~20 games) |
| 20 | Bally MCR 1-3 | mcr.cpp, mcr2.cpp | Simple tilemap/sprite | Tron, Spy Hunter, Tapper, Sinistar (~60 games) |

**Games added: ~130**

---

## Phase 8: New CPU Architectures (~80 games, harder)

Each unlocks a new hardware family.

| # | Core | New CPU | Key Games | Unlocks |
|---|------|---------|-----------|---------|
| 21 | SSV / Vasara | NEC V60 | Vasara 1+2, Drift Out, Storm Blade (~26 games) | — |
| 22 | Super Kaneko Nova | SH-2 | Puzz Loop, Cyvern, Sengeki Striker (~35 games) | Future Psikyo SH-2 |
| 23 | DECO 32-bit | ARM | Captain America, Night Slashers (~10 games) | DECO16IC reused |
| 24 | Sega System 24 | Dual 68000 | — | ~10 games |
| 25 | Seibu SPI | 386DX | Raiden Fighters 1/2/Jet, Viper Phase 1 (~20 games) | Requires V30 from #11 |

**Games added: ~80**

---

## Total

| Phase | Cores | New Games | Cumulative |
|-------|-------|-----------|-----------|
| 0 (current) | 8 | ~30 | 30 |
| 1 (GP9001 variants) | 3 | ~20 | 50 |
| 2 (NMK derivatives) | 2 | ~15 | 65 |
| 3 (SETA family) | 2 | ~65 | 130 |
| 4 (New 68K platforms) | 4 | ~80 | 210 |
| 5 (Kaneko+Metro+Fuuki) | 4 | ~45 | 255 |
| 6 (Konami GX + IGS) | 2 | ~40 | 295 |
| 7 (Z80 platforms) | 3 | ~130 | 425 |
| 8 (New CPUs) | 5 | ~80 | **505** |
| **TOTAL** | **33** | **~505** | |

---

## Dependency Graph

```
[GP9001 done] ──→ Raizing ──→ Batrider ──→ Dual GP9001
[NMK16 done] ──→ Afega ──→ ESD
[Taito X X1-001] ──→ SETA 1 (X1-010) ──→ SETA 2
[fx68k done] ──→ Video System
             ──→ DECO16 (DECO16IC) ──→ DECO32 ARM
             ──→ SNK Alpha 68K
             ──→ Fuuki FG-2 ──→ FG-3 (free)
             ──→ Metro/Imagetek
             ──→ Konami GX
             ──→ IGS PGM
[Kaneko16 VIEW2] ──→ Gals Panic
[V30 new] ──→ Seibu Raiden 2 ──→ Seibu SPI (386DX)
[SH-2 new] ──→ Super Kaneko Nova ──→ (future Psikyo SH-2)
[V60 new] ──→ SSV/Vasara
[Z80 done] ──→ Sega System 1 ──→ System 2
           ──→ Bally MCR 1-3
```

---

## Strategic Notes

1. **GP9001 is the biggest multiplier** — ~15 additional boards from work already done
2. **X1-001/X1-010 is the SETA multiplier** — 65 games from Taito X chip reuse
3. **DECO16IC covers 3 cores** — implement once, reuse for dec0 + cninja + deco32
4. **Fuuki FG-3 is free after FG-2** — same chips, CPU upgrade already done
5. **Raiden Fighters requires V30 → 386DX stepping stones** — don't attempt cold
6. **Cave CV1K is Year 2+** — SH-3 @ 102MHz, plan as capstone after pipeline is mature
7. **Always check ecosystem before starting** — some of these may get community implementations
