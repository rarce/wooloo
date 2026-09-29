#!/bin/zsh
# Runs the terminal pipeline benchmarks (xherdrTests/TerminalPipelineBenchmarks) in an
# optimized build, saves their results under build/perf and compares them with
# docs/perf/bench-baseline.jsonl when it exists.
#
#   scripts/terminal-bench.sh                 # run and compare with the baseline
#   scripts/terminal-bench.sh --save-baseline # run and make these results the baseline
#
# XHERDR_BENCH_COLS, _ROWS, _FRAMES and _REPEAT change the workload size (200×60, 240, 3).
set -euo pipefail

root=${0:A:h:h}
derived=${XHERDR_DERIVED_DATA:-$root/build/DerivedData}
out_dir=$root/build/perf
baseline=$root/docs/perf/bench-baseline.jsonl
save_baseline=0
[[ ${1:-} == --save-baseline ]] && save_baseline=1

mkdir -p $out_dir
stamp=$(date +%Y%m%d-%H%M%S)
log=$out_dir/bench-$stamp.log
results=$out_dir/bench-$stamp.jsonl

# The load average marks runs that shared the machine with builds or other heavy work.
echo "{\"machine\":\"$(sysctl -n hw.model)\",\"commit\":\"$(git -C $root rev-parse --short HEAD)\",\"load_before\":\"$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')\"}" > $results
export TEST_RUNNER_XHERDR_BENCH=1 TEST_RUNNER_XHERDR_BENCH_OUT=$results
for name in COLS ROWS FRAMES REPEAT; do
    value=${(P)${:-XHERDR_BENCH_$name}:-}
    [[ -n $value ]] && export TEST_RUNNER_XHERDR_BENCH_$name=$value
done

echo "Building and running benchmarks (Release) — log: $log"
if ! xcodebuild test -project $root/xherdr.xcodeproj -scheme xherdr -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
        -only-testing:xherdrTests/TerminalPipelineBenchmarks \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES \
        > $log 2>&1; then
    grep -E "error:|failed" $log | head -20
    echo "Benchmarks failed; see $log" >&2
    exit 1
fi

echo "{\"load_after\":\"$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')\"}" >> $results

if [[ $save_baseline == 1 ]]; then
    mkdir -p ${baseline:h}
    cp $results $baseline
    echo "Saved baseline: $baseline"
    python3 $root/scripts/terminal-perf.py bench $results
elif [[ -f $baseline ]]; then
    python3 $root/scripts/terminal-perf.py bench $results --baseline $baseline
else
    python3 $root/scripts/terminal-perf.py bench $results
fi
echo "Results: $results"
