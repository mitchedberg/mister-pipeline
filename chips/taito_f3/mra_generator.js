#!/usr/bin/env node

/**
 * Taito F3 MRA File Generator
 *
 * Generates MRA descriptor files for Taito F3 arcade games.
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

// Taito F3 game database
// Key: MAME setname
// Value: { fullname, year, manufacturer, category, buttons, notes, rom_sizes }
const F3_GAMES = {
  'dariusg': {
    name: 'Darius Gaiden',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
    notes: 'Wide screen',
    rom_sizes: {
      maincpu: 0x200000,      // 2MB
      sprites: 0x400000,      // 4MB sprite_lo
      sprites_hi: 0x200000,   // 2MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x100000,     // 1MB
      ensoniq: 0x800000       // 8MB
    }
  },
  'bubblem': {
    name: 'Bubble Memories',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,      // 512KB
      ensoniq: 0x800000
    }
  },
  'gunlock': {
    name: 'Gunlock / Rayforce',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x180000,     // 1.5MB (largest)
      ensoniq: 0x800000
    }
  },
  'elvactr': {
    name: 'Elevator Action Returns',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Platform',
    buttons: 'Button1,Button2,Button3,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x400000,      // 4MB sprite_lo
      sprites_hi: 0x200000,   // 2MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'kaiserkn': {
    name: 'Kaiser Knuckle',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Fighter',
    buttons: 'Button1,Button2,Button3,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x300000,      // 3MB sprite_lo
      sprites_hi: 0x180000,   // 1.5MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'lightbr': {
    name: 'Light Bringer',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
    notes: 'Largest tile ROM',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x600000,      // 6MB sprite_lo
      sprites_hi: 0x300000,   // 3MB sprite_hi
      tilemap: 0x400000,      // 4MB tile_lo (largest)
      tilemap_hi: 0x200000,   // 2MB tile_hi (largest)
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'commandw': {
    name: 'Command W / Mahou no Shoujou Silky Lip',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
    notes: 'Largest sprite ROM',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x800000,      // 8MB sprite_lo (largest)
      sprites_hi: 0x400000,   // 4MB sprite_hi (largest)
      tilemap: 0x400000,      // 4MB tile_lo
      tilemap_hi: 0x200000,   // 2MB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'bublsymp': {
    name: 'Bubble Symphony / Bubbles Symphony',
    year: 1994,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: 'Alt sprite decode (5bpp)',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x400000,      // 4MB sprite_lo
      sprites_hi: 0x200000,   // 2MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'pbobble2': {
    name: 'Puzzle Bobble 2 / Bust-A-Move 2',
    year: 1995,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'cleopatr': {
    name: 'Cleopatra Fortune',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'arabianm': {
    name: 'Arabian Magic',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Maze',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '4-player',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x400000,      // 4MB sprite_lo
      sprites_hi: 0x200000,   // 2MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'ringrage': {
    name: 'Ring Rage',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Fighter',
    buttons: 'Button1,Button2,Button3,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x400000,      // 4MB sprite_lo
      sprites_hi: 0x200000,   // 2MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'gseeker': {
    name: 'Golden Seek',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'ridingf': {
    name: 'Riding Fight',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Shooter',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x300000,      // 3MB sprite_lo
      sprites_hi: 0x180000,   // 1.5MB sprite_hi
      tilemap: 0x200000,      // 2MB tile_lo
      tilemap_hi: 0x100000,   // 1MB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'trstar': {
    name: 'Twin Stars',
    year: 1992,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'popnpop': {
    name: 'Pop \'n Pop',
    year: 1996,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x100000,
      ensoniq: 0x800000
    }
  },
  'quizhuhu': {
    name: 'Quiz HuHu',
    year: 1995,
    manufacturer: 'Taito',
    category: 'Quiz',
    buttons: 'Button1,Button2,Button3,Button4,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x100000,      // 1MB sprite_lo
      sprites_hi: 0x80000,    // 512KB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  },
  'landmakr': {
    name: 'Land Maker',
    year: 1993,
    manufacturer: 'Taito',
    category: 'Puzzle',
    buttons: 'Button1,Button2,Start,Coin',
    notes: '',
    rom_sizes: {
      maincpu: 0x200000,
      sprites: 0x200000,      // 2MB sprite_lo
      sprites_hi: 0x100000,   // 1MB sprite_hi
      tilemap: 0x100000,      // 1MB tile_lo
      tilemap_hi: 0x80000,    // 512KB tile_hi
      audiocpu: 0x80000,
      ensoniq: 0x800000
    }
  }
};

// SDRAM offsets (from integration_plan.md §3)
const SDRAM_OFFSETS = {
  maincpu: 0x000000,
  sprites: 0x200000,
  sprites_hi: 0xA00000,
  tilemap: 0xE00000,
  tilemap_hi: 0x1200000,
  audiocpu: 0x1400000,
  ensoniq: 0x1600000
};

/**
 * Generate MRA XML for a single game
 */
function generateMRA(setname, game) {
  const mra = {
    name: game.name,
    setname: setname,
    rbf: 'taito_f3',
    mameversion: '0230',
    year: game.year,
    manufacturer: game.manufacturer,
    category: game.category,
    buttons: game.buttons,
    romParts: []
  };

  // Map ROM regions to part definitions
  // Note: Darksoft F3 archive stores individual ROM files
  // Each game has: .01 .03 .05 .07 .08 .09 .10/.11 .12 .13 .14
  // This maps to MAME ROM regions

  const romMapping = {
    '01': { region: 'maincpu', type: 'program', crc: '00000000' },
    '03': { region: 'sprites', type: 'gfx_lo', crc: '00000000' },
    '05': { region: 'sprites_hi', type: 'gfx_hi', crc: '00000000' },
    '07': { region: 'tilemap', type: 'tile_lo', crc: '00000000' },
    '08': { region: 'tilemap_hi', type: 'tile_hi', crc: '00000000' },
    '09': { region: 'audiocpu', type: 'audio', crc: '00000000' },
    '10': { region: 'ensoniq', type: 'ensoniq', crc: '00000000' },
    '11': { region: 'ensoniq', type: 'ensoniq', crc: '00000000' },
    '12': { region: 'ensoniq', type: 'ensoniq', crc: '00000000' },
    '13': { region: 'ensoniq', type: 'ensoniq', crc: '00000000' },
    '14': { region: 'ensoniq', type: 'ensoniq', crc: '00000000' }
  };

  // Build ROM parts
  for (const [fileNum, info] of Object.entries(romMapping)) {
    const region = info.region;
    const offset = SDRAM_OFFSETS[region];

    if (region && offset !== undefined) {
      mra.romParts.push({
        name: `${setname}.${fileNum}`,
        region: region,
        offset: offset,
        crc: info.crc
      });
    }
  }

  return mra;
}

/**
 * Format as MRA XML
 */
function formatMRA(mra) {
  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
  xml += '<misterromdescription>\n';
  xml += `  <name>${escapeXml(mra.name)}</name>\n`;
  xml += `  <setname>${mra.setname}</setname>\n`;
  xml += `  <rbf>${mra.rbf}</rbf>\n`;
  xml += `  <mameversion>${mra.mameversion}</mameversion>\n`;
  xml += `  <year>${mra.year}</year>\n`;
  xml += `  <manufacturer>${escapeXml(mra.manufacturer)}</manufacturer>\n`;
  xml += `  <category>${escapeXml(mra.category)}</category>\n`;
  xml += `  <buttons names="${escapeXml(mra.buttons)}" default="A,B,X,Y,Start,Select"/>\n`;
  xml += `  <rom index="0" zip="${mra.setname}.zip" type="merged" md5="00000000000000000000000000000000">\n`;

  for (const part of mra.romParts) {
    const offsetHex = `0x${part.offset.toString(16).toUpperCase().padStart(7, '0')}`;
    xml += `    <part name="${part.name}" crc="${part.crc}" offset="${offsetHex}" length="0x00000000"/>\n`;
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
    const mra = generateMRA(setname, game);
    const xml = formatMRA(mra);
    const filename = path.join(outputDir, `${setname}.mra`);

    fs.writeFileSync(filename, xml);
    console.log(`Generated: ${setname}.mra (${game.name})`);
    count++;
  }

  console.log(`\nTotal: ${count} MRA files generated`);
}

main();
