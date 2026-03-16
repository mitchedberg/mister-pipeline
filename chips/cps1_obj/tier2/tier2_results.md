# CPS1 OBJ — Tier-2 Test Results: Real Game Integration

**Date:** 2026-03-15
**Source:** Final Fight (ffight) attract mode, frame 4980 (~81 seconds game time)
**OBJ RAM source:** MAME 0.286 Lua memory dump
**ROM model:** Procedural (deterministic, matches tier-1)

---

## Summary

| Metric | Value |
|--------|-------|
| Total pixel vectors | 24,064 |
| PASS | 24,064 |
| FAIL | 0 |
| **Pass rate** | **100.00%** |
| Sprite entries | 108 (256 scanned, no terminator) |
| Unique tile codes | 56 |
| Active scanlines | 72–168 (sprites visible in ~97 scanlines) |

---

## Sprite Table Characteristics

Frame 4980 appears to be the Final Fight title/intro logo sequence rendered as sprites.
All sprites are single-tile (nx=0, ny=0), no flip, packed tightly across the screen.

**Scanline load analysis:**
| Scanline range | Sprites | Slots used | Overflow |
|----------------|---------|------------|----------|
| 72–87          | 18      | 16         | 2 dropped |
| 88–103         | 18      | 16         | 2 dropped |
| 104–119        | 18      | 16         | 2 dropped |
| 120–135        | 20      | 16         | 4 dropped |
| 136–151        | 20      | 16         | 4 dropped |
| 152–167        | 8       | 8          | 0 |
| 168–183        | 6       | 6          | 0 |

Several scanlines exceed the 16-sprite hardware cap, exercising the SIB overflow behavior.

---

## Hardware Cap Fix (obj_model.py)

This test exposed a missing feature in the Python model: the hardware's 16-slot-per-scanline
limit (enforced by the SIB state machine in the RTL). The model was updated to:

1. Process sprites ascending (entry 0 = highest priority, fills slots first)
2. Track per-scanline slot counts (max 16)
3. Drop sprites that exceed the slot cap on any given scanline
4. Render remaining sprites in reverse order (lower index overwrites = wins priority)

The fix was applied to `chips/cps1_obj/vectors/obj_model.py` — tier-1 vectors regenerated
and verified: still 88,000/88,000 (100.00%) because all tier-1 overflow scenarios had
higher-priority sprites already covering the same pixel positions.

---

## What Tier-2 Tests Beyond Tier-1

1. **Real game sprite table patterns** — 108 sprites across 7 scanline bands, dense
   packing that naturally exercises the 16-slot overflow hardware behavior
2. **Real tile codes** — codes in the 0x0400–0x1170 range (vs tier-1's 0x0001–0x04FF)
3. **Hardware cap enforcement** — scanlines with 18–20 sprites verify cap correctly
   drops lowest-priority (highest-index) entries
4. **OBJ_BASE = 0x9000** — Final Fight uses a non-default OBJ_BASE (0x9000 vs the
   documented default 0x9200), confirming the RTL handles any valid OBJ table location

---

## Infrastructure Notes

**ROM extraction:** MAME Lua dumps were used to locate the OBJ RAM:
- OBJ_BASE register (0x800100) is WRITE-ONLY — reads as zero
- Final Fight sets OBJ_BASE = 0x9000 → OBJ RAM at CPU 0x900000 (start of GFX RAM)
- Sprite data only appears after ~4970 frames (~83 game-seconds), during the intro logo

**GFX region:** The `:gfx` memory region (2MB, interleaved from 4 ROMs) contains the raw
sprite tile data. The decoding format (bit-plane vs packed nibble) is unresolved; this
tier-2 run uses the procedural ROM model instead of real ROM data.

**MAME Lua API (v0.286):**
- `manager.machine.gfx` → nil (not valid)
- `manager.machine.memory.regions[":gfx"]` → works, 2MB region accessible
- `manager.machine.devices[":maincpu"].spaces["program"]` → CPU memory readable
- `install_write_tap()` → works for memory write interception
- `gfx_element:pixel()` → not accessible via standard path

---

## Next Steps for Tier-2

1. Resolve GFX region bit-plane decoding → use real ROM tile data for VISUAL accuracy
2. Capture multiple frames (gameplay scenes, boss fights) for more diverse sprite patterns
3. Capture during 2-player co-op scenes (maximum sprite density)
4. Verify against MAME's actual rendered output (OBJ layer isolation via layer control)
