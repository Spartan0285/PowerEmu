#!/usr/bin/env python3
"""
Type text into the QEMU guest as keystrokes — a stand-in for clipboard sharing.

Real clipboard sharing needs a guest agent (spice-vdagent), and none exists
for Mac OS X Tiger on PowerPC. This instead drives QEMU's HMP monitor with
`sendkey`, one keystroke at a time, so whatever app is frontmost in the guest
receives the text as if it were typed.

Usage:
    python3 paste-to-guest.py              # types the macOS clipboard
    python3 paste-to-guest.py "some text"  # types the given text
    python3 paste-to-guest.py --dry-run    # prints the keystrokes, sends nothing
    python3 paste-to-guest.py --run "cmd"  # types it AND presses Return

Before running: click into the guest window you want the text to go to
(e.g. a Terminal prompt). The QEMU window itself does not need focus — keys
are injected through the monitor, not the host keyboard.

Assumes a US keyboard layout in the guest, which is Tiger's default.
"""

import socket
import subprocess
import sys
import time

MONITOR = ("127.0.0.1", 4444)

# How long QEMU holds each key down, and the gap between keystrokes. Under
# TCG the guest polls the USB keyboard slowly; sending faster than it drains
# the HID queue drops characters.
HOLD_MS = 30
GAP_S = 0.06

UNSHIFTED = {
    " ": "spc", "\n": "ret", "\t": "tab",
    "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    ",": "comma", ".": "dot", "/": "slash",
}

SHIFTED = {
    "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right",
    "|": "backslash", ":": "semicolon", '"': "apostrophe", "~": "grave_accent",
    "<": "comma", ">": "dot", "?": "slash",
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
}


def keycombo(ch):
    """Return the sendkey combo for one character, or None if untypeable."""
    if "a" <= ch <= "z" or "0" <= ch <= "9":
        return ch
    if "A" <= ch <= "Z":
        return "shift-" + ch.lower()
    if ch in UNSHIFTED:
        return UNSHIFTED[ch]
    if ch in SHIFTED:
        return "shift-" + SHIFTED[ch]
    return None


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    run = "--run" in args
    args = [a for a in args if a not in ("--dry-run", "--run")]

    if args:
        text = " ".join(args)
    else:
        text = subprocess.run(["pbpaste"], capture_output=True,
                              text=True).stdout

    # Normalise line endings, and drop a single trailing newline so pasting a
    # command does not also run it — the user presses Return themselves.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if text.endswith("\n"):
        text = text[:-1]

    if not text:
        sys.exit("Nothing to type: clipboard is empty.")

    combos = []
    skipped = []
    for ch in text:
        k = keycombo(ch)
        if k is None:
            skipped.append(ch)
        else:
            combos.append(k)

    if run:
        combos.append("ret")   # --run: press Return after typing

    if skipped:
        uniq = "".join(sorted(set(skipped)))
        print(f"Warning: skipping {len(skipped)} untypeable character(s): {uniq!r}",
              file=sys.stderr)

    if dry_run:
        print(" ".join(combos))
        return

    try:
        sock = socket.create_connection(MONITOR, timeout=5)
    except OSError as e:
        sys.exit(f"Cannot reach the QEMU monitor at {MONITOR[0]}:{MONITOR[1]} "
                 f"({e}). Is the VM running?")

    sock.settimeout(0.2)

    def drain():
        try:
            while sock.recv(4096):
                pass
        except (socket.timeout, BlockingIOError):
            pass

    drain()  # discard the monitor banner

    # The first keystrokes after connecting can be lost before the guest's
    # USB keyboard is ready — observed as a command arriving with its first
    # two characters missing ("ep" for "grep"). Settle, then prime the
    # keyboard with a lone Shift press, which types nothing.
    time.sleep(0.4)
    sock.sendall(f"sendkey shift {HOLD_MS}\n".encode())
    time.sleep(0.3)
    drain()
    print(f"Typing {len(combos)} keystrokes into the guest "
          f"(~{len(combos) * GAP_S:.0f}s) ...", file=sys.stderr)
    for k in combos:
        sock.sendall(f"sendkey {k} {HOLD_MS}\n".encode())
        time.sleep(GAP_S)
        drain()
    sock.close()
    print("Done.", file=sys.stderr)


if __name__ == "__main__":
    main()
