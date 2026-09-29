#!/usr/bin/env python3
"""Reports for the terminal pipeline measurements.

  terminal-perf.py workloads DIR
      Writes the output files the end-to-end run cats into a pane.
  terminal-perf.py play FILE [--lines-per-second N | --chars-per-second N] [--seconds S]
      Writes FILE to stdout at a steady pace, like a build log or an agent typing.
  terminal-perf.py bench RESULTS.jsonl [--baseline OLD.jsonl]
      Tabulates XHERDR-BENCH lines from TerminalPipelineBenchmarks.
  terminal-perf.py e2e METRICS.jsonl PHASES.jsonl [--baseline OLD.json] [--json OUT.json]
      Summarizes a live run recorded with XHERDR_METRICS_FILE, one row per workload phase.
"""
import argparse
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
        line = line.split("XHERDR-BENCH ", 1)[-1].strip()
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
        for stage in ("decode", "layout", "layout-cold", "draw", "burst"):
            record = results.get((scenario, stage), {})
            old = base.get((scenario, stage), {})
            row.append(fmt(record.get("p50_us"), 1) + change(record.get("p50_us"), old.get("p50_us")))
            row.append(fmt(record.get("p95_us"), 1))
        burst = results.get((scenario, "burst"), {})
        row.append(fmt(burst.get("fps"), 0) + change(burst.get("fps"), base.get((scenario, "burst"), {}).get("fps"), False))
        rows.append(row)
    table(["scenario", "decode p50 µs", "p95", "layout p50 µs", "p95", "cold layout p50 µs", "p95", "draw p50 µs", "p95",
           "frame p50 µs", "p95", "burst fps"], rows)


# End-to-end ------------------------------------------------------------------------------

def e2e_summary(metrics_path, phases_path):
    events = [json.loads(line) for line in Path(metrics_path).read_text().splitlines() if line.strip()]
    start = next(e for e in events if e["e"] == "start")
    phases = [json.loads(line) for line in Path(phases_path).read_text().splitlines() if line.strip()]
    ns = lambda wall_ms: (wall_ms - start["wall_ms"]) * 1_000_000
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
        first_draw, e2e = set(), []
        for event in draws:
            key = (event["boot"], event["proj"], event["rev"])
            if key in first_draw or key not in received:
                continue
            first_draw.add(key)
            e2e.append((event["t"] - received[key]["t"]) / 1e6)
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
            "main_busy_pct": round(100 * busy / (seconds * 1e9), 1),
            "last_frame_drawn": bool(last) and (last["boot"], last["proj"], last["rev"]) in
                                {(e["boot"], e["proj"], e["rev"]) for e in events if e["e"] == "draw"},
        })
    return summaries


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
               ("e2e_max_ms", "e2e max ms", True), ("main_busy_pct", "main busy %", True)]
    rows = []
    for summary in summaries:
        old = base.get(summary["phase"], {})
        row = [f"{summary['phase']} ({summary['grid']}, {summary['seconds']}s)"]
        for key, _, lower in columns:
            value = summary[key]
            row.append(fmt(value) + (change(value, old.get(key), lower) if lower is not None else ""))
        rows.append(row)
    table(["phase"] + [label for _, label, _ in columns], rows)
    for summary in summaries:
        if not summary["last_frame_drawn"]:
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
    elif args.command == "bench":
        bench_report(args.results, args.baseline)
    else:
        e2e_report(args.metrics, args.phases, args.baseline, args.json)


if __name__ == "__main__":
    sys.exit(main())
