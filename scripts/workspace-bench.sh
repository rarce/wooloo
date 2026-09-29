#!/bin/zsh
# Runs the workspace benchmarks (xherdrTests/WorkspaceFilesBenchmarks): what the file explorer,
# Git panels, diffs and documents ask of git, SSH and the file system, timed and counted in
# processes, in a small and a large disposable repository. Results go under build/perf and are
# compared with docs/perf/files-baseline.jsonl when it exists.
#
#   scripts/workspace-bench.sh                 # run and compare with the baseline
#   scripts/workspace-bench.sh --save-baseline # run and make these results the baseline
#
# XHERDR_BENCH_SSH_TARGET also measures a remote over SSH (key authentication, git installed);
# it defaults to the first enabled Herdr machine that answers. Set it to "none" to skip SSH.
# XHERDR_BENCH_REPEAT changes the repetitions (5).
set -euo pipefail

root=${0:A:h:h}
derived=${XHERDR_DERIVED_DATA:-$root/build/DerivedData}
out_dir=$root/build/perf
baseline=$root/docs/perf/files-baseline.jsonl
save_baseline=0
[[ ${1:-} == --save-baseline ]] && save_baseline=1

target=${XHERDR_BENCH_SSH_TARGET:-}
if [[ -z $target ]]; then
    for candidate in $(herdr machine list 2>/dev/null | awk -F'\t' '$5 == "enabled" { print $3 }'); do
        if ssh -T -o BatchMode=yes -o ConnectTimeout=5 $candidate 'command -v git' > /dev/null 2>&1; then
            target=$candidate
            break
        fi
    done
fi
[[ $target == none ]] && target=

mkdir -p $out_dir
stamp=$(date +%Y%m%d-%H%M%S)
log=$out_dir/files-$stamp.log
results=$out_dir/files-$stamp.jsonl
echo "{\"machine\":\"$(sysctl -n hw.model)\",\"commit\":\"$(git -C $root rev-parse --short HEAD)\"}" > $results
export TEST_RUNNER_XHERDR_BENCH_FILES=1 TEST_RUNNER_XHERDR_BENCH_OUT=$results
export TEST_RUNNER_XHERDR_BENCH_SSH_TARGET=$target
[[ -n ${XHERDR_BENCH_REPEAT:-} ]] && export TEST_RUNNER_XHERDR_BENCH_REPEAT=$XHERDR_BENCH_REPEAT

echo "Running workspace benchmarks (Release${target:+, SSH to $target}) — log: $log"
if ! xcodebuild test -project $root/xherdr.xcodeproj -scheme xherdr -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
        -only-testing:xherdrTests/WorkspaceFilesBenchmarks \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES \
        > $log 2>&1; then
    grep -E "error:|failed" $log | head -20
    echo "Benchmarks failed; see $log" >&2
    exit 1
fi

if [[ $save_baseline == 1 ]]; then
    mkdir -p ${baseline:h}
    cp $results $baseline
    echo "Saved baseline: $baseline"
    python3 $root/scripts/terminal-perf.py files $results
elif [[ -f $baseline ]]; then
    python3 $root/scripts/terminal-perf.py files $results --baseline $baseline
else
    python3 $root/scripts/terminal-perf.py files $results
fi
echo "Results: $results"
