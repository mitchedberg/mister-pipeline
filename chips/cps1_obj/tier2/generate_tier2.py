#!/usr/bin/env python3
"""
CPS1 OBJ Tier-2 test vector generator.

Reads:
  frame<N>_obj_ram.json  -- OBJ RAM dump from MAME Lua (1024 words, flip_screen)
  frame<N>_gfx.json      -- Decoded tile pixel data from MAME Lua (may be absent)

Outputs:
  tier2_vectors.jsonl    -- Per-scanline expected pixel maps (same format as tier1)
  tier2_obj_ram.jsonl    -- OBJ RAM + ROM lookup for testbench
  tier2_rom.json         -- ROM nibble lookup: {"{code}_{vsub}": [n0..n15]}

Usage:
  python3 generate_tier2.py frame0200_obj_ram.json [frame0200_gfx.json]
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VECTORS_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "vectors")

sys.path.insert(0, VECTORS_DIR)
from obj_model import (
    CPS1OBJModel, TRANSPARENT, make_rom
)

ACTIVE_SCANLINES = list(range(0, 240))
VISIBLE_X_START  = 64
VISIBLE_X_END    = 447


def load_obj_ram_json(path):
    with open(path) as f:
        data = json.load(f)
    obj_ram_raw = data["obj_ram"]   # list of 1024 ints (1-indexed from Lua)
    # Lua arrays are 1-indexed; Python list will be 0-indexed
    if len(obj_ram_raw) != 1024:
        raise ValueError(f"Expected 1024 OBJ RAM words, got {len(obj_ram_raw)}")
    obj_ram = [int(w) & 0xFFFF for w in obj_ram_raw]
    flip_screen   = bool(data.get("flip_screen", False))
    sprite_count  = int(data.get("sprite_count", 0))
    frame_num     = int(data.get("frame", 0))
    return obj_ram, flip_screen, sprite_count, frame_num


def load_gfx_json(path):
    """
    Load GFX data from MAME Lua dump.
    Format: {"<code_str>": [[vsub0_px0..px15], ...]}
    Returns dict: (code_int, vsub_int) -> [16 nibbles]
    """
    with open(path) as f:
        raw = json.load(f)
    rom_overrides = {}
    for code_str, vsub_list in raw.items():
        code = int(code_str)
        for vsub_idx, pixels in enumerate(vsub_list):
            nibbles = [int(n) & 0xF for n in pixels]
            if len(nibbles) != 16:
                nibbles = (nibbles + [0xF]*16)[:16]
            rom_overrides[(code, vsub_idx)] = nibbles
    return rom_overrides


def build_rom_lookup(rom_overrides):
    """Build a ROM lookup function that uses real data with procedural fallback."""
    from obj_model import make_rom
    return make_rom(overrides=rom_overrides)


def run_model(obj_ram, flip_screen, rom):
    """Run CPS1OBJModel with given OBJ RAM and ROM, return line buffers."""
    model = CPS1OBJModel(flip_screen=flip_screen, rom=rom)
    for addr, word in enumerate(obj_ram):
        model.write_obj_ram(addr, word)
    model.vblank()
    return model


def make_test_name(frame_num, flip_screen):
    flip_str = "flip" if flip_screen else "noflip"
    return f"tier2_frame{frame_num:04d}_{flip_str}"


def generate_vectors(model, test_name, flip_screen):
    """Generate per-scanline vector records."""
    vec_records = []
    for sl in ACTIVE_SCANLINES:
        line = model.get_line(sl)
        pixels = {}
        for px in range(VISIBLE_X_START, VISIBLE_X_END + 1):
            val = line[px]
            if val != TRANSPARENT:
                pixels[str(px)] = val
        vec_records.append({
            "test_name":   test_name,
            "scanline":    sl,
            "flip_screen": flip_screen,
            "pixels":      pixels,
        })
    return vec_records


def generate_rom_json(rom_overrides):
    """
    Build ROM JSON for the testbench.
    Format: {"{code}_{vsub}": [n0..n15]}
    """
    rom_json = {}
    for (code, vsub), nibbles in rom_overrides.items():
        key = f"{code}_{vsub}"
        rom_json[key] = nibbles
    return rom_json


def main():
    if len(sys.argv) < 2:
        print("Usage: generate_tier2.py <frame_obj_ram.json> [<frame_gfx.json>]")
        sys.exit(1)

    obj_ram_path = sys.argv[1]
    gfx_path     = sys.argv[2] if len(sys.argv) > 2 else None

    # --- Load OBJ RAM ---
    obj_ram, flip_screen, sprite_count, frame_num = load_obj_ram_json(obj_ram_path)
    test_name = make_test_name(frame_num, flip_screen)
    print(f"Frame {frame_num}: {sprite_count} sprites, flip_screen={flip_screen}")
    print(f"Test name: {test_name}")

    # --- Load GFX data (real ROM pixels) ---
    rom_overrides = {}
    if gfx_path and os.path.exists(gfx_path):
        rom_overrides = load_gfx_json(gfx_path)
        print(f"Loaded {len(rom_overrides)} tile rows from GFX dump")
    else:
        print("No GFX dump — using procedural ROM (matches tier-1 behavior)")

    # --- Build ROM lookup ---
    rom = build_rom_lookup(rom_overrides)

    # --- Run model ---
    print("Running CPS1OBJModel...")
    model = run_model(obj_ram, flip_screen, rom)

    # --- Count non-transparent pixels ---
    total_pixels = 0
    for sl in ACTIVE_SCANLINES:
        line = model.get_line(sl)
        for px in range(VISIBLE_X_START, VISIBLE_X_END + 1):
            if line[px] != TRANSPARENT:
                total_pixels += 1
    print(f"Model output: {total_pixels} non-transparent pixels across 240 scanlines")

    # --- Generate outputs ---
    tier2_dir = os.path.dirname(obj_ram_path)

    # tier2_vectors.jsonl
    vec_path = os.path.join(tier2_dir, "tier2_vectors.jsonl")
    vec_records = generate_vectors(model, test_name, flip_screen)
    with open(vec_path, "w") as f:
        for rec in vec_records:
            f.write(json.dumps(rec) + "\n")
    print(f"Written: {vec_path} ({len(vec_records)} records)")

    # tier2_obj_ram.jsonl
    ram_path = os.path.join(tier2_dir, "tier2_obj_ram.jsonl")
    ram_record = {"test_name": test_name, "obj_ram": obj_ram}
    with open(ram_path, "w") as f:
        f.write(json.dumps(ram_record) + "\n")
    print(f"Written: {ram_path}")

    # tier2_rom.json
    if rom_overrides:
        rom_json_path = os.path.join(tier2_dir, "tier2_rom.json")
        rom_json = generate_rom_json(rom_overrides)
        with open(rom_json_path, "w") as f:
            json.dump(rom_json, f)
        print(f"Written: {rom_json_path} ({len(rom_json)} entries)")

    print(f"\nDone. To run RTL testbench:")
    print(f"  cd chips/cps1_obj/vectors")
    if rom_overrides:
        print(f"  ./run_tier2.sh ../tier2/tier2_vectors.jsonl ../tier2/tier2_obj_ram.jsonl ../tier2/tier2_rom.json")
    else:
        print(f"  ./run_tier2.sh ../tier2/tier2_vectors.jsonl ../tier2/tier2_obj_ram.jsonl")


if __name__ == "__main__":
    main()
