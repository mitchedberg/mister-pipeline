#!/usr/bin/env python3
"""
MiSTer live feedback harness.

Purpose:
- keep the hardware loop in seconds instead of "walk to the garage"
- standardize deploy / launch / screenshot / key injection over SSH
- give the factory one repeatable control path for MiSTer hardware checks

This is intentionally transport-focused. It does not claim to solve generic RAM dumps
yet; it provides the stable remote loop the dump/debug path will plug into.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import sys
import time


DEFAULT_HOST = os.environ.get("MISTER_HOST", "192.168.0.106")
DEFAULT_USER = os.environ.get("MISTER_USER", "root")
DEFAULT_PASS = os.environ.get("MISTER_PASSWORD", "1")
DEFAULT_REMOTE_UINPUT = "/tmp/mister_uinput.py"
DEFAULT_FIFO = "/tmp/codex_keys"
DEFAULT_SHOTS = pathlib.Path(os.environ.get("MISTER_SHOTS_DIR", "/tmp/mister_shots"))
DEFAULT_REMOTE_FBGRAB = "/tmp/codex_fbgrab.png"


def get_mister_state(args) -> dict[str, object]:
    if not mister_reachable(args):
        return {
            "reachable": False,
            "host": "",
            "boot_id": "",
            "pids": [],
            "proc_count": 0,
            "primary_pid": "",
            "primary_args": "",
        }
    cmd = (
        "python3 - <<'PY'\n"
        "import json, pathlib, subprocess\n"
        "host = subprocess.run(['hostname'], capture_output=True, text=True, check=True).stdout.strip()\n"
        "boot_id = ''\n"
        "p = pathlib.Path('/proc/sys/kernel/random/boot_id')\n"
        "if p.exists():\n"
        "    try:\n"
        "        boot_id = p.read_text().strip()\n"
        "    except OSError:\n"
        "        pass\n"
        "procs = []\n"
        "cp = subprocess.run(['ps', '-o', 'pid,args'], capture_output=True, text=True, check=True)\n"
        "for line in cp.stdout.splitlines()[1:]:\n"
        "    line = line.strip()\n"
        "    if not line:\n"
        "        continue\n"
        "    parts = line.split(None, 1)\n"
        "    pid = parts[0]\n"
        "    args = parts[1] if len(parts) > 1 else ''\n"
        "    if \"python3 - <<'PY'\" in args:\n"
        "        continue\n"
        "    if '/media/fat/MiSTer' in args:\n"
        "        procs.append({'pid': pid, 'args': args})\n"
        "state = {\n"
        "    'reachable': True,\n"
        "    'host': host,\n"
        "    'boot_id': boot_id,\n"
        "    'pids': [p['pid'] for p in procs],\n"
        "    'proc_count': len(procs),\n"
        "    'primary_pid': procs[0]['pid'] if procs else '',\n"
        "    'primary_args': procs[0]['args'] if procs else '',\n"
        "}\n"
        "print(json.dumps(state))\n"
        "PY"
    )
    cp = ssh(args, cmd)
    return json.loads(cp.stdout or "{}")


def describe_health_transition(before: dict[str, object], after: dict[str, object]) -> str:
    if not before.get("reachable", False) and not after.get("reachable", False):
        return "unreachable"
    if before.get("reachable", False) and not after.get("reachable", False):
        return "ssh_lost"
    if not before.get("reachable", False) and after.get("reachable", False):
        return "ssh_restored"
    if before.get("boot_id", "") and after.get("boot_id", "") and before["boot_id"] != after["boot_id"]:
        return "rebooted"
    if int(after.get("proc_count", 0)) == 0:
        return "mister_process_missing"
    if int(after.get("proc_count", 0)) > 1:
        return "multiple_mister_processes"
    if before.get("primary_pid", "") != after.get("primary_pid", ""):
        return "mister_pid_changed"
    return "stable"


def base_ssh_cmd(host: str, user: str, password: str) -> list[str]:
    return [
        "sshpass",
        "-p",
        password,
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "PreferredAuthentications=password",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "IdentitiesOnly=yes",
        f"{user}@{host}",
    ]


def base_scp_cmd(host: str, user: str, password: str) -> list[str]:
    return [
        "sshpass",
        "-p",
        password,
        "scp",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "PreferredAuthentications=password",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "IdentitiesOnly=yes",
    ]


def run_local(cmd: list[str], capture: bool = True, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=capture, check=check)


def ssh(args, command: str, capture: bool = True, check: bool = True) -> subprocess.CompletedProcess:
    return run_local(base_ssh_cmd(args.host, args.user, args.password) + [command], capture=capture, check=check)


def scp_to(args, local_path: str, remote_path: str) -> None:
    run_local(base_scp_cmd(args.host, args.user, args.password) + [local_path, f"{args.user}@{args.host}:{remote_path}"], capture=True, check=True)


def scp_from(args, remote_path: str, local_path: str) -> None:
    pathlib.Path(local_path).parent.mkdir(parents=True, exist_ok=True)
    run_local(base_scp_cmd(args.host, args.user, args.password) + [f"{args.user}@{args.host}:{remote_path}", local_path], capture=True, check=True)


def shquote(value: str) -> str:
    return shlex.quote(value)


def mister_reachable(args) -> bool:
    try:
        ssh(args, "true", capture=True, check=True)
        return True
    except subprocess.CalledProcessError:
        return False
    except FileNotFoundError:
        raise


def ensure_reachable(args, context: str) -> None:
    if not mister_reachable(args):
        raise RuntimeError(f"MiSTer is not reachable over SSH during {context} (reboot, hang, or network loss)")


def send_mister_cmd(args, raw: str) -> None:
    ssh(
        args,
        "sh -c {cmd} >/dev/null 2>&1 </dev/null &".format(
            cmd=shquote(f"printf '%s\\n' {shquote(raw)} > /dev/MiSTer_cmd")
        ),
        capture=False,
    )


def list_remote_pngs(args, remote_dir: str) -> dict[str, float]:
    cmd = (
        "python3 - <<'PY'\n"
        "import json, os\n"
        f"root = {remote_dir!r}\n"
        "rows = []\n"
        "for base, _, files in os.walk(root):\n"
        "    for name in files:\n"
        "        if name.lower().endswith('.png'):\n"
        "            path = os.path.join(base, name)\n"
        "            try:\n"
        "                rows.append((path, os.path.getmtime(path)))\n"
        "            except OSError:\n"
        "                pass\n"
        "print(json.dumps(rows))\n"
        "PY"
    )
    cp = ssh(args, cmd)
    rows = json.loads(cp.stdout or "[]")
    return {path: float(mtime) for path, mtime in rows}


def list_remote_processes(args, needle: str) -> list[dict[str, str]]:
    cmd = (
        "python3 - <<'PY'\n"
        "import json, subprocess\n"
        f"needle = {needle!r}\n"
        "rows = []\n"
        "cp = subprocess.run(['ps', '-o', 'pid,args'], capture_output=True, text=True, check=True)\n"
        "for line in cp.stdout.splitlines()[1:]:\n"
        "    line = line.strip()\n"
        "    if not line:\n"
        "        continue\n"
        "    parts = line.split(None, 1)\n"
        "    pid = parts[0]\n"
        "    args = parts[1] if len(parts) > 1 else ''\n"
        "    if \"python3 - <<'PY'\" in args:\n"
        "        continue\n"
        "    if needle in args:\n"
        "        rows.append({'pid': pid, 'args': args})\n"
        "print(json.dumps(rows))\n"
        "PY"
    )
    cp = ssh(args, cmd)
    return json.loads(cp.stdout or "[]")


def kill_remote_processes(args, needle: str) -> None:
    procs = list_remote_processes(args, needle)
    if not procs:
        return
    pids = " ".join(shquote(proc["pid"]) for proc in procs)
    ssh(args, f"kill {pids}", capture=False)
    time.sleep(1.0)


def cmd_status(args) -> int:
    ensure_reachable(args, "status")
    state = get_mister_state(args)
    cp = ssh(
        args,
        "printf 'host=%s\n' \"$(hostname)\"; "
        "printf 'shots=%s\n' \"$(ls -1d /media/fat/screenshots 2>/dev/null)\"; "
        "printf 'uinput=%s\n' \"$(test -c /dev/uinput && echo yes || echo no)\"; "
        "printf 'mister_cmd=%s\n' \"$(test -e /dev/MiSTer_cmd && echo yes || echo no)\"",
    )
    sys.stdout.write(cp.stdout)
    print(f"boot_id={state.get('boot_id', '')}")
    print(f"mister_proc_count={state.get('proc_count', 0)}")
    if int(state.get("proc_count", 0)) > 0:
        print(f"mister_pid={state.get('primary_pid', '')} args={state.get('primary_args', '')}")
    else:
        print("mister_pid=")
    return 0


def cmd_deploy(args) -> int:
    ensure_reachable(args, "deploy")
    if args.core:
        scp_to(args, args.core, args.core_dest)
        print(f"copied core -> {args.core_dest}")
    for mra in args.mra:
        remote = f"{args.mra_dest.rstrip('/')}/{pathlib.Path(mra).name}"
        scp_to(args, mra, remote)
        print(f"copied mra -> {remote}")
    for rom in args.rom:
        remote = f"{args.rom_dest.rstrip('/')}/{pathlib.Path(rom).name}"
        scp_to(args, rom, remote)
        print(f"copied rom -> {remote}")
    return 0


def cmd_launch(args) -> int:
    ensure_reachable(args, "launch")
    before = get_mister_state(args)
    if args.replace_existing:
        kill_remote_processes(args, "/media/fat/MiSTer")
    parts = ["/media/fat/MiSTer", shquote(args.core)]
    if args.mra:
        parts.append(shquote(args.mra))
    command = "nohup " + " ".join(parts) + " >/dev/null 2>&1 </dev/null &"
    ssh(args, command)
    print(f"launched: {' '.join(parts)}")
    if args.delay > 0:
        time.sleep(args.delay)
    after = get_mister_state(args)
    verdict = describe_health_transition(before, after)
    print(
        "health: verdict={v} boot_id={b} proc_count={c} pid={p}".format(
            v=verdict,
            b=after.get("boot_id", ""),
            c=after.get("proc_count", 0),
            p=after.get("primary_pid", ""),
        )
    )
    return 0


def screenshot_once(args, name: str) -> pathlib.Path:
    ensure_reachable(args, "screenshot start")
    before_state = get_mister_state(args)
    if args.capture_mode == "fbgrab":
        remote = args.remote_fbgrab
        ssh(args, f"fbgrab {shquote(remote)} >/dev/null 2>&1 && ls -l {shquote(remote)}")
    if not remote:
        remote_dir = args.remote_dir.rstrip("/")
        ssh(args, f"mkdir -p {shquote(remote_dir)}")
        before = list_remote_pngs(args, remote_dir)
        send_mister_cmd(args, "screenshot " + name)
        remote = ""
        deadline = time.time() + max(args.delay, 1.0) + 10.0
        while time.time() < deadline:
            time.sleep(0.5)
            if not mister_reachable(args):
                raise RuntimeError("MiSTer became unreachable while waiting for screenshot output")
            after = list_remote_pngs(args, remote_dir)
            changed = []
            for path, mtime in after.items():
                if path not in before or mtime > before[path]:
                    changed.append((mtime, path))
            if changed:
                changed.sort()
                remote = changed[-1][1]
                break
        if not remote:
            after_state = get_mister_state(args)
            verdict = describe_health_transition(before_state, after_state)
            if after_state.get("reachable", False):
                raise RuntimeError(
                    "no new screenshot found; health verdict={v} boot_id={b} proc_count={c} pid={p}".format(
                        v=verdict,
                        b=after_state.get("boot_id", ""),
                        c=after_state.get("proc_count", 0),
                        p=after_state.get("primary_pid", ""),
                    )
                )
            raise RuntimeError("no new screenshot found after screenshot command; MiSTer is unreachable")
    local = args.out_dir / pathlib.Path(remote).name
    scp_from(args, remote, str(local))
    print(local)
    after_state = get_mister_state(args)
    verdict = describe_health_transition(before_state, after_state)
    print(
        "health: verdict={v} boot_id={b} proc_count={c} pid={p}".format(
            v=verdict,
            b=after_state.get("boot_id", ""),
            c=after_state.get("proc_count", 0),
            p=after_state.get("primary_pid", ""),
        )
    )
    return local


def cmd_screenshot(args) -> int:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    screenshot_once(args, args.name)
    return 0


def cmd_burst(args) -> int:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for idx in range(1, args.count + 1):
        screenshot_once(args, f"{args.name}_{idx}")
        if idx != args.count:
            time.sleep(args.interval)
    return 0


def cmd_cmd(args) -> int:
    ensure_reachable(args, "raw command send")
    send_mister_cmd(args, args.raw)
    print(f"sent command: {args.raw}")
    return 0


def cmd_ensure_uinput(args) -> int:
    ensure_reachable(args, "uinput setup")
    local_script = pathlib.Path(__file__).with_name("mister_uinput.py")
    scp_to(args, str(local_script), args.remote_script)
    ssh(args, f"chmod +x {shquote(args.remote_script)}")
    needle = f"mister_uinput.py --fifo {args.fifo}"
    if not list_remote_processes(args, needle):
        ssh(
            args,
            "nohup python3 {script} --fifo {fifo} --delay {delay} >/tmp/mister_uinput.log 2>&1 </dev/null &".format(
                fifo=shquote(args.fifo),
                script=shquote(args.remote_script),
                delay=args.key_delay,
            ),
            capture=False,
        )
    print(f"uinput helper ready via fifo {args.fifo}")
    return 0


def cmd_keys(args) -> int:
    ensure_reachable(args, "key injection")
    seq = " ".join(args.keys)
    ssh(args, f"test -p {shquote(args.fifo)} || exit 9; printf '%s\\n' {shquote(seq)} > {shquote(args.fifo)}", capture=False)
    print(f"sent keys: {seq}")
    return 0


def cmd_probe(args) -> int:
    launch_args = argparse.Namespace(**vars(args))
    if not hasattr(launch_args, "replace_existing"):
        launch_args.replace_existing = True
    cmd_launch(launch_args)
    shot_args = argparse.Namespace(**vars(args))
    shot_args.out_dir = args.out_dir
    screenshot_once(shot_args, args.name)
    return 0


def cmd_alive(args) -> int:
    if mister_reachable(args):
        print("alive=yes")
        return 0
    print("alive=no")
    return 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Remote MiSTer deploy/launch/screenshot harness")
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--user", default=DEFAULT_USER)
    p.add_argument("--password", default=DEFAULT_PASS)

    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status")
    s.set_defaults(func=cmd_status)

    a = sub.add_parser("alive")
    a.set_defaults(func=cmd_alive)

    d = sub.add_parser("deploy")
    d.add_argument("--core")
    d.add_argument("--core-dest", default="/media/fat/_Arcade/cores/taito_b.rbf")
    d.add_argument("--mra", action="append", default=[])
    d.add_argument("--mra-dest", default="/media/fat/_Arcade/_ Beta AI Cores")
    d.add_argument("--rom", action="append", default=[])
    d.add_argument("--rom-dest", default="/media/fat/games/mame")
    d.set_defaults(func=cmd_deploy)

    l = sub.add_parser("launch")
    l.add_argument("--core", required=True, help="Remote core path on MiSTer")
    l.add_argument("--mra", help="Remote MRA path on MiSTer")
    l.add_argument("--delay", type=float, default=2.0)
    l.add_argument("--replace-existing", action=argparse.BooleanOptionalAction, default=True)
    l.set_defaults(func=cmd_launch)

    sc = sub.add_parser("screenshot")
    sc.add_argument("--name", required=True)
    sc.add_argument("--delay", type=float, default=1.0)
    sc.add_argument("--remote-dir", default="/media/fat/screenshots")
    sc.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_SHOTS)
    sc.add_argument("--capture-mode", choices=["mister", "fbgrab"], default="mister")
    sc.add_argument("--remote-fbgrab", default=DEFAULT_REMOTE_FBGRAB)
    sc.set_defaults(func=cmd_screenshot)

    b = sub.add_parser("burst")
    b.add_argument("--name", required=True)
    b.add_argument("--count", type=int, default=4)
    b.add_argument("--interval", type=float, default=1.0)
    b.add_argument("--delay", type=float, default=1.0)
    b.add_argument("--remote-dir", default="/media/fat/screenshots")
    b.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_SHOTS)
    b.add_argument("--capture-mode", choices=["mister", "fbgrab"], default="mister")
    b.add_argument("--remote-fbgrab", default=DEFAULT_REMOTE_FBGRAB)
    b.set_defaults(func=cmd_burst)

    c = sub.add_parser("cmd")
    c.add_argument("raw", help="Raw /dev/MiSTer_cmd line")
    c.set_defaults(func=cmd_cmd)

    eu = sub.add_parser("ensure-uinput")
    eu.add_argument("--remote-script", default=DEFAULT_REMOTE_UINPUT)
    eu.add_argument("--fifo", default=DEFAULT_FIFO)
    eu.add_argument("--key-delay", type=float, default=0.12)
    eu.set_defaults(func=cmd_ensure_uinput)

    k = sub.add_parser("keys")
    k.add_argument("keys", nargs="+", help="Keys/combos, e.g. F12 DOWN ENTER or RIGHTCTRL+RIGHTSHIFT")
    k.add_argument("--fifo", default=DEFAULT_FIFO)
    k.set_defaults(func=cmd_keys)

    pr = sub.add_parser("probe")
    pr.add_argument("--core", required=True)
    pr.add_argument("--mra")
    pr.add_argument("--name", required=True)
    pr.add_argument("--delay", type=float, default=2.0)
    pr.add_argument("--remote-dir", default="/media/fat/screenshots")
    pr.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_SHOTS)
    pr.add_argument("--capture-mode", choices=["mister", "fbgrab"], default="mister")
    pr.add_argument("--remote-fbgrab", default=DEFAULT_REMOTE_FBGRAB)
    pr.set_defaults(func=cmd_probe)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
