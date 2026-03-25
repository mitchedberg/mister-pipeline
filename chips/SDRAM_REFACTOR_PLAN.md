# MiSTer Pipeline SDRAM Refactor Plan

## Why This Exists

Several current cores use custom per-core SDRAM glue (`sdram_b.sv`, `sdram_z.sv`, `sdram_f3.sv`)
that duplicates memory-client arbitration and low-level SDRAM protocol handling. Hardware testing
has already shown that at least part of this stack is not trustworthy on DE-10 Nano even when sim
and gate-5 results are strong.

The goal of this refactor is to replace ad hoc per-core SDRAM glue with a shared, community-grounded
memory frontend so future core bring-up reuses a known-good pattern instead of re-deriving it.

## Reference Audit

### 1. Sorgelig canonical MiSTer SDRAM controller

Primary source:
- `MiSTer-devel/NES_MiSTer/rtl/sdram.sv`

Useful takeaways:
- proven external SDRAM clock launch pattern via `altddio_out`
- simple and conservative low-level command sequencing
- community-trusted baseline for raw MiSTer SDRAM behavior

Limitations for this repo:
- exposed client interface is 3-channel and byte-oriented
- not a drop-in match for current arcade cores that want multiple ROM clients and 16-bit words

### 2. Jotego JTFRAME arcade SDRAM stack

Primary sources:
- `modules/jtframe/doc/sdram.md`
- `modules/jtframe/hdl/jtframe_board_sdram.v`
- `modules/jtframe/hdl/sdram/jtframe_rom_4slots.v`
- `modules/jtframe/hdl/sdram/jtframe_ram1_5slots.v`
- `modules/jtframe/hdl/sdram/jtframe_romrq.v`
- `cores/cps1/hdl/jtcps1_sdram.v`
- `cores/s16/hdl/jts16_sdram.v`

Useful takeaways:
- arcade-focused slot-based client model
- clean separation between game-facing memory clients and the low-level SDRAM engine
- reusable download/programming path
- explicit offsets per ROM consumer
- shared arbitration rather than per-core bespoke logic

This is the best architectural match for MiSTer arcade bring-up in this repo.

## Chosen Target Architecture

### Low-level principle

Use a community-proven low-level SDRAM engine pattern. Do not generate new SDRAM protocol logic
from scratch for each core.

### Shared repo abstraction

Create one reusable frontend that exposes ROM clients as slots:

- one writable/programming slot for ROM download
- multiple read-only slots for CPU ROM, graphics ROM, audio/sample ROMs, etc.
- per-slot offset parameter for SDRAM layout
- explicit data width per client (8/16/32 where needed)

### Per-core responsibility

Each core should only define:
- which ROM clients exist
- address widths
- offsets into SDRAM
- client priority if required

Each core should not define:
- a bespoke SDRAM FSM
- bespoke refresh scheduling
- bespoke byte-packing rules unless the board truly requires them

## Pilot Core

Pilot: `taito_b` / `nastar`

Why:
- simplest current hardware target among the failing cores
- existing sim/gate-5 quality is already good
- ROM clients are straightforward:
  - 68000 program ROM
  - TC0180VCU graphics ROM
  - ADPCM ROM
  - Z80 ROM
  - download/programming path

## Taito B Migration Strategy

### Phase 1: immediate hardware-risk cleanup

- use canonical MiSTer `altddio_out` SDRAM clock launch in `chips/taito_b/quartus/emu.sv`
- keep the rest of the current Taito B path intact long enough to get a synthesis test result

### Phase 2: true replacement

- remove dependency on `chips/taito_b/rtl/sdram_b.sv`
- introduce a new Taito-B-specific memory module with a JTFRAME-style slot frontend
- keep the low-level SDRAM controller and client/arbitration pattern community-grounded
- preserve the existing `taito_b.sv` external ROM client expectations where possible

### Phase 3: propagate

After Taito B passes hardware:
- move `nmk_arcade`, `psikyo_arcade`, `kaneko_arcade`, `toaplan_v2`, `taito_x` one at a time
- delete duplicated custom controllers instead of maintaining them in parallel

## Pilot Execution Workflow

For the pilot core, the expected proof chain is:

1. Touch only the pilot core and shared memory/refactor files.
2. Run repo-local checks relevant to the touched files.
3. Push to a synthesis-enabled branch (`sim-batch2`, `main`, or `master` per current CI filters).
4. Let GitHub run:
   - `Quartus Synthesis Gates`
   - core-specific synthesis workflow (`Taito B Synthesis`)
5. If synthesis succeeds:
   - download the `taito_b_rbf` artifact
   - deploy the new `taito_b.rbf` to MiSTer
   - preserve/update MRA files as needed
6. Confirm the behavioral side is still aligned with the existing golden workflow:
   - Taito B / Nastar gate-5 baseline is already documented in `.shared/findings.md`
   - if the memory frontend changes logical timing, re-run the Nastar golden comparison
7. Only after a clean MiSTer hardware boot should the pattern be propagated to other cores.

## Rules Going Forward

1. No new per-core SDRAM controller files unless a core has a genuinely different memory device.
2. All new arcade cores should start from the shared frontend pattern, not raw SDRAM RTL.
3. Low-level SDRAM behavior must be anchored to community references.
4. Hardware validation remains mandatory even after gate-5 success.
