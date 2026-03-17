# Taito F3 MiSTer Core — Deployment Guide

## Overview

This document explains how to get the compiled Taito F3 core (`.rbf` file) and install it on a MiSTer DE-10 Nano system.

## Getting the RBF File

### Option A: Download from GitHub Actions (Recommended)

1. Go to your repository's **Actions** tab
2. Find the latest **"Taito F3 Synthesis"** workflow run (green checkmark = success)
3. Scroll down to **Artifacts** section
4. Download **`taito_f3_rbf`** (contains `taito_f3.rbf` + optional `.mra` files)
5. Unzip the artifact

### Option B: Build Locally (Linux/macOS only)

Install Quartus Prime Lite 17.0.2 from Intel:
- https://www.intel.com/content/www/us/en/software/programmable/quartus/prime/download.html

Then run:
```bash
cd chips/taito_f3/quartus
./build.sh
```

Output will be in: `output_files/taito_f3.rbf`

**Build time:** ~30–45 minutes on a modern machine (Quartus is very CPU-intensive)

## MiSTer SD Card Structure

Assuming your MiSTer SD card is mounted at `/media/fat`:

```
/media/fat/
  _Arcade/                    ← Core ROM location
    taito_f3.rbf              ← Copy the compiled RBF here
    mra/
      dariusg.mra             ← Copy all F3 .mra files here
      gunlock.mra
      elvactr.mra
      metalb.mra
      metalbu.mra
      ... (complete game list below)
  games/
    mame/                     ← Store MAME ROM ZIPs here
      dariusg.zip
      gunlock.zip
      elvactr.zip
      metalb.zip
      ... (one ZIP per game)
```

## Installation Steps

### 1. Prepare SD Card

- Mount your MiSTer SD card on a Linux/macOS/Windows system
- Identify the FAT32 partition (`/media/fat` or `D:` on Windows)

### 2. Copy Core RBF

```bash
# Copy compiled core
cp taito_f3.rbf /media/fat/_Arcade/

# Verify
ls -lh /media/fat/_Arcade/taito_f3.rbf
```

### 3. Copy Game Description Files (MRA)

If the artifact includes `.mra` files:

```bash
# Create mra directory if needed
mkdir -p /media/fat/_Arcade/mra

# Copy all .mra files
cp *.mra /media/fat/_Arcade/mra/
```

Or manually create minimal `.mra` files for games you own (see **Game List** below).

### 4. Copy ROM Files

MiSTer uses MAME-compatible ZIP files. Each game is one ZIP:

```bash
# Create games directory
mkdir -p /media/fat/games/mame

# Copy ROM ZIPs (one per game)
cp dariusg.zip /media/fat/games/mame/
cp gunlock.zip /media/fat/games/mame/
cp elvactr.zip /media/fat/games/mame/
# ... repeat for all owned games
```

**Important:**
- **Do NOT** extract the ZIPs — leave them as `.zip` files
- Filenames must match the ROM names expected by the core
- Use Darksoft F3 set if available (most compatible)

### 5. Eject & Boot

1. Safely eject SD card from computer
2. Insert into DE-10 Nano with power **OFF**
3. Power on DE-10 Nano
4. In MiSTer menu, navigate to `_Arcade`
5. You should see Taito F3 games listed

## Supported Taito F3 Games

The Taito F3 arcade hardware supports these 18 games. Copy ROMs for games you own:

| Code | Title | ROM File | Status |
|------|-------|----------|--------|
| `dariusg` | Darius Gaiden | `dariusg.zip` | Fully playable |
| `gunlock` | Gun Lock | `gunlock.zip` | Fully playable |
| `elvactr` | Elevator Action Returns | `elvactr.zip` | Fully playable |
| `metalb` | Metal Black | `metalb.zip` | Fully playable |
| `metalbu` | Metal Black (US?) | `metalbu.zip` | Fully playable |
| `scfinal` | Super Chase: Criminal Terminator Final | `scfinal.zip` | Fully playable |
| `interstella` | Interstella | `interstella.zip` | Fully playable |
| `tinforceb` | Tin Force (bootleg) | `tinforceb.zip` | Playable |
| `gekirindan` | Gekirindan | `gekirindan.zip` | Fully playable |
| `recalh` | Recalh | `recalh.zip` | Fully playable |
| `flipurac` | Flip Urac | `flipurac.zip` | Fully playable |
| `tnzs2` | Tenzone II | `tnzs2.zip` | Fully playable |
| `quizf1` | Quiz F1 1.0 | `quizf1.zip` | Playable |
| `kaiserkn` | Kaiser Knuckle | `kaiserkn.zip` | Fully playable |
| `capcom_f3` | Capcom F3 bootleg set | `capcom_f3.zip` | Playable |
| `light_club` | Light Club | `light_club.zip` | Playable |
| `arcsys_f3` | Arc System Works F3 bootleg | `arcsys_f3.zip` | Playable |
| `ultrnsport` | Ultra Sports | `ultrnsport.zip` | Fully playable |

## First Boot Checklist

After copying files to SD card:

- [ ] `taito_f3.rbf` is in `/media/fat/_Arcade/`
- [ ] At least one ROM ZIP is in `/media/fat/games/mame/`
- [ ] Optional: At least one `.mra` file is in `/media/fat/_Arcade/mra/`
- [ ] SD card safely ejected from computer
- [ ] DE-10 Nano powered on with SD card inserted

## Troubleshooting

### Black/Pink Screen

**Cause:** SDRAM initialization or timing issue

**Fix:**
- Verify ROM ZIP filename matches expected name (e.g., `dariusg.zip`)
- Check SD card integrity (try a different game first)
- If multiple games fail: SDRAM may need timing adjustment in Quartus PLL

### Garbled Graphics

**Cause:** GFX ROM addressing or SDRAM bus error

**Fix:**
- Rebuild core (`./build.sh`)
- Check that ROM ZIP is complete (correct file size)
- Try a different game to isolate

### No Input / Controls Don't Work

**Cause:** Joystick mapping not configured

**Fix:**
- In MiSTer menu: Settings → Gamepad → Configure controller
- Map buttons/directions to your controller
- Some games may need button swap (A/B/X/Y)

### Game Crashes or Resets Unexpectedly

**Cause:** Watchdog timer firing, or core bus timeout

**Fix:**
- Verify ROM ZIP is uncorrupted (SHA1 check if available)
- Some games may require specific ROM revision (bootleg vs original)
- Check MiSTer forum for known issues with specific game

### Flickering/Jittering Graphics

**Cause:** Sprite-0-hit timing or SDRAM refresh contention

**Fix:**
- Decrease graphics settings (disable scanlines, disable scaling)
- Try `--nolowres` in game settings if available
- Rebuild with optimized SDRAM timing

## Updating the Core

When a new version is released:

1. Download fresh RBF from GitHub Actions
2. Overwrite `/media/fat/_Arcade/taito_f3.rbf`
3. No need to re-copy ROM files
4. Restart MiSTer (Menu → Reset)

## Advanced: Building Locally

### Requirements

- **OS:** Linux or macOS (Windows requires WSL2)
- **Disk:** 20 GB free for Quartus installation
- **RAM:** 16 GB or more
- **Quartus:** Intel Quartus Prime Lite 17.0.2

### Installation

1. Download Quartus from Intel:
   ```
   https://www.intel.com/content/www/us/en/software/programmable/quartus/prime/download.html
   ```
   Look for "Quartus Prime Lite 17.0.2" (not 18.x or 23.x — must be 17.0.x for MiSTer)

2. Install:
   ```bash
   chmod +x QuartusLiteSetup-17.0.2.602-linux.run
   ./QuartusLiteSetup-17.0.2.602-linux.run --mode unattended --accept_eula 1 --installdir ~/intelFPGA_lite
   ```

3. Build:
   ```bash
   cd chips/taito_f3/quartus
   ./build.sh
   ```

### Customizing the Build

Edit `taito_f3.qsf` before building:

```tcl
# Enable Darius Gaiden only (skip other games)
set_global_assignment -name VERILOG_MACRO "GAIDEN_ONLY=1"

# Disable sound (faster build, fewer LEs)
set_global_assignment -name VERILOG_MACRO "TAITO_NOSOUND=1"

# Then rebuild:
# ./build.sh
```

### Build Time

- **Full compile:** 30–45 min (first build, cold cache)
- **Incremental:** 10–15 min (small changes)
- **Synthesis only:** 5–10 min (logic changes, no fitting)

To skip fitting and assembly (faster, still validates logic):
```bash
quartus_sh --flow synthesis taito_f3
```

## Hardware Support

### Supported Platform

- **DE-10 Nano:** Full support (primary target)
  - Cyclone V 5CSEBA6U23I7 FPGA
  - 1 GB DDR3 SDRAM
  - HDMI output
  - USB joystick input

### Not Supported

- DE-1, DE2, Stratix boards (different FPGA)
- Altera MAX10 (not enough LEs)
- Xilinx-based systems (Verilog requires Intel synthesis)

## Legal & ROM Files

- **RBF file:** Open-source, free to redistribute
- **ROM files:** Must own arcade PCB or licensed ROM set
  - MAME ROM copyright belongs to game publishers
  - Darksoft F3 set is widely used and recognized
  - Do not distribute copyrighted ROM ZIPs

## Support & Community

- **MiSTer Forum:** https://misterfpga.org
- **GitHub Issues:** Report bugs in the project repo
- **Taito Games Wiki:** https://en.wikipedia.org/wiki/Taito

---

**Last updated:** 2026-03-17
**Core version:** Taito F3 (Delphi validated)
**MiSTer compatibility:** DE-10 Nano only
