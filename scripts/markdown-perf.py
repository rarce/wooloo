#!/usr/bin/env python3
"""Compare actual Markdown preview render, resize and cached draw timings."""
import argparse
import json
from pathlib import Path


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
    parser.add_argument("--check", action="store_true", help="fail for >25%% and >10 ms median regressions")
    args = parser.parse_args()
    if args.check and not args.baseline:
        parser.error("--check requires a baseline")
    config, results = read(args.results)
    if not results:
        parser.error("no Markdown benchmark results")
    old_config, old = read(args.baseline) if args.baseline else ({}, {})
    for field in ("width", "height", "resize_width", "base_font", "code_font"):
        if old and config.get(field) != old_config.get(field):
            parser.error(f"incompatible {field}: {config.get(field)} vs {old_config.get(field)}")
    print("Config:", json.dumps(config, sort_keys=True))
    if args.baseline:
        print("Baseline:", args.baseline, "(speedup = baseline / current)")
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
        regressed = previous is not None and current > previous * 1.25 and current - previous > 10
        if regressed:
            regressions.append(key)
        print(f"{' / '.join(key):58} {current:10.2f} {result['p95_ms']:10.2f} {ratio:>9}" + ("  REGRESSION" if regressed else ""))
    missing = old.keys() - results.keys()
    if missing:
        print("Missing baseline cases:", ", ".join("/".join(key) for key in sorted(missing)))
    return int(args.check and bool(regressions or missing or changed))


if __name__ == "__main__":
    raise SystemExit(main())
