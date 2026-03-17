# Contributing to MiSTer Pipeline

We welcome contributions of all kinds: bug fixes, new chip implementations, improved test vectors, documentation, and optimization work.

## Core Principles

This project exists to preserve and improve arcade hardware through accurate FPGA implementations. Contributions should:

1. **Maintain accuracy** — RTL must match documented hardware behavior
2. **Respect licenses** — All code must be GPL-2.0 compatible or original MIT
3. **Never copy code** — Implement from scratch; use MAME/datasheets as reference only
4. **Write tests first** — Test vectors and MAME behavioral validation come before RTL merges
5. **Document your sources** — Credit MAME commits, datasheets, decaps, hardware analysis

## Contribution Types

### 1. Bug Fixes to Existing Cores

**Scope:** Errors in already-integrated chip implementations (Taito B, F3, Z, X, etc.)

**Process:**
1. Open an issue describing the bug (include game, behavior, frame where divergence occurs)
2. Create a test vector that reproduces the bug
3. Run the gate pipeline to verify your fix doesn't introduce new failures
4. Submit PR with bug description, test vector, and gate results

**Gate requirement:** Your fix must pass all gates (verilator lint, synthesis check, MAME behavioral regression).

### 2. New Chip Implementations

**Scope:** Adding support for a new arcade chip (e.g., a sprite generator, tilemap engine, sound processor not yet covered).

**Process:**

1. **Research phase**
   - Read MAME source for the chip (find `src/devices/video/`, `src/devices/sound/`, etc.)
   - Gather any decap analysis or hardware documentation
   - Understand the address map, register layout, and state machines

2. **Create chip directory**
   ```bash
   mkdir -p chips/<CHIPNAME>/vectors
   ```

3. **Write test vectors**
   - Use `test_modules/mame_lua_trace.lua` to capture MAME register/RAM behavior
   - Create at least 3 test scenarios:
     - Power-on + initialization
     - Normal operation (a few game frames)
     - Edge case (sprite wrapping, priority calculation, etc.)
   - Vectors should be in `chips/<CHIPNAME>/vectors/` as `.txt` or `.json`

4. **Generate RTL**
   - Use the template at `templates/generation_prompt.md`
   - Write a detailed prompt describing the chip's behavior
   - Run through AI generation or write from scratch
   - Ensure first line is `` `default_nettype none ``
   - Follow RTL style rules in `CLAUDE.md`

5. **Run gate pipeline**
   ```bash
   gates/run_gates.sh chips/<CHIPNAME>/<CHIPNAME>.sv chips/<CHIPNAME>/vectors
   ```
   - **Gate 1:** Verilator behavioral simulation (must match test vectors)
   - **Gate 2.5:** Verilator lint (zero warnings with `-Wall`)
   - **Gate 3a:** Yosys structural synthesis (must elaborate cleanly)
   - **Gate 3b:** Quartus mapping (compile to hardware, Linux only; macOS stubs gracefully)
   - **Gate 4:** Behavioral regression vs MAME (byte-for-byte comparison of RAM/register state)

6. **Iterate until all gates pass**
   - Gate 1 or 4 failure? Fix the RTL or the test vector
   - Gate 2.5 failure? Fix the RTL to remove lint warnings
   - Expected iteration count: 3-7 passes before clean merge
   - **Never hand-patch RTL**; if gates fail, the generation prompt or template is wrong

7. **Document the chip**
   - Create `chips/<CHIPNAME>/CORE_README.md` (see template below)
   - Include games supported, hardware accuracy notes, known limitations
   - Add credits for decaps, MAME authors, or datasheets you used

8. **Submit PR**
   - Title: "Add CHIPNAME support"
   - Include gate results in PR description
   - Attach the test vectors and CORE_README.md
   - Link to MAME commit if you reference it

### 3. Test Vector Improvements

**Scope:** Better or more comprehensive test scenarios for existing chips.

**Process:**
1. Identify a game or scenario not currently covered
2. Use `test_modules/mame_lua_trace.lua` to capture behavior
3. Submit PR with new vectors and game/scenario description
4. Run gates to verify the new vectors don't break existing tests

### 4. Documentation

**Scope:** README improvements, architecture guides, tutorials.

**Process:**
- No gate pipeline needed for docs
- Submit PR with clear, accurate information
- Link to the code or systems you're describing

## License Compliance

### For New RTL

All RTL you write must be **original code**. You may read MAME, datasheets, and decaps as reference, but the actual Verilog/SystemVerilog is yours.

- **License your RTL as MIT** (compatible with project default)
- **Include a header comment** in each `.sv` file:
  ```verilog
  `default_nettype none

  // =============================================================================
  // <CHIPNAME>.sv
  // =============================================================================
  // <Description of what the chip does>
  //
  // Hardware reference: <MAME commit, decap link, or datasheet>
  // =============================================================================
  ```

- **For complex state machines**, add comments linking your implementation to MAME:
  ```verilog
  // This state machine is based on the behavior documented in MAME's
  // src/devices/video/chip.cpp, particularly the render() function.
  // We replicate the pixel pipeline without copying code.
  ```

### For GPL-2.0 Dependencies

If you use code from GPL-2.0 sources (MAME, MiSTer sys/, etc.):

- **Do not embed it directly** in your RTL
- **Analyze and reimplement** the logic in original code
- **Always credit the source** in comments and CREDITS.md
- **Compile bitstream** will be GPL-2.0 due to sys/ dependency (this is fine; it's how all MiSTer cores work)

### Contributing Code from Other Projects

**Do not copy code from:**
- Other MiSTer cores (unless they're MIT and you have permission)
- MAME (it's GPL; you can't relicense your derivative)
- Closed-source FPGA implementations
- Community disassemblies without understanding the license

**It's fine to:**
- Read and understand MAME's algorithm, then implement it fresh
- Use fx68k, T80, TG68K (they're properly licensed for reuse)
- Contribute to community projects with permission

## Code Style

Follow the rules in `CLAUDE.md`:

- `\`default_nettype none\` on first line
- Use `always_ff`, `always_comb`, `logic` (modern SystemVerilog)
- No latches (every `case` has a `default`)
- No async reset deassertion (use section5_reset.sv synchronizer)
- No multi-driver signals
- No latch-gated clocks
- All memories via `altsyncram` with M10K targeting
- CDC crossings marked with `// CDC:` comments

**Linting:** Gate 2.5 will catch violations. Zero warnings required.

## Testing & Validation

### Test Vector Format

Store captured RAM/register state as JSON or text:

```json
{
  "frame": 100,
  "timestamp_us": 16667,
  "registers": {
    "0xFF0000": "0x1234",
    "0xFF0002": "0x5678"
  },
  "ram_pages": {
    "0x0000": [0xFF, 0xFE, 0xFD, ...]
  }
}
```

Or text format:
```
frame: 100
reg 0xFF0000 = 0x1234
reg 0xFF0002 = 0x5678
mem 0x0000 = FF FE FD ...
```

### Running Gates Locally

```bash
# Test a single chip
gates/run_gates.sh chips/taito_b/rtl/taito_b.sv chips/taito_b/vectors

# Test all chips
for chip in chips/*/rtl/*.sv; do
  gates/run_gates.sh "$chip" "$(dirname $chip)/../vectors"
done
```

**Expected results:**
- Gate 1 (sim): < 30 seconds per chip
- Gate 2.5 (lint): < 10 seconds
- Gate 3a (Yosys): < 30 seconds
- Gate 3b (Quartus): 2-5 minutes (skipped on macOS)
- Gate 4 (MAME regression): 1-10 minutes depending on vector count

### MAME Behavioral Reference

When your RTL diverges from test vectors:

1. **Check MAME source** — Is the expected behavior correct?
2. **Update vectors if wrong** — Behavioral docs can be incomplete
3. **Fix RTL if MAME is right** — Your implementation needs adjustment

**Example workflow:**
```bash
# 1. Run simulation, capture output
./gates/gate1.sh my_chip.sv my_vectors > /tmp/rtl_output.txt

# 2. Run MAME with Lua tracing
mame -window -noverifyroms -nouserui emugame.zip -script my_trace.lua

# 3. Compare byte-by-byte
diff <(grep "^mem" /tmp/rtl_output.txt) <(grep "^mem" mame_output.txt)
```

## Review & Merge

PRs are reviewed for:

1. **Correctness** — Does the code do what it claims?
2. **Compatibility** — Does it pass all gates?
3. **License** — Are sources credited and licenses respected?
4. **Documentation** — Are changes clear and well-explained?

**Turnaround:** Usually 1-2 weeks, depending on review capacity. Complex chips may take longer.

## No Coordination Required

You don't need to ask permission or "claim" a chip before starting. If two people submit PRs for the same chip:

- First to merge wins
- Second contributor should rebase and focus on improvements
- We'll help mediate conflicts

## Questions?

- **RTL style:** See `CLAUDE.md` and `templates/`
- **MAME integration:** Check existing chips in `chips/`
- **Licensing:** See LICENSE and CREDITS.md
- **Technical questions:** Open an issue or discussion

---

## Credit

When your contribution is merged, you'll be listed in:

- The commit history
- This CONTRIBUTING.md (if it's a major new chip)
- CREDITS.md (if appropriate for your contribution)
- The individual chip's CORE_README.md (for chip-specific work)

We take attribution seriously. Your work makes this project better; we make sure everyone knows who built it.

