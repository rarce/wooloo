#!/bin/zsh
# Measure actual SwiftUI Markdown previews in Release, comparing tables and prose in both styles.
# WOOLOO_BENCH_REPEAT sets repetitions (3); WOOLOO_BENCH_MARKDOWN_FILE adds a local document.
set -euo pipefail
root=${0:A:h:h}
derived=${WOOLOO_DERIVED_DATA:-$root/build/DerivedData}
baseline=$root/docs/perf/markdown-baseline.jsonl
save_baseline=0
check=()
while (( $# )); do
    case $1 in
        --save-baseline) save_baseline=1; shift ;;
        --baseline) baseline=$2; shift 2 ;;
        --check) check=(--check); shift ;;
        *) echo "Usage: $0 [--save-baseline] [--baseline FILE] [--check]" >&2; exit 2 ;;
    esac
done
mkdir -p $root/build/perf
stamp=$(date +%Y%m%d-%H%M%S)
results=$root/build/perf/markdown-$stamp.jsonl
log=$root/build/perf/markdown-$stamp.log
python3 - "$results" "$root" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[2]) / "scripts"))
from perf_support import capture
record = {"machine": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
          "os": platform.mac_ver()[0],
          "commit": subprocess.check_output(["git", "-C", sys.argv[2], "rev-parse", "--short", "HEAD"], text=True).strip(),
          "load_before": subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()}
repo = Path(sys.argv[2])
sources = [repo / "wooloo/MarkdownPreviewView.swift", *(repo / "Vendor/MarkdownView/Sources").rglob("*.swift")]
digest = hashlib.sha256()
for source in sorted(sources):
    digest.update(source.relative_to(repo).as_posix().encode() + b"\0")
    digest.update(source.read_bytes())
record["source_sha256"] = digest.hexdigest()
record.update(capture(Path(sys.argv[2]), ["woolooTests/MarkdownTableBenchmarks.swift"]))
Path(sys.argv[1]).write_text(json.dumps(record) + "\n")
PY
export TEST_RUNNER_WOOLOO_BENCH_MARKDOWN=1 TEST_RUNNER_WOOLOO_BENCH_OUT=$results
export TEST_RUNNER_WOOLOO_BENCH_REPEAT=${WOOLOO_BENCH_REPEAT:-3}
export TEST_RUNNER_WOOLOO_BENCH_MARKDOWN_FILE=${WOOLOO_BENCH_MARKDOWN_FILE:-}
echo "Markdown benchmarks (Release) — log: $log"
if ! xcodebuild test -disableAutomaticPackageResolution -skipPackageUpdates -project $root/wooloo.xcodeproj -scheme wooloo -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived ONLY_ACTIVE_ARCH=YES \
        -only-testing:woolooTests/MarkdownTableBenchmarks \
        -only-testing:woolooTests/MarkdownPreviewRenderingTests \
        -only-testing:woolooTests/MarkdownPreviewInteractionTests \
        -only-testing:woolooTests/ViewSnapshotTests/testMarkdownPreview \
        -only-testing:woolooTests/ViewSnapshotTests/testMarkdownPreviewDocument \
        -only-testing:woolooTests/ViewSnapshotTests/testMarkdownTables \
        -only-testing:woolooTests/ViewSnapshotTests/testMarkdownTablesDocument \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES > $log 2>&1; then
    rg 'error:|failed' $log | head -20
    echo "Markdown benchmarks failed; see $log" >&2
    exit 1
fi
python3 - "$results" <<'PY'
import json, subprocess, sys
with open(sys.argv[1], "a") as output:
    output.write(json.dumps({"load_after": subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()}) + "\n")
PY
if [[ $save_baseline == 1 ]]; then
    cp $results $baseline
    echo "Saved baseline: $baseline"
fi
comparison=()
[[ -f $baseline ]] && comparison=(--baseline $baseline)
python3 $root/scripts/markdown-perf.py $results $comparison $check
echo "Results: $results"
