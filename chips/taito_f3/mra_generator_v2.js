#!/usr/bin/env node

/**
 * Taito F3 MRA File Generator v2
 *
 * Generates MRA descriptor files for Taito F3 arcade games.
 * Extracts ROM file sizes from the Darksoft F3 archive via bsdtar.
 *
 * Based on MAME romset definitions and MiSTer SDRAM layout.
 *
 * SDRAM Layout (from integration_plan.md §3):
 *   0x000000 — 2MB — 68EC020 program ROM
 *   0x200000 — 8MB — Sprite GFX (low 4bpp)
 *   0xA00000 — 4MB — Sprite GFX (high 2bpp)
 *   0xE00000 — 4MB — Tilemap GFX (low 4bpp)
 *   0x1200000 — 2MB — Tilemap GFX (high 2bpp)
 *   0x1400000 — 1.5MB — Sound CPU program ROM
 *   0x1580000 — (padding)
 *   0x1600000 — 8MB — Ensoniq sample ROMs
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Taito F3 game database with actual ROM regions
const F3_GAMES = {
  'dariusg': {
    name: 'Darius Gaiden',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'bubblem': {
    name: 'Bubble Memories',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'gunlock': {
    name: 'Gunlock / Rayforce',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'elvactr': {
    name: 'Elevator Action Returns',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Platform',
    buttons: 'Button1,Button2,Button3,Start,Coin',
  },
  'kaiserkn': {
    name: 'Kaiser Knuckle',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Fighter',
    buttons: 'Button1,Button2,Button3,Start,Coin',
  },
  'lightbr': {
    name: 'Light Bringer',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'commandw': {
    name: 'Command W',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'bublsymp': {
    name: 'Bubble Symphony',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'pbobble2': {
    name: 'Puzzle Bobble 2 / Bust-A-Move 2',
    year: 1995,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'cleopatr': {
    name: 'Cleopatra Fortune',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'arabianm': {
    name: 'Arabian Magic',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Maze',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'ringrage': {
    name: 'Ring Rage',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Fighter',
    buttons: 'Button1,Button2,Button3,Start,Coin',
  },
  'gseeker': {
    name: 'Golden Seek',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'ridingf': {
    name: 'Riding Fight',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'trstar': {
    name: 'Twin Stars',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'popnpop': {
    name: 'Pop \'n Pop',
    year: 1996,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
  'quizhuhu': {
    name: 'Quiz HuHu',
    year: 1995,
    manufacturer: 'Taito',
    category: 'Quiz',
    buttons: 'Button1,Button2,Button3,Button4,Start,Coin',
  },
  'landmakr': {
    name: 'Land Maker',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
  },
};

// SDRAM offsets (from integration_plan.md §3)
const SDRAM_OFFSETS = {
  maincpu: 0x000000,
  sprites: 0x200000,
  sprites_hi: 0xA00000,
  tilemap: 0xE00000,
  tilemap_hi: 0x1200000,
  audiocpu: 0x1400000,
  ensoniq: 0x1600000,
};

// ROM file mapping: file extension -> (region, offset in SDRAM)
const FILE_MAPPING = {
  '01': { region: 'maincpu', offset: SDRAM_OFFSETS.maincpu },
  '03': { region: 'sprites', offset: SDRAM_OFFSETS.sprites },
  '05': { region: 'sprites_hi', offset: SDRAM_OFFSETS.sprites_hi },
  '07': { region: 'tilemap', offset: SDRAM_OFFSETS.tilemap },
  '08': { region: 'tilemap_hi', offset: SDRAM_OFFSETS.tilemap_hi },
  '09': { region: 'audiocpu', offset: SDRAM_OFFSETS.audiocpu },
  '10': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq, index: 0 },
  '11': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq, index: 1 },
  '12': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq, index: 2 },
  '13': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq, index: 3 },
  '14': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq, index: 4 },
};

const ARCHIVE_PATH = '/Volumes/2TB_20260220/Projects/ROMs_Claude/F3_Roms/Darksoft F3 OLED + LCD 2024-05-22.7z';

/**
 * Get ROM file sizes from archive using bsdtar
 */
function getRomSizesFromArchive(gameName) {
  const romSizes = {};

  try {
    const cmd = `bsdtar -tvf "${ARCHIVE_PATH}" 2>/dev/null | grep "games/${gameName}/${gameName}\\\\."`;
    const output = execSync(cmd, { encoding: 'utf-8' });

    // Parse each line: -rw-rw-rw-  0 0      0     SIZE DATE TIME games/GAME/game.EXT
    const lines = output.trim().split('\n');
    for (const line of lines) {
      const parts = line.split(/\s+/);
      if (parts.length >= 5) {
        const size = parseInt(parts[4], 10);
        const filename = parts[parts.length - 1];
        const ext = filename.split('.').pop();

        if (FILE_MAPPING[ext]) {
          romSizes[ext] = size;
        }
      }
    }
  } catch (error) {
    console.error(`Warning: Could not get ROM sizes for ${gameName}`);
  }

  return romSizes;
}

/**
 * Generate MRA XML for a single game
 */
function generateMRA(setname, game) {
  const romSizes = getRomSizesFromArchive(setname);
  const romParts = [];
  const offsetMap = {}; // Track cumulative offset for multi-part regions

  // Sort file numbers to maintain order
  const sortedExts = Object.keys(FILE_MAPPING).sort();

  for (const ext of sortedExts) {
    if (!romSizes[ext]) continue;

    const size = romSizes[ext];
    const { region, offset, index } = FILE_MAPPING[ext];
    const filename = `${setname}.${ext}`;

    // For multi-part regions (ensoniq), track cumulative offset
    const currentOffset =
      region === 'ensoniq'
        ? offset + (offsetMap[region] || 0)
        : offset;

    romParts.push({
      name: filename,
      offset: currentOffset,
      length: size,
      crc: '00000000', // Placeholder
    });

    // Update cumulative offset for next file in same region
    if (region === 'ensoniq') {
      offsetMap[region] = (offsetMap[region] || 0) + size;
    }
  }

  return {
    name: game.name,
    setname: setname,
    year: game.year,
    manufacturer: game.manufacturer,
    category: game.category,
    buttons: game.buttons,
    romParts: romParts,
  };
}

/**
 * Format as MRA XML
 */
function formatMRA(mra) {
  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
  xml += '<misterromdescription>\n';
  xml += `  <name>${escapeXml(mra.name)}</name>\n`;
  xml += `  <setname>${mra.setname}</setname>\n`;
  xml += '  <rbf>taito_f3</rbf>\n';
  xml += '  <mameversion>0230</mameversion>\n';
  xml += `  <year>${mra.year}</year>\n`;
  xml += `  <manufacturer>${escapeXml(mra.manufacturer)}</manufacturer>\n`;
  xml += `  <category>${escapeXml(mra.category)}</category>\n`;
  xml += `  <buttons names="${escapeXml(mra.buttons)}" default="A,B,X,Y,Start,Select"/>\n`;
  xml += `  <rom index="0" zip="${mra.setname}.zip" type="merged" md5="00000000000000000000000000000000">\n`;

  for (const part of mra.romParts) {
    const offsetHex = `0x${part.offset.toString(16).toUpperCase().padStart(7, '0')}`;
    const lengthHex = `0x${part.length.toString(16).toUpperCase().padStart(8, '0')}`;
    xml += `    <part name="${part.name}" crc="${part.crc}" offset="${offsetHex}" length="${lengthHex}"/>\n`;
  }

  xml += '  </rom>\n';
  xml += '</misterromdescription>\n';

  return xml;
}

function escapeXml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * Main generation loop
 */
function main() {
  const outputDir = path.join(__dirname, 'mra');

  // Ensure output directory exists
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  let count = 0;
  for (const [setname, game] of Object.entries(F3_GAMES)) {
    try {
      const mra = generateMRA(setname, game);
      const xml = formatMRA(mra);
      const filename = path.join(outputDir, `${setname}.mra`);

      fs.writeFileSync(filename, xml);
      console.log(`✓ ${setname}.mra (${game.name}) — ${mra.romParts.length} ROM parts`);
      count++;
    } catch (error) {
      console.error(`✗ ${setname}: ${error.message}`);
    }
  }

  console.log(`\n${count}/${Object.keys(F3_GAMES).length} MRA files generated`);
}

main();
