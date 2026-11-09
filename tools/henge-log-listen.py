#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Listen for Henge's log stream and write it to a file.

Henge sends every line it logs over TCP to a computer on the same network
(Settings > Log stream). Run this on that computer first:

    python3 tools/henge-log-listen.py

It prints the addresses to type into Henge, then prints each line as it arrives
and appends it to henge-stream.log. Performance marks (the flag in the session's
controls) are highlighted, and the lines after one say what the engine and the
GPU did over that window.

Ctrl-C stops it. Nothing is sent back, and the file is plain text in the same
format as Documents/henge.log on the device.
"""

from __future__ import annotations

import argparse
import datetime as dt
import socket
import sys
import threading
import time

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
MARK = "\033[1;36m"      # a performance mark's own lines
ENGINE = "\033[0;33m"    # the engine's detailed stats lines
BAD = "\033[1;31m"


def local_addresses() -> list[str]:
    """The addresses this computer can be reached on, best guess first."""
    found: list[str] = []
    try:
        # No packet is sent: this only asks the routing table which address would be used.
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.0.2.1", 9))
            found.append(probe.getsockname()[0])
        finally:
            probe.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(info[4][0])
    except OSError:
        pass
    unique = []
    for address in found:
        if address and not address.startswith("127.") and address not in unique:
            unique.append(address)
    return unique


def stamp() -> str:
    now = dt.datetime.now()
    return now.strftime("%H:%M:%S.") + f"{now.microsecond // 1000:03d}"


# Lines iOS repeats that say nothing about Henge. Dropped from the file and the screen; the
# count is reported when the connection ends, so a filter that is hiding too much shows up.
NOISE = (
    "This app is not allowed to query for scheme",
)


def is_noise(line: str) -> bool:
    return any(pattern.lower() in line.lower() for pattern in NOISE)


def colour_for(line: str) -> str:
    if "[mark]" in line:
        return MARK
    if line.startswith("stats ") or line.startswith("  "):
        return ENGINE
    if "FATAL SIGNAL" in line or "[crash]" in line:
        return BAD
    return ""


def serve_connection(conn: socket.socket, peer: str, out, args, lock: threading.Lock) -> None:
    with conn:
        conn.settimeout(None)
        reader = conn.makefile("rb")
        filtered = 0

        def note(text: str) -> None:
            with lock:
                out.write(text + "\n")
                out.flush()
                if not args.quiet:
                    print(f"{DIM}{text}{RESET}", flush=True)

        note(f"---- connected: {peer} at {dt.datetime.now().isoformat(timespec='seconds')} ----")
        try:
            for raw in reader:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if not args.no_filter and is_noise(line):
                    filtered += 1
                    continue
                with lock:
                    out.write(line + "\n")
                    out.flush()
                if args.quiet:
                    continue
                colour = colour_for(line)
                prefix = f"{DIM}{stamp()}{RESET} " if args.stamp_console else ""
                print(f"{prefix}{colour}{line}{RESET}" if colour else f"{prefix}{line}", flush=True)
        except (ConnectionError, OSError) as error:
            note(f"---- {peer} went away: {error} ----")
        finally:
            if filtered:
                note(f"---- {filtered} lines filtered as noise ----")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Receive Henge's log over the network and write it to a file.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--port", type=int, default=7777, help="TCP port to listen on")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--out", default="henge-stream.log", help="file to append the log to")
    parser.add_argument("--quiet", action="store_true", help="write the file only, print nothing")
    parser.add_argument("--no-stamp", dest="stamp_console", action="store_false",
                        help="print lines without a local time in front (a time is shown by default)")
    parser.add_argument("--no-filter", dest="no_filter", action="store_true",
                        help="keep the lines the filter drops (" + "; ".join(f'"{n}"' for n in NOISE) + ")")
    args = parser.parse_args()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((args.bind, args.port))
    except OSError as error:
        print(f"cannot listen on {args.bind}:{args.port}: {error}", file=sys.stderr)
        return 1
    listener.listen(4)

    out = open(args.out, "a", encoding="utf-8")
    lock = threading.Lock()

    if not args.quiet:
        print(f"{BOLD}Henge log stream{RESET} on port {args.port}, appending to {args.out}")
        addresses = local_addresses()
        if addresses:
            print("Type one of these into Henge, Settings > Log stream:")
            for address in addresses:
                print(f"  {BOLD}{address}{RESET}   port {args.port}")
        else:
            print("Could not work out this computer's address; use its IP from System Settings.")
        print(f"{DIM}Ctrl-C stops it.{RESET}", flush=True)

    try:
        while True:
            conn, peer = listener.accept()
            peer_name = f"{peer[0]}:{peer[1]}"
            threading.Thread(target=serve_connection, args=(conn, peer_name, out, args, lock),
                             daemon=True).start()
    except KeyboardInterrupt:
        if not args.quiet:
            print("\nstopped")
    finally:
        listener.close()
        out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
