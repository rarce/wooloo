#!/bin/zsh
# Measure native source layout/editing and document/project search paths in Release.
# WOOLOO_BENCH_REPEAT sets repetitions (5). No private files are read.
set -euo pipefail
root=${0:A:h:h}
derived=${WOOLOO_DERIVED_DATA:-$root/build/DerivedData}
baseline=$root/docs/perf/editor-baseline.jsonl
save_baseline=0
check=()
while (( $# )); do
    case $1 in
        --save-baseline) save_baseline=1; shift ;;
        --baseline) baseline=$2; shift 2 ;;
        --check) check=(--check); shift ;;
        --no-baseline) baseline=; shift ;;
        *) echo "Usage: $0 [--save-baseline] [--baseline FILE] [--check] [--no-baseline]" >&2; exit 2 ;;
    esac
done
if [[ $save_baseline == 1 && -z $baseline ]]; then
    echo "Choose either --save-baseline or --no-baseline." >&2
    exit 2
fi
if [[ $save_baseline == 1 && ${#check} -gt 0 ]]; then
    echo "Choose either --save-baseline or --check." >&2
    exit 2
fi
if (( ${#check} )) && [[ ! -f $baseline ]]; then
    echo "Editor baseline not found: $baseline" >&2
    exit 2
fi
mkdir -p $root/build/perf
stamp=$(date +%Y%m%d-%H%M%S)
results=$root/build/perf/editor-$stamp.jsonl
log=$root/build/perf/editor-$stamp.log
python3 $root/scripts/perf_support.py $root woolooTests/EditorFindHighlightTests.swift > $results
export TEST_RUNNER_WOOLOO_BENCH_EDITOR=1 TEST_RUNNER_WOOLOO_BENCH_OUT=$results
export TEST_RUNNER_WOOLOO_BENCH_REPEAT=${WOOLOO_BENCH_REPEAT:-5}
echo "Editor benchmarks (Release) — log: $log"
if ! xcodebuild test -disableAutomaticPackageResolution -skipPackageUpdates -project $root/wooloo.xcodeproj -scheme wooloo -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived ONLY_ACTIVE_ARCH=YES \
        -only-testing:woolooTests/EditorFindHighlightTests/testEditorPerformance \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES > $log 2>&1; then
    rg 'error:|failed' $log | head -20
    echo "Editor benchmarks failed; see $log" >&2
    exit 1
fi
python3 - "$results" <<'PY'
import json, subprocess, sys
with open(sys.argv[1], "a") as output:
    output.write(json.dumps({"load_after": subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()}) + "\n")
PY
python3 $root/scripts/perf_support.py $root woolooTests/EditorFindHighlightTests.swift --verify $results

if [[ $save_baseline == 1 ]]; then
    python3 $root/scripts/markdown-perf.py $results --kind Editor
    cp $results $baseline
    echo "Saved baseline: $baseline"
    echo "Results: $results"
    exit 0
fi
comparison=()
[[ -f $baseline ]] && comparison=(--baseline $baseline)
python3 $root/scripts/markdown-perf.py $results --kind Editor $comparison $check
echo "Results: $results"
