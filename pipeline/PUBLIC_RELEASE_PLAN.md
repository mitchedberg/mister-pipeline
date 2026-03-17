# MiSTer FPGA Arcade Pipeline — Public Release Plan

## Overview

This document outlines the phased strategy for releasing arcade cores from the private development pipeline to the public MiSTer community. The goal is to maximize quality, community feedback, and long-term maintainability while respecting existing community work and standards.

---

## Release Phases

### Phase 1: Private Development (Current)

**Timeline**: 2026-01 through 2026-03 (ongoing)

**Status**: All four Taito systems + GP9001 in active development

**Activities**:
- RTL development and iteration
- Internal gate validation (behavioral sim, lint, synthesis)
- Test vector development
- MRA file generation
- Documentation (attribution, architecture notes)
- No public visibility

**Deliverables**:
- `MiSTer_Pipeline` private repo with complete development artifacts
- ARCADE_TARGETS_RANKED.md (strategic planning)
- CLAUDE.md (development rules)
- Individual chip READMEs in `chips/[system]/`
- CI/CD workflows for automated synthesis

**Systems Ready by March 17, 2026**:
- ✅ Taito F3 — Synthesis-ready, RBF generated, MRA complete
- ✅ Taito B — Synthesis-ready, RBF generated, MRA complete
- ✅ Taito X — Synthesis-ready, RBF generated, MRA complete
- ✅ Taito Z — Synthesis-ready, RBF generated, MRA complete
- 🟡 GP9001 — Sprite/priority logic 90% complete

### Phase 2: Hardware Validation (2–4 weeks)

**Timeline**: 2026-03-20 through 2026-04-15 (estimated)

**Activities**:
- Boot cores on real DE-10 Nano boards
- Test game ROM compatibility (at least 5 games per system)
- Frame-accurate validation using TAS data (if available)
- Bug fixes and optimization (if needed)
- Community early-access testing (closed group)

**Success Criteria per System**:
- ✅ Bitstream boots without errors
- ✅ At least 5 games fully playable
- ✅ Frame-perfect or near-frame-perfect TAS validation
- ✅ Sound/video output verified on real hardware
- ✅ No CPU hangs or infinite loops
- ✅ MRA files generate correct ROM requirements

**Expected Outcomes**:
- Identify and fix any hardware-specific issues
- Gather community feedback (closed beta)
- Refine documentation (CREDITS, README, known issues)
- Confirm no critical bugs in release package

**If Issues Arise**:
- Fix in private repo, re-synthesize, re-validate
- Document known limitations in README (with fixes for v1.1)
- Delay public release if critical issues found
- If minor: note in README and proceed to Phase 3

### Phase 3: Soft Public Launch (Beta Release)

**Timeline**: 2026-04-15 through 2026-06-15 (8 weeks)

**Visibility**: Limited announcement, clear "BETA/TESTING" label

**Activities**:

1. **Create Public Repositories** (one per system)
   ```
   Arcade-TaitoF3_MiSTer
   Arcade-TaitoB_MiSTer
   Arcade-TaitoX_MiSTer
   Arcade-TaitoZ_MiSTer
   ```
   Use `prepare_release.sh` to auto-generate from private repo

2. **Initial Release Tags**
   - Tag: v0.1.0-beta
   - Message: "First public beta release — hardware validated, community testing phase"
   - Pre-built RBF available in GitHub Releases

3. **Community Announcements**

   **Venue 1: MiSTer Forum**
   ```
   Title: [BETA] Taito System Arcade Cores — TaitoF3, TaitoB, TaitoX, TaitoZ

   This is the first public release of Taito arcade cores from the MiSTer
   pipeline project. These cores are hardware-validated on DE-10 Nano
   boards but still in BETA — testing and feedback welcome.

   Supported Games (per core):
   - TaitoF3: Puzzle Bobble, Taito F3 library (18+ titles)
   - TaitoB: [list]
   - TaitoX: [list]
   - TaitoZ: [list]

   Status: ✅ Boots hardware, ✅ Most games playable, 🟡 Some edge cases

   Known Issues:
   - [List any documented issues]

   How to Help:
   1. Test games and report issues via GitHub Issues
   2. Suggest MRA files for untested games
   3. Report any hardware incompatibilities (different FPGA, etc.)

   Disclaimer:
   - This is BETA software — use at your own risk
   - No warranty of completeness or accuracy
   - Cores may change significantly before v1.0
   ```

   **Venue 2: GitHub Releases Page**
   - Pre-built .rbf files (optional, can be downloaded from Actions)
   - Changelog and release notes
   - Known issues and workarounds

   **Venue 3: (Optional) Reddit/Discord**
   - Link to forum thread, GitHub issues for discussion
   - No overstated claims

4. **Gather Community Feedback**
   - Issue tracker: bug reports, missing games, MRA issues
   - Forum: general discussion, user experience
   - Email/DM: private feedback from community testers
   - GitHub Discussions: architecture questions

5. **Address Feedback**
   - Critical bugs (hangs, crashes): fix and release v0.2.0 patch
   - Minor issues (missing MRA, game quirk): document and defer to v1.0
   - Feature requests (graphics modes, etc.): defer to v1.1+
   - Attribution requests: add to CREDITS.md with next release

**Expected Community Response**:
- ~50–200 downloads per core
- ~10–30 GitHub issues (mostly MRA requests, game-specific issues)
- ~5–10 serious bugs identified
- ~20–50 forum posts with feedback

**Release Cadence**:
- v0.1.0-beta: Initial release (April 15)
- v0.2.0: Patch release with critical fixes (May 1)
- v0.3.0: Community-integrated version (May 30)
- Ongoing patches (v0.3.1, v0.3.2, ...) as needed

### Phase 4: Stable Release (v1.0)

**Timeline**: 2026-06-15 onwards

**Milestone Criteria**:
- ✅ All critical bugs fixed
- ✅ At least 10 games per system fully validated
- ✅ Community feedback incorporated
- ✅ Documentation complete and accurate
- ✅ MRA files for all validated games
- ✅ No known hangs or crashes

**Release Process**:
1. Tag v1.0.0 with comprehensive release notes
2. Create GitHub Release with pre-built RBF
3. Post "v1.0 Stable Release" announcement on MiSTer forum
4. Update core in official MiSTer repository (if accepted)
5. Create standalone documentation website (optional, Phase 4+)

**Post-Stable Roadmap**:
- v1.1.0: Graphics enhancements (widescreen, scanlines, filters)
- v1.2.0: Additional game compatibility
- v2.0.0: Next-generation systems (Psikyo, NMK16, etc.)

---

## Announcement Strategy

### What to Say

✅ **DO SAY**:
- "Hardware-validated on DE-10 Nano"
- "Cycle-accurate emulation of [system]"
- "Based on [community decap/reverse-engineering work]"
- "Framework leverages MAME as behavioral reference"
- "Beta status — testing and community feedback welcome"
- "Community-driven improvements incorporated in updates"
- "GPL-2.0 licensed — all source code available"

### What NOT to Say

❌ **DON'T SAY**:
- "Perfect cycle-accurate emulation" (no such thing)
- "Better than MAME" (irrelevant comparison)
- "100% authentic" (can't guarantee without access to original hardware)
- "Will ever support console versions" (different hardware, out of scope)
- Anything claiming to be "official" Taito/Namco/whoever
- "Groundbreaking achievement" (it's solid engineering, not revolutionary)
- "Fixes MAME bugs" (might be compatibility differences, not bugs)
- Hype language ("amazing", "incredible", "first ever") — let the work speak

### Tone

- Professional but approachable
- Focused on technical accuracy and community contribution
- Humble: acknowledge MAME developers, hardware researchers, community
- Transparent: clearly label beta/experimental status
- Collaborative: invite feedback, don't claim perfection

### Announcement Checklist

- [ ] Write MiSTer forum post with game list, known issues, testing invitation
- [ ] Create GitHub Release with changelogs and download links
- [ ] Update CREDITS.md with all contributors
- [ ] Write README.md with installation instructions and build notes
- [ ] Document known issues in GitHub Issues (pinned)
- [ ] Prepare email to MAME developers (if using decap data) — simple thank-you
- [ ] Prepare email to Jotego (MiSTer framework lead) — brief notification
- [ ] Set up issue labels and response guidelines

---

## System-Specific Release Timeline

### Taito Systems (April 2026)

**Readiness**: All four systems hardware-validated by early April

**Release Order**: Simultaneous (all four on same date)

**Rationale**: Shared infrastructure = no incremental learning curve for second/third/fourth system

**Announcement**:
```
Four Taito arcade cores — all hardware-validated, all beta-ready.
Choose your system; all follow same development standards.
```

### Post-Taito Pipeline (May 2026+)

**Next Targets** (from ARCADE_TARGETS_RANKED.md):
1. **Toaplan V2** — 6–8 weeks (Jun–Jul 2026)
2. **NMK16** — 4–6 weeks (Jul–Sep 2026)
3. **Psikyo** — 10–12 weeks (Oct–Dec 2026)
4. **Kaneko 16** — 8–10 weeks (Dec 2026 – Jan 2027)

**Release Strategy**:
- Stagger releases: one major system per quarter
- Use lessons from Taito release to improve next rounds
- Reuse test/CI infrastructure from Taito (faster iterations)
- Community feedback on Taito drives improvements for Toaplan/NMK

---

## Community Engagement

### GitHub Issues

**Issue Categories**:
- 🐛 Bug (game doesn't boot, graphics wrong, crash)
- 🎮 Game Support (request MRA for untested game)
- 📖 Documentation (docs unclear, typo, wrong instructions)
- 🎨 Feature (graphics mode, sound option, UI)
- ❓ Question (how-to, troubleshooting, architecture)

**Response SLA**:
- Critical bugs (crash, hang): 24 hours
- Game support (missing MRA): 3 days
- Documentation: 1 week
- Features/nice-to-haves: 2 weeks or deferred to v1.1

### MiSTer Forum

**Moderation**:
- Respectful discussion welcome
- No spam, advertising, off-topic
- Keep technical discussion in GitHub Issues (easier to track)
- Provide GitHub Issues link in forum posts

**Engagement**:
- Post weekly status update during beta phase (May–Jun)
- Announce new patch versions within 24 hours
- Acknowledge major contributors in forum posts

### Direct Feedback

**Email/DM channels** (optional):
- Jotego (MiSTer lead) — brief quarterly update
- MAME developers (if using decap data) — thank-you email once per release
- Beta testers (closed group) — weekly updates during Phase 2

---

## Quality Gates Before Public Release

Before deploying to GitHub public repos, run `validate_release_checklist.sh`:

```bash
./pipeline/scripts/validate_release_checklist.sh taito_f3 verbose
```

**Must-Pass Checks**:
- ✅ RTL files present (*.sv in rtl/)
- ✅ Quartus project complete (.qsf, .sdc, .qip)
- ✅ RBF bitstream generated (quartus/output_files/)
- ✅ License file (GPL-2.0)
- ✅ Credits filled out (CREDITS.md)
- ✅ README with game list
- ✅ At least 5 MRA files

**Nice-to-Have Checks**:
- 🟡 All tests pass (vectors/Makefile)
- 🟡 Documentation complete (known issues, architecture notes)
- 🟡 Synthesis reports reviewed (no critical warnings)

---

## Special Considerations

### Attributing Decap Data

If using community oscilloscope traces or gate captures:
1. **Ask permission** — email contributor before using
2. **Credit by name** — "Joe Smith's oscilloscope measurements at IC U12" in CREDITS.md
3. **Link to source** — include URL if available (Data Crystal, Twitter thread, etc.)
4. **Thank-you email** — one sentence acknowledging contribution

### Referencing MAME

- Don't copy MAME C code directly to RTL (violates spirit of reverse-engineering)
- DO cite MAME drivers for algorithmic understanding ("Based on MAME driver analysis")
- DO credit MAME developers in CREDITS.md ("MAME project emulation reference")
- DON'T claim to be "better than MAME" — it's a different architecture (FPGA vs C)

### Jotego Coordination

MiSTer framework lead and core maintainer. Best practice:
- **No competition**: Don't build systems Jotego has announced as in-progress
- **Notification**: Send email once or twice per year with progress update
- **Openness**: If he offers advice, accept gracefully; don't ignore
- **No pressure**: He's busy; short emails only

Check `feedback_agent_delegation.md` and jotego's GitHub for announced projects before starting new systems.

---

## Known Risks & Mitigation

### Risk 1: Critical Bug Found After Release

**Scenario**: Core boots fine in Phase 2 but crashes on a specific game during Phase 3.

**Mitigation**:
- Label v0.1.0 as "testing" in release notes
- Fix in private repo, test thoroughly, release v0.2.0 within 1 week
- Public acknowledgment: "Thanks for report; fix in progress"
- Document workaround if fix delayed

### Risk 2: Community Finds Better Reverse-Engineering Data

**Scenario**: Data Crystal wiki publishes detailed schematics, contradicts assumptions.

**Mitigation**:
- Use new data for v1.1 refinements
- Update CREDITS.md with new source
- Post on forum: "Excited to learn about these schematics; will integrate in next update"
- Don't republish core immediately (let Phase 3 beta continue; integrate in final phase)

### Risk 3: Licensing Concern (GPL Compliance)

**Scenario**: Contributor claims GPL-2.0 not followed properly.

**Mitigation**:
- Ensure full source code available in public repo (rtl/ + documentation)
- Include LICENSE file in every release
- CREDITS.md cites all major sources
- GitHub repo allows forking and modification (GPL compliance)
- If concern raised: respond publicly with specific remediation

### Risk 4: IP Concerns (Taito, Namco, etc.)

**Scenario**: Taito sends cease-and-desist about using their name/trademarks.

**Mitigation**:
- Use "Taito F3 arcade system" language, not "Taito F3" as product name
- Name repo "Arcade-TaitoF3_MiSTer" (follows MiSTer convention)
- No Taito logos or trademarked art in repo
- DISCLAIMER in README: "This is a community project not affiliated with Taito Corp."
- Legal consultation (if needed): ensure compliance with fair use for reverse-engineering

---

## Success Metrics

By end of Phase 4 (v1.0 stable release, circa August 2026):

- ✅ At least 800 unique downloads per core (from GitHub)
- ✅ 50+ GitHub stars per core
- ✅ 50+ games fully validated per core
- ✅ Community contributions (MRA files, game testing) from 20+ users
- ✅ Positive feedback on MiSTer forum and Reddit
- ✅ Cited in MiSTer documentation/core list
- ✅ Zero critical bugs in final release
- ✅ Fully GPL-compliant and properly attributed

---

## Appendix: Public Repo Directory Structure

Final structure of released public repos (e.g., `Arcade-TaitoF3_MiSTer`):

```
Arcade-TaitoF3_MiSTer/
├── rtl/
│   ├── emu.sv (top-level)
│   ├── tc0180vcu.sv (custom chips)
│   └── [support modules]
├── quartus/
│   ├── emu.qpf
│   ├── emu.qsf
│   ├── emu.sdc
│   ├── files.qip
│   └── output_files/ (optional, pre-built RBF)
├── mra/
│   ├── [game1].mra
│   ├── [game2].mra
│   └── ... (10+ games)
├── LICENSE (GPL-2.0 full text)
├── CREDITS.md (contributors, MAME, decap sources)
├── README.md (game list, installation, known issues)
├── HARDWARE_NOTES.md (optional, technical architecture)
└── .gitignore
```

**Total Public Repo Size**: ~15–25 MB per core (RTL + Quartus + MRA + docs)

---

## Timeline Summary

| Phase | Period | Status | Activity | Public? |
|-------|--------|--------|----------|---------|
| 1 | 2026-01 to 2026-03-17 | ✅ DONE | RTL dev, gates, synthesis | 🔒 Private |
| 2 | 2026-03-20 to 2026-04-15 | 🟡 IN PROGRESS | Hardware validation, beta testing | 🔒 Private |
| 3 | 2026-04-15 to 2026-06-15 | 📅 UPCOMING | Beta release, community feedback | 🌍 Public Beta |
| 4 | 2026-06-15+ | 📅 UPCOMING | Stable v1.0, ongoing support | 🌍 Public Stable |

---

See also:
- `REPO_STRATEGY.md` — Complete two-tier strategy
- `ATTRIBUTION_POLICY.md` — Detailed licensing and attribution rules
- `prepare_release.sh` — Automation for creating public repos
- `validate_release_checklist.sh` — Quality gates before release
