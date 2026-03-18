#!/usr/bin/env python3
"""
MiSTer Pipeline Dashboard — 3-Tier Layout
Tier 1: Our Work (8 systems in active development)
Tier 2: Ecosystem (community cores that already exist)
Tier 3: Future Targets (genuine gaps with no public core)
"""

import os
import json
from flask import Flask, render_template, jsonify, request
from datetime import datetime

app = Flask(__name__, template_folder=os.path.dirname(os.path.abspath(__file__)))

BASE = '/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips'
DASH = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# Load static data once at startup
# ---------------------------------------------------------------------------
with open(os.path.join(DASH, 'game_data.json')) as f:
    GAME_DATA = json.load(f)

with open(os.path.join(DASH, 'candidates.json')) as f:
    CANDIDATES = json.load(f)

# ---------------------------------------------------------------------------
# Per-system game counts
# ---------------------------------------------------------------------------
SYSTEM_GAME_COUNTS = {}
for system_key, games in GAME_DATA.items():
    parents = [g for g in games if not g.get('parent')]
    top10 = sorted(parents, key=lambda g: g.get('year', '9999'))[:10]
    SYSTEM_GAME_COUNTS[system_key] = {
        'total': len(games),
        'parents': len(parents),
        'top10': top10,
    }

# Flatten all games for the library view
ALL_GAMES = []
for system_key, games in GAME_DATA.items():
    for g in games:
        ALL_GAMES.append({
            'system': system_key,
            'name': g.get('name', ''),
            'title': g.get('title', ''),
            'year': g.get('year', ''),
            'manufacturer': g.get('manufacturer', ''),
            'parent': g.get('parent'),
        })
ALL_GAMES.sort(key=lambda g: g['year'])

# ---------------------------------------------------------------------------
# Filesystem-detection helpers
# ---------------------------------------------------------------------------

def has_real_audio(chip_name):
    emu = os.path.join(BASE, chip_name, 'quartus', 'emu.sv')
    if not os.path.exists(emu):
        return False
    try:
        with open(emu) as f:
            content = f.read()
        return 'AUDIO_L = 16\'h0' not in content and 'AUDIO_L' in content
    except Exception:
        return False


def has_real_pll(chip_name):
    pll = os.path.join(BASE, chip_name, 'rtl', 'pll.sv')
    if not os.path.exists(pll):
        return False
    try:
        with open(pll) as f:
            return 'altpll' in f.read()
    except Exception:
        return False


def has_joystick(chip_name):
    emu = os.path.join(BASE, chip_name, 'quartus', 'emu.sv')
    if not os.path.exists(emu):
        return False
    try:
        with open(emu) as f:
            return 'joystick_0' in f.read()
    except Exception:
        return False


def get_rtl_gates(chip_name):
    """Return list of RTL gate files present (up to 5)."""
    rtl_dir = os.path.join(BASE, chip_name, 'rtl')
    if not os.path.exists(rtl_dir):
        return []
    return [f for f in os.listdir(rtl_dir) if f.endswith('.sv')][:5]


def get_rtl_status(chip_name):
    rtl_dir = os.path.join(BASE, chip_name, 'rtl')
    if not os.path.exists(rtl_dir):
        return 'not_started'
    sv_files = [f for f in os.listdir(rtl_dir) if f.endswith('.sv')]
    if len(sv_files) >= 3:
        return 'ready'
    elif sv_files:
        return 'in_progress'
    return 'not_started'


def get_synthesis_status(chip_name):
    """Check if a QPF (Quartus project) exists — indicates CI-able synthesis."""
    q_dir = os.path.join(BASE, chip_name, 'quartus')
    if not os.path.exists(q_dir):
        return 'not_started'
    if any(f.endswith('.qpf') for f in os.listdir(q_dir)):
        return 'ready'
    if any(f.endswith('.sv') for f in os.listdir(q_dir)):
        return 'in_progress'
    return 'not_started'


def get_vectors_status(chip_name):
    v_dir = os.path.join(BASE, chip_name, 'vectors')
    if not os.path.exists(v_dir):
        return 'not_started'
    test_files = [f for f in os.listdir(v_dir)
                  if f.endswith(('.txt', '.json', '.py'))]
    if len(test_files) > 10:
        return 'ready'
    elif test_files:
        return 'in_progress'
    return 'not_started'


def get_sdram_status(chip_name):
    """Check for SDRAM controller instantiation in RTL."""
    rtl_dir = os.path.join(BASE, chip_name, 'rtl')
    if not os.path.exists(rtl_dir):
        return False
    for fname in os.listdir(rtl_dir):
        if not fname.endswith('.sv'):
            continue
        try:
            with open(os.path.join(rtl_dir, fname)) as f:
                if 'sdram' in f.read().lower():
                    return True
        except Exception:
            pass
    return False


# ---------------------------------------------------------------------------
# Tier 1: Our Work — 8 systems in active development
# ---------------------------------------------------------------------------
OUR_SYSTEMS = [
    {
        'name': 'Taito B',
        'chip': 'taito_b',
        'system_key': 'taito_b',
        'description': 'Ninja Warriors, Rastan Saga II, Rambo III',
        'key_chips': ['TC0170ABT', 'TC0220IOC', 'TC0140SYT', 'TC0180VCU'],
        'priority': 1,
    },
    {
        'name': 'Taito F3',
        'chip': 'taito_f3',
        'system_key': 'taito_f3',
        'description': 'Bubble Bobble 2, Puzzle Bobble 2, Darius Gaiden',
        'key_chips': ['TC0630FDP', 'TC0660FCM', 'TC0140SYT', 'ES5505'],
        'priority': 2,
    },
    {
        'name': 'Taito Z',
        'chip': 'taito_z',
        'system_key': 'taito_z',
        'description': 'Chase HQ, Continental Circus, Aqua Jack',
        'key_chips': ['TC0150ROD', 'TC0220IOC', 'TC0140SYT'],
        'priority': 3,
    },
    {
        'name': 'Taito X',
        'chip': 'taito_x',
        'system_key': 'taito_x',
        'description': 'Darius Gaiden, Elevator Action Returns',
        'key_chips': ['TC0480SCP', 'TC0620SCC', 'TC0140SYT'],
        'priority': 4,
    },
    {
        'name': 'Toaplan V2',
        'chip': 'gp9001',
        'system_key': 'toaplan_v2',
        'description': 'Batsugun, Zero Wing, Fire Shark, Battle Garegga',
        'key_chips': ['GP9001 VDP', 'OKI6242 PCM', 'YM2151'],
        'priority': 5,
    },
    {
        'name': 'NMK16',
        'chip': 'nmk',
        'system_key': 'nmk16',
        'description': 'Rapid Hero, GunNail, Vandyke, Thunder Dragon',
        'key_chips': ['NMK-005', 'NMK-112', 'OKI6295'],
        'priority': 6,
    },
    {
        'name': 'Psikyo',
        'chip': 'psikyo',
        'system_key': 'psikyo',
        'description': 'Strikers 1945, Gunbird, Dragon Blaze',
        'key_chips': ['SH-2 (32-bit)', 'custom sprite ASIC', 'YM2610B'],
        'priority': 7,
    },
    {
        'name': 'Kaneko16',
        'chip': 'kaneko',
        'system_key': 'kaneko16',
        'description': 'Blood Warrior, Magical Crystal, Great 1000 Miles Rally',
        'key_chips': ['CALC3', 'KC-002', 'OKI6295'],
        'priority': 8,
    },
]


def get_our_system_status(sys_def):
    chip = sys_def['chip']
    sk = sys_def['system_key']
    counts = SYSTEM_GAME_COUNTS.get(sk, {'total': 0, 'parents': 0, 'top10': []})
    rtl_gates = get_rtl_gates(chip)
    return {
        **sys_def,
        'rtl_status': get_rtl_status(chip),
        'rtl_gates': rtl_gates,
        'synthesis_status': get_synthesis_status(chip),
        'vectors_status': get_vectors_status(chip),
        'has_audio': has_real_audio(chip),
        'has_pll': has_real_pll(chip),
        'has_joystick': has_joystick(chip),
        'has_sdram': get_sdram_status(chip),
        'game_total': counts['total'],
        'game_parents': counts['parents'],
        'top10': counts['top10'],
    }


# ---------------------------------------------------------------------------
# Tier 2: Ecosystem — community cores that already exist
# ---------------------------------------------------------------------------
ECOSYSTEM_CORES = [
    {
        'name': 'Cave 68K',
        'system_key': 'cave_68k',
        'author': 'furrtek',
        'repo': 'https://github.com/MiSTer-devel/Arcade-Cave_MiSTer',
        'status': 'mature',
        'status_label': 'Mature',
        'games_supported': 8,
        'notes': 'Chisel-written. 8 games public (DoDonPachi, DonPachi, ESP Ra.De., Guwange, etc). 7 more unimplemented.',
        'opportunity': 'Contribute missing game support (Air Gallet, Gogetsuji Legends, Power Instinct 2)',
    },
    {
        'name': 'Sega OutRun',
        'system_key': 'sega_outrun',
        'author': 'jotego',
        'repo': 'https://github.com/jotego/jtoutrun',
        'status': 'mature',
        'status_label': 'Mature',
        'games_supported': 3,
        'notes': 'OutRun, Turbo OutRun, OutRunners. Full sprite-scaling support.',
        'opportunity': None,
    },
    {
        'name': 'Sega System 18',
        'system_key': 'sega_sys18',
        'author': 'jotego',
        'repo': 'https://github.com/jotego/jts18',
        'status': 'active',
        'status_label': 'Active',
        'games_supported': 11,
        'notes': 'Alien Storm, Blaze On, D.D. Crew, Moonwalker, Shadow Dancer. Jotego patreon core.',
        'opportunity': None,
    },
    {
        'name': 'Raizing / 8ing',
        'system_key': None,
        'author': 'archived',
        'repo': 'https://github.com/MiSTer-devel/Arcade-Raizing_MiSTer',
        'status': 'archived',
        'status_label': 'Archived',
        'games_supported': 4,
        'notes': 'Battle Garegga, Mahou Daisakusen, Kingdom Grandprix. GP9001 derivative — free unlock once Toaplan V2 done.',
        'opportunity': 'Revive/extend once GP9001 VDP complete in our Toaplan V2 work',
    },
    {
        'name': 'Jaleco MS1',
        'system_key': 'jaleco_ms1',
        'author': 'va7deo',
        'repo': 'https://github.com/va7deo/ArmedF',
        'status': 'active',
        'status_label': 'Active',
        'games_supported': 6,
        'notes': 'Armed Formation, P-47, Psychic 5. va7deo cores. Jaleco Mega System 1.',
        'opportunity': None,
    },
    {
        'name': 'Irem M72',
        'system_key': 'irem_m72',
        'author': 'MiSTer-devel',
        'repo': 'https://github.com/MiSTer-devel/Arcade-IremM72_MiSTer',
        'status': 'mature',
        'status_label': 'Mature',
        'games_supported': 14,
        'notes': 'R-Type, Dragon Breed, Image Fight, X Multiply, Air Duel. Community maintained.',
        'opportunity': None,
    },
    {
        'name': 'Irem M92',
        'system_key': 'irem_m92',
        'author': 'MiSTer-devel',
        'repo': 'https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer',
        'status': 'mature',
        'status_label': 'Mature',
        'games_supported': 12,
        'notes': 'In The Hunt, Undercover Cops, Blade Master, Hook. V33 CPU based.',
        'opportunity': None,
    },
    {
        'name': 'Technos',
        'system_key': None,
        'author': 'Coin-Op Collection',
        'repo': 'https://github.com/Coin-OpCollection',
        'status': 'active',
        'status_label': 'Active',
        'games_supported': 4,
        'notes': 'Double Dragon, Renegade, Combatribes. Coin-Op Collection team.',
        'opportunity': None,
    },
    {
        'name': 'Sega System 16A/B',
        'system_key': 'sega_sys16b',
        'author': 'MiSTer-devel / jotego',
        'repo': 'https://github.com/MiSTer-devel/Arcade-Segasys16_MiSTer',
        'status': 'mature',
        'status_label': 'Mature',
        'games_supported': 35,
        'notes': 'Golden Axe, Altered Beast, Shinobi, Streets of Rage, Fantasy Zone. Multiple community implementations.',
        'opportunity': None,
    },
]


# ---------------------------------------------------------------------------
# Tier 3: Future Targets — genuine gaps with no public core
# ---------------------------------------------------------------------------
FUTURE_TARGETS = [
    {
        'name': 'Konami GX',
        'system_key': 'konami_gx',
        'cpu': '68020 @ 24 MHz',
        'lut_estimate': 72000,
        'feasibility': 'yellow',
        'key_games': ['Lethal Enforcers', 'Midnight Run', 'Rushing Heroes', 'Martial Champions'],
        'notes': '68020 is larger than 68000 but still fits. Custom tilemap + sprite ASICs. No public MiSTer core.',
        'priority': 1,
    },
    {
        'name': 'Video System',
        'system_key': 'video_system',
        'cpu': '68000 @ 16 MHz',
        'lut_estimate': 38000,
        'feasibility': 'green',
        'key_games': ['Aero Fighters', 'Turbo Force', 'Rabio Lepus'],
        'notes': 'Simple sprite hardware, similar complexity to NMK16. No public core. Small game library but includes shmup classics.',
        'priority': 2,
    },
    {
        'name': 'SETA 1',
        'system_key': 'seta1',
        'cpu': '68000 @ 16 MHz',
        'lut_estimate': 45000,
        'feasibility': 'green',
        'key_games': ['Thundercade', 'Twin Eagles', 'Blandia', 'Caliber 50', 'Quiz Kokology'],
        'notes': '35 parent games. X1-010 sound chip. No public MiSTer core. Good library diversity (shmups + fighters + quiz).',
        'priority': 3,
    },
    {
        'name': 'Sega X Board',
        'system_key': 'sega_xboard',
        'cpu': 'Dual 68000 @ 12.5 MHz',
        'lut_estimate': 65000,
        'feasibility': 'yellow',
        'key_games': ['After Burner II', 'Thunder Blade', 'AB Cop'],
        'notes': 'Sprite scaling hardware. Tight but fits on DE-10 Nano. 19 parent games. No public core.',
        'priority': 4,
    },
    {
        'name': 'Sega Y Board',
        'system_key': 'sega_yboard',
        'cpu': 'Triple 68000 @ 12.5 MHz',
        'lut_estimate': 75000,
        'feasibility': 'yellow',
        'key_games': ['Galaxy Force II', 'Power Drift', 'Strike Fighter'],
        'notes': 'Three CPUs + sprite scaler. Most complex Sega arcade board of the era. Fits but tight.',
        'priority': 5,
    },
    {
        'name': 'Psikyo SH',
        'system_key': 'psikyo_sh',
        'cpu': 'SH-2 @ 28.6 MHz',
        'lut_estimate': 55000,
        'feasibility': 'green',
        'key_games': ['Strikers 1945 II', 'Strikers 1945 III', 'Gunbird 2', 'Dragon Blaze'],
        'notes': '10 parent games. Successor to Psikyo hardware with SH-2. No public core. Our Psikyo work is directly applicable.',
        'priority': 6,
    },
]


# ---------------------------------------------------------------------------
# System display names (for game library)
# ---------------------------------------------------------------------------
SYSTEM_DISPLAY = {
    'toaplan_v2': 'Toaplan V2',
    'taito_b': 'Taito B',
    'taito_f3': 'Taito F3',
    'taito_z': 'Taito Z',
    'taito_x': 'Taito X',
    'nmk16': 'NMK16',
    'psikyo': 'Psikyo',
    'kaneko16': 'Kaneko16',
    'cave_68k': 'Cave 68K',
    'sega_sys16a': 'Sega Sys16A',
    'sega_sys16b': 'Sega Sys16B',
    'sega_sys18': 'Sega Sys18',
    'sega_outrun': 'Sega OutRun',
    'sega_xboard': 'Sega X Board',
    'sega_yboard': 'Sega Y Board',
    'konami_gx': 'Konami GX',
    'psikyo_sh': 'Psikyo SH',
    'video_system': 'Video System',
    'seta1': 'SETA 1',
    'jaleco_ms1': 'Jaleco MS1',
    'irem_m72': 'Irem M72',
    'irem_m92': 'Irem M92',
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route('/')
def dashboard():
    our_systems = [get_our_system_status(s) for s in OUR_SYSTEMS]

    # Attach game counts to ecosystem entries
    ecosystem = []
    for ec in ECOSYSTEM_CORES:
        sk = ec.get('system_key')
        counts = SYSTEM_GAME_COUNTS.get(sk, {'total': 0, 'parents': 0, 'top10': []}) if sk else {}
        ecosystem.append({**ec, 'game_total': counts.get('total', 0), 'game_parents': counts.get('parents', 0)})

    # Attach game counts to future targets
    future = []
    for ft in FUTURE_TARGETS:
        sk = ft.get('system_key')
        counts = SYSTEM_GAME_COUNTS.get(sk, {'total': 0, 'parents': 0, 'top10': []}) if sk else {}
        future.append({**ft, 'game_total': counts.get('total', 0), 'game_parents': counts.get('parents', 0)})

    total_games = sum(c['total'] for c in SYSTEM_GAME_COUNTS.values())
    total_parents = sum(c['parents'] for c in SYSTEM_GAME_COUNTS.values())

    return render_template(
        'template.html',
        our_systems=our_systems,
        ecosystem=ecosystem,
        future_targets=future,
        system_game_counts=SYSTEM_GAME_COUNTS,
        system_display=SYSTEM_DISPLAY,
        systems_list=sorted(GAME_DATA.keys()),
        total_games=total_games,
        total_parents=total_parents,
        # JSON-serialised for client-side filtering in the game library widget
        all_games_js=json.dumps(ALL_GAMES),
        system_display_js=json.dumps(SYSTEM_DISPLAY),
        updated_at=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    )


@app.route('/games')
def games_page():
    """Full game listing with search/filter."""
    system_filter = request.args.get('system', '')
    search = request.args.get('q', '').lower()
    parents_only = request.args.get('parents', '') == '1'

    filtered = ALL_GAMES
    if system_filter:
        filtered = [g for g in filtered if g['system'] == system_filter]
    if search:
        filtered = [g for g in filtered if search in (g['title'] + ' ' + g['name']).lower()]
    if parents_only:
        filtered = [g for g in filtered if not g['parent']]

    return render_template(
        'games.html',
        games=filtered,
        system_filter=system_filter,
        search=search,
        parents_only=parents_only,
        system_display=SYSTEM_DISPLAY,
        systems_list=sorted(GAME_DATA.keys()),
        total_shown=len(filtered),
        total_all=len(ALL_GAMES),
        updated_at=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    )


@app.route('/ecosystem')
def ecosystem_page():
    """Community core status overview."""
    ecosystem = []
    for ec in ECOSYSTEM_CORES:
        sk = ec.get('system_key')
        counts = SYSTEM_GAME_COUNTS.get(sk, {'total': 0, 'parents': 0, 'top10': []}) if sk else {}
        ecosystem.append({**ec, 'game_total': counts.get('total', 0), 'game_parents': counts.get('parents', 0)})

    return render_template(
        'ecosystem.html',
        ecosystem=ecosystem,
        updated_at=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    )


@app.route('/api/systems')
def api_systems():
    return jsonify([get_our_system_status(s) for s in OUR_SYSTEMS])


@app.route('/api/games')
def api_games():
    system_filter = request.args.get('system', '')
    parents_only = request.args.get('parents', '') == '1'
    filtered = ALL_GAMES
    if system_filter:
        filtered = [g for g in filtered if g['system'] == system_filter]
    if parents_only:
        filtered = [g for g in filtered if not g['parent']]
    return jsonify(filtered)


@app.route('/api/ecosystem')
def api_ecosystem():
    return jsonify(ECOSYSTEM_CORES)


@app.route('/api/future')
def api_future():
    return jsonify(FUTURE_TARGETS)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5200, debug=False)
