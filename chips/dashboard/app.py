#!/usr/bin/env python3
"""
MiSTer Pipeline Dashboard — Comprehensive Arcade Ecosystem View
Tier 1: Our Work (8 systems in active development)
Tier 2: Full MiSTer Ecosystem — all hardware platforms with core status
Tier 3: Individual game cores catalog
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

with open(os.path.join(DASH, 'ecosystem_data.json')) as f:
    ECOSYSTEM_DATA = json.load(f)

# ---------------------------------------------------------------------------
# Per-system game counts (our systems)
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
# Timeline — milestones in chronological order
# ---------------------------------------------------------------------------
TIMELINE = [
    {'date': '2026-03-15', 'event': 'Project initialized', 'detail': 'Repo created, gate scripts, CI workflow, CPS1 OBJ + TC0100SCN RTL'},
    {'date': '2026-03-16', 'event': 'Taito B + F3 + Z RTL complete', 'detail': 'TC0180VCU (398 tests), TC0630FDP (1,156 tests), TC0480SCP (213 tests)'},
    {'date': '2026-03-17', 'event': '8 systems integrated', 'detail': 'NMK16, Toaplan V2, Psikyo, Kaneko16, Taito B/F3/Z/X — all with audio + I/O'},
    {'date': '2026-03-17', 'event': 'CI synthesis pipeline live', 'detail': 'GitHub Actions Quartus workflows for all 8 chips'},
    {'date': '2026-03-18', 'event': 'fx68k CPU boot breakthrough', 'detail': 'Root cause: enPhi1/enPhi2 Verilator race. Fix: C++-driven phi enables'},
    {'date': '2026-03-18', 'event': '6 RBF bitstreams produced', 'detail': 'NMK, Psikyo, Taito B, Toaplan V2, Taito X, Kaneko — all fit Cyclone V'},
    {'date': '2026-03-19', 'event': 'All 6 CPUs boot in Verilator', 'detail': 'Thunder Dragon, Batsugun, Gunbird, Berlwall, Nastar, Gigandes'},
    {'date': '2026-03-19', 'event': '3 cores rendering game graphics', 'detail': 'Thunder Dragon (BG tiles, 91% non-black), Gunbird, Berlwall'},
    {'date': '2026-03-20', 'event': 'Gigandes + Berlwall rendering', 'detail': 'Purple sprite pixels from frame 12; Berlwall palette writes visible'},
    {'date': '2026-03-20', 'event': 'Process safety added', 'detail': 'Timeouts on all sim runners to prevent runaway processes'},
    {'date': '2026-03-20', 'event': 'fx68k interrupt fix (IACK pattern)', 'detail': 'Timer-based IPL replaced with IACK-based clear — community pattern from 10+ cores'},
    {'date': '2026-03-20', 'event': 'NMK sprites rendering!', 'detail': 'Thunder Dragon: BG + sprites + palette + scrolling. 95.73% MainRAM accuracy vs MAME'},
    {'date': '2026-03-20', 'event': 'Toaplan V2 Truxton II boots', 'detail': '45M bus cycles, 2048 palette writes. YM2151 stub + WRAM decode + address map fixed'},
    {'date': '2026-03-20', 'event': 'MAME RAM comparison pipeline', 'detail': '1012 NMK + 1000 Truxton II frames captured. Byte-by-byte comparison tool working'},
    {'date': '2026-03-20', 'event': 'Taito F3 optimization plan', 'detail': '8-phase plan: time-multiplex 4 BG engines at 96MHz. Estimated 35-42K ALMs'},
]

# ---------------------------------------------------------------------------
# Agent Status — live task assignments
# ---------------------------------------------------------------------------
AGENT_STATUS = [
    {
        'name': 'Agent 1',
        'branch': 'master',
        'machine': 'Mac Mini 3',
        'status': 'active',
        'tasks': [
            {'core': 'NMK16', 'task': 'DONE — sprites + BG + palette rendering, 95.73% RAM accuracy', 'status': 'in_progress'},
            {'core': 'Toaplan V2', 'task': 'IACK fix in progress, Truxton II boots 45M cycles', 'status': 'in_progress'},
            {'core': 'Psikyo', 'task': 'IACK fix applied, Gunbird sim running', 'status': 'in_progress'},
        ],
    },
    {
        'name': 'Agent 2',
        'branch': 'sim-batch2',
        'machine': 'iMac-Garage',
        'status': 'active',
        'tasks': [
            {'core': 'Kaneko', 'task': 'VBlank IRQ working! Palette writes every frame', 'status': 'in_progress'},
            {'core': 'Taito X', 'task': 'BG tilemap renderer complete, Gigandes rendering', 'status': 'in_progress'},
            {'core': 'Taito B', 'task': 'IACK fix needed', 'status': 'next'},
        ],
    },
]

# ---------------------------------------------------------------------------
# Ecosystem statistics
# ---------------------------------------------------------------------------
def get_ecosystem_stats():
    stats = {'mature': 0, 'beta': 0, 'wip': 0, 'gap': 0, 'our_work': 0}
    for entry in ECOSYSTEM_DATA:
        s = entry.get('status', 'gap')
        if s in stats:
            stats[s] += 1
    return stats

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route('/')
def dashboard():
    our_systems = [get_our_system_status(s) for s in OUR_SYSTEMS]

    # Split ecosystem by status
    mature_cores = [e for e in ECOSYSTEM_DATA if e['status'] == 'mature']
    beta_cores = [e for e in ECOSYSTEM_DATA if e['status'] == 'beta']
    wip_cores = [e for e in ECOSYSTEM_DATA if e['status'] == 'wip']
    gap_cores = [e for e in ECOSYSTEM_DATA if e['status'] == 'gap']
    our_work_eco = [e for e in ECOSYSTEM_DATA if e['status'] == 'our_work']

    total_games = sum(c['total'] for c in SYSTEM_GAME_COUNTS.values())
    total_parents = sum(c['parents'] for c in SYSTEM_GAME_COUNTS.values())

    eco_stats = get_ecosystem_stats()

    # Total game coverage from ecosystem
    eco_games_covered = sum(e.get('game_count', 0) for e in ECOSYSTEM_DATA if e['status'] in ('mature', 'beta', 'wip', 'our_work'))
    eco_games_total = sum(e.get('game_count', 0) for e in ECOSYSTEM_DATA)

    return render_template(
        'template.html',
        our_systems=our_systems,
        ecosystem_data=ECOSYSTEM_DATA,
        mature_cores=mature_cores,
        beta_cores=beta_cores,
        wip_cores=wip_cores,
        gap_cores=gap_cores,
        our_work_eco=our_work_eco,
        eco_stats=eco_stats,
        eco_games_covered=eco_games_covered,
        eco_games_total=eco_games_total,
        system_game_counts=SYSTEM_GAME_COUNTS,
        system_display=SYSTEM_DISPLAY,
        systems_list=sorted(GAME_DATA.keys()),
        total_games=total_games,
        total_parents=total_parents,
        all_games_js=json.dumps(ALL_GAMES),
        system_display_js=json.dumps(SYSTEM_DISPLAY),
        updated_at=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        timeline=TIMELINE,
        agent_status=AGENT_STATUS,
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
    """Full ecosystem table — all hardware platforms."""
    return render_template(
        'ecosystem.html',
        ecosystem=ECOSYSTEM_DATA,
        eco_stats=get_ecosystem_stats(),
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
    return jsonify(ECOSYSTEM_DATA)


@app.route('/api/timeline')
def api_timeline():
    return jsonify(TIMELINE)


@app.route('/api/agents')
def api_agents():
    return jsonify(AGENT_STATUS)


# ---------------------------------------------------------------------------
# Factory Status API — reads live .shared/ files
# ---------------------------------------------------------------------------

SHARED_DIR = os.path.join(os.path.dirname(BASE), '.shared')

def read_shared_file(name):
    path = os.path.join(SHARED_DIR, name)
    if os.path.exists(path):
        with open(path) as f:
            return f.read()
    return ""

def parse_factory_tasks():
    """Parse task_queue.md for structured tasks."""
    import re
    content = read_shared_file('task_queue.md')
    tasks = []
    pattern = re.compile(
        r'###\s+TASK-(\d+):\s*(.+?)(?=\n###\s+TASK-|\Z)', re.DOTALL
    )
    for m in pattern.finditer(content):
        block = m.group(0)
        task_id = f"TASK-{m.group(1)}"
        title = m.group(2).split('\n')[0].strip()
        status_m = re.search(r'\*\*Status:\*\*\s*(\S+)', block)
        status = status_m.group(1) if status_m else 'UNKNOWN'
        depends_m = re.search(r'\*\*Depends on:\*\*\s*(.+)', block)
        depends = depends_m.group(1).strip() if depends_m else 'none'
        assigned_m = re.search(r'\*\*Assigned to:\*\*\s*(.+)', block)
        assigned = assigned_m.group(1).strip() if assigned_m else 'any'
        tasks.append({
            'id': task_id, 'title': title, 'status': status,
            'depends': depends, 'assigned': assigned,
        })
    return tasks

@app.route('/api/factory')
def api_factory():
    """Factory status: tasks, findings, heartbeat, failure catalog."""
    tasks = parse_factory_tasks()
    heartbeat = read_shared_file('heartbeat.md')
    last_heartbeat = heartbeat.strip().split('\n')[-1] if heartbeat.strip() else 'none'

    findings_raw = read_shared_file('findings.md')
    # Count entries by looking for ## headers
    findings_count = findings_raw.count('\n## ')

    catalog_raw = read_shared_file('failure_catalog.md')
    catalog_count = catalog_raw.count('\n### ')

    comms_raw = read_shared_file('agent_comms.md')
    comms_count = comms_raw.count('\n## ')

    status_counts = {}
    for t in tasks:
        k = t['status'].split(':')[0]
        status_counts[k] = status_counts.get(k, 0) + 1

    return jsonify({
        'tasks': tasks,
        'summary': status_counts,
        'total_tasks': len(tasks),
        'last_heartbeat': last_heartbeat,
        'findings_count': findings_count,
        'catalog_entries': catalog_count,
        'agent_comms_count': comms_count,
        'updated_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    })

@app.route('/api/factory/findings')
def api_factory_findings():
    return read_shared_file('findings.md'), 200, {'Content-Type': 'text/plain'}

@app.route('/api/factory/catalog')
def api_factory_catalog():
    return read_shared_file('failure_catalog.md'), 200, {'Content-Type': 'text/plain'}

@app.route('/api/factory/comms')
def api_factory_comms():
    return read_shared_file('agent_comms.md'), 200, {'Content-Type': 'text/plain'}

@app.route('/api/factory/roadmap')
def api_factory_roadmap():
    roadmap_path = os.path.join(os.path.dirname(BASE), 'BUILD_ROADMAP.md')
    if os.path.exists(roadmap_path):
        with open(roadmap_path) as f:
            return f.read(), 200, {'Content-Type': 'text/plain'}
    return 'No roadmap found', 404

@app.route('/api/mame/stats')
def api_mame_stats():
    """Full MAME database stats from SQLite."""
    db_path = os.path.join(os.path.dirname(BASE), 'factory', 'mame.db')
    if not os.path.exists(db_path):
        return jsonify({"error": "No MAME database"}), 404
    import sqlite3
    conn = sqlite3.connect(db_path)

    total = conn.execute("SELECT COUNT(*) FROM games").fetchone()[0]
    arcade = conn.execute("SELECT COUNT(*) FROM games WHERE is_arcade = 1").fetchone()[0]
    feasible = conn.execute("SELECT COUNT(*) FROM games WHERE feasibility = 'FEASIBLE'").fetchone()[0]
    maybe = conn.execute("SELECT COUNT(*) FROM games WHERE feasibility = 'MAYBE'").fetchone()[0]
    unique_chips = conn.execute("SELECT COUNT(*) FROM chips").fetchone()[0]
    total_roms = conn.execute("SELECT COUNT(*) FROM roms").fetchone()[0]

    # Top drivers
    top_drivers = conn.execute("""
        SELECT source_file, COUNT(*) as cnt,
               SUM(CASE WHEN is_clone = 0 THEN 1 ELSE 0 END) as unique_cnt,
               feasibility
        FROM games WHERE is_arcade = 1
        GROUP BY source_file ORDER BY cnt DESC LIMIT 50
    """).fetchall()

    # Top chips (non-trivial)
    top_chips = conn.execute("""
        SELECT c.chip_name, c.chip_type, COUNT(DISTINCT g.id) as cnt
        FROM games g JOIN game_chips gc ON g.id = gc.game_id
        JOIN chips c ON gc.chip_id = c.id
        WHERE g.is_arcade = 1 AND g.feasibility IN ('FEASIBLE', 'MAYBE')
        AND c.chip_name NOT LIKE '%Speaker%'
        GROUP BY c.chip_name ORDER BY cnt DESC LIMIT 40
    """).fetchall()

    conn.close()
    return jsonify({
        "total_games": total, "arcade_games": arcade,
        "feasible_games": feasible, "maybe_games": maybe,
        "unique_chips": unique_chips, "total_roms": total_roms,
        "top_drivers": [{"source": r[0], "total": r[1], "unique": r[2], "feasibility": r[3]} for r in top_drivers],
        "top_chips": [{"name": r[0], "type": r[1], "games": r[2]} for r in top_chips],
        "updated_at": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    })

@app.route('/api/mame/search')
def api_mame_search():
    """Search MAME games."""
    q = request.args.get('q', '')
    feasible_only = request.args.get('feasible', '') == '1'
    db_path = os.path.join(os.path.dirname(BASE), 'factory', 'mame.db')
    if not os.path.exists(db_path):
        return jsonify([])
    import sqlite3
    conn = sqlite3.connect(db_path)
    query_sql = "SELECT short_name, description, year, manufacturer, source_file, feasibility FROM games WHERE is_arcade = 1"
    params = []
    if q:
        query_sql += " AND (description LIKE ? OR short_name LIKE ?)"
        params.extend([f"%{q}%", f"%{q}%"])
    if feasible_only:
        query_sql += " AND feasibility = 'FEASIBLE'"
    query_sql += " ORDER BY year LIMIT 200"
    rows = conn.execute(query_sql, params).fetchall()
    conn.close()
    return jsonify([{"name": r[0], "title": r[1], "year": r[2], "mfg": r[3], "driver": r[4], "feasibility": r[5]} for r in rows])

@app.route('/api/factory/requirements')
def api_factory_requirements():
    req_path = os.path.join(os.path.dirname(BASE), 'factory', 'requirements_tree.json')
    if os.path.exists(req_path):
        with open(req_path) as f:
            return jsonify(json.load(f))
    return jsonify({"error": "No requirements tree found"}), 404

@app.route('/api/factory/community_patterns')
def api_factory_patterns():
    patterns_path = os.path.join(BASE, 'COMMUNITY_PATTERNS.md')
    if os.path.exists(patterns_path):
        with open(patterns_path) as f:
            return f.read(), 200, {'Content-Type': 'text/plain'}
    return 'No patterns found', 404

@app.route('/mame')
def mame_page():
    """MAME database explorer."""
    return render_template('mame.html')

@app.route('/factory')
def factory_page():
    """Factory dashboard — comprehensive view of the autonomous pipeline."""
    tasks = parse_factory_tasks()
    heartbeat = read_shared_file('heartbeat.md')
    last_hb = heartbeat.strip().split('\n')[-1] if heartbeat.strip() else 'No heartbeat yet'

    status_counts = {}
    for t in tasks:
        k = t['status'].split(':')[0]
        status_counts[k] = status_counts.get(k, 0) + 1

    # Read roadmap for display
    roadmap_path = os.path.join(os.path.dirname(BASE), 'BUILD_ROADMAP.md')
    roadmap = ''
    if os.path.exists(roadmap_path):
        with open(roadmap_path) as f:
            roadmap = f.read()

    # Read BOM
    bom_path = os.path.join(os.path.dirname(BASE), 'ARCADE_CHIP_BOM.md')
    bom = ''
    if os.path.exists(bom_path):
        with open(bom_path) as f:
            bom = f.read()

    return render_template('factory.html',
        tasks=tasks,
        summary=status_counts,
        last_heartbeat=last_hb,
        roadmap=roadmap,
        bom=bom,
        findings=read_shared_file('findings.md'),
        catalog=read_shared_file('failure_catalog.md'),
        comms=read_shared_file('agent_comms.md'),
        updated_at=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    )


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5200, debug=False)
