#!/usr/bin/env python3
"""Gate migrated source files in a complete-concurrency xcodebuild test log.

CI must start without cached app build products so each migrated source is compiled.
This checks that precondition and the completed test marker rather than treating an
empty or incremental-build log as evidence of concurrency validation.
"""
import argparse
from collections import Counter
from pathlib import Path
import re
import sys

MIGRATED = frozenset({
    "wooloo/BlockingWork.swift",
    "wooloo/RemoteAccessLineBuffer.swift",
    "wooloo/RemoteAccess.swift",
    "wooloo/HerdrRemoteBridge.swift",
})
DIAGNOSTIC = re.compile(r"^(.+?):(\d+)(?::(\d+))?: (warning|error): (.+)$")
COMPILE = re.compile(r"^SwiftCompile\s+\S+\s+\S+\s+(.+?)(?: \(in target .+\))?$")


def relative_source(raw, root):
    path = Path(raw.replace("\\ ", " "))
    if not path.is_absolute():
        path = root / path
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return None


def audit(text, root):
    root = Path(root).resolve()
    diagnostics = set()
    compiled = set()
    for line in text.splitlines():
        match = DIAGNOSTIC.match(line)
        if match:
            raw, row, column, severity, message = match.groups()
            path = relative_source(raw, root)
            if path is not None:
                diagnostics.add((path, int(row), int(column or 0), severity, message))
        match = COMPILE.match(line)
        if match:
            path = relative_source(match[1], root)
            if path is not None:
                compiled.add(path)
    failures = []
    if not text.strip():
        failures.append("The compiler log is empty; no concurrency validation was performed.")
    if "** TEST SUCCEEDED **" not in text.splitlines():
        failures.append("The compiler log has no completed successful test run.")
    if not re.search(r"^\s*SWIFT_STRICT_CONCURRENCY\s*=\s*complete\s*$", text, re.MULTILINE):
        failures.append("The compiler log does not confirm SWIFT_STRICT_CONCURRENCY=complete.")
    missing = sorted(MIGRATED - compiled)
    if missing:
        failures.append("No compilation evidence for: " + ", ".join(missing)
                        + ". Run CI without cached app build products.")
    guarded = sorted(item for item in diagnostics if item[0] in MIGRATED)
    if guarded:
        failures.append(f"Migrated files have {len(guarded)} compiler warning(s)/error(s).")
    return sorted(diagnostics), guarded, failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    try:
        text = args.log.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        print(f"Concurrency audit failed: cannot read {args.log}: {error}", file=sys.stderr)
        return 1
    diagnostics, guarded, failures = audit(text, args.root)
    print(f"Complete-concurrency audit: {len(diagnostics)} distinct repository diagnostics.")
    for (path, severity), count in sorted(Counter((d[0], d[3]) for d in diagnostics).items()):
        print(f"  {path}: {count} {severity}(s)")
    for path, row, column, severity, message in guarded:
        print(f"{path}:{row}:{column}: {severity}: {message}", file=sys.stderr)
    for failure in failures:
        print(f"Concurrency audit failed: {failure}", file=sys.stderr)
    if not failures:
        print("Migrated-file gate passed: " + ", ".join(sorted(MIGRATED)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
