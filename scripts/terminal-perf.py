#!/usr/bin/env python3
"""Reports for the terminal pipeline measurements.

  terminal-perf.py workloads DIR
      Writes the output files the end-to-end run plays into a pane, Kitty images included.
  terminal-perf.py play FILE [--lines-per-second N | --chars-per-second N] [--seconds S]
      Writes FILE to stdout at a steady pace, like a build log or an agent typing.
  terminal-perf.py bench RESULTS.jsonl [--baseline OLD.jsonl]
      Tabulates WOOLOO-BENCH lines from TerminalPipelineBenchmarks.
  terminal-perf.py files RESULTS.jsonl [--baseline OLD.jsonl]
      Tabulates WorkspaceFilesBenchmarks results: time and processes per operation.
  terminal-perf.py e2e METRICS.jsonl PHASES.jsonl [--baseline OLD.json] [--json OUT.json]
      Summarizes a live run recorded with WOOLOO_METRICS_FILE, one row per workload phase.
"""
import argparse
import bisect
import json
import random
import sys
from pathlib import Path


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * p))]


def fmt(value, digits=2):
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def change(new, old, lower_is_better=True):
    if new is None or old in (None, 0) or new == 0:
        return ""
    ratio = old / new if lower_is_better else new / old
    return f" ({ratio:.2f}×)"


def table(headers, rows):
    widths = [max(len(str(h)), *(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    line = "  ".join(str(h).rjust(w) if i else str(h).ljust(w) for i, (h, w) in enumerate(zip(headers, widths)))
    print(line)
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(str(c).rjust(w) if i else str(c).ljust(w) for i, (c, w) in enumerate(zip(row, widths))))


# Workloads -----------------------------------------------------------------------------

WORDS = ("build compile link warning error func struct let var herdr pane surface render glyph "
         "cell cursor patch frame layout draw metal atlas swift zig ghostty 0x7f3a 42 true nil").split()


def write_workloads(directory):
    rng = random.Random(7)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / "ascii.txt", "w") as out:
        for index in range(60000):
            words = " ".join(rng.choice(WORDS) for _ in range(rng.randint(3, 22)))
            out.write(f"[{index:06d}] {words}\n")
    with open(directory / "color.txt", "w") as out:
        levels = [("ERROR", "1;31"), ("WARN ", "33"), ("INFO ", "32"), ("DEBUG", "34"), ("TRACE", "35")]
        for index in range(20000):
            tag, sgr = rng.choice(levels)
            words = " ".join(
                f"\x1b[38;5;{rng.randint(16, 231)}m{w}\x1b[0m" if rng.random() < 0.3 else w
                for w in (rng.choice(WORDS) for _ in range(rng.randint(3, 14))))
            highlight = "\x1b[41m" if tag == "ERROR" else ""
            out.write(f"{highlight}\x1b[38;5;244m{index // 3600 % 24:02d}:{index // 60 % 60:02d}:{index % 60:02d}\x1b[39m "
                      f"\x1b[{sgr}m{tag}\x1b[22;39m \x1b[4;38;2;137;180;250msrc/module{rng.randint(0, 40)}/file"
                      f"{rng.randint(0, 200)}.swift:{rng.randint(1, 900)}\x1b[24;39m {words}\x1b[K\x1b[0m\n")
    with open(directory / "unicode.txt", "w") as out:
        fragments = ["│   ├── ", "└── ", "─────", "→ ", "✓ ", "✗ ", " ", " ", "é", "ñ",
                     "漢字", "テスト", "한글", "🚀", "✅", "📦"]
        for index in range(15000):
            parts = [rng.choice(fragments) if rng.random() < 0.6 else rng.choice(WORDS) + " "
                     for _ in range(rng.randint(3, 16))]
            out.write(f"\x1b[33m{index:05d}\x1b[0m {''.join(parts)}\n")
    write_graphics(directory, rng)


def png(width, height, pixel):
    """A minimal RGB PNG; `pixel(x, y)` gives each pixel's (r, g, b)."""
    import struct
    import zlib
    rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def kitty_image(data, cols, rows):
    """Kitty graphics escapes that transmit and show a PNG over `cols`x`rows` cells, in 4 KB
    chunks, with every reply suppressed (q=2) so nothing is written back to the program."""
    import base64
    encoded = base64.standard_b64encode(data).decode()
    chunks = [encoded[i:i + 4096] for i in range(0, len(encoded), 4096)]
    out = []
    for index, chunk in enumerate(chunks):
        more = 1 if index + 1 < len(chunks) else 0
        keys = f"a=T,f=100,c={cols},r={rows},q=2,m={more}" if index == 0 else f"q=2,m={more}"
        out.append(f"\x1b_G{keys};{chunk}\x1b\\")
    return "".join(out)


def write_graphics(directory, rng):
    """A log with a different 192x96 picture every 10 lines, shown over 24x4 cells, like a
    notebook or an agent printing plots between output."""
    with open(directory / "graphics.txt", "w") as out:
        for index in range(3000):
            if index % 10 == 9:
                hue = index * 37 % 256
                noise = [rng.randrange(64) for _ in range(192)]
                data = png(192, 96, lambda x, y: ((x + hue) % 256, (y * 2 + hue) % 256, (noise[x] + y + hue) % 256))
                out.write(kitty_image(data, 24, 4) + "\n")
            else:
                words = " ".join(rng.choice(WORDS) for _ in range(rng.randint(3, 14)))
                out.write(f"[{index:06d}] {words}\n")


def play(path, lines_per_second, chars_per_second, seconds):
    import time
    text = Path(path).read_text()
    out = sys.stdout
    deadline = time.monotonic() + seconds
    if chars_per_second:
        units, interval = list(text), 1 / chars_per_second
    else:
        units, interval = text.splitlines(keepends=True), 1 / lines_per_second
    next_at = time.monotonic()
    for unit in units:
        if time.monotonic() >= deadline:
            break
        out.write(unit)
        out.flush()
        next_at += interval
        time.sleep(max(0, next_at - time.monotonic()))
    out.write("\x1b[0m\n")


# Benchmarks ------------------------------------------------------------------------------

def read_bench(path):
    config, results = {}, {}
    for line in Path(path).read_text().splitlines():
        line = line.split("WOOLOO-BENCH ", 1)[-1].strip()
        if not line.startswith("{"):
            continue
        record = json.loads(line)
        if "scenario" in record:
            results[(record["scenario"], record["stage"])] = record
        else:
            config.update(record.get("config", record))
    return config, results


def bench_report(path, baseline_path):
    config, results = read_bench(path)
    base = read_bench(baseline_path)[1] if baseline_path else {}
    print(f"Benchmark {path}  config: {json.dumps(config)}")
    if baseline_path:
        print(f"Baseline  {baseline_path}  (n× = speedup vs baseline)")
    scenarios = sorted({s for s, _ in results})
    rows = []
    for scenario in scenarios:
        row = [scenario]
        for stage in ("decode", "layout", "layout-cold", "layout-seen", "draw", "burst"):
            record = results.get((scenario, stage), {})
            old = base.get((scenario, stage), {})
            row.append(fmt(record.get("p50_us"), 1) + change(record.get("p50_us"), old.get("p50_us")))
            row.append(fmt(record.get("p95_us"), 1))
        burst = results.get((scenario, "burst"), {})
        row.append(fmt(burst.get("fps"), 0) + change(burst.get("fps"), base.get((scenario, "burst"), {}).get("fps"), False))
        rows.append(row)
    table(["scenario", "decode p50 µs", "p95", "layout p50 µs", "p95", "cold layout p50 µs", "p95", "seen layout p50 µs", "p95", "draw p50 µs", "p95",
           "frame p50 µs", "p95", "burst fps"], rows)


# Workspace ------------------------------------------------------------------------------

def read_files(path):
    config, results = {}, {}
    for line in Path(path).read_text().splitlines():
        if not line.startswith("{"):
            continue
        record = json.loads(line)
        if "op" in record:
            results[(record["target"], record["repo"], record["op"])] = record
        else:
            config.update(record.get("config", record))
    return config, results


def files_report(path, baseline_path):
    config, results = read_files(path)
    base = read_files(baseline_path)[1] if baseline_path else {}
    print(f"Workspace benchmark {path}  config: {json.dumps(config)}")
    if baseline_path:
        print(f"Baseline {baseline_path}  (n× = speedup vs baseline)")
    rows = []
    for key in sorted(results, key=lambda k: (k[0], k[1] != "small", k[2])):
        record, old = results[key], base.get(key, {})
        labels = ", ".join(f"{k}×{v}" if v > 1 else k for k, v in record.get("by_label", {}).items())
        rows.append([f"{key[0]} {key[1]}", key[2],
                     fmt(record["p50_ms"]) + change(record["p50_ms"], old.get("p50_ms")),
                     fmt(record["p95_ms"]),
                     str(record["procs"]) + (f" (was {old['procs']})" if old and old.get("procs") != record["procs"] else ""),
                     fmt(record.get("proc_ms")), f"{record.get('bytes', 0) / 1000:.0f} KB", labels])
    table(["where", "operation", "p50 ms", "p95 ms", "procs", "proc ms", "output", "processes"], rows)


# End-to-end ------------------------------------------------------------------------------

class Screen:
    """Estimates when a draw reaches the screen. AppKit commits the drawn layer when the main
    thread's turn ends (the first `commit` event after the draw); the window server composites the
    commit at the next display refresh and shows it at the refresh after that (`target` of the
    `vsync` that follows the commit). Refreshes the display link missed while the main thread was
    busy are extrapolated from the refresh period, so the estimate is good to about one refresh."""

    def __init__(self, events):
        self.commits = sorted(e["t"] for e in events if e["e"] == "commit")
        vsyncs = sorted((e["t"], e["target"]) for e in events if e["e"] == "vsync")
        self.vsyncs = [t for t, _ in vsyncs]
        periods = [target - t for t, target in vsyncs if target > t]
        self.period = sorted(periods)[len(periods) // 2] if periods else None

    def __bool__(self):
        return bool(self.commits) and bool(self.vsyncs) and bool(self.period)

    def at(self, drawn_t):
        """Estimated time the draw that ended at `drawn_t` appears, or None."""
        if not self:
            return None
        index = bisect.bisect_left(self.commits, drawn_t)
        if index == len(self.commits):
            return None
        commit = self.commits[index]
        index = bisect.bisect_right(self.vsyncs, commit) - 1
        if index < 0:
            return None
        last = self.vsyncs[index]
        refreshes = -(-(commit - last) // self.period)  # the first refresh at or after the commit
        return last + (refreshes + 1) * self.period


def e2e_summary(metrics_path, phases_path):
    events = [json.loads(line) for line in Path(metrics_path).read_text().splitlines() if line.strip()]
    start = next(e for e in events if e["e"] == "start")
    phases = [json.loads(line) for line in Path(phases_path).read_text().splitlines() if line.strip()]
    ns = lambda wall_ms: (wall_ms - start["wall_ms"]) * 1_000_000
    screen = Screen(events)
    received = {}
    for event in events:
        if event["e"] == "recv":
            received.setdefault((event["boot"], event["proj"], event["rev"]), event)
    summaries = []
    for phase in phases:
        lo, hi = ns(phase["start_ms"]), ns(phase["end_ms"])
        seconds = max(1e-9, (hi - lo) / 1e9)
        inside = [e for e in events if e["e"] != "start" and lo <= e["t"] <= hi]
        recv = [e for e in inside if e["e"] == "recv"]
        delivers = [e for e in inside if e["e"] == "deliver"]
        updates = [e for e in inside if e["e"] == "update"]
        draws = [e for e in inside if e["e"] == "draw"]
        layouts = [e["layout"] for e in updates if e.get("layout") is not None]
        deliver_latency = [(e["t"] - received[k]["t"]) / 1e6 for e in delivers
                           if (k := (e["boot"], e["proj"], e["rev"])) in received]
        first_draw, e2e, shown = set(), [], []
        for event in draws:
            key = (event["boot"], event["proj"], event["rev"])
            if key in first_draw or key not in received:
                continue
            first_draw.add(key)
            e2e.append((event["t"] - received[key]["t"]) / 1e6)
            if (on_screen := screen.at(event["t"])) is not None:
                shown.append((on_screen - received[key]["t"]) / 1e6)
        received_keys = {(e["boot"], e["proj"], e["rev"]) for e in recv}
        busy = sum(e["dur"] for e in updates) + sum(e["dur"] for e in draws)
        last = recv[-1] if recv else None
        summaries.append({
            "phase": phase["name"],
            "seconds": round(seconds, 2),
            "grid": f"{last['cols']}x{last['rows']}" if last else None,
            "frames": len(recv),
            "patches": sum(1 for e in recv if e["patch"]),
            "fps_in": round(len(recv) / seconds, 1),
            "mb_in": round(sum(e["bytes"] for e in recv) / 1e6, 2),
            "decode_p50_us": percentile([e["decode"] / 1e3 for e in recv], 0.5),
            "decode_p95_us": percentile([e["decode"] / 1e3 for e in recv], 0.95),
            "decode_max_ms": max(e["decode"] for e in recv) / 1e6 if recv else None,
            "deliver_p50_ms": percentile(deliver_latency, 0.5),
            "deliver_p95_ms": percentile(deliver_latency, 0.95),
            "updates": len(updates),
            "layouts": len(layouts),
            "layout_p50_ms": percentile([v / 1e6 for v in layouts], 0.5),
            "layout_p95_ms": percentile([v / 1e6 for v in layouts], 0.95),
            "draws": len(draws),
            "draw_p50_ms": percentile([e["dur"] / 1e6 for e in draws], 0.5),
            "draw_p95_ms": percentile([e["dur"] / 1e6 for e in draws], 0.95),
            "fps_drawn": round(len(first_draw) / seconds, 1),
            "revisions_skipped": len(received_keys - first_draw),
            "e2e_p50_ms": percentile(e2e, 0.5),
            "e2e_p95_ms": percentile(e2e, 0.95),
            "e2e_max_ms": max(e2e) if e2e else None,
            # Steady output draws a frame every 20-30 ms; a longer gap is a stall someone sees.
            "draw_gap_max_ms": max(gaps) if (gaps := draw_gaps(draws, received, len(recv) / seconds)) else None,
            "draw_gaps_50ms": sum(1 for gap in gaps if gap > 50) if gaps else None,
            "screen_p50_ms": percentile(shown, 0.5),
            "screen_p95_ms": percentile(shown, 0.95),
            "main_busy_pct": round(100 * busy / (seconds * 1e9), 1),
            "keystrokes": keystrokes(events, lo, hi, screen),
            "mouse": mouse_events(events, lo, hi, screen),
            "last_frame_drawn": bool(last) and (last["boot"], last["proj"], last["rev"]) in
                                {(e["boot"], e["proj"], e["rev"]) for e in events if e["e"] == "draw"},
        })
    return summaries


def draw_gaps(draws, received, fps_in):
    """Milliseconds between consecutive first draws of new revisions while output streams: how
    long the screen stood still. Only for phases that stream (over 15 frames a second); the
    first and last 5 draws, the command starting and the prompt after it, are left out."""
    if fps_in < 15:
        return []
    times, seen = [], set()
    for event in draws:
        key = (event["boot"], event["proj"], event["rev"])
        if key in seen or key not in received:
            continue
        seen.add(key)
        times.append(event["t"])
    times = times[5:-5]
    return [(b - a) / 1e6 for a, b in zip(times, times[1:])]


def keystrokes(events, lo, hi, screen):
    """Matches each key event in [lo, hi] with its input write, the first frame received after
    it that moved the cursor (the echo), the first draw of that frame and its estimated time on
    screen."""
    key = lambda e: (e["boot"], e["proj"], e["rev"])
    keys = [e for e in events if e["e"] == "key" and lo <= e["t"] <= hi]
    sents = [e for e in events if e["e"] == "sent"]
    recvs = [e for e in events if e["e"] == "recv"]
    draws = [e for e in events if e["e"] == "draw"]
    samples = []
    for index, press in enumerate(keys):
        sent = next((e for e in sents if e["t"] >= press["t"]), None)
        if not sent:
            continue
        limit = keys[index + 1]["t"] if index + 1 < len(keys) else float("inf")
        echo = next((e for e in recvs if sent["t"] < e["t"] < limit
                     and (e.get("cx"), e.get("cy")) != (press.get("cx"), press.get("cy"))), None)
        if not echo:
            continue
        drawn = next((e for e in draws if key(e) == key(echo) and e["t"] >= echo["t"]), None)
        if not drawn:
            continue
        on_screen = screen.at(drawn["t"])
        samples.append({
            "queue": (press["t"] - press["t_event"]) / 1e6,
            "send": (sent["t"] - press["t"]) / 1e6,
            "herdr": (echo["t"] - sent["t"]) / 1e6,
            "render": (drawn["t"] - echo["t"]) / 1e6,
            "total": (drawn["t"] - press["t_event"]) / 1e6,
            "screen": None if on_screen is None else (on_screen - press["t_event"]) / 1e6,
        })
    if not samples:
        return None
    result = {"keys": len(keys), "matched": len(samples)}
    for part in ("queue", "send", "herdr", "render", "total"):
        values = [sample[part] for sample in samples]
        result[f"key_{part}_p50_ms"] = percentile(values, 0.5)
        result[f"key_{part}_p95_ms"] = percentile(values, 0.95)
    result["key_total_max_ms"] = max(sample["total"] for sample in samples)
    shown = [sample["screen"] for sample in samples if sample["screen"] is not None]
    result["key_screen_p50_ms"] = percentile(shown, 0.5)
    result["key_screen_p95_ms"] = percentile(shown, 0.95)
    return result


def mouse_events(events, lo, hi, screen):
    """Counts, for the probe's events in [lo, hi], the store's change notifications and the view
    updates without a new revision (SwiftUI updating the window) from the first event until 0.5 s
    after the last, and matches each event with the draw that shows its effect: for `select`, the
    next draw (the selection is drawn locally); for `resize`, the first draw of the first frame
    whose size differs from the frame before; for `tabs`, of the first complete surface (a new
    tab's projection); otherwise of the first frame received after the event, which Herdr redrew
    in response."""
    key = lambda e: (e["boot"], e["proj"], e["rev"])
    mice = [e for e in events if e["e"] == "mouse" and lo <= e["t"] <= hi]
    if not mice:
        return None
    first, end = mice[0]["t"], min(hi, mice[-1]["t"] + 500_000_000)
    inside = [e for e in events if e["e"] != "start" and first <= e["t"] <= end]
    publishes = sum(1 for e in inside if e["e"] == "publish")
    view_updates = sum(1 for e in inside if e["e"] == "update" and e.get("rev") is None)
    recvs = [e for e in inside if e["e"] == "recv"]
    all_recvs = [e for e in events if e["e"] == "recv"]
    draws = [e for e in events if e["e"] == "draw"]
    kind = mice[0]["kind"]
    size = lambda e: (e["cols"], e["rows"])
    resizes = [e for e in events if e["e"] == "resize"]
    samples, shown, parts = [], [], []
    for index, event in enumerate(mice):
        limit = mice[index + 1]["t"] if index + 1 < len(mice) else end
        if kind == "select":
            drawn = next((e for e in draws if event["t"] <= e["t"] < limit), None)
        else:
            if kind == "resize":
                before = next((e for e in reversed(all_recvs) if e["t"] <= event["t"]), None)
                match = lambda e: before is None or size(e) != size(before)
            elif kind == "tabs":
                match = lambda e: not e["patch"]
            else:
                match = lambda e: True
            frame = next((e for e in recvs if event["t"] < e["t"] < limit and match(e)), None)
            drawn = frame and next((e for e in draws if key(e) == key(frame) and e["t"] >= frame["t"]), None)
            sent = kind == "resize" and next((e for e in resizes if event["t"] <= e["t"] < limit), None)
            if drawn and sent and sent["t"] <= frame["t"]:
                parts.append({"send": (sent["t"] - event["t_event"]) / 1e6, "herdr": (frame["t"] - sent["t"]) / 1e6,
                              "render": (drawn["t"] - frame["t"]) / 1e6})
        if drawn:
            samples.append((drawn["t"] - event["t_event"]) / 1e6)
            if (on_screen := screen.at(drawn["t"])) is not None:
                shown.append((on_screen - event["t_event"]) / 1e6)
    split = {}
    for part in ("send", "herdr", "render"):
        values = [sample[part] for sample in parts]
        split[f"{part}_p50_ms"] = percentile(values, 0.5)
        split[f"{part}_p95_ms"] = percentile(values, 0.95)
    return {
        "split": split if parts else None,
        "kind": kind,
        "events": len(mice),
        "publishes": publishes,
        "publishes_per_event": round(publishes / len(mice), 2),
        "view_updates": view_updates,
        "view_updates_per_event": round(view_updates / len(mice), 2),
        "frames": len(recvs),
        "matched": len(samples),
        "drawn_p50_ms": percentile(samples, 0.5),
        "drawn_p95_ms": percentile(samples, 0.95),
        "drawn_max_ms": max(samples) if samples else None,
        "screen_p50_ms": percentile(shown, 0.5),
        "screen_p95_ms": percentile(shown, 0.95),
    }


def e2e_report(metrics_path, phases_path, baseline_path, json_path):
    summaries = e2e_summary(metrics_path, phases_path)
    base = {}
    if baseline_path:
        base = {s["phase"]: s for s in json.loads(Path(baseline_path).read_text())}
        print(f"Baseline {baseline_path}  (n× = improvement vs baseline)")
    columns = [("frames", "frames", None), ("fps_in", "fps in", False), ("fps_drawn", "fps drawn", False),
               ("revisions_skipped", "skipped", None), ("deliver_p95_ms", "deliver p95 ms", True),
               ("layout_p50_ms", "layout p50 ms", True), ("draw_p50_ms", "draw p50 ms", True),
               ("e2e_p50_ms", "e2e p50 ms", True), ("e2e_p95_ms", "e2e p95 ms", True),
               ("e2e_max_ms", "e2e max ms", True), ("draw_gap_max_ms", "max gap ms", True),
               ("draw_gaps_50ms", "gaps >50 ms", True),
               ("decode_max_ms", "decode max ms", True), ("screen_p50_ms", "screen p50 ms", True),
               ("screen_p95_ms", "screen p95 ms", True), ("main_busy_pct", "main busy %", True)]
    rows = []
    for summary in summaries:
        old = base.get(summary["phase"], {})
        row = [f"{summary['phase']} ({summary['grid']}, {summary['seconds']}s)"]
        for key, _, lower in columns:
            value = summary[key]
            row.append(fmt(value) + (change(value, old.get(key), lower) if lower is not None else ""))
        rows.append(row)
    table(["phase"] + [label for _, label, _ in columns], rows)
    typed = [s for s in summaries if s.get("keystrokes")]
    if typed:
        print()
        print("Keystroke to screen, ms: queue = event to keyDown, send = keyDown to socket write,")
        print("herdr = write to echo frame received, render = received to drawn, total = event to drawn,")
        print("screen = event to the estimated refresh that shows it")
        rows = []
        for summary in typed:
            keys = summary["keystrokes"]
            old = (base.get(summary["phase"]) or {}).get("keystrokes") or {}
            row = [f"{summary['phase']} ({keys['matched']}/{keys['keys']} keys)"]
            for part in ("queue", "send", "herdr", "render", "total"):
                for p in ("p50", "p95"):
                    name = f"key_{part}_{p}_ms"
                    row.append(fmt(keys[name]) + (change(keys[name], old.get(name)) if part == "total" else ""))
            row.append(fmt(keys["key_total_max_ms"]) + change(keys["key_total_max_ms"], old.get("key_total_max_ms")))
            for p in ("p50", "p95"):
                name = f"key_screen_{p}_ms"
                row.append(fmt(keys.get(name)) + change(keys.get(name), old.get(name)))
            rows.append(row)
        table(["phase", "queue p50", "p95", "send p50", "p95", "herdr p50", "p95", "render p50", "p95",
               "total p50", "p95", "max", "screen p50", "p95"], rows)
    moused = [s for s in summaries if s.get("mouse")]
    if moused:
        print()
        print("Mouse and window: publishes = HerdrStore change notifications, view updates = terminal view")
        print("updates without a new revision (SwiftUI updating the window); drawn = event to the draw that")
        print("shows its effect (see mouse_events), screen = event to the estimated refresh that shows it")
        rows = []
        for summary in moused:
            mouse = summary["mouse"]
            old = (base.get(summary["phase"]) or {}).get("mouse") or {}
            rows.append([summary["phase"], mouse["events"], mouse["publishes"],
                         fmt(mouse["publishes_per_event"]) + change(mouse["publishes_per_event"], old.get("publishes_per_event")),
                         mouse["view_updates"], fmt(mouse["view_updates_per_event"]), mouse["frames"],
                         f"{mouse['matched']}/{mouse['events']}",
                         fmt(mouse["drawn_p50_ms"]) + change(mouse["drawn_p50_ms"], old.get("drawn_p50_ms")),
                         fmt(mouse["drawn_p95_ms"]), fmt(mouse["drawn_max_ms"]),
                         fmt(mouse.get("screen_p50_ms")), fmt(mouse.get("screen_p95_ms"))])
        table(["phase", "events", "publishes", "per event", "view updates", "per event", "frames",
               "matched", "drawn p50", "p95", "max", "screen p50", "p95"], rows)
        split = [s for s in moused if s["mouse"].get("split")]
        if split:
            print()
            print("Resize, ms: send = event to the new size written to the socket, herdr = written to the")
            print("first frame at the new size received, render = received to drawn")
            table(["phase", "send p50", "p95", "herdr p50", "p95", "render p50", "p95"],
                  [[s["phase"]] + [fmt(s["mouse"]["split"][f"{part}_{p}_ms"]) for part in ("send", "herdr", "render")
                                   for p in ("p50", "p95")] for s in split])
    for summary in summaries:
        if summary["frames"] and not summary["last_frame_drawn"]:
            print(f"WARNING: {summary['phase']}: the last frame received was never drawn")
    if json_path:
        Path(json_path).write_text(json.dumps(summaries, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    workloads = commands.add_parser("workloads")
    workloads.add_argument("directory")
    player = commands.add_parser("play")
    player.add_argument("file")
    player.add_argument("--lines-per-second", type=float, default=250)
    player.add_argument("--chars-per-second", type=float)
    player.add_argument("--seconds", type=float, default=5)
    bench = commands.add_parser("bench")
    bench.add_argument("results")
    bench.add_argument("--baseline")
    files = commands.add_parser("files")
    files.add_argument("results")
    files.add_argument("--baseline")
    e2e = commands.add_parser("e2e")
    e2e.add_argument("metrics")
    e2e.add_argument("phases")
    e2e.add_argument("--baseline")
    e2e.add_argument("--json")
    args = parser.parse_args()
    if args.command == "workloads":
        write_workloads(args.directory)
    elif args.command == "play":
        play(args.file, args.lines_per_second, args.chars_per_second, args.seconds)
    elif args.command == "files":
        files_report(args.results, args.baseline)
    elif args.command == "bench":
        bench_report(args.results, args.baseline)
    else:
        e2e_report(args.metrics, args.phases, args.baseline, args.json)


if __name__ == "__main__":
    sys.exit(main())
