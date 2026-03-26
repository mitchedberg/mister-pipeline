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
    mister_procs = list_remote_processes(args, "/media/fat/MiSTer")
    cp = ssh(
        args,
        "printf 'host=%s\n' \"$(hostname)\"; "
        "printf 'shots=%s\n' \"$(ls -1d /media/fat/screenshots 2>/dev/null)\"; "
        "printf 'uinput=%s\n' \"$(test -c /dev/uinput && echo yes || echo no)\"; "
        "printf 'mister_cmd=%s\n' \"$(test -e /dev/MiSTer_cmd && echo yes || echo no)\"",
    )
    sys.stdout.write(cp.stdout)
    if mister_procs:
        for proc in mister_procs:
            print(f"mister_pid={proc['pid']} args={proc['args']}")
    else:
        print("mister_pid=")
    return 0


def cmd_deploy(args) -> int:
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
    return 0


def screenshot_once(args, name: str) -> pathlib.Path:
    remote_dir = args.remote_dir.rstrip("/")
    ssh(args, f"mkdir -p {shquote(remote_dir)}")
    before = list_remote_pngs(args, remote_dir)
    ssh(args, f"printf '%s\\n' {shquote('screenshot ' + name)} > /dev/MiSTer_cmd", capture=False)
    remote = ""
    deadline = time.time() + max(args.delay, 1.0) + 10.0
    while time.time() < deadline:
        time.sleep(0.5)
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
        raise RuntimeError("no new screenshot found after screenshot command")
    local = args.out_dir / pathlib.Path(remote).name
    scp_from(args, remote, str(local))
    print(local)
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
    ssh(args, f"printf '%s\\n' {shquote(args.raw)} > /dev/MiSTer_cmd", capture=False)
    print(f"sent command: {args.raw}")
    return 0


def cmd_ensure_uinput(args) -> int:
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
    seq = " ".join(args.keys)
    ssh(args, f"test -p {shquote(args.fifo)} || exit 9; printf '%s\\n' {shquote(seq)} > {shquote(args.fifo)}", capture=False)
    print(f"sent keys: {seq}")
    return 0


def cmd_probe(args) -> int:
    launch_args = argparse.Namespace(**vars(args))
    cmd_launch(launch_args)
    shot_args = argparse.Namespace(**vars(args))
    shot_args.out_dir = args.out_dir
    screenshot_once(shot_args, args.name)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Remote MiSTer deploy/launch/screenshot harness")
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--user", default=DEFAULT_USER)
    p.add_argument("--password", default=DEFAULT_PASS)

    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status")
    s.set_defaults(func=cmd_status)

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
    sc.set_defaults(func=cmd_screenshot)

    b = sub.add_parser("burst")
    b.add_argument("--name", required=True)
    b.add_argument("--count", type=int, default=4)
    b.add_argument("--interval", type=float, default=1.0)
    b.add_argument("--delay", type=float, default=1.0)
    b.add_argument("--remote-dir", default="/media/fat/screenshots")
    b.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_SHOTS)
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
    pr.set_defaults(func=cmd_probe)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
