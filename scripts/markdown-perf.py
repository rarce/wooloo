#!/usr/bin/env python3
"""Compare actual preview render, resize, cached draw and scroll timings."""
import argparse
import json
from pathlib import Path
from perf_support import compatible


def read(path):
    config, results = {}, {}
    for line in Path(path).read_text().splitlines():
        record = json.loads(line)
        if "scenario" in record:
            results[(record["style"], record["scenario"], record["stage"])] = record
        else:
            config.update(record.get("config", record))
    return config, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results")
    parser.add_argument("--baseline")
    parser.add_argument("--kind", choices=["Markdown", "Notebook"], default="Markdown", help="preview metrics and name in diagnostics")
    parser.add_argument("--check", action="store_true", help="fail for >25%% median regressions and >10 ms (Notebook captures: >50 ms)")
    args = parser.parse_args()
    if args.check and not args.baseline:
        parser.error("--check requires a baseline")
    config, results = read(args.results)
    if not results:
        parser.error(f"no {args.kind} benchmark results")
    old_config, old = read(args.baseline) if args.baseline else ({}, {})
    if args.baseline and not old:
        parser.error(f"no {args.kind} benchmark results in baseline")
    if args.baseline:
        try:
            compatible(config, old_config,
                       ("width", "height", "resize_width", "base_font", "code_font", "theme", "renderer", "capture"),
                       results, old)
        except ValueError as error:
            parser.error(str(error))
    print("Config:", json.dumps(config, sort_keys=True))
    if args.baseline:
        print("Baseline:", args.baseline, "(speedup = baseline / current)")
    if args.kind == "Notebook":
        print("Gate: >25% and >10 ms for parser/JS; >25% and >50 ms for viewport captures")
    print(f"{'style / scenario / stage':58} {'p50 ms':>10} {'p95 ms':>10} {'speedup':>9}")
    regressions = []
    changed = []
    for key, result in sorted(results.items()):
        baseline = old.get(key)
        if baseline and baseline["sha256"] != result["sha256"]:
            print("SKIP comparison for changed document:", "/".join(key))
            changed.append(key)
            baseline = None
        current = result["p50_ms"]
        previous = baseline["p50_ms"] if baseline else None
        ratio = f"{previous / current:.2f}x" if previous is not None and current else "—"
        # Cross-process WebKit viewport captures vary by tens of milliseconds even
        # with identical renderer/input hashes. Keep parser and synchronous JS gates
        # sensitive; the capture gate detects sustained UI stalls above that noise.
        capture = result["stage"] in {"first-render", "resize", "cached-draw", "scroll"} or result["stage"].endswith("-paint")
        minimum_delta = 50 if args.kind == "Notebook" and capture else 10
        regressed = previous is not None and current > previous * 1.25 and current - previous > minimum_delta
        if regressed:
            regressions.append(key)
        print(f"{' / '.join(key):58} {current:10.2f} {result['p95_ms']:10.2f} {ratio:>9}" + ("  REGRESSION" if regressed else ""))
    missing = old.keys() - results.keys()
    if missing:
        print("Missing baseline cases:", ", ".join("/".join(key) for key in sorted(missing)))
    return int(args.check and bool(regressions or missing or changed))


if __name__ == "__main__":
    raise SystemExit(main())
