#!/usr/bin/env python3
"""
Minimal MiSTer keyboard injector.

Runs on the MiSTer Linux side and emits synthetic keyboard events through
/dev/uinput so Codex can drive OSD actions remotely over SSH.
"""

import argparse
import ctypes
import fcntl
import os
import struct
import time


UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0x00
EV_KEY = 0x01
SYN_REPORT = 0

# Minimal keyboard set needed for MiSTer OSD navigation.
KEY_CODES = {
    "ESC": 1,
    "ENTER": 28,
    "RIGHTCTRL": 97,
    "RIGHTSHIFT": 54,
    "UP": 103,
    "LEFT": 105,
    "RIGHT": 106,
    "DOWN": 108,
    "F12": 88,
}


class TimeVal(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class InputEvent(ctypes.Structure):
    _fields_ = [
        ("time", TimeVal),
        ("type", ctypes.c_ushort),
        ("code", ctypes.c_ushort),
        ("value", ctypes.c_int),
    ]


def emit(fd, etype, code, value):
    event = InputEvent()
    now = time.time()
    event.time.tv_sec = int(now)
    event.time.tv_usec = int((now - int(now)) * 1_000_000)
    event.type = etype
    event.code = code
    event.value = value
    os.write(fd, bytes(event))


def syn(fd):
    emit(fd, EV_SYN, SYN_REPORT, 0)


def tap_key(fd, code, delay):
    emit(fd, EV_KEY, code, 1)
    syn(fd)
    time.sleep(delay)
    emit(fd, EV_KEY, code, 0)
    syn(fd)
    time.sleep(delay)


def tap_combo(fd, codes, delay):
    for code in codes:
        emit(fd, EV_KEY, code, 1)
    syn(fd)
    time.sleep(delay)
    for code in reversed(codes):
        emit(fd, EV_KEY, code, 0)
    syn(fd)
    time.sleep(delay)


def open_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in KEY_CODES.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)

    # struct uinput_user_dev:
    #   char name[80];
    #   input_id id;
    #   int ff_effects_max;
    #   int absmax[64], absmin[64], absfuzz[64], absflat[64];
    name = b"Codex MiSTer Remote"
    uidev = struct.pack(
        "80sHHHHi" + "i" * (64 * 4),
        name,
        0x03,      # BUS_USB
        0x0001,    # vendor
        0x0001,    # product
        0x0001,    # version
        0,         # ff_effects_max
        *([0] * (64 * 4)),
    )
    os.write(fd, uidev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.25)
    return fd


def parse_steps(raw_steps):
    steps = []
    for raw in raw_steps:
        step = raw.strip().upper()
        if "+" in step:
            names = [part.strip() for part in step.split("+") if part.strip()]
            codes = [KEY_CODES[name] for name in names]
            steps.append(("combo", codes))
        else:
            steps.append(("tap", KEY_CODES[step]))
    return steps


def run_steps(fd, raw_steps, delay):
    steps = parse_steps(raw_steps)
    for kind, payload in steps:
        if kind == "tap":
            tap_key(fd, payload, delay)
        else:
            tap_combo(fd, payload, delay)


def fifo_loop(fd, fifo_path, delay):
    if os.path.exists(fifo_path):
        os.unlink(fifo_path)
    os.mkfifo(fifo_path, 0o600)
    try:
        while True:
            with open(fifo_path, "r", encoding="utf-8") as fifo:
                for line in fifo:
                    line = line.strip()
                    if not line:
                        continue
                    if line.upper() == "QUIT":
                        return
                    run_steps(fd, line.split(), delay)
    finally:
        if os.path.exists(fifo_path):
            os.unlink(fifo_path)


def main():
    parser = argparse.ArgumentParser(description="Emit MiSTer keyboard input through /dev/uinput")
    parser.add_argument("steps", nargs="*", help="Keys or combos, e.g. F12 RIGHT DOWN ENTER or RIGHTCTRL+RIGHTSHIFT")
    parser.add_argument("--delay", type=float, default=0.08, help="Delay between press/release steps")
    parser.add_argument("--repeat", type=int, default=1, help="Repeat full sequence N times")
    parser.add_argument("--fifo", default=None, help="Create a persistent virtual keyboard and execute sequences read from FIFO lines")
    args = parser.parse_args()

    fd = open_uinput()
    try:
        if args.fifo:
            fifo_loop(fd, args.fifo, args.delay)
        else:
            if not args.steps:
                raise SystemExit("steps required unless --fifo is used")
            for _ in range(args.repeat):
                run_steps(fd, args.steps, args.delay)
    finally:
        time.sleep(0.1)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    main()
