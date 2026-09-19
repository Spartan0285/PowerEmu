#!/usr/bin/env python3
"""rmouse.py — relative-mouse control of the guest via the HMP monitor.
  home                  slam to (0,0)
  step DX DY N [ms]     N relative moves of (DX,DY), ms apart
  btn 0|1               release/press left button
Commands for one invocation go over a single monitor connection."""
import socket, sys, time
s = socket.create_connection(("127.0.0.1", 4444)); s.settimeout(0.05)
def send(c):
    s.sendall((c + "\n").encode())
    try:
        while s.recv(65536): pass
    except Exception: pass
a = sys.argv[1:]
while a:
    op = a.pop(0)
    if op == "home":
        for _ in range(30): send("mouse_move -100 -100"); time.sleep(0.01)
    elif op == "step":
        dx, dy, n = int(a.pop(0)), int(a.pop(0)), int(a.pop(0))
        ms = int(a.pop(0)) if a and a[0].isdigit() else 15
        for _ in range(n): send(f"mouse_move {dx} {dy}"); time.sleep(ms / 1000)
    elif op == "btn":
        send(f"mouse_button {a.pop(0)}"); time.sleep(0.1)
    elif op == "sleep":
        time.sleep(float(a.pop(0)))
time.sleep(0.2)
