# MiSTer FPGA Arcade Pipeline — Attribution Policy

## Purpose

This document defines the project's policy on attribution, licensing, and community engagement. It ensures proper credit to sources while respecting intellectual property, GPL-2.0 compliance, and "surfing etiquette" within the arcade hardware preservation community.

---

## Core Principles

1. **Transparency**: All major sources cited; no hidden dependencies or uncredited inspiration
2. **Respect**: Acknowledge MAME developers, hardware researchers, decap contributors as peers
3. **Compliance**: GPL-2.0 viral clause means derivative works must be open-source
4. **Community**: Don't duplicate efforts; check existing work before starting new systems
5. **Humility**: Our work builds on decades of community effort; we're custodians, not originators

---

## GPL-2.0 Licensing Framework

### When GPL-2.0 Applies

Every public release repo uses **GPL-2.0** because:

1. **Compatibility**: MiSTer arcade cores are GPL-2.0; we follow convention
2. **Viral Clause**: Derivative works must remain open-source (aligns with emulation community norms)
3. **Commercial Use**: Allowed with source code release (fair: encourages business participation)
4. **Community Stewardship**: Ensures improvements flow back to everyone

### What GPL-2.0 Requires

```
LICENSE file:        Must include full GPL-2.0 text
CREDITS/Attribution: All major sources cited by name
Source Code:         All RTL publicly available on GitHub
Derivative Works:    Any forked cores must remain GPL-2.0
Commercial Use:      Allowed IF you release your modified source code
```

### What GPL-2.0 Does NOT Require

- ❌ Attribution in every file header (CREDITS.md is sufficient)
- ❌ Identical architecture to original hardware (RTL design is yours)
- ❌ MAME source code embedded (you can reference/cite only)
- ❌ Permission from original hardware manufacturer (reverse-engineering is legal)
- ❌ Removal of names from code (common practice: keep original designers' names as comments)

---

## Attribution Categories

### Category 1: MAME Project (Behavioral Reference)

**Usage**: MAME drivers are reverse-engineering reference, not copied code.

**Attribution Rule**: Cite in CREDITS.md and code comments, but don't copy verbatim.

**CORRECT** ✅:
```
// TC0180VCU tile engine behavior based on MAME driver analysis:
// @see mame/src/mame/video/tc0180vcu.cpp (MAME project)
//
// Key insight: priority bits [15:14] determine layer rendering order
always_comb begin
    case (priority[15:14])
        2'b00: layer_order = {BG0, BG1, SPR, FG0};
        2'b01: layer_order = {BG1, BG0, FG0, SPR};
        // ... MAME-derived behavior, implemented in original RTL
    endcase
end
```

```markdown
## CREDITS.md
- **MAME Project** — Reference emulation for TC0180VCU custom chip behavior
  - tc0180vcu.cpp (tile engine)
  - tc0180vcu.h (register definitions)
  - [MAME authors] for 20+ years of reverse-engineering work
```

**INCORRECT** ❌:
```c
// Copy-paste from MAME:
void tc0180vcu_device::draw_bg_layer(bitmap_ind16 &bitmap, const rectangle &cliprect, int layer)
{
    // ... verbatim MAME C code in RTL comment
}
```

**Why**: MAME is C emulation; we're implementing in SystemVerilog. Citing behavior ≠ copying code.

### Category 2: Decap Data & Community Hardware Research

**Usage**: Oscilloscope captures, gate traces, IC pin measurements shared by community.

**Sourcing Requirements**:
1. ✅ Ask permission BEFORE public release
2. ✅ Attribute by contributor name and measurement detail
3. ✅ Link to original research if available (Data Crystal, blog, Twitter)
4. ✅ Thank-you email to contributor (one sentence; sincere)

**Attribution Format** ✅:

```markdown
## CREDITS.md

### Hardware Research & Decap Analysis

- **Oscilloscope Measurements** (IC timing, pin voltages)
  - Joe Smith (@username) — TC0180VCU address setup timing at IC U12 pin 5
    Measurement: 24ns clock-to-address valid delay
    Reference: [Tweet link / Data Crystal page / measurement file]

  - Jane Doe — GP9001 sprite priority logic gate trace at IC U8
    Trace: SPI clock vs RAM read strobe, 4 MHz cycle analysis
    Reference: Hardware preservation wiki, section [X]

- **Decap Analysis** (silicon die photographs)
  - [Name] — TC0150ROD pattern analysis, memory cell identification
    Contribution: Identified as 16Kx8 SRAM, confirmed address decode logic
```

**Email Template**:
```
Subject: Attribution Request — [System] Core Public Release

Hi [Name],

We're releasing a public FPGA implementation of [System] as open-source GPL-2.0.
Your oscilloscope measurements of [IC / pin / measurement] were invaluable for
understanding [behavior]. Would you be comfortable with public attribution?

We'd credit you as: "[Name] — [measurement detail]"

Let us know if you'd prefer anonymity, a link to your website, or different wording.

Thanks for the community work!
```

### Category 3: Existing FPGA Community Work

**Usage**: Adapting/extending existing open-source FPGA cores (e.g., Toaplan V1→V2).

**Attribution Rule**: Cite original author, preserve GPL-2.0, clearly mark modifications.

**Example**: Toaplan V2 from V1 (zerowing core)

✅ **CORRECT**:
```markdown
## README.md

This core is based on the **Toaplan V1 architecture** by [va7deo](https://github.com/va7deo).

**Differences from V1**:
- Extended graphics pipeline for V2 sprite handling
- Additional VRAM blending modes (registers 0x30-0x37)
- Modified priority logic for V2 game library

See DELTAS.md for detailed comparison.

Original work: https://github.com/va7deo/zerowing (GPL-2.0)
This derivative: GPL-2.0, all modifications available
```

```
git log --oneline
a1b2c3d Extend GP9001 for V2 sprite modes
d4e5f6g Preserve V1 architecture, add V2 extensions
// ... (original V1 commits still visible)
```

❌ **INCORRECT**:
```markdown
"Toaplan V2 core from scratch" (obscures V1 origin)
Deleting V1 author from blame/git history
Using V1 code without GPL-2.0 attribution
```

---

## Community Coordination ("Surfing Etiquette")

### The Rule: Don't Drop In On Active Development

**Principle**: Respect Jotego and other active FPGA developers by checking announced projects before starting new systems.

**What Jotego Has Announced** (as of 2026-03):
- Checking his GitHub: https://github.com/jotego
- His MiSTer forum posts (search "Jotego")
- Public roadmaps in jtcores repository

**IMPORTANT**: Before picking next system post-Taito, verify NO ONE is working on it.

**Example Scenario**:
```
❌ DON'T START: "I'm going to build Capcom CPS-2"
   → Jotego has jtcps2 in progress, announced 2025-11

✅ DO START: "I'm going to build NMK16"
   → Check jtcores, no announcement, none of the 122 cores mention it
   → Email Jotego: "We're planning NMK16 as next system, cool?"
   → He says "go ahead, let me know if you need advice"
   → Proceed with clear conscience

✅ DO START: "I'm going to build Toaplan V2"
   → V1 exists (zerowing), V2 is logical extension
   → No competing announcement from Jotego or others
   → Reach out to va7deo (original V1 author): "Can we extend to V2?"
   → Collaborate or proceed with proper attribution
```

### Email Template (Jotego Coordination)

```
Subject: FYI — NMK16 FPGA core development

Hi Jotego,

We're starting development on NMK16 arcade cores as the next system
in our MiSTer FPGA pipeline (after Taito systems release in April 2026).

Just wanted to check: Is this system on your roadmap? No need to commit
to anything; just making sure we're not duplicating efforts.

Thanks for all the infrastructure work on MiSTer!

Best,
[Your name]
```

**Note**: Jotego is busy. Keep email to 3 sentences max. Don't expect reply; silence = "no conflict."

### Checking for Conflicts

**Before starting ANY new system**:

1. Search jtcores repo README: https://github.com/jotego/jtcores
2. Check GitHub issues on MiSTer project
3. Search MiSTer forum for system announcements
4. Google "[System] FPGA" to find any other community work
5. Send brief email to Jotego (only if high-profile system like Capcom CPS)

**ARCADE_TARGETS_RANKED.md** is our strategic plan; update it once per quarter with any new conflicts discovered.

---

## Detailed Attribution Checklist

Before any public release, verify:

### CREDITS.md Completeness

- ✅ MAME project cited (core drivers used as reference)
- ✅ MiSTer framework acknowledged (infrastructure)
- ✅ All decap contributors named with specific measurements
- ✅ Any existing FPGA code authors cited (Toaplan V1 = va7deo, etc.)
- ✅ Hardware researchers credited (Data Crystal, hobbyists, etc.)
- ✅ Community testers/feedback contributors (optional, but nice)
- ✅ Your name + team members listed

### Code Comments

- ✅ TC0180VCU behavior traced to MAME driver (comments)
- ✅ Custom chip state machines documented with source references
- ✅ Suspicious logic explained ("Based on Data Crystal oscilloscope trace")

### README.md Disclaimers

- ✅ "Not affiliated with [original manufacturer]"
- ✅ "GPL-2.0 licensed — all source available"
- ✅ "Based on community reverse-engineering work"
- ✅ Link to CREDITS.md for detailed attribution

### GitHub Repository

- ✅ LICENSE file (full GPL-2.0 text, not truncated)
- ✅ No proprietary FPGA IP (only GPL-compatible modules)
- ✅ No vendor datasheets (reference links only, no full PDFs)
- ✅ No closed-source dependencies

---

## Special Cases

### Case 1: Using Proprietary FPGA IP (Altera/Intel IP)

**Scenario**: Quartus generates IP (e.g., altsyncram for RAM inference).

**Rule**: OK because:
- Quartus generates, compiles into bitstream (source is auto-generated)
- altsyncram is standard infrastructure, not proprietary logic
- Only RBF bitstream distributed (closed), RTL is open

**Attribution**: Document in README: "Uses Altera Quartus built-in IP cores for memory synthesis."

### Case 2: Porting MAME C to SystemVerilog

**Scenario**: Custom chip behavior is complex; MAME has detailed C implementation.

**Rule**: Reference, don't copy. Functional recreation ≠ code translation.

**CORRECT** ✅:
```systemverilog
// TC0150ROD road chip state machine
// @see mame/src/mame/video/tc0150rod.cpp
// State flow: IDLE → READ_ADDR → READ_DATA → DRAW → RENDER
// Our implementation follows MAME's state transitions while
// optimizing for pipelined FPGA architecture.

always_ff @(posedge clk) begin
    case (state)
        ST_IDLE: state <= (scroll_update) ? ST_READ_ADDR : ST_IDLE;
        ST_READ_ADDR: state <= ST_READ_DATA;
        // ... (original RTL, not MAME C translated)
    endcase
end
```

**INCORRECT** ❌:
```systemverilog
// Direct translation of MAME C to RTL
// tc0150rod_device::process_state()
// Original MAME authors: [list]
// We translated their C to SystemVerilog:

always_ff @(posedge clk) begin
    if (m_scroll_update) begin  // m_scroll_update from MAME
        m_state = STATE_READ_ADDR;  // m_state from MAME
        // etc. — looks like MAME variable names everywhere
    end
end
```

**Why**: First example cites MAME for guidance but implements original RTL. Second looks like code translation, which violates the spirit of reverse-engineering (you should understand the logic, not just translate).

### Case 3: Using Data Crystal / Hardware Preservation Wiki

**Scenario**: RAM maps, register definitions sourced from community wikis.

**Rule**: Link to source; if derivative work, attribute clearly.

**CORRECT** ✅:
```verilog
// Register definitions from Data Crystal wiki
// @see datacrystal.tcrf.net/wiki/[System]_hardware
// Register 0x200: Sprite priority control
//   Bits [7:4]: Sprite layer priority
//   Bits [3:0]: Reserved

localparam REG_SPRITE_PRI = 8'h200;  // From Data Crystal
```

```markdown
## CREDITS.md
- **Data Crystal Wiki** — Community-curated hardware documentation
  - Register mapping, address decoding, sprite chip behavior
  - Reference: https://datacrystal.tcrf.net/wiki/[System]_hardware
```

❌ **INCORRECT**: Using Data Crystal definitions without any credit or link.

### Case 4: Contributing Back to MAME

**Scenario**: Your FPGA RTL reveals a bug or missing feature in MAME emulation.

**Option A: Cite in MAME issue** ✅
```
GitHub issue on MAME:
"Our FPGA analysis of TC0180VCU shows priority bits [15:14]
behave differently than current emulation. See [our GitHub repo]
for RTL implementation. Worth a patch?"

Outcome: MAME developers learn, improve emulation, credit you.
```

**Option B: Contribute patch to MAME** ✅
```
Send pull request to MAME with test case proving corrected behavior.
MAME accepts = you're now an official MAME contributor!
(Also: updates MAME in your credits naturally.)
```

**Option C: Ignore and just use our version** 🤷
```
Fine, but less collaborative. MAME may eventually discover and fix
independently, which is OK but less elegant.
```

---

## Handling Attribution Requests & Corrections

### When Community Finds Missing Attribution

**Scenario**: "You used my oscilloscope data without credit!"

**Response Template** ✅:
```
You're absolutely right, and I apologize. Your measurement of [detail]
was crucial to understanding [behavior].

We'll add you to CREDITS.md in the next release (v0.2.0, ETA [date])
with attribution: "[Your name] — [measurement detail]"

Would you prefer a link to your website, Twitter, or just your name?
Again, thanks for the community contribution!
```

### When Contributor Requests Removal

**Scenario**: "I want to be anonymous."

**Response** ✅:
```
Absolutely. We'll update CREDITS.md to:
"Anonymous oscilloscope measurements" or
"Community contributor (requested anonymity)"

Would you prefer a specific phrase?
```

### When Competitor Claims You Stole Work

**Scenario**: "You used my Toaplan V1 code without credit!"

**Response** (if TRUE):
```
You're right. Our extended V2 implementation started from your
V1 architecture. We should have been clearer in README.md.

Updated credits now reference your work:
https://github.com/you/toaplan-v1-fpga

Thanks for the foundation; extending to V2 was much easier because
of your clean architecture.
```

**Response** (if FALSE):
```
I've reviewed your V1 core and our V2. While both target Toaplan,
our implementations diverged significantly:

- You use [architecture detail], we use [different approach]
- Register names follow MAME convention, not your naming
- Sprite pipeline organized differently

I'm happy to cite your work as inspiration, but the code is
independently developed. If you see specific similarities,
let me know and I'll credit appropriately.
```

**Escalation**: If unresolved, ask Jotego for mediation (rare, but he has authority in MiSTer community).

---

## Licensing Edge Cases

### Edge Case 1: Using GPL-2.0 Code in GPL-2.0 Project

✅ **OK**: Full compatibility. Just cite source and maintain GPL-2.0.

### Edge Case 2: Using MIT/Apache-2.0 Code in GPL-2.0 Project

✅ **OK**: MIT/Apache are compatible with GPL-2.0 (more permissive can become less permissive). Cite the original license, maintain GPL-2.0 for your work.

### Edge Case 3: Using Proprietary Code in GPL-2.0 Project

❌ **NOT OK**: Proprietary code cannot be included in GPL-2.0 repo (viral clause). Options:
- Don't use proprietary code
- Use open-source alternative
- Keep proprietary part in private repo (not released)

**Example**: "I can't release X's proprietary sprite engine, so I reimplemented it."

### Edge Case 4: Funding/Sponsorship Attribution

**Scenario**: Someone funded your development (grant, sponsor, employer).

**Attribution**: Not legally required by GPL-2.0, but ethical to acknowledge.

```markdown
## CREDITS.md

### Funding & Support
- [Company/Grant] — Funded development of Taito F3 core
- [Person] — Consulting and architectural guidance
```

---

## Attribution Policy Update Cadence

Review this policy once per year (January) to account for:
- New community standards (if any)
- Changed relationships (e.g., new core collaborators)
- Licensing clarifications from Free Software Foundation

Update when:
- GPL-2.0 is superseded (unlikely, but possible in 2030s)
- Jotego or community establishes new standards
- Legal concern arises (e.g., trademark dispute)

---

## Summary Table

| Source | Attribution Required | Format | Example |
|--------|----------------------|--------|---------|
| MAME project | ✅ Yes | Code comment + CREDITS.md | `@see mame/src/mame/video/tc0180vcu.cpp` |
| Decap data (oscilloscope) | ✅ Yes, with permission | CREDITS.md by name + measurement | `Joe Smith — TC0150ROD timing trace` |
| Data Crystal wiki | ✅ Yes | Link in code comment | `@see datacrystal.tcrf.net/wiki/...` |
| Existing FPGA code | ✅ Yes | README origin statement | `Based on va7deo's Toaplan V1 core` |
| MiSTer framework | ✅ Yes | CREDITS.md | Acknowledge Jotego/MiSTer project |
| Community feedback | 🟡 Optional | CREDITS.md / forum post | `Thanks to [testers] for validation` |
| Proprietary IP (altsyncram) | ✅ Yes | README docstring | "Uses Quartus built-in IP for memory" |
| Your own work | ✅ Yes | Author in CREDITS.md | `[Your name] — RTL design & validation` |

---

## Appendix: CREDITS.md Template

```markdown
# Credits and Attribution

## Reverse Engineering & Hardware Research

### MAME Project
The authoritative emulation reference for arcade hardware.
- **tc0180vcu.cpp** — Tile engine behavior, priority logic
- **tc0150rod.cpp** — Road rendering chip state machine
- **Custom chip register analysis** — All register definitions reverse-engineered by MAME team

See mame.org for complete list of contributors.

### Community Hardware Research
- **[Name]** — Oscilloscope measurements of TC0180VCU timing
  IC U12 pin 5 (address valid) clock-to-data delay: 24ns
  Reference: [link or description]

- **[Name]** — Gate capture analysis of GP9001 sprite priority
  Detailed state machine trace from physical oscilloscope
  Reference: [link]

- **Data Crystal Wiki** — Community documentation of register maps and hardware architecture
  https://datacrystal.tcrf.net/wiki/[System]_hardware

### Hardware Preservation
- [Any decap contributors, IC photographers, schematic digitizers]

## FPGA Implementation

- **[Your Name]** — RTL design, synthesis, and validation
- **[Collaborators]** — Code review, optimization, testing

## Testing & Validation

- **MiSTer Community** — Frame-perfect TAS validation and game testing
- **[Beta Testers]** — Hardware testing on DE-10 Nano boards
- **[Jotego]** — MiSTer framework and infrastructure

## Tools & Infrastructure

- **Quartus Lite 17.0** — Altera/Intel FPGA synthesis
- **Verilator** — Open-source SystemVerilog simulator
- **MiSTer Project** — FPGA framework, DE-10 Nano infrastructure
- **MAME Project** — Emulation reference and behavioral ground truth

## License

This work is licensed under **GNU General Public License v2.0**.

All derivative works must remain open-source under GPL-2.0.
Commercial use is permitted with source code release.

See LICENSE file for full terms.
```

---

**See also**:
- `REPO_STRATEGY.md` — Repository structure and two-tier approach
- `PUBLIC_RELEASE_PLAN.md` — Release timeline and community engagement
- `prepare_release.sh` — Automation for creating compliant public repos
