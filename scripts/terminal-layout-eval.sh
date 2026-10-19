#!/bin/zsh
# Paired inline vs serial-worker layout feasibility experiment; no app behavior changes.
# Uses synthetic frames and offscreen drawing, not Claude or measured input latency.
# WOOLOO_BENCH_COLS/ROWS/FRAMES/REPEAT configure the same fixtures as terminal-bench.sh.
set -euo pipefail
root=${0:A:h:h}
derived=${WOOLOO_DERIVED_DATA:-$root/build/DerivedData}
out_dir=$root/build/perf
if (( $# )); then
    echo "Usage: $0 (configure with WOOLOO_BENCH_* environment variables)" >&2
    exit 2
fi
mkdir -p $out_dir
stamp=$(date +%Y%m%d-%H%M%S)
log=$out_dir/layout-eval-$stamp.log
results=$out_dir/layout-eval-$stamp.jsonl

# The load average marks runs that shared the machine with builds or other heavy work.
python3 $root/scripts/perf_support.py $root woolooTests/SurfaceFixtures.swift woolooTests/TerminalLayoutEvaluationTests.swift woolooTests/TerminalRenderHarness.swift scripts/terminal-layout-eval.sh > $results
export TEST_RUNNER_WOOLOO_LAYOUT_EVAL=1 TEST_RUNNER_WOOLOO_BENCH_OUT=$results
for name in COLS ROWS FRAMES REPEAT; do
    value=${(P)${:-WOOLOO_BENCH_$name}:-}
    [[ -n $value ]] && export TEST_RUNNER_WOOLOO_BENCH_$name=$value
done

echo "Building and running benchmarks (Release) — log: $log"
if ! xcodebuild test -disableAutomaticPackageResolution -skipPackageUpdates -project $root/wooloo.xcodeproj -scheme wooloo -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived ONLY_ACTIVE_ARCH=YES \
        -only-testing:woolooTests/TerminalLayoutEvaluationTests/testLayoutWorkerEvaluation \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES \
        > $log 2>&1; then
    grep -E "error:|failed" $log | head -20
    echo "Benchmarks failed; see $log" >&2
    exit 1
fi

echo "{\"load_after\":\"$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')\"}" >> $results

python3 $root/scripts/perf_support.py $root woolooTests/SurfaceFixtures.swift woolooTests/TerminalLayoutEvaluationTests.swift woolooTests/TerminalRenderHarness.swift scripts/terminal-layout-eval.sh --verify $results

python3 - "$results" <<'PYCODE'
import json, sys
from collections import Counter
rows = [json.loads(line) for line in open(sys.argv[1])]
config = next(row['evaluation'] for row in rows if 'evaluation' in row)
checks = [row for row in rows if 'pixel_check' in row]
assert len(checks) == 6 and all(row['equal'] and row['frames'] > 0 for row in checks), 'missing pixel checks'
expected = {(row['pixel_check'], stage, mode) for row in checks
            for stage in ('prepare', 'main-work', 'ready-to-drawn', 'main-probe') for mode in ('inline', 'worker')}
counts = Counter((row['scenario'], row['stage'], row['mode']) for row in rows if 'scenario' in row)
assert set(counts) == expected and all(n == config['repeat'] for n in counts.values()), 'incomplete paired results'
assert all(row['n'] > 0 for row in rows if 'scenario' in row), 'empty timing samples'
print('Validated paired results and pixel checks:', sys.argv[1])
PYCODE
echo "Paired layout evaluation complete: $results"
