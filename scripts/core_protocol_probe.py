#!/usr/bin/env python3
"""Probe a herdr-core (`hc`) session for the facts the Core backend plan depends on.

Run it only against an isolated session, never `default`:

    HC_SESSION=wooloo-ui-test XDG_RUNTIME_DIR=/private/tmp/hc-run \\
        python3 scripts/core_protocol_probe.py --hc /path/to/hc

It talks to the core through `hc connect` (stdio, framed mode), the same transport the
plan uses locally and over SSH. It prints one JSON report with these keys:

- hello: the plain and framed `hello` replies (features, methods, core identity).
- events: the events seen while a document and a label change.
- queries: for each terminal query a program sends, whether the core answered it, or
  forwarded it to the attached viewer. This is checked twice, with a viewer attached and
  without one.
- status: the terminal's `status` and `turn` while a program reports `working`, then
  `done`, with OSC 7501, from `terminal.get` and from `terminal.list`, whose records are
  what wooloo's Agents list reads on herdr-core.

The terminals it starts are removed at the end. Stop the core yourself afterwards
(`hc server stop`).
"""
import argparse
import json
import os
import select
import struct
import subprocess
import sys
import tempfile
import time

DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS, AUTOMATIC_INPUT = range(7)

# Queries a terminal program may send. Each is (name, bytes).
QUERIES = [
    ("DA1", "\x1b[c"),
    ("DA2", "\x1b[>c"),
    ("XTVERSION", "\x1b[>0q"),
    ("DSR cursor position", "\x1b[6n"),
    ("DSR status", "\x1b[5n"),
    ("OSC 10 foreground", "\x1b]10;?\x1b\\"),
    ("OSC 11 background", "\x1b]11;?\x1b\\"),
    ("OSC 4 palette 1", "\x1b]4;1;?\x1b\\"),
    ("DECRQM 2048 (in-band resize)", "\x1b[?2048$p"),
    ("DECRQM 2026 (synchronized output)", "\x1b[?2026$p"),
    ("kitty keyboard flags", "\x1b[?u"),
    ("kitty graphics support", "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"),
    ("XTGETTCAP TN", "\x1bP+q544e\x1b\\"),
    ("XTWINOPS 14t (text area pixels)", "\x1b[14t"),
    ("XTWINOPS 16t (cell pixels)", "\x1b[16t"),
    ("XTWINOPS 18t (text area cells)", "\x1b[18t"),
    ("DECRQSS SGR", "\x1bP$qm\x1b\\"),
    ("OSC 7501 status support", "\x1b]7501;?\x1b\\"),
]

# A program reporting its status with OSC 7501 (the Program Status Protocol), as agent CLIs
# that support it do: working, then done. Each is (state, seconds to hold it).
STATUS_STEPS = [("working", 3), ("done", 3)]

STATUS_CHILD = r'''
import json, sys, time
for state, hold in json.loads(sys.argv[1]):
    sys.stdout.write("\x1b]7501;state=%s:app=wooloo-probe\x1b\\" % state); sys.stdout.flush()
    time.sleep(hold)
time.sleep(30)
'''

CHILD = r'''
import json, os, select, sys, termios, time, tty
queries = json.loads(sys.argv[1]); out = sys.argv[2]
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
time.sleep(float(sys.argv[3]))
results = []
try:
    for name, q in queries:
        while select.select([fd], [], [], 0)[0]:
            os.read(fd, 4096)
        os.write(sys.stdout.fileno(), q.encode())
        got = b""; end = time.time() + 1.5
        while time.time() < end:
            r = select.select([fd], [], [], 0.1)[0]
            if r:
                got += os.read(fd, 4096); end = min(end, time.time() + 0.3)
        results.append({"query": name, "reply": got.decode("latin-1")})
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
with open(out, "w") as f:
    json.dump(results, f)
'''


class Connection:
    def __init__(self, hc, session):
        self.proc = subprocess.Popen(
            [hc, "connect", "--session", session],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.buf = b""
        self.next_id = 1
        self.framed = False
        self.channels = {}  # channel -> bytearray
        self.closed = {}
        self.pending = {}  # id -> reply

    def _read(self, timeout):
        r = select.select([self.proc.stdout], [], [], timeout)[0]
        if not r:
            return False
        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            raise RuntimeError("hc connect closed: " + self.proc.stderr.read().decode())
        self.buf += chunk
        return True

    def send_plain(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def read_plain(self, timeout=10):
        end = time.time() + timeout
        while b"\n" not in self.buf:
            if not self._read(max(0, end - time.time())) and time.time() > end:
                raise TimeoutError("no plain reply")
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def send_frame(self, channel, kind, payload=b""):
        self.proc.stdin.write(struct.pack("<IBI", channel, kind, len(payload)) + payload)
        self.proc.stdin.flush()

    def pump(self, timeout=0.2):
        """Read and dispatch frames for up to `timeout` seconds."""
        end = time.time() + timeout
        while True:
            while len(self.buf) >= 9:
                channel, kind, length = struct.unpack("<IBI", self.buf[:9])
                if len(self.buf) < 9 + length:
                    break
                payload, self.buf = self.buf[9:9 + length], self.buf[9 + length:]
                if channel == 0 and kind == DATA:
                    msg = json.loads(payload)
                    if "id" in msg:
                        self.pending[msg["id"]] = msg
                    else:
                        self.channels.setdefault(0, bytearray()).extend(payload + b"\n")
                elif kind == DATA:
                    self.channels.setdefault(channel, bytearray()).extend(payload)
                    self.send_frame(channel, CREDIT, struct.pack("<I", len(payload)))
                elif kind == CLOSE:
                    self.closed[channel] = payload.decode(errors="replace")
            remaining = end - time.time()
            if remaining <= 0 or not self._read(remaining):
                return

    def call(self, method, params=None, timeout=10):
        ident = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}}
        if self.framed:
            self.send_frame(0, DATA, json.dumps(msg).encode())
            end = time.time() + timeout
            while ident not in self.pending:
                if time.time() > end:
                    raise TimeoutError(method)
                self.pump(0.1)
            return self.pending.pop(ident)
        self.send_plain(msg)
        return self.read_plain(timeout)

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        self.proc.wait(timeout=10)


def events_of(conn, channel):
    raw = bytes(conn.channels.get(channel, b""))
    return [json.loads(line) for line in raw.split(b"\n") if line.strip()]


def run_query_child(conn, tmp, attach, wait_before):
    out = os.path.join(tmp, f"replies-{'viewer' if attach else 'headless'}.json")
    child = os.path.join(tmp, "child.py")
    with open(child, "w") as f:
        f.write(CHILD)
    run = conn.call("terminal.run", {
        "argv": [sys.executable, child, json.dumps(QUERIES), out, str(wait_before)],
        "cwd": tmp, "labels": {"wooloo.probe": "queries"}, "no_parent": True,
    })
    if "error" in run:
        raise RuntimeError(run)
    terminal = run["result"]["address"]
    seen = b""
    if attach:
        att = conn.call("terminal.attach", {"terminal": terminal, "cols": 100, "rows": 30})
        if "error" in att:
            raise RuntimeError(att)
        channel = att["result"]["channel"]
        end = time.time() + wait_before + 1.6 * len(QUERIES) + 3
        while time.time() < end and not os.path.exists(out):
            conn.pump(0.2)
        conn.pump(0.5)
        seen = bytes(conn.channels.get(channel, b""))
        attach_result = att["result"]
    else:
        end = time.time() + wait_before + 1.6 * len(QUERIES) + 3
        while time.time() < end and not os.path.exists(out):
            conn.pump(0.2)
        attach_result = None
    replies = json.load(open(out)) if os.path.exists(out) else []
    conn.call("terminal.kill", {"terminal": terminal})
    conn.call("terminal.rm", {"terminal": terminal})
    text = seen.decode("latin-1")
    table = []
    for (name, q), r in zip(QUERIES, replies):
        table.append({
            "query": name,
            "program_got_reply": bool(r["reply"]),
            "reply": r["reply"],
            "forwarded_to_viewer": (q in text) if attach else None,
        })
    return {"attach_result": attach_result, "terminal": terminal, "table": table}


def run_status_child(conn, tmp):
    child = os.path.join(tmp, "status.py")
    with open(child, "w") as f:
        f.write(STATUS_CHILD)
    run = conn.call("terminal.run", {
        "argv": [sys.executable, child, json.dumps(STATUS_STEPS)],
        "cwd": tmp, "labels": {"wooloo.probe": "status"}, "no_parent": True,
    })
    if "error" in run:
        raise RuntimeError(run)
    terminal = run["result"]["address"]
    seen = []
    for state, _ in STATUS_STEPS:
        # Waits for each state rather than sampling at fixed times, since the child may be
        # slow to start; a state that never arrives is recorded as what was seen last.
        end = time.time() + 15
        while True:
            got = conn.call("terminal.get", {"terminal": terminal}).get("result", {})
            if (got.get("status") or {}).get("state") == state or time.time() > end:
                break
            time.sleep(0.1)
        # wooloo reads terminals from `terminal.list`, so its record is reported too.
        listed = next((t for t in conn.call("terminal.list", {}).get("result", {}).get("terminals", [])
                       if t.get("address") == terminal), {})
        seen.append({"reported": state, "status": got.get("status"), "turn": got.get("turn"),
                     "list_status": listed.get("status"), "list_turn": listed.get("turn")})
    conn.call("terminal.kill", {"terminal": terminal})
    conn.call("terminal.rm", {"terminal": terminal})
    return {"terminal": terminal, "steps": seen}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hc", default="hc")
    ap.add_argument("--session", default=os.environ.get("HC_SESSION", "wooloo-ui-test"))
    args = ap.parse_args()
    if args.session == "default":
        sys.exit("refusing to probe the default session")
    report = {}

    plain = Connection(args.hc, args.session)
    report["hello_plain"] = plain.call("hello", {"generation": 1})
    plain.close()

    conn = Connection(args.hc, args.session)
    conn.send_plain({"jsonrpc": "2.0", "id": 0, "method": "hello",
                     "params": {"framed": True, "generation": 1}})
    report["hello_framed"] = conn.read_plain()
    conn.framed = True

    sub = conn.call("events.subscribe", {})
    report["subscribe"] = {k: v for k, v in sub.get("result", {}).items() if k != "terminals"}
    events_channel = sub.get("result", {}).get("channel")

    doc = conn.call("doc.get", {"name": "wooloo-probe"})
    version = doc.get("result", {}).get("version", 0)
    report["doc_set"] = conn.call("doc.set", {"name": "wooloo-probe", "value": {"probe": True},
                                              "version": version})
    report["doc_set_stale"] = conn.call("doc.set", {"name": "wooloo-probe", "value": {"x": 1},
                                                    "version": version})
    conn.pump(1.0)

    with tempfile.TemporaryDirectory(prefix="wooloo-core-probe-") as tmp:
        report["queries_with_viewer"] = run_query_child(conn, tmp, attach=True, wait_before=2)
        report["queries_headless"] = run_query_child(conn, tmp, attach=False, wait_before=1)
        report["status"] = run_status_child(conn, tmp)

    conn.call("doc.set", {"name": "wooloo-probe", "value": None,
                          "version": report["doc_set"].get("result", {}).get("version", 0)})
    conn.pump(1.0)
    report["events"] = [
        {k: e.get("params", {}).get(k) for k in ("seq", "type", "terminal", "data")}
        for e in events_of(conn, events_channel)
    ]
    report["closed_channels"] = conn.closed
    conn.close()
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
