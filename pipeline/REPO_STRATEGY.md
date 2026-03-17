# MiSTer FPGA Arcade Pipeline — Two-Tier Repository Strategy

## Overview

This document defines the complete repository strategy for the MiSTer FPGA arcade core generation pipeline. The strategy separates development (private) from release (public), ensuring clean, auditable separation of concerns and compliance with community standards.

---

## Tier 1: Private Development Repository

**Repository**: `MiSTer_Pipeline` (this repository)
**Visibility**: Private (GitHub private repo, no public clones)
**Lifetime**: Permanent
**Git Remote**: Private GitHub org repository

### Contents (Everything Allowed)

```
MiSTer_Pipeline/
├── chips/                      # All custom chip RTL under development
│   ├── taito_f3/
│   ├── taito_b/
│   ├── taito_x/
│   ├── taito_z/
│   └── [future systems]
│       ├── rtl/               # SystemVerilog source files
│       ├── quartus/           # Quartus IDE projects, synthesis logs
│       ├── mra/               # MRA files (ROM autolaunchers)
│       └── vectors/           # Test vectors, ground truth from MAME
├── research/                   # DEEP RESEARCH ARTIFACTS
│   ├── [system]/README.md      # Reverse-engineering notes, decap analysis
│   ├── [system]/schematics/    # Gate captures, PDF scans
│   └── [system]/gate-traces/   # Oscilloscope recordings, timing diagrams
├── chips/[system]/README.md    # Chip-level technical docs
├── gates/                       # Gate scripts (behavioral, lint, synthesis checks)
├── templates/                   # Codegen templates (prompts, Verilator stubs)
├── test_modules/               # Cross-chip integration test harnesses
├── .github/workflows/          # CI/CD (synthesis, testing)
├── CLAUDE.md                   # Development rules and principles
├── ARCADE_TARGETS_RANKED.md   # Strategic roadmap
├── LICENSE                     # GPL-2.0 (development repo)
└── [session notes, debugging artifacts, dead ends]
```

### Purpose

- **Development iteration**: All work-in-progress, dead ends, debugging harnesses
- **Quality gates**: Behavioral sim, lint, structural synthesis, functional regression
- **Knowledge capture**: Deep reverse-engineering notes, community decap data
- **Collaboration**: Internal team review, architecture discussions
- **CI/CD**: Automated synthesis, artifact generation, gate reporting

### Key Properties

1. **No public visibility** — research artifacts, reverse-engineering details, incomplete work remain private
2. **Complete traceability** — git history of all decisions, failed experiments, iterative fixes
3. **All artifacts kept** — debug scripts, test vectors, diagnostic logs never deleted (needed for future reference)
4. **Ground truth**: MAME source references, community decap data properly attributed in README files
5. **Vendor separation**: Chip documentation (TC0180VCU, GP9001, etc.) kept alongside RTL for reference

### Who Has Access

- Core development team
- Collaborators with signed NDAs or collaboration agreements
- Consultants (Delphi, hardware preservation experts) on as-needed basis
- All access logged and auditable

### Never Committed to Public

- Proprietary research notes beyond what's in ARCADE_TARGETS_RANKED.md
- Decap photos or detailed circuit scans (only references/summaries)
- Reverse-engineering steps that could aid illegal activities
- Vendor datasheets (reference them, don't include full PDFs)

---

## Tier 2: Public Release Repositories

**Repository Format**: One per released system
**Naming Convention**: `Arcade-{SystemName}_MiSTer`
**Visibility**: Public (GitHub public repos)
**Lifetime**: Indefinite (maintained with community feedback)
**License**: GPL-2.0

### Example Repositories

- `Arcade-TaitoF3_MiSTer`
- `Arcade-TaitoX_MiSTer`
- `Arcade-Psikyo_MiSTer`
- `Arcade-NMK16_MiSTer`

### Contents (Minimal, Release-Only)

```
Arcade-TaitoF3_MiSTer/
├── rtl/                        # Final, validated SystemVerilog
│   ├── emu.sv                  # Top-level module
│   ├── [custom_chip].sv        # Verified custom chip implementations
│   └── [support_modules]/      # Verified utility modules
├── quartus/                    # Quartus project (QSF, SDC, QIP)
│   ├── output_files/
│   │   └── emu.rbf            # Pre-built bitstream (optional, can be CI-generated)
│   └── [quartus project files]
├── mra/                        # MRA files for ROM autolaunchers
│   ├── [game1].mra
│   ├── [game2].mra
│   └── ...
├── LICENSE                     # GPL-2.0 license text
├── CREDITS.md                  # Attribution (MAME, community, decap data)
├── README.md                   # User-facing documentation
├── HARDWARE_NOTES.md          # (Optional) Hardware architecture overview
└── .gitignore
```

### What Is NOT Included

- ❌ `research/` directory (stay in private repo)
- ❌ `gates/` scripts (internal QA only)
- ❌ `vectors/` (test data stays private)
- ❌ `templates/` (codegen details stay private)
- ❌ `test_modules/` (internal testing harnesses)
- ❌ Session notes or debugging artifacts
- ❌ Community decap photos (reference only, in CREDITS.md)
- ❌ Incomplete chips or work-in-progress systems
- ❌ ARCADE_TARGETS_RANKED.md (strategic planning, stays private)

### License

**GPL-2.0** — All release repos use GPL-2.0 to match MiSTer core licensing. This ensures:
- Derivative works must be open-source
- Commercial use allowed (must release source code)
- Clear viral clause for community improvements
- Compatibility with MAME/arcade emulation community norms

### README Template

Each release repo README includes:
- System name, release date, version number
- Supported games (list, not exhaustive)
- Known issues (if any)
- Build instructions (Quartus Lite version, target device)
- ROM compatibility (how to auto-generate MRA files)
- Credit to MAME developers, community decap contributors, original hardware researchers
- Link back to official MiSTer repository

Example structure:
```
# Arcade-TaitoF3_MiSTer

Cycle-accurate FPGA implementation of the Taito F3 arcade hardware.

## Supported Games

- Puzzle Bobble
- Taito F3 library (18+ titles)
- See `mra/` directory for auto-launcher files

## Installation

1. Clone this repo to MiSTer cores directory
2. Copy MRA files to `_Arcade/` folder
3. Place ROM files (auto-generated via MAME)
4. Launch from MiSTer menu

## Build from Source

```bash
cd quartus
quartus_sh --flow compile emu
```

Requires Quartus Lite 17.0+ and DE-10 Nano board.

## Known Issues

- None at release; see GitHub Issues for latest

## Attribution

See CREDITS.md for complete attribution.
```

### CREDITS.md Format

Every release repo includes detailed CREDITS.md:
```markdown
# Credits

## Reverse Engineering & Hardware Research
- MAME developers (taito_f3.cpp, custom chip implementations)
- [Community member names] (decap analysis, oscilloscope measurements)
- Taito hardware preservation community

## FPGA Architecture
- [Your name] — RTL design, implementation, validation
- [Collaborators] — specific contributions

## Testing & Validation
- Community TAS validation (frame-perfect testing)
- [Beta testers] — hardware testing, MRA generation

## Community Tools
- MAME Project (emulation reference)
- MiSTer Project (FPGA framework, infrastructure)
```

### Release Lifecycle

1. **Alpha (Private)**: Only in MiSTer_Pipeline, not yet public
2. **Beta (Public, v0.x)**: Create public repo, tag v0.1.0-beta, post to MiSTer forum with clear "TESTING" label
3. **Stable (v1.0+)**: After community feedback, hardware testing, fix critical issues
4. **Mature (v1.x+)**: Community-driven improvements, feature enhancements, game additions

---

## Git Configuration

### Private Repo (MiSTer_Pipeline)

```bash
# Remote URL
git remote add origin git@github.com:YOUR-ORG/MiSTer_Pipeline.git

# Branch strategy
main: stable development baseline
dev:  active work-in-progress (rebased frequently)
feature/*: per-system development branches

# Tags
v0.1.0-synthesis-ready: ready for hardware validation
v0.2.0-hardware-validated: tested on real DE-10 Nano
```

### Public Release Repo (Arcade-SystemName_MiSTer)

```bash
# Remote URL
git remote add origin git@github.com:MiSTer-devel/Arcade-TaitoF3_MiSTer.git

# Branch strategy
main: release branch (tagged, immutable history)
dev: community feature branch (optional, rebased before merge)

# Tags
v0.1.0-beta: initial beta release
v1.0.0: first stable release
v1.0.1: patch releases (critical fixes only)

# Protection rules
main branch: PR-only, automated tests must pass
```

---

## Release Criteria Checklist

Before creating a public release repo, verify:

1. ✅ **Synthesis**: Compiles cleanly in Quartus Lite
2. ✅ **Bitstream**: Produces valid .rbf file
3. ✅ **Hardware Boot**: Tested on real DE-10 Nano, boots without errors
4. ✅ **Frame Accuracy**: TAS validation shows ≥95% frame-perfect accuracy (or documented deviation)
5. ✅ **Test Coverage**: At least 50% of system test vectors pass
6. ✅ **Documentation**: README, CREDITS, hardware notes complete
7. ✅ **MRA Files**: At least 5 working game ROM launchers
8. ✅ **License**: GPL-2.0 file present, no proprietary code
9. ✅ **Gate Review**: All internal gates passed (behavioral, lint, structural)
10. ✅ **Attribution**: All sources cited (MAME, community decap, reverse-engineering docs)

See `validate_release_checklist.sh` for automation.

---

## Relationship to MiSTer-devel

### MiSTer Official Framework

The public release repos follow MiSTer-devel conventions:
- Naming: `Arcade-SystemName_MiSTer`
- License: GPL-2.0
- Location: Under `MiSTer-devel` GitHub organization (when approved)
- Maintenance: Ongoing community support

### Not a Dependency

The private `MiSTer_Pipeline` repo is NOT a dependency for public cores. Public repos are self-contained, cloneable, and buildable independently.

Private repo is for:
- Development iteration
- Shared chip/gate infrastructure
- Research archival
- Strategic planning

Public repos are for:
- User installation
- Community collaboration
- Long-term maintenance
- Stable releases

---

## Future Expansion

As the pipeline matures:

1. **Shared library**: Create `MiSTer-devel/arcade-library` for common components (frame buffers, sound, input)
   - Pins: GPL-2.0 license
   - Includes: Reusable RTL, test templates, CI/CD examples

2. **Documentation site**: Static HTML documentation site linking all public cores
   - Hosted on GitHub Pages
   - List of supported games, build instructions, known issues

3. **Binary releases**: GitHub Releases with pre-built .rbf files for each public repo
   - Automatic CI/CD generation
   - Versioned, checksummed bitstreams

---

## Summary

| Aspect | Private (MiSTer_Pipeline) | Public (Arcade-SystemName_MiSTer) |
|--------|--------------------------|----------------------------------|
| **Repo Name** | MiSTer_Pipeline | Arcade-TaitoF3_MiSTer, etc. |
| **Visibility** | Private (team only) | Public (anyone can clone) |
| **Contents** | All: RTL, research, gates, vectors, notes | Release only: RTL, quartus, MRA, docs |
| **License** | GPL-2.0 (internal) | GPL-2.0 (public) |
| **Branch Policy** | Feature branches, rebasing, history cleanup | Immutable main, tagged releases |
| **CI/CD** | Full gates, synthesis, testing | Build+test, optional binary artifacts |
| **Lifetime** | Permanent development repo | Per-system, indefinite maintenance |
| **Git History** | Complete, all experiments kept | Clean, release-only commits |

---

## Appendix: System Readiness Status

As of 2026-03-17:

| System | Status | Ready for Public? | Notes |
|--------|--------|------------------|-------|
| Taito F3 | ✅ Synthesis-ready | ~2 weeks | Hardware validation pending |
| Taito B | ✅ Synthesis-ready | ~2 weeks | Hardware validation pending |
| Taito X | ✅ Synthesis-ready | ~2 weeks | Hardware validation pending |
| Taito Z | ✅ Synthesis-ready | ~2 weeks | Hardware validation pending |
| GP9001 | 🟡 In progress | Not yet | Sprite/priority logic in progress |
| Toaplan V2 | 🟠 Research | Not yet | Architecture planning (ARCADE_TARGETS_RANKED.md) |
| Psikyo | 🟠 Research | Not yet | 4-chip graphics pipeline research |
| NMK16 | 🟠 Research | Not yet | Simplest architecture, planned Phase 2 |

---

**See also**:
- `PUBLIC_RELEASE_PLAN.md` — Timeline and announcement strategy
- `ATTRIBUTION_POLICY.md` — Detailed attribution and licensing rules
- `prepare_release.sh` — Automation for creating public repos
- `validate_release_checklist.sh` — Verification script before public release
