# Post-Taito X Arcade Hardware Targets — Ranked Research Summary

## Research Methodology
- GitHub API searches for MiSTer/FPGA coverage (verified 0 results for untouched systems)
- jotego/jtcores directory audit (122 cores, specific targets confirmed absent)
- MAME source inspection for hardware specs and complexity
- Existing FPGA community work identified (va7deo Toaplan cores, MyVision console)

---

## Rankings: Recommended Build Order

### 1. **Toaplan V2** ⭐ HIGHEST PRIORITY
**Coverage**: CLEAR (V2 untouched, V1 proven by zerowing core)
**Difficulty**: MEDIUM (~60-90 dev days from V1 baseline)
**Game Library**: EXCELLENT (~12-15 key titles: Batsugun, Truxton II, Dogyuun, FixEight)
**Strategic Value**: Fills critical 1990s bullet-hell shmup gap; V1 architecture proven in FPGA

**Why First**:
- zerowing core (va7deo, 174 commits, 47 stars, GPL-2.0) provides exact reference implementation
- V2 likely incremental evolution from V1 (can fork and extend)
- Batsugun is legendary; strong community interest
- 68000-based, sound chips (YM2610/YM2151) already solved
- Can contact va7deo for architectural guidance

**Next Steps**:
1. Fork zeroing repo, trace V2 differences in MAME source
2. Implement V2 graphics chip enhancements (likely VRAMblending modes, priority changes)
3. Test against Batsugun/Dogyuun TAS data

---

### 2. **NMK16** ⭐ RECOMMENDED (SECOND)
**Coverage**: CLEAR (0 MiSTer/FPGA cores)
**Difficulty**: MEDIUM-LOW (~50-80 dev days)
**Game Library**: GOOD (~10 titles: Truxton, Blazing Lazers, Gunhed, Cyber Lip)
**Strategic Value**: Simplest custom-chip architecture; fills 1989-1993 shmup library gap

**Why Second**:
- **Architectural simplicity**: No custom graphics ICs (vs Psikyo's 4 chips, Kaneko's 7)
- **68000 + Z80 standard**: Both well-understood
- **Sound solved**: YM2203 and OKI6295 both in jotego cores
- **MAME documentation solid**: 5 core drivers (nmk16, nmk004, nmk214, etc.)
- **Best learning project**: Fewest moving parts, clear signal/noise ratio for debugging

**Why not First**:
- Smaller game library than Toaplan V2 (overlaps significantly with Psikyo/Toaplan)
- No existing FPGA reference work (vs V1 for Toaplan)
- Less community demand than bullet-hell cult classics

**Next Steps**:
1. Audit nmk16.cpp in MAME for graphics pipeline
2. Trace sprite/tile priority logic (likely straightforward)
3. Validate against Truxton / Blazing Lazers TAS data

---

### 3. **Psikyo** ⭐ STRONG CANDIDATE (THIRD or PARALLEL)
**Coverage**: CLEAR (0 MiSTer/FPGA cores)
**Difficulty**: MEDIUM-HIGH (~80-120 dev days)
**Game Library**: EXCELLENT (~8 key titles: Gunbird 1/2, Strikers 1945 I/II/III)
**Strategic Value**: Most famous shmup library; 4 custom graphics ICs, well-documented

**Why Third**:
- **Larger custom chip footprint**: 4 dedicated ICs (PS2001B, PS3103, PS3204, PS3305)
- **Strong community interest**: Recent hardware preservation work (motozilog PIC16C57 replacement, Feb 2026)
- **Well-documented in MAME**: All custom chip behaviors reverse-engineered
- **Architecture proven feasible**: Similar complexity to Taito F3 (already FPGA'd)
- **Game library unmatched**: Gunbird/Strikers 1945 are apex of 1990s vertical shmups

**Why not First**:
- More complex than NMK/Toaplan V2 (4 custom chips)
- No existing FPGA reference work (unlike Toaplan V1)
- Could start in parallel with NMK if resources allow

**Build Order Flexibility**:
- Option A: NMK (50-80 days) → Psikyo (80-120 days) → Toaplan V2 (60-90 days)
- Option B: Toaplan V2 (60-90 days) + NMK (50-80 days) in parallel
- Psikyo is standalone; can start anytime after Taito X infrastructure is proven

**Next Steps**:
1. MAME deep-dive: psikyo.cpp graphics pipeline (PS2001B-3305 handoff)
2. Schematic analysis (if available): understand 4-chip blitting/priority/palette coordination
3. Parallel feasibility study: compare to Taito F3 complexity

---

### 4. **Kaneko 16** 🟡 VIABLE (FOURTH or RESEARCH)
**Coverage**: CLEAR (0 MiSTer/FPGA cores)
**Difficulty**: MEDIUM (~70-100 dev days)
**Game Library**: MODEST (~12 titles: Berlin Wall, Brap Boys, Shogun Warriors)
**Strategic Value**: Covers late 1980s action/racing; interesting MCU co-processors

**Why Fourth**:
- **7 custom chips**: More complex than Psikyo (4) or NMK (0)
- **CALC3/TOYBOX MCU subsystems**: May require cycle-accurate emulation (risky/slow)
- **Smaller game library**: Niche action/racing titles, not AAA-tier demand
- **Architectural sophistication**: VU-series sprite/tile pipeline more intricate than contemporaries

**Strengths**:
- Well-documented in MAME (custom chip behaviors clear)
- MCU-based protection can be stubbed for most titles
- Interesting high-color background processing (VU-003, 3x chips)

**Build Timing**:
- After Psikyo/NMK proven stable
- Research feasibility in parallel
- Consider deferring unless CALC3/TOYBOX reverse-engineering yields clean results

---

### 5. **DECO32** 🟠 HIGHER RISK (FIFTH or DEFER)
**Coverage**: CLEAR (0 MiSTer/FPGA cores)
**Difficulty**: HIGH (~120-180 dev days)
**Game Library**: SMALL (~6-8 titles: Caveman Ninja, Fighter's History, Wizard Fire)
**Strategic Value**: 1990s action/fighting games, but architecturally complex

**Why Lower Priority**:
- **ARM CPU encryption**: DE 156 chip wraps encrypted ARM — requires key extraction or functional sim
- **H6280 sound CPU**: Not yet in jotego cores (PC Engine chip, needs implementation)
- **Custom chip mystery**: DE 141/74/99 rendering pipeline poorly documented vs other vendors
- **Smallest game library**: Only ~6-8 titles, largely forgotten in modern arcade zeitgeist

**Strengths**:
- ARM emulation is solvable (but complex)
- Well-researched in MAME (can extract decryption logic)
- Fighter's History is historically important (Capcom fighting game challenger)

**Build Timing**:
- Defer until post-Psikyo/NMK/Kaneko
- Consider only if H6280 and ARM decryption community work emerges
- High risk/reward ratio; better options available first

---

### 6. **Nichibutsu** 🔴 NOT RECOMMENDED (RESEARCH ONLY)
**Coverage**: PARTIAL (Console exists, arcade untouched)
**Difficulty**: UNKNOWN/HIGH RISK (~80-120 dev days, low confidence)
**Game Library**: TINY (~4-6 titles: Bomb Jack, Blast Off, Mahjong variants)
**Strategic Value**: Bomb Jack nostalgia only; no strategic arcade library coverage

**Why Defer Indefinitely**:
- **Sparse documentation**: Custom chip behaviors far less researched than major vendors
- **Limited test cases**: Only Bomb Jack widely recognized; others are mahjong/gambling titles
- **No FPGA community work**: Starting from zero with minimal reverse-engineering baseline
- **Console core irrelevant**: My Vision is separate hardware, won't transfer knowledge
- **Better alternatives available**: NMK/Psikyo/Toaplan cover same era with better coverage

**Future Option**:
- If community demand for Bomb Jack grows, revisit after major systems complete
- Could implement as a "bonus" once framework mature (low incremental cost)

---

## Summary Table

| System | Status | Difficulty | Game Count | Recommendation | Est. Days |
|--------|--------|------------|-----------|-----------------|-----------|
| **Toaplan V2** | CLEAR (V1 proven) | MEDIUM | 12-15 | **1st Priority** | 60-90 |
| **NMK16** | CLEAR | MEDIUM-LOW | 10 | **2nd Priority** | 50-80 |
| **Psikyo** | CLEAR | MEDIUM-HIGH | 8 | **3rd Priority** | 80-120 |
| **Kaneko 16** | CLEAR | MEDIUM | 12 | **4th (Research)** | 70-100 |
| **DECO32** | CLEAR | HIGH | 6-8 | **5th (Defer)** | 120-180 |
| **Nichibutsu** | PARTIAL | UNKNOWN | 4-6 | **Not Recommended** | 80-120 |

---

## Strategic Principles (Post-Taito X)

1. **Leverage existing FPGA work**: Toaplan V1 (zerowing) provides architectural baseline for V2
2. **Start simple, escalate complexity**: NMK (0 custom chips) → Psikyo (4 chips) → Kaneko (7 chips)
3. **Prioritize game libraries**: Toaplan V2 (Batsugun) > NMK (Truxton) > Psikyo (Gunbird) in terms of cultural impact
4. **Avoid encryption/MCU risk early**: Defer DECO32 (ARM encryption) and Kaneko (CALC3 co-processor) until team confidence high
5. **Build validation infrastructure first**: Ensure TAS validation pipeline extends to each new system before implementation

---

## Implementation Roadmap Recommendation

**Phase 1 (Months 1-3)**:
- Toaplan V2 (build from V1 reference) + NMK16 (simplest architecture)
- Parallel development, shared infrastructure

**Phase 2 (Months 4-6)**:
- Psikyo (custom graphics research + implementation)
- Kaneko 16 (research CALC3/TOYBOX feasibility)

**Phase 3 (Months 7-9)**:
- Kaneko 16 completion (if feasible) OR
- DECO32 research (if ARM decryption work emerges)

**Phase 4+**:
- Nichibutsu (if community demand justifies)
- Advanced systems (Taito Type X, CPS-3, etc.)

---

## Research Artifacts
See individual READMEs in `/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/`:
- `psikyo/README.md` — Full hardware specs, game list, 4-chip architecture analysis
- `deco32/README.md` — ARM encryption challenges, H6280 complexity analysis
- `toaplan/README.md` — V1 vs V2 delta analysis, architectural extension strategy
- `kaneko/README.md` — MCU subsystem breakdown, custom graphics pipeline
- `nmk/README.md` — Simplest architecture, architectural reference for new developers
- `nichibutsu/README.md` — Why deferred, limited coverage justification
