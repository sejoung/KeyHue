"""Records the bytes a Ghostty test window sends to its program (ADR 0066).

Runs as the window's only program, in raw mode, and appends every byte to the
given file. Only the runner's test keys reach this window.

    GhosttyByteLogger.py <output file> legacy|kitty

`kitty` turns on the kitty keyboard protocol (disambiguate) and bracketed paste,
as Claude Code and other full-screen programs do.
"""
import os
import sys
import tty

output, protocol = sys.argv[1], sys.argv[2]
tty.setraw(sys.stdin.fileno())
if protocol == "kitty":
    os.write(sys.stdout.fileno(), b"\x1b[>1u\x1b[?2004h")
os.write(sys.stdout.fileno(), ("KeyHue Ghostty test (" + protocol + ")\r\n").encode())
with open(output, "ab", buffering=0) as log:
    while True:
        data = os.read(sys.stdin.fileno(), 1024)
        if not data:
            break
        log.write(data)
