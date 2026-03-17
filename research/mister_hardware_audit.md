# MiSTer FPGA Hardware Audit — Exhaustive Status Report

**Date**: 2026-03-16
**Sources**: MiSTer-devel GitHub org, jotego/jtcores, community developer repos (va7deo, atrac17, RndMnkIII, etc.), direct repo inspection

---

## Classification Key

- **TIER 1 — MATURE**: Core exists on MiSTer-devel or well-known fork; runs multiple games reliably; active community use
- **TIER 2 — IN DEVELOPMENT**: Core exists but incomplete, inaccurate, or actively being worked on
- **TIER 3 — UNTOUCHED**: No public MiSTer core exists

Accuracy flags:
- `[ACCURACY CONCERN]` — mature core with known accuracy issues that make it a candidate for replacement work
- `[WIP]` — subset of games unimplemented within an otherwise-mature core
- `[DEPRECATED]` — superseded by another core

---

## Part 1: Capcom

### CPS1 (Capcom Play System 1)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `cps1`)
80+ titles including Street Fighter II series, Final Fight, Ghouls'n Ghosts (CPS1 version), Knights of the Round, Magic Sword, Captain Commando, Mercs, Carrier Air Wing, 1941, Dynasty Wars, Forgotten Worlds, Nemo, and many more. Requires 32MB SDRAM. Custom Q-Sound chip NOT implemented (Q-Sound games use HLE or silence depending on core version). Some large GFX ROMs need 64MB module.

Known issues: Q-Sound emulation is HLE-based and not cycle-accurate.

### CPS1.5 (CPS "1.5" — Warriors of Fate / Slam Masters era)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `cps15`)
Games: Cadillacs and Dinosaurs, Warriors of Fate, Slam Masters, Muscle Bomber Duo, The Punisher, Sangokushi II, Super Street Fighter II Turbo (note: SF2 Turbo/CE is CPS1). These boards used CPS-B chips requiring decryption. Treated as separate core from CPS1.

### CPS2 (Capcom Play System 2)
**TIER 1 — MATURE** `[ACCURACY CONCERN — encryption decryption coverage]`
Repo: https://github.com/jotego/jtcores (core: `cps2`)
150+ titles. Street Fighter Alpha series, Marvel vs. Capcom, X-Men vs. Street Fighter, Darkstalkers, Alien vs. Predator, Dungeons & Dragons, Super Street Fighter II Turbo, and many more. Some games require 64MB SDRAM module. CPS2 encryption is decrypted in the core via keys.

Known issues: Some encrypted variant ROMs may not be properly decrypted without specific key data in ROM header.

### CPS3 (Capcom Play System 3)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/jotego/jtcores (core: `cps3` — directory exists, minimal/no content as of 2025)
No public binary released. CPS3 uses a custom SH-2 CPU and CD-ROM, requires CD decryption via NO-CD patches or genuine discs. Custom graphics IC is complex. MAME emulates it well. The directory in jtcores suggests jotego is working on it.
Difficulty: Very Complex. Custom SH-2 variant, CD-ROM, unique GFX pipeline.

### Pre-CPS Capcom (1942-era through GNG)
**TIER 1 — MATURE**
Multiple cores via jotego/jtcores:
- `1942` — 1942, Vulgus, Pirate Ship Higemaru (10 games)
- `1943` — 1943 / 1943 Kai (8 games)
- `gng` — Ghosts'n Goblins (Arcade-GnG_MiSTer, MiSTer-devel) — described as "allegedly 100% accurate"
- `commnd` — Commando / Senjou no Ookami (7 games)
- `biocom` — Bionic Commando (6 games)
- `btiger` — Black Tiger / Black Dragon (3 games)
- `gunsmk` — Gun.Smoke (6 games)
- `tora` — Tiger Road / F-1 Dream (3 games)
- `trojan` — Trojan / Avengers / Buraiken (8 games)
- `exed` — Exed Exes / Savage Bees (2 games)
- `sectnz` — Section Z / Legendary Wings (7 games)
- `sarms` — Side Arms (4 games)
- `rumble` — Speed Rumbler (3 games)
- `sonson` — SonSon (Arcade-Sonson_MiSTer, MiSTer-devel)

Also:
- Repo: https://github.com/MiSTer-devel/Arcade-GnG_MiSTer (standalone, separate from jotego)
- Repo: https://github.com/MiSTer-devel/Arcade-Sonson_MiSTer

### Capcom 1942-derived misc (jotego)
- `sf` — Street Fighter (original 1987) — 4 variants
- `roc` — Roc'n Rope (2 games, Konami-era Capcom hardware)
- `sectnz` — Section Z / Legendary Wings
- `rumble` — Speed Rumbler

---

## Part 2: Konami

### Konami Scramble / Frogger era (early Z80)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Scramble_MiSTer
20 games: Scramble, Frogger, Super Cobra, Strategy X, Amidar, Anteater, and 14 more. High score save for 16 games.

### Konami Pengo / Pac-Man era (early tiles)
See Sega Pengo entry. Pengo uses Sega hardware.

### Konami 005885 chipset games (Gradius / Scramble era successor)
Via jotego/jtcores:
- `circus` — Circus Charlie (6 games)
- `roadf` — Track & Field / Hyper Olympics / Road Fighter / Hyper Sports (8 games)
- `track` — Hyper Olympic / Track & Field (4 games, separate core)
- `roc` — Roc'n Rope
- `pinpon` — Konami's Ping-Pong (1 game)
- `yiear` — Yie Ar Kung-Fu (2 games)
- `kicker` — Kicker / Shaolin's Road (2 games)
- `sbaskt` — Super Basketball (4 games)
- `roadf` — Road Fighter (3 games)

Repo: https://github.com/MiSTer-devel/Arcade-Scramble_MiSTer also covers some

### Konami 007121 chipset (Contra / Combat School)
**TIER 1 — MATURE**
Via jotego/jtcores:
- `contra` — Contra / Gryzor (7 games)
- `comsc` — Combat School / Boot Camp (3 games)
- `flane` — Fast Lane (3 games)
- `mx5k` — MX5000 / Flak Attack (3 games)
- `labrun` — Labyrinth Runner / Trick Trap (4 games)

### Konami 007121 / 052109 chipset (Aliens / Crime Fighters era)
**TIER 1 — MATURE**
Via jotego/jtcores:
- `aliens` — Aliens, Crime Fighters, Gang Busters, Super Contra, Thunder Cross (14 games)
- `ajax` — Ajax / Typhoon (3 games)
- `mikie` — Mikie / High School Graffiti (4 games)

### Konami Bubble System (Gradius era)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BubSys_MiSTer
Gradius / Nemesis. Known issue: Vic Viper disappears in specific scenario (fixable pending chip decap). Solid otherwise.

### Konami Salamander (Life Force)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Salamander_MiSTer
Salamander / Life Force (GX456). Same disappearing sprite issue as BubSys.

### Konami Gyruss
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Gyruss_MiSTer
Gyruss. Timing-accurate. AY-3-8910 volume scale needs tuning.

### Konami Time Pilot
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TimePilot_MiSTer
Time Pilot. Timing-accurate. Volume tuning pending.

### Konami Time Pilot '84
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TimePilot84_MISTer
Time Pilot '84. MC6809E + Z80, SN76489 audio.

### Konami Tutankham
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Tutankham_MiSTer

### Konami Pooyan
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Pooyan_MiSTer

### Konami Rush'n Attack (Green Beret)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-RushnAttack_MiSTer

### Konami Juno First
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-JunoFirst_MiSTer

### Konami Iron Horse
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-IronHorse_MiSTer
Known issues: sprite flickering incomplete, high score saving can lockup, YM2203 SSG volume needs verification.

### Konami Jackal (Top Gunner)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer
Multiple variants. Requires SDRAM. Minor attract mode and tilemap glitch known.

### Konami Twin16 hardware (Vulcan Venture / Gradius II era)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `twin16`)
Vulcan Venture / Gradius II, Devilish (+ others on same PCB).

### Konami 007232 / TMNT hardware (TMNT, Aliens II)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `tmnt`)
TMNT (4-player), TMNT2/Turtles in Time is in `riders` core. Note: video ROM check in service mode reports ROMs as BAD (does not affect gameplay).

### Konami Simpsons / Vendetta hardware (052109/051960)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `simson`)
The Simpsons (2P and 4P), Vendetta (World/US/Asia), Crime Fighters 2 — 17 game variants.

### Konami Sunset Riders / Lightning Fighters (053251/053246 era)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `riders`)
Sunset Riders (4-player), TMNT: Turtles in Time (4-player), Lightning Fighters, Golfing Greats, Trigon — 20+ variants.

### Konami Run and Gun / Slam Dunk (1993)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `rungun`)
Run and Gun / Slam Dunk. 6 variants.

### Konami WWF Superstars
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `wwfss`)
WWF Superstars (6 variants).

### Konami X-Men (6-player)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `xmen`)
X-Men arcade (2P/4P/6P variants). Complex 055555 layer mixer chip required.

### Konami Haunted Castle (castle hardware)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `castle`)
Haunted Castle / Akuma-Jou Dracula (6 variants).

### Konami Parodius / Surprise Attack (paroda)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `paroda`)
Parodius Da!, Surprise Attack (7 variants).

### Konami Gradius 3 (grad3)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/jotego/jtcores (core: `grad3` — schematics only, no HDL found)
Directory contains only schematics. No playable binary yet.

### Konami Surprise Attack / Premier Soccer (prmr, paroda continuation)
See `paroda` and `prmr` entries.
`prmr` — Premier Soccer (2 variants). TIER 1.

### Konami SNK Triple Z80 era (Psycho Soldier / Ikari Warriors — see SNK section)

### Konami 32-bit era (GX, Hornet, etc.)
**TIER 3 — UNTOUCHED**
Konami GX (Gradius 4, Silent Scope), Konami Hornet, Konami M2, ZR107 — no MiSTer cores.
Custom chips: 058143, 058144, SHARC DSPs, custom polygon ASICs.
MAME quality: Good (GX), fair (Hornet/M2 — no 3D hardware accurate).
Difficulty: Very Complex. 3D hardware, DSPs.

---

## Part 3: Namco

### Namco Galaxian hardware
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Galaxian_MiSTer
Galaxian and variants (ZigZag shares same hardware).
Also: https://github.com/MiSTer-devel/Arcade-ZigZag_MiSTer — Galaxian hardware

### Namco Pac-Man board
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer
14 games: Pac-Man, Ms. Pac-Man, Pac-Man Plus, Puck Man, Crush Roller, Dream Shopper, Mr. TNT, Lizard Wizard, etc.

### Namco Galaga hardware (Namco Galaga)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Galaga_MiSTer
Galaga. Hi-score save. Minor inherited sound CPU bug.

### Namco Gaplus / Galaga 3
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Gaplus_MiSTer

### Namco Bosconian / Pole Position era (Namco Galaxian successor)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Bosconian_MiSTer
Bosconian. Both Namco and Midway DIP variants.

### Namco Dig Dug
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-DigDug_MiSTer

### Namco Xevious
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Xevious_MiSTer

### Namco Tower of Druaga / Mappy era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Druaga_MiSTer
Also jotego fork: https://github.com/jotego/Arcade-Druaga_MiSTer

### Namco Pac-Land
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `paclan`)
Pac-Land (6 variants — Japan, World, Midway, Bally-Midway).

### Namco Rolling Thunder / Metro-Cross era (Namco System 86)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `thundr`)
Rolling Thunder (5 variants), Metro-Cross (2), Sky Kid Deluxe (2), Wonder Momo (1), Return of Ishtar (1), Genpei Toma Den / Hopping Mappy.

### Namco System I / System II (Assault, Dangerous Seed era)
**TIER 1 — MATURE** (via jotego `shouse`)
Repo: https://github.com/jotego/jtcores (core: `shouse`)
Splatter House, Galaga '88, Pac-Mania, Dragon Spirit, Dangerous Seed, Tank Force, Pro Yakyuu World Stadium, Rompers, Souko Ban Deluxe, Youkai Douchuuki, Shadowland, Quester, Face Off, and more — 30+ variants.
Note: `shouse` = "Stone House" — Namco System I/II hardware era.

### Namco System 21 / 22 / System FL (Starblade, Ridge Racer era)
**TIER 3 — UNTOUCHED**
No MiSTer core. System 21 uses custom DSPs for 3D polygon rendering.
MAME quality: Fair (System 21 partial 3D), Poor (System 22 — limited).
Difficulty: Very Complex. Custom 3D pipeline.

### Namco System 23 / Super System 23 (Point Blank 3, etc.)
**TIER 3 — UNTOUCHED**
Custom 3D hardware.

---

## Part 4: Sega

### Sega VIC-Z80 / Gremlin era (pre-System 1)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-SegaVICZ80_MiSTer
26 games total; 2 fully working (Carnival, Pulsar), most lack sound, 2 non-functional.

### Sega System 1 / 2
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SEGASYS1_MiSTer
18 games: Wonder Boy, Up'n Down, Flicky, My Hero, Pitfall II, Mister Viking, Star Jacker, Sega Ninja, and others. 3 games unsupported (Choplifter, Gardia, Noboranka).

### Sega Super Locomotive (early Sega raster)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SuprLoco_MiSTer

### Sega Congo Bongo (isometric)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CongoBongo_MiSTer

### Sega Pengo (Z80 + custom tilemap)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Pengo_MiSTer

### Sega Zaxxon / Super Zaxxon
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Zaxxon_MiSTer
3 games: Zaxxon, Super Zaxxon, Future Spy.

### Sega Dottori-Kun (test ROM hardware)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-DottoriKun_MiSTer

### Sega Bank Panic (Sanritsu license)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-BankPanic_MiSTer
Pre-release, 1 open issue.

### Sega System 16A / 16B
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `s16`, `s16b`)
50+ games: Altered Beast, Golden Axe, Shinobi, Wonderboy in Monster Land, Alex Kidd, Outrun (System 16 version), SDI, Quartet, Sukeban Jansi Ryuko, Passing Shot, and many more. Encrypted games require correct FD1089/FD1094 key data.

### Sega System 18
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `s18`)
Games including Bloxeed, D.D. Crew, Moonwalker, Shadow Dancer, Laser Ghost.

### Sega Out Run / Turbo Out Run / Super Hang-On
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `outrun`)
Out Run (all variants + Enhanced Edition), Turbo Out Run (all variants).

### Sega Super Hang-On (non-OutRun version)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `shanon`)
Super Hang-On (5 variants).

### Sega System 24 (Hotrod, Scramble Spirits)
**TIER 3 — UNTOUCHED**
Custom 315-5296 I/O chip. MAME quality: Good.
Difficulty: Moderate.

### Sega System 32 (Golden Axe II, Rad Mobile, Spiderman)
**TIER 3 — UNTOUCHED**
Custom 315-5441 V60 CPU board. MAME quality: Good.
Difficulty: Complex. V60 CPU, custom GFX ASICs.

### Sega X Board (After Burner II, G-Loc, Thunder Blade)
**TIER 3 — UNTOUCHED**
Custom scaling/rotation ASICs. MAME quality: Good.
Difficulty: Complex. Multiple scaling chips.

### Sega Y Board (G-Loc, Power Drift)
**TIER 3 — UNTOUCHED**
More advanced than X Board. Custom polygon-like hardware.
MAME quality: Fair-Good.
Difficulty: Very Complex.

### Sega Model 1 (Virtua Fighter, Virtua Racing)
**TIER 3 — UNTOUCHED**
Custom floating-point DSPs (TGP). First Sega 3D hardware.
MAME quality: Good (TGP softfloat implemented).
Difficulty: Very Complex. Custom TGP DSPs.

### Sega Model 2 (Daytona, Virtua Fighter 2)
**TIER 3 — UNTOUCHED**
SHARC DSP + custom ADSP-21062 based rendering. MAME quality: Fair.
Difficulty: Very Complex.

### Sega Model 3 (Scud Race, Virtua Fighter 3)
**TIER 3 — UNTOUCHED**
PowerPC + custom 3D ASICs. MAME quality: improving but not full speed.
Difficulty: Extremely Complex. Real-Time 3D custom silicon.

### Sega ST-V (Titan Video — Sega Saturn arcade)
**TIER 3 — UNTOUCHED**
ST-V = Saturn CPU/GPU in arcade form. See Saturn console (TIER 2 WIP).
MAME quality: Excellent.
Difficulty: Complex — same as Saturn.

### Sega NAOMI / Naomi 2
**TIER 3 — UNTOUCHED**
Dreamcast-derived. PowerVR2 GPU.
MAME quality: Good (NAOMI 1 mostly works, NAOMI 2 partial).
Difficulty: Extremely Complex. PowerVR2 custom silicon.

### Sega Hikaru / Chihiro / Lindbergh
**TIER 3 — UNTOUCHED**
Modern 3D arcade hardware, beyond FPGA scope.

---

## Part 5: SNK

### SNK NeoGeo (MVS / AES / CD)
**TIER 1 — MATURE** `[ACCURACY CONCERN — encrypted ROMs not supported]`
Repo: https://github.com/MiSTer-devel/NeoGeo_MiSTer
Supports MVS, AES, CDZ. Requires decrypted MAME or Darksoft ROM sets — encrypted ROMs NOT supported. Most games need 32MB, some need 64MB, 8 games need 128MB.

### SNK Triple Z80 era (Ikari Warriors, Psycho Soldier, Athena, Alpha Mission)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-SNK_TripleZ80_MiSTer (WIP, ASO/Alpha Mission focus)
Repo: https://github.com/MiSTer-devel/Arcade-IkariWarriors_MiSTer (beta — Ikari Warriors + Victory Road)
Repo: https://github.com/MiSTer-devel/Arcade-TNKIII_MiSTer (beta — T.N.K. III)
Repo: https://github.com/MiSTer-devel/Arcade-Athena_MiSTer (beta — Athena, Country Club)
Plan: Unify all into SNK Triple Z80 core. Currently separate beta releases.

### SNK 68K era (P.O.W., Ikari III, Street Smart)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/va7deo/SNK68 (beta)
4 games: P.O.W., Ikari III, Street Smart, SAR: Search and Rescue. Minor screen tearing in Ikari III, audio issues.

### SNK Alpha Denshi M68K (Alpha68K — Gang Wars, Time Soldiers)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/va7deo/alpha68k (beta)
5 games implemented: Gang Wars, Super Champion Baseball, Sky Adventure, Time Soldiers, Sky Soldiers. Gold Medalist needs ROM dump. More games WIP.

### SNK Prehistoric Isle
**TIER 1 — MATURE**
Repo: https://github.com/va7deo/PrehistoricIsle

### SNK NeoGeo Pocket / NeoGeo Pocket Color
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `ngp` / `ngpc`)
Both monochrome NGP and NGP Color supported. MiSTer and Pocket only (frame buffering required).

---

## Part 6: Taito

### Taito Space Invaders / early Z80 era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SpaceInvaders_MiSTer
Space Invaders and variants.

### Taito SJ System (Elevator Action, Jungle King)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TaitoSystemSJ_MiSTer
11 games: Elevator Action, Jungle King/Hunt, Alpine Ski, Bio Attack, High Way Race, Pirate Pete, Space Cruiser, Space Seeker, Time Tunnel, Water Ski, Wild Western. Known issues: sprite positioning glitches. 4 games unsupported.

### Taito Arkanoid hardware (Bubble Bobble era)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Arkanoid_MISTer
Arkanoid.

### Taito Bubble Bobble / Tokio hardware
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `bubl`)
14 games: Bubble Bobble (all variants + Lost Cave hacks), Tokio/Scramble Formation (4 variants).

### Taito Arkanoid 2 / kiwi hardware
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `kiwi`)
Arkanoid Revenge of DOH, Dr. Toppel's Adventure, Extermination, Insector X, Kageki — 12 games.

### Taito FairyLand Story / flstory hardware
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `flstory`)
The FairyLand Story, N.Y. Captor (Cycle Shooting), Onna Sanshirou, Rumba Lumber, Victorious Nine, Bronx (bootleg) — 8 games. Hardware-accurate including light gun support.

### Taito Rastan Saga
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `rastan`)
Rastan Saga, multiple regional variants.

### Taito Slap Fight / Tiger Heli (Toaplan-designed for Taito)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SlapFight_MiSTer
3 games: Slap Fight, Tiger Heli, Get Star.

### Taito Crazy Balloon
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CrazyBalloon_MiSTer

### Taito Irem M57 — Tropical Angel
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TropicalAngel_MiSTer
Irem M57 hardware — Tropical Angel only.

### Taito Kick & Run / Kiki Kaikai
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-KickAndRun_MiSTer
Kick And Run works. Kiki Kaikai blocked by missing MCU dump.

### Taito F2 (Cameltry, Growl, Gun Frontier, etc.)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer
14 games implemented: Cameltry, Dino Rex, Don Doko Don, Thunder Fox, Drift Out, Final Blow, Growl, Gun Frontier, Liquid Kids, Mega Blast, The Ninja Kids, PuLiRuLa, Solitary Fighter, Super Space Invaders '91. Active development, no formal release yet.

### Taito F3 (Bubble Bobble 2, Darius Gaiden, etc.)
**TIER 3 — UNTOUCHED**
No MiSTer core found.
Custom chips: TC0630FDP, TC0480SCP, TC0100SCN, ES5505 sound, M68EC020 CPU.
MAME quality: Excellent.
Difficulty: Complex. 68EC020, custom sprite/tile ICs, ENSONIQ sound.
Chip reuse potential: Some TC0xxx tile logic from F2 core may apply.

### Taito B System (Ninja Warriors, Rastan II)
**TIER 3 — UNTOUCHED**
No MiSTer core.
Custom chips: TC0180VCU, TC0140SYT.
MAME quality: Good.
Difficulty: Moderate-Complex.

### Taito X System (UN Squadron / Area 88, etc.)
**TIER 3 — UNTOUCHED** (separate from CPS1 — different board)
No MiSTer core (note: CPS-based UN Squadron is in CPS1 core as `area88`).
Taito X used different boards for different games.

### Taito Z System (Continental Circus, Night Striker, etc.)
**TIER 3 — UNTOUCHED**
Custom Z80/68000 hybrid, multi-layer parallax, sprite-scaling.
MAME quality: Good.
Difficulty: Complex.

### Taito H System (Master of Weapon, etc.)
**TIER 3 — UNTOUCHED**
No MiSTer core.
MAME quality: Good.
Difficulty: Moderate.

### Taito L System (Plotting, Puzznic, etc.)
**TIER 3 — UNTOUCHED**
No MiSTer core.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 7: Irem

### Irem M52 (Traverse USA, Mr. Heli)
**TIER 1 — MATURE** (partial)
Repo: https://github.com/MiSTer-devel/Arcade-TraverseUSA_MiSTer
Traverse USA on M52 hardware. Other M52 games not covered.

### Irem M62 (Kung-Fu Master, Lode Runner, Spelunker)
**TIER 1 — MATURE** `[ACCURACY CONCERN — Kung-Fu Master sprite color bug]`
Repo: https://github.com/MiSTer-devel/Arcade-IremM62_MiSTer
Lode Runner 1-4, Kung Fu Master, Horizon, Battle Road, Spelunker 1-2, Kid Niki, Youjyudn. Kung-Fu Master has sprite color problem. Lot Lot not fully implemented.

### Irem M72 (R-Type, Dragon Breed, etc.)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-IremM72_MiSTer
Also: https://github.com/RndMnkIII/Irem_M72_MiSTer (fork with Analogizer support)
12 games: R-Type (multiple regions), Ninja Spirit, Image Fight, Legend of Hero Tonma, Mr. Heli, Gallop, Air Duel, Dragon Breed, X-Multiply, Hammerin' Harry, R-Type II. Emulated MCU for several games.

### Irem M84 (part of M72 core)
**TIER 1 — MATURE**
Covered in M72 core above. M84 = M72 derivative.

### Irem M90 / M97 / M99 (Bomberman World, Risky Challenge)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-IremM90_MiSTer
2 games supported: Bomber Man, Bomber Man World. 4 games unsupported due to video timing/bank switching issues.

### Irem M92 (In the Hunt, Ninja Baseball Batman, Undercover Cops)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer
Numerous games including In the Hunt, R-Type Leo, Hook, Gunforce, Blade Master, Mystic Riders, Undercover Cops, Ninja Baseball Batman. 287 commits, active.

### Irem M107 (Prime Goal, Undercover Cops sequel board)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-IremM107_MiSTer
Based on M92 core with extra tile layer. 308 commits.

---

## Part 8: Data East

### Data East BurgerTime / Express Raider era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BurgerTime_MiSTer
Repo: https://github.com/MiSTer-devel/Arcade-ExpressRaider_MiSTer

### Data East Karnov / Boulder Dash era (karnov / cop / slyspy)
**TIER 1 — MATURE**
Via jotego/jtcores:
- `karnov` — Karnov
- `cop` — RoboCop, Fighting Fantasy, Hippodrome (6 games)
- `slyspy` — Sly Spy, Secret Agent, Boulder Dash (7 games)
- `ninja` — Bad Dudes, Heavy Barrel, Bandit (5 games)
- `midres` — Midnight Resistance (4 games)

### Data East Karate Champ (kchamp)
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `kchamp`)
Karate Champ, Karate Dou — 10 variants.

### Data East Finalizer
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Finalizer_MiSTer

### Data East DECO-32 / 156 era (Lethality era / 1990s)
**TIER 3 — UNTOUCHED**
No MiSTer core for DECO-32 system (Captain America, Rohga, Tattoo Assassins).
Custom chips: DECO 156, DECO 141.
MAME quality: Good.
Difficulty: Moderate-Complex.

---

## Part 9: Toaplan

### Toaplan Version 1 (Truxton / Hellfire / Zero Wing / OutZone)
**TIER 1 — MATURE**
Multiple repos by va7deo:
- https://github.com/va7deo/zerowing — 4 games: Tatsujin/Truxton, Hellfire, Zero Wing, OutZone
- https://github.com/va7deo/vimana — 2 games: Same! Same! Same!/Fire Shark, Vimana
- https://github.com/va7deo/demonswld — 1 game: Demon's World (beta)
- https://github.com/va7deo/rallybike — 1 game: Rally Bike

Also via jotego/jtcores:
- `rbike` — Rally Bike (separate implementation)

### Toaplan SlapFight / Tiger Heli (Toaplan for Taito, early)
See Taito section above — Arcade-SlapFight_MiSTer covers these.

### Toaplan Version 2 (Batsugun / V-V / Knuckle Bash)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/atrac17/Toaplan2 (beta)
Released: Teki Paki, Tatsujin Oh, Whoopee!!, Snow Bros. 2 (4 games).
WIP: Ghox, Dogyuun.
Not implemented: Dogyuun full, Knuckle Bash, FixEight, V-V, Batsugun.

---

## Part 10: Cave

### Cave 1st Generation (68000-based: DonPachi, DoDonPachi)
**TIER 1 — MATURE** `[WIP — several games unimplemented]`
Repo: https://github.com/MiSTer-devel/Arcade-Cave_MiSTer
Written in Chisel. 8 games public: DonPachi, DoDonPachi, ESP Ra.De., Dangun Feveron, Uo Poko, Guwange, Gaia Crusaders, Thunder Heroes.
WIP: Hotdog Storm (1 game).
Unimplemented: Air Gallet, Koro Koro Quest, Mazinger Z, Gogetsuji Legends, Power Instinct 2, Pretty Soldier Sailor Moon, The Ninja Master (7 games).

### Cave 2nd Generation (SH-3 based: Mushihimesama, Deathsmiles, etc.)
**TIER 3 — UNTOUCHED**
No MiSTer core for Cave SH-3 hardware.
Custom chips: custom 2D sprite ASICs.
MAME quality: Good.
Difficulty: Very Complex. SH-3 CPU, custom sprite ICs.

---

## Part 11: Jaleco

### Jaleco Exerion
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-Exerion_MiSTer
Author's first FPGA project. No formal release.

### Jaleco Psychic 5
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-Psychic5_MiSTer
SNAC WIP, functional but pre-release.

### Jaleco Blue Print / Grasspin / Saturn
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BluePrint_MiSTer
3 games: Blue Print, Grasspin, Saturn.

### Jaleco Chameleon
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-Chameleon_MiSTer
Beta; joystick mapping issues.

### Jaleco Mega System 1 (Type A)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/va7deo/MegaSys1_A (beta)
14 games including P-47, Ninja Kazan, Astyanax, Rod-Land, Saint Dragon, Hachoo, Soldam, E.D.F. Some games still WIP.

### Jaleco Mega System 1 (Type B/C) and other Jaleco
**TIER 3 — UNTOUCHED**
No MiSTer core for Mega System 1 B/C or later Jaleco hardware.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 12: Technos / Nekketsu

### Technos Double Dragon hardware
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `dd`)
Double Dragon — 7 variants.

### Technos Double Dragon II
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `dd2`)
Double Dragon II — 4 variants.

### Technos Nekketsu / Kunio-kun
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `kunio`)
Renegade / Nekketsu Kouha Kunio-kun — 4 variants.

### Technos V-Ball
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-VBall_MiSTer

### Technos WWF Wrestlefest (later hardware)
**TIER 3 — UNTOUCHED**
No MiSTer core for later Technos hardware.

---

## Part 13: Tecmo

### Tecmo Rygar / Gemini Wing / Silkworm
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Tecmo_MiSTer
3 games. Old Arcade-Rygar_MiSTer is deprecated in favor of this.

### Tecmo Solomon's Key
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SolomonsKey_MiSTer

### Tecmo Kick & Run / Ninja Gaiden arcade
**TIER 2 — IN DEVELOPMENT** (see Taito KickAndRun entry)
Also via jotego:
- `gaiden` — Ninja Gaiden (arcade), Wild Fang, Raiga, Tecmo Knight, Shadow Warriors — 9 games. TIER 1.

---

## Part 14: Williams / Bally Midway

### Williams Defender (1st gen)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Defender_MiSTer

### Williams Robotron / Joust / Stargate era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Robotron_MiSTer
7 games: Robotron 2084, Joust, Stargate, Bubbles, Sinistar, Splat!, PlayBall!

### Williams Joust 2
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Joust2_MiSTer

### Williams Mystic Marathon
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MysticMarathon_MiSTer

### Williams Inferno (2nd gen)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Inferno_MiSTer

### Williams Turkey Shoot
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TurkeyShoot_MiSTer

### Midway MCR1
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MCR1_MiSTer
2 games: Kick, Solar Fox. (Draw Poker not supported).

### Midway MCR2 (Tron, Satan's Hollow)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MCR2_MiSTer
6 games: Tron, Domino Man, Kozmik Krooz'r, Satan's Hollow, Two Tigers, Wacko.

### Midway MCR3 (Discs of Tron, Tapper, Journey)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MCR3_MiSTer
Also: Arcade-MCR3Mono, Arcade-MCR3Scroll
4 games: Timber, Tapper, Discs of Tron, Journey.

### Midway MCR4 / later (Spy Hunter, RAMPAGE era)
**TIER 3 — UNTOUCHED**
No MiSTer core.
MAME quality: Good.
Difficulty: Moderate.

### Midway Y-Unit / T-Unit (Mortal Kombat)
**TIER 3 — UNTOUCHED**
No MiSTer core. DCS audio, custom ASIC.
MAME quality: Good.
Difficulty: Complex. Custom DSP (DCS), proprietary video ASICs, large ROM sets.

### Midway Seattle / Vegas (San Francisco Rush, NFL Blitz)
**TIER 3 — UNTOUCHED**
3D hardware, beyond FPGA scope.

---

## Part 15: Atari Arcade

### Atari Asteroids / Asteroids Deluxe (vector)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Asteroids_MiSTer
Repo: https://github.com/MiSTer-devel/Arcade-AsteroidsDeluxe_MiSTer

### Atari Battle Zone (vector)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BattleZone_MiSTer

### Atari Black Widow (vector)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BlackWidow_MiSTer

### Atari Lunar Lander (vector)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-LunarLander_MiSTer

### Atari Missile Command
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MissileCommand_MiSTer

### Atari Centipede / Millipede
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Centipede_MiSTer

### Atari Breakout / Super Breakout
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Breakout_MiSTer
Repo: https://github.com/MiSTer-devel/Arcade-SuperBreakout_MiSTer

### Atari Canyon Bomber
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CanyonBomber_MiSTer

### Atari Dominos / Sprint 1 / Sprint 2 / Subs / Ultratank
**TIER 1 — MATURE**
Repos: Arcade-Dominos_MiSTer, Arcade-Sprint1_MiSTer, Arcade-Sprint2_MiSTer, Arcade-Subs_MiSTer, Arcade-Ultratank_MiSTer

### Atari Berzerk / Frenzy (Stern)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Berzerk_MiSTer
Repo: https://github.com/MiSTer-devel/Arcade-Frenzy_MiSTer

### Atari System 1 (Marble Madness, Road Runner, Indiana Jones)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer
5 games. Known graphical bugs in Indiana Jones (cocktail/set 3). SDRAM required. 13 commits, early stage.

### Atari A-Tetris (Tetris arcade)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-ATetris_MiSTer

### Atari Food Fight
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-FoodFight_MiSTer
MC68000 + Pokey.

### Atari Crystal Castles
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CrystalCastles_MiSTer
Built from original schematics.

### Atari Gauntlet
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Gauntlet_MiSTer
3 games: Gauntlet, Gauntlet II, Vindicators II. SDRAM required. EPROM settings lost on power off.

### Atari Space Race / Computer Space (Nutting)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SpaceRace_MiSTer
Repo: https://github.com/MiSTer-devel/Arcade-ComputerSpace_MiSTer

### Atari Pong / related
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Pong_MiSTer

### Atari Skydiver / Stunt Cycle era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SkySkipper_MiSTer

### Atari System 2 (later raster — Marble Madness 2, S.T.U.N. Runner)
**TIER 3 — UNTOUCHED**
Quad TMS34010 based. MAME quality: Good.
Difficulty: Very Complex. Multiple DSPs.

### Atari Hard Drivin' / Race Drivin' (ADSP-2100 3D)
**TIER 3 — UNTOUCHED**
Custom geometric DSP. MAME quality: Fair.
Difficulty: Very Complex.

---

## Part 16: Nintendo Arcade

### Nintendo Donkey Kong hardware
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-DonkeyKong_MiSTer
Also: Arcade-DonkeyKongJunior_MiSTer, Arcade-DonkeyKong3_MiSTer

### Nintendo Mario Bros. arcade
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MarioBros_MiSTer

### Nintendo Popeye arcade
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Popeye_MiSTer

### Nintendo VS System (arcade NES)
**TIER 2 — IN DEVELOPMENT** `[integrated in NES core]`
Repo: https://github.com/MiSTer-devel/NES_MiSTer
The NES core has some VS System support but it's not a primary feature and coverage is incomplete. No dedicated VS System arcade core.

### Nintendo PlayChoice-10
**TIER 3 — UNTOUCHED**
No dedicated MiSTer core.
Would build on NES/VS System base.
Difficulty: Moderate.

---

## Part 17: Psikyo

### Psikyo 1st Generation (Strikers 1945, Dragon Blaze era — SH-2 based)
**TIER 3 — UNTOUCHED**
No MiSTer core found via any search.
Hardware: Psikyo PS2V1/PS5/PS3-V1 boards. Hitachi SH-2 CPU, custom sprite IC.
MAME quality: Excellent (near-perfect).
Difficulty: Complex. Custom sprite hardware + SH-2.
Community: No known FPGA work.

### Psikyo SH403 / SH404 (Gunbird, Sengoku Ace)
**TIER 3 — UNTOUCHED**
Same assessment as above. jotego has `gunbird2` directory with schematics only.

---

## Part 18: Nichibutsu

### Nichibutsu Crazy Climber / Terra Cresta era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CrazyClimber_MiSTer
Repo: https://github.com/va7deo/TerraCresta

### Nichibutsu Armed F / Terra Force
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/va7deo/ArmedF (WIP)

### Nichibutsu GV-1412 (Cosmo Police Galivan / Dangar)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-Galivan_MiSTer
2 games: Cosmo Police Galivan, UFO Robo Dangar. 29 commits, no release.

---

## Part 19: UPL (UPL Co.)

### UPL Nova 2001 / Raiders 5 (Ninja-Kun hardware)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-NinjaKun_MiSTer
3 games: Ninja-Kun, Raiders 5, Nova 2001.

---

## Part 20: Kaneko

### Kaneko 16 / Kaneko Super Nova System
**TIER 3 — UNTOUCHED**
No MiSTer core for Kaneko hardware (Air Buster, B-Wings sequel, Magical Crystal, DJ Boy, etc.)
Custom chips: KC-001, KC-002 sprite ICs.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 21: Banpresto

### Banpresto / Video System (Aero Fighters / Sonic Wings)
**TIER 3 — UNTOUCHED**
No MiSTer core.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 22: Atlus / NMK

### Atlus / NMK (Hacha Mecha Fighter, etc.)
**TIER 3 — UNTOUCHED**
No MiSTer core.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 23: Tehkan / Tecmo (early)

### Tehkan Bomb Jack
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-BombJack_MiSTer

### Tehkan World Cup / Gridiron Fight
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `wc`)
6 games: Tehkan World Cup (4 variants), Gridiron Fight, All American Football.

---

## Part 24: Seibu Kaihatsu / TAD

### Seibu Toki / TAD Corporation
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `toki`)
Toki / JuJu Densetsu.

### Seibu SPI System (Raiden 2, Four-Den)
**TIER 3 — UNTOUCHED**
No MiSTer core for Seibu SPI.
Custom V30 CPU variant, OKI ADPCM.
MAME quality: Good.
Difficulty: Complex. Custom security chips.

---

## Part 25: Konami Racing / Namco Vintage misc

### Konami Road Fighter / Track & Field era
See entries under Konami 005885 section.

### Namco Pole Position
**TIER 3 — UNTOUCHED**
No MiSTer core (separate from Galaxian board).
Custom Namco chips: Namco custom 06xx/51xx/52xx.
MAME quality: Good.
Difficulty: Moderate.

---

## Part 26: Miscellaneous Notable Arcade

### Universal Lady Bug / Snap Jack
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-LadyBug_MiSTer

### Universal Mr. Do! / Mr. Do's Castle
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MrDo_MiSTer

### Universal Cosmic series (Space Panic, Cosmic Alien)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Cosmic_MiSTer
5 games: Space Panic, Cosmic Alien, Devil Zone, Magical Spot, No Mans Land.

### Universal Cosmic Guerilla (TMS9980)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CosmicGuerilla_MiSTer
Uses TMS9900 (approximation of TMS9980).

### Exidy Universal Game Board II (Venture, Mouse Trap, Targ)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Exidy2_MiSTer
5 of 9 games working: TARG, Spectar, Venture, Mouse Trap, Pepper II. Analog sound incomplete.

### Cinematronics Freeze / Jack the Giantkiller
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Freeze_MiSTer
5 games: Jack the Giantkiller, Freeze, Zzyzzyxx, SuperCasino, Tri-Pool.

### Capcom Pang / Super Pang / Block Block
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `pang`)
3 games. "Allegedly 100% accurate" hardware recreation.

### Capcom Caliber 50
**TIER 1 — MATURE**
Repo: https://github.com/jotego/jtcores (core: `cal50`)

### Namco/Midway Rally-X / New Rally-X
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-RallyX_MiSTer

### Gremlin Industries Blockade era
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Blockade_MiSTer
4 games: Blockade, CoMotion, Hustle, Blasto.

### Taito Crazy Balloon (1981)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-CrazyBalloon_MiSTer

### Irem M57 — Tropical Angel
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TropicalAngel_MiSTer

### Bagman (Stern/Valadon)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Bagman_MiSTer

### Data East Finalizer
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Finalizer_MiSTer

### Technos Scooter Shooter
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-ScooterShooter_MiSTer

### Nichibutsu Penguin Kun Wars
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-PenguinKunWars_MiSTer

### Nichibutsu River Patrol
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-RiverPatrol_MiSTer
Based on Crazy Climber core.

### Jaleco Naughty Boy (WIP, 2025)
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Arcade-NaughtyBoy_MiSTer

### Poly-Play (VEB Polytechnik, East Germany)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-PolyPlay_MiSTer
Single East German multi-game arcade cabinet.

### TIA-MC1 (USSR arcade)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TIAMC1_MiSTer
Soviet arcade, games including Gorodki.

### Sega Astrocade (Bally / Midway video game)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Astrocade_MiSTer
Also: https://github.com/MiSTer-devel/Astrocade_MiSTer (home console version)

### SNK Prehistoric Isle
**TIER 1 — MATURE**
Repo: https://github.com/va7deo/PrehistoricIsle

### Kiwako Mr. Jong
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-MrJong_MiSTer
Mr. Jong, Crazy Blocks, Block Buster.

### Orca/Sesame Vastar
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Vastar_MiSTer

### Irem Traverse USA (M52)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-TraverseUSA_MiSTer

### Taito/SNK Jailbreak (Konami hardware)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Jailbreak_MiSTer

### Technos XSleena / Solar Warrior
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-XSleena_MiSTer
Also: https://github.com/RndMnkIII/Xain_Sleena_MiSTer (Analogizer variant)

### Taito Kick and Run / Mr. Goemon
**TIER 2 — IN DEVELOPMENT**
See above.

### Taito Performan (based on Slap Fight)
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-Performan_MiSTer

### Nintendo Sky Skipper
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Arcade-SkySkipper_MiSTer

---

## Part 27: Console Hardware

### Nintendo NES / Famicom
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/NES_MiSTer
628 commits, 25 contributors. 100+ mappers. FDS, expansions. Mature.

### Nintendo SNES / Super Famicom
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/SNES_MiSTer
Mature. Cycle-accurate CPU/PPU.

### Nintendo Game Boy / Game Boy Color
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Gameboy_MiSTer

### Nintendo Game Boy Advance
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/GBA_MiSTer

### Nintendo N64
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/N64_MiSTer
33 commits, 58 open issues. Still in active early development.

### Sega Master System / Game Gear
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/SMS_MiSTer

### Sega Genesis / Mega Drive
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/Genesis_MiSTer

### Sega Mega CD / Sega CD
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/MegaCD_MiSTer
~150 games tested. 2 known games with graphical glitches. US/EU regions only tested.

### Sega 32X
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/S32X_MiSTer
Most games playable. Audio/graphics bugs present. No cheats/saves.

### Sega Saturn
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Saturn_MiSTer
Status: WIP/Beta. Requires dual 128MB SDRAM. Limited game compatibility.

### NEC PC Engine / TurboGrafx-16 / PC Engine CD
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/TurboGrafx16_MiSTer
Cycle-accurate CPU/VDC rewrite. CD-ROM, Super CD-ROM, Arcade Card. 430 commits.

### NEC PC-FX
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/PCFX_MiSTer
85 commits, minimal documentation. Status unclear.

### SNK NeoGeo (see arcade section above)

### SNK NeoGeo Pocket / Color
**TIER 1 — MATURE**
See jotego ngp/ngpc cores above.

### Atari Jaguar
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/Jaguar_MiSTer
All known games boot; many have glitches, no audio in some. CD support present.

### Sony PlayStation 1
**TIER 1 — MATURE** `[ACCURACY CONCERN — CPU exceptions, GPU mask bits, GTE pipeline]`
Repo: https://github.com/MiSTer-devel/PSX_MiSTer
Many games working. Known incomplete: CPU exception paths, GPU mask bits, multitap, GTE pipeline delays, MDEC timing.

### Nintendo Super Game Boy
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/SGB_MiSTer

### Atari 2600 / 5200 / 7800 / Lynx
**TIER 1 — MATURE**
Repos: Atari2600_MiSTer, Atari7800_MiSTer, Atari800_MiSTer, AtariLynx_MiSTer

### Sharp X68000
**TIER 2 — IN DEVELOPMENT**
Repo: https://github.com/MiSTer-devel/X68000_MiSTer
Explicitly "Work in progress." FDD and HDD support. Controller variety implemented.

### WonderSwan / WonderSwan Color
**TIER 1 — MATURE**
Repo: https://github.com/MiSTer-devel/WonderSwan_MiSTer
Most official games playable. Only 1 game documented non-working.

### Bandai WonderSwan Crystal
**TIER 1 — MATURE** (via WonderSwan core)

### Casio PV-1000 / PV-2000
**TIER 1 — MATURE**
Repos: Casio_PV-1000_MiSTer, Casio_PV-2000_MiSTer

---

## Part 28: Major TIER 3 Gaps Summary

The following systems have **no public MiSTer core** and represent the largest opportunities for future development work:

| System | Manufacturer | Key Games | MAME Quality | Difficulty | Key Custom Chips |
|--------|-------------|-----------|-------------|------------|-----------------|
| CPS3 | Capcom | Street Fighter III, JoJo's BA | Excellent | Very Complex | SH-2, CD-ROM decrypt, custom GFX |
| Taito F3 | Taito | Darius Gaiden, Bubble Bobble 2, Pulstar | Excellent | Complex | TC0630FDP, ES5505, MC68EC020 |
| Taito B System | Taito | Ninja Warriors, Rastan II | Good | Moderate | TC0180VCU, TC0140SYT |
| Taito L/H/X Systems | Taito | Puzznic, Plotting | Good | Moderate | Various TC0xxx |
| Taito Z System | Taito | Continental Circus, Night Striker | Good | Complex | Custom Z80/68K hybrid |
| Psikyo SH402/SH3 | Psikyo | Strikers 1945 series, Gunbird, Dragon Blaze | Excellent | Complex | Custom SH-2 variant, custom sprite IC |
| Cave 2nd Gen | Cave | Mushihimesama, Deathsmiles, Espgaluda | Good | Very Complex | Custom SH-3, sprite ASICs |
| Sega System 24 | Sega | Hot Rod, Scramble Spirits | Good | Moderate | 315-5296 I/O, Z80/68K |
| Sega System 32 | Sega | Golden Axe Death Adder, Alien 3 | Good | Complex | V60 CPU, 315-5441 |
| Sega X Board | Sega | After Burner II, G-Loc, Thunder Blade | Good | Complex | FD1094, scaling ASICs |
| Sega Y Board | Sega | G-Loc, Power Drift | Fair | Very Complex | Custom polygon scaling |
| Sega Model 1 | Sega | Virtua Fighter, Virtua Racing | Good | Very Complex | TGP floating-point DSP |
| Sega Model 2 | Sega | Daytona USA, VF2 | Fair | Very Complex | SHARC, ADSP-21062 |
| Sega Model 3 | Sega | Scud Race, VF3, Sega Rally 2 | Improving | Extreme | PowerPC, custom 3D ASICs |
| Sega ST-V | Sega | Cotton Boomerang, Radiant Silvergun | Excellent | Complex | Saturn hardware (SH-2 x2) |
| Sega NAOMI | Sega | Marvel vs Capcom 2, Guilty Gear XX | Good | Extreme | PowerVR2, SH-4 |
| Konami GX (68020) | Konami | Gradius 4, Sexy Parodius | Good | Complex | 058143/058144, custom ASICs |
| Kaneko 16 | Kaneko | Air Buster, B.Wings 2, DJ Boy | Good | Moderate | KC-001, KC-002 |
| Jaleco MegaSys1 B/C | Jaleco | Chimera Beast, Bio-ship Paladin | Good | Moderate | Similar to Type A |
| Data East DECO-32 | Data East | Captain America, Rohga | Good | Moderate | DECO 156, DECO 141 |
| Banpresto/VideoSys | Banpresto | Aero Fighters series | Good | Moderate | Custom ASIC |
| NMK / Atlus | NMK | Thunder Dragon 2 | Good | Moderate | Custom NMK sprite chips |
| Seibu SPI | Seibu | Raiden 2, Raiden DX | Good | Complex | V30, security custom |
| Midway Y/T-Unit | Midway | Mortal Kombat 1-3, NBA Jam | Good | Complex | DCS audio DSP, custom video |
| Nintendo VS System | Nintendo | vs. Excitebike, vs. Pinball | Good | Moderate | Based on NES hardware |
| Nintendo PlayChoice-10 | Nintendo | Various NES games | Good | Moderate | Based on NES hardware |
| Namco System 21 | Namco | Starblade, Winning Run | Fair | Very Complex | Custom DSP polygon engine |
| Namco System 22 | Namco | Ridge Racer, Cyber Commando | Fair | Very Complex | Custom 3D DSP cluster |
| Atari Hard Drivin' | Atari | Hard Drivin', Race Drivin' | Fair | Very Complex | ADSP-2100 geometric DSP |
| Atari System 2 | Atari | S.T.U.N. Runner, Paperboy | Good | Complex | Quad TMS34010 |

---

## Part 29: Chip Reuse Map for TIER 3 Targets

For developers considering new cores, existing IP that can be reused:

| Existing Component | Where Used | Reusable For |
|-------------------|------------|-------------|
| jotego fx68k | CPS1/2, S16, S18, OutRun | CPS3 (partial — SH-2 is different), Taito F3 |
| jotego jt5205 (MSM5205) | Multiple cores | Any game using MSM5205 ADPCM |
| jotego jt6295 (OKI M6295) | Multiple cores | Any game using OKI M6295 |
| jotego jt51 (YM2151) | CPS1, OutRun, etc. | Any game with YM2151 |
| jotego jt12 (YM2612) | Genesis | — |
| jotego jtopl (YM3812/OPL2) | Multiple | Any OPL2 game |
| T80 (Z80) | Dozens of cores | Any Z80 game |
| TG68 / fx68k (M68K) | Many cores | Any 68000 system |
| TC0xxx tiles (F2 core) | Taito F2 | Taito F3 has successor TC0xxx chips |
| LSPC2-A2 (NeoGeo) | NeoGeo core | — |
| SDRAM controller | Universal | All new cores |
| Cave sprite engine | Cave core | Cave 2nd gen (different architecture) |
| Irem M92 core | M92/M107 | M90 (partial) |
| Sega S16 core | S16/S18 | System 24 (partial), System 32 (partial) |

---

## Part 30: Accuracy Flags for TIER 1 Cores

These mature cores have documented accuracy concerns that could justify replacement or improvement work:

| Core | Issue | Severity |
|------|-------|----------|
| NeoGeo | No encrypted ROM support; requires pre-decrypted sets | Medium |
| CPS2 | Key-based decryption; some encrypted variants may fail | Low |
| Cave (1st gen) | 8 games unimplemented; 1 WIP | Low |
| Sega VIC-Z80 | Most games lack sound; 2 non-functional | Medium |
| IremM62 | Kung-Fu Master sprite color bug; Lot Lot incomplete | Low |
| IremM90 | 4 of 8 games unsupported | Medium |
| NES | VS System support incomplete | Low |
| PSX | CPU exceptions, GPU mask bits, GTE pipeline, multitap | Medium |
| Saturn | WIP/Beta — not production ready | High |
| Jaguar | "Beta" — most games boot with issues | High |
| N64 | Very early — 58 open issues | High |
| SNK Triple Z80 | Fragmented across 3 separate beta repos | Medium |

---

*Generated by automated web research + GitHub API inspection.*
*All repo URLs current as of 2026-03-16.*
*jotego/jtcores contains 1050+ game variants across 73 unique core directories.*
