#!/usr/bin/env node

/**
 * Taito F3 MRA File Generator v3
 *
 * Generates MRA descriptor files for Taito F3 arcade games.
 * Handles games with alternate ROM filename prefixes (e.g., arab vs arabianm).
 *
 * Based on MAME romset definitions and MiSTer SDRAM layout.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Taito F3 game database
const F3_GAMES = {
  'dariusg': { name: 'Darius Gaiden', year: 1994, prefix: 'dariusg' },
  'bubblem': { name: 'Bubble Memories', year: 1994, prefix: 'bubblem' },
  'gunlock': { name: 'Gunlock / Rayforce', year: 1993, prefix: 'gunlock' },
  'elvactr': { name: 'Elevator Action Returns', year: 1994, prefix: 'elvactr' },
  'kaiserkn': { name: 'Kaiser Knuckle', year: 1994, prefix: 'kaiserkn' },
  'lightbr': { name: 'Light Bringer', year: 1993, prefix: 'lightbr' },
  'commandw': { name: 'Command W', year: 1994, prefix: 'commandw' },
  'bublsymp': { name: 'Bubble Symphony', year: 1994, prefix: 'bublsymp' },
  'pbobble2': { name: 'Puzzle Bobble 2 / Bust-A-Move 2', year: 1995, prefix: 'pbobble2' },
  'cleopatr': { name: 'Cleopatra Fortune', year: 1992, prefix: 'cleopatr' },
  'arabianm': { name: 'Arabian Magic', year: 1992, prefix: 'arab' }, // Different prefix!
  'ringrage': { name: 'Ring Rage', year: 1992, prefix: 'ringrage' },
  'gseeker': { name: 'Golden Seek', year: 1992, prefix: 'gseeker' },
  'ridingf': { name: 'Riding Fight', year: 1992, prefix: 'ridingf' },
  'trstar': { name: 'Twin Stars', year: 1992, prefix: 'trstar' },
  'popnpop': { name: 'Pop \'n Pop', year: 1996, prefix: 'popnpop' },
  'quizhuhu': { name: 'Quiz HuHu', year: 1995, prefix: 'quizhuhu' },
  'landmakr': { name: 'Land Maker', year: 1993, prefix: 'landmakr' },
};

// SDRAM offsets
const SDRAM_OFFSETS = {
  maincpu: 0x000000,
  sprites: 0x200000,
  sprites_hi: 0xA00000,
  tilemap: 0xE00000,
  tilemap_hi: 0x1200000,
  audiocpu: 0x1400000,
  ensoniq: 0x1600000,
};

// ROM file mapping
const FILE_MAPPING = {
  '01': { region: 'maincpu', offset: SDRAM_OFFSETS.maincpu },
  '03': { region: 'sprites', offset: SDRAM_OFFSETS.sprites },
  '05': { region: 'sprites_hi', offset: SDRAM_OFFSETS.sprites_hi },
  '07': { region: 'tilemap', offset: SDRAM_OFFSETS.tilemap },
  '08': { region: 'tilemap_hi', offset: SDRAM_OFFSETS.tilemap_hi },
  '09': { region: 'audiocpu', offset: SDRAM_OFFSETS.audiocpu },
  '10': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq },
  '11': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq },
  '12': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq },
  '13': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq },
  '14': { region: 'ensoniq', offset: SDRAM_OFFSETS.ensoniq },
};

const ARCHIVE_PATH = '/Volumes/2TB_20260220/Projects/ROMs_Claude/F3_Roms/Darksoft F3 OLED + LCD 2024-05-22.7z';

/**
 * Get ROM file sizes from archive
 */
function getRomSizesFromArchive(gameName, romPrefix) {
  const romSizes = {};

  try {
    const cmd = `bsdtar -tvf "${ARCHIVE_PATH}" 2>/dev/null | grep "games/${gameName}/${romPrefix}" | grep -E '\\.(01|03|05|07|08|09|10|11|12|13|14)$'`;
    const output = execSync(cmd, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'ignore'] });

    const lines = output.trim().split('\n');
    for (const line of lines) {
      if (!line) continue;
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
    // Silently fail - just return empty
  }

  return romSizes;
}

/**
 * Generate MRA XML for a single game
 */
function generateMRA(setname, game) {
  const romSizes = getRomSizesFromArchive(setname, game.prefix);
  const romParts = [];
  const offsetMap = {}; // Track cumulative offset for multi-part regions

  // Sort file numbers to maintain order
  const sortedExts = Object.keys(FILE_MAPPING).sort();

  for (const ext of sortedExts) {
    if (!romSizes[ext]) continue;

    const size = romSizes[ext];
    const { region, offset } = FILE_MAPPING[ext];
    const filename = `${game.prefix}.${ext}`;

    // For multi-part regions (ensoniq), track cumulative offset
    const currentOffset =
      region === 'ensoniq'
        ? offset + (offsetMap[region] || 0)
        : offset;

    romParts.push({
      name: filename,
      offset: currentOffset,
      length: size,
      crc: '00000000',
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
    manufacturer: 'Taito',
    category: 'Arcade',
    buttons: 'Button1,Button2,Button3,Start,Coin',
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

  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  let count = 0;
  for (const [setname, game] of Object.entries(F3_GAMES)) {
    try {
      const mra = generateMRA(setname, game);

      if (mra.romParts.length === 0) {
        console.log(`⚠ ${setname}: No ROM parts found`);
        continue;
      }

      const xml = formatMRA(mra);
      const filename = path.join(outputDir, `${setname}.mra`);

      fs.writeFileSync(filename, xml);
      console.log(`✓ ${setname}.mra (${game.name}) — ${mra.romParts.length} ROM parts`);
      count++;
    } catch (error) {
      console.error(`✗ ${setname}: ${error.message}`);
    }
  }

  console.log(`\n${count}/${Object.keys(F3_GAMES).length} MRA files generated successfully`);
}

main();
