# MiSTer Live Feedback Harness

Purpose: collapse the hardware loop from "build -> walk to the garage -> vague symptom report"
into a repeatable remote cycle:

1. deploy candidate RBF/MRA/ROMs
2. launch the core remotely
3. capture screenshots remotely
4. send OSD/input keys remotely
5. inspect MiSTer process/file state remotely

The harness is written against MiSTer's BusyBox userspace, not a full Linux shell.
It does not assume `pgrep` or GNU `ps`, and launch commands replace older MiSTer
core processes by default so the remote loop stays single-instanced.

Script:

```bash
python3 factory/mister_live_feedback.py --host 192.168.0.106 status
```

Default credentials:
- host: `192.168.0.106`
- user: `root`
- password: `1`

Override with:
- `--host`
- `--user`
- `--password`
- or env vars `MISTER_HOST`, `MISTER_USER`, `MISTER_PASSWORD`

## Common flows

### 1. Check MiSTer reachability and current process

```bash
python3 factory/mister_live_feedback.py status
```

### 2. Deploy a candidate build

```bash
python3 factory/mister_live_feedback.py deploy \
  --core /tmp/tb_artifacts/taito_b.rbf \
  --core-dest /media/fat/_Arcade/cores/taito_b.rbf \
  --mra /tmp/tb_artifacts/nastar.mra
```

### 3. Launch a core + game

```bash
python3 factory/mister_live_feedback.py launch \
  --core /media/fat/_Arcade/cores/taito_b.rbf \
  --mra "/media/fat/_Arcade/_ Beta AI Cores/nastar.mra"
```

By default this will terminate older `/media/fat/MiSTer ...` processes first.
Use `--no-replace-existing` only if you intentionally need to preserve them.

### 4. Capture one screenshot

```bash
python3 factory/mister_live_feedback.py screenshot --name nastar_probe
```

### 5. Capture a short burst

```bash
python3 factory/mister_live_feedback.py burst --name nastar_burst --count 4 --interval 1.0
```

### 6. Ensure remote keyboard injection is available

```bash
python3 factory/mister_live_feedback.py ensure-uinput
```

Then send keys:

```bash
python3 factory/mister_live_feedback.py keys F12 DOWN ENTER
python3 factory/mister_live_feedback.py keys RIGHTCTRL+RIGHTSHIFT
```

### 7. One-command probe

Launch, wait, and capture:

```bash
python3 factory/mister_live_feedback.py probe \
  --core /media/fat/_Arcade/cores/taito_b.rbf \
  --mra "/media/fat/_Arcade/_ Beta AI Cores/nastar.mra" \
  --name nastar_probe
```

## What this harness solves

- repeated SSH/scp command re-derivation
- remote screenshot capture
- remote core launch
- remote OSD/input setup
- reproducible MiSTer-side debug loops
- BusyBox-safe process inspection and single-instance core launch

## What it does not solve yet

- generic FPGA RAM dump from arbitrary cores
- automated hardware RAM-vs-MAME compare
- turnkey JTAG/SignalTap integration

Those are the next layers. This script is the transport and control base they plug into.
