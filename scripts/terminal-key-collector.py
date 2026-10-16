#!/usr/bin/env python3
"""Raw PTY child for terminal-key-probe.py; not a standalone command."""
import json
import os
import pathlib
import select
import sys
import termios
import time
import tty
root = pathlib.Path(sys.argv[1])
cases = json.loads((root / 'fixture.json').read_text())['cases']
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    os.write(1, b'\x1b[=0u\x1b[>4;0m\x1b[?1l')
    current = None
    for i, case in enumerate(cases):
        mode = case['mode']
        if mode != current:
            if current == 'kitty':
                os.write(1, b'\x1b[<u')
            if mode == 'kitty':
                os.write(1, b'\x1b[>1u')
            os.write(1, b'\x1b[?2004h')
            current = mode
            time.sleep(0.2)
        (root / f'ready-{i}').touch()
        output = bytearray()
        # The first event waits for Xcode's test runner to launch. Later captures
        # allow a short idle gap so repeated events can arrive as separate writes.
        deadline = time.monotonic() + (60 if i == 0 else 8)
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.15 if output else 0.1)
            if not ready:
                if output:
                    break
                continue
            output.extend(os.read(fd, 65536))
        tmp = root / f'result-{i}.tmp'
        tmp.write_text(json.dumps({'name': case['name'], 'hex': output.hex()}))
        tmp.rename(root / f'result-{i}.json')
finally:
    if current == 'kitty':
        os.write(1, b'\x1b[<u')
    os.write(1, b'\x1b[?2004l')
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
