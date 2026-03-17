# Release Preparation Agent — {{TARGET_NAME}}

You are preparing the **{{TARGET_NAME}}** MiSTer arcade core for public release.
The core has passed all gate tests, synthesizes cleanly, and has been validated on real hardware.

## Target

- **System ID**: {{TARGET_ID}}
- **Games**: {{GAMES}}
- **Integration directory**: `{{INTEGRATION_DIR}}/`
- **RTL directory**: `{{RTL_DIR}}/`
- **Notes**: {{NOTES}}

## Release Checklist (must all be PASS before publishing)

Review each item and report PASS / FAIL / NEEDS_WORK:

- [ ] All gate tests pass (`make test` exits 0 in `{{TEST_DIR}}/`)
- [ ] Synthesis completes without errors on Cyclone V (see GitHub Actions run)
- [ ] At least one game boots on real DE-10 Nano (see `HARDWARE_VALIDATED` file)
- [ ] `LICENSE` file present with GPL-2.0 text
- [ ] `CREDITS.md` lists all dependencies with links
- [ ] MRA files present for all representative games
- [ ] MRA ROM filenames verified against MAME hash files
- [ ] No borrowed RTL without attribution in `CREDITS.md`
- [ ] No hand-patched RTL (all fixes went through generation template)

## Tasks

### Task 1: Write README.md

Create `{{INTEGRATION_DIR}}/README.md` with:

```markdown
# {{TARGET_NAME}} — MiSTer FPGA Core

## Supported Games
(list all games, one per line, with year and developer)

## Hardware Notes
(brief description of the original PCB — CPU, custom chips, video specs)

## Status
- Gate tests: PASS
- Synthesis: PASS (Cyclone V, Quartus 17.0)
- Hardware validation: PASS (DE-10 Nano)

## Known Issues / Limitations
(list any known divergence from original hardware behavior)

## Building from Source
(brief build instructions)

## Credits
See CREDITS.md

## License
GPL-2.0 — see LICENSE
```

### Task 2: Write CREDITS.md

Create `{{INTEGRATION_DIR}}/CREDITS.md`.

Include:
- This core's author(s)
- Any reference implementations used (e.g., va7deo/zerowing for Toaplan V1)
- MAME contributors whose research was used
- Any community members who contributed preservation work or schematic analysis
- jotego cores if any sound chips were reused
- MiSTer framework authors

Format each entry as:
```
## <Name or Project>
- **Author**: <name or GitHub handle>
- **URL**: <GitHub/MAME/archive link>
- **License**: <SPDX identifier>
- **Usage**: <one sentence: what was borrowed and how>
```

### Task 3: Verify LICENSE file

Confirm `{{INTEGRATION_DIR}}/LICENSE` exists and contains the GPL-2.0 full text.
If missing, note it as a hard blocker.

### Task 4: MRA verification

For each game in {{GAMES}}:
1. Find the MAME set name (e.g., `batsugun` for Batsugun)
2. Check `{{INTEGRATION_DIR}}/mra/<game>.mra` exists
3. Verify each `<rom>` entry's `name` attribute matches the MAME hash file
   (MAME hash files are at `mame/hash/<driver>.xml`)

Report any mismatches as FAIL — wrong ROM names will cause the core to fail to load on MiSTer.

### Task 5: Tag recommendation

Recommend a version tag. Use `v1.0.0` for the initial public release.
List the exact `git tag` command to create it:
```
git tag -a v1.0.0 -m "{{TARGET_NAME}} initial release — gates pass, hardware validated"
```

## Output Format

1. **Release checklist** — each item with PASS/FAIL/NEEDS_WORK status
2. **README.md** — complete content
3. **CREDITS.md** — complete content
4. **MRA verification table** — game, MAME set name, MRA present (Y/N), ROM names verified (Y/N)
5. **Blockers** — any FAIL items that must be resolved before the `--publish` flag is used
