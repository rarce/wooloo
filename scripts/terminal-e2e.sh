#!/bin/zsh
# Measures the live terminal pipeline end to end: starts a dedicated Herdr session, opens an
# optimized xherdr build on it with metrics and a surface trace enabled, runs output workloads
# in the pane, then
#   1. summarizes frames in/out, main-thread costs and arrival-to-draw latency per workload,
#      compared with docs/perf/e2e-baseline.json when it exists;
#   2. replays the recorded trace through the reference decoder and checks that every drawn
#      revision showed exactly what Herdr sent, and that each workload's last frame was drawn.
#
#   scripts/terminal-e2e.sh [--save-baseline] [workload...]
#
# Workloads: ascii, color and unicode stream 250 log lines per second for 5 s; typing echoes
# 40 characters per second for 5 s; burst cats 60,000 lines at once. All run by default.
#
# The xherdr window opens and must stay visible while it runs. XHERDR_E2E_SESSION changes the
# session (default xherdr-perf); the primary session is refused.
set -euo pipefail

root=${0:A:h:h}
session=${XHERDR_E2E_SESSION:-xherdr-perf}
derived=${XHERDR_DERIVED_DATA:-$root/build/DerivedData}
baseline=$root/docs/perf/e2e-baseline.json
herdr=(herdr --session $session)
save_baseline=0
if [[ ${1:-} == --save-baseline ]]; then save_baseline=1; shift; fi
workloads=(ascii color unicode typing burst)
(( $# )) && workloads=($@)
[[ $session == default ]] && { echo "Refusing to use the primary Herdr session" >&2; exit 1; }

run=$root/build/perf/e2e-$(date +%Y%m%d-%H%M%S)
mkdir -p $run
metrics=$run/metrics.jsonl
trace=$run/surface.trace
phases=$run/phases.jsonl
: > $phases
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

echo "Building xherdr (Release) — run directory: $run"
if ! xcodebuild build-for-testing -project $root/xherdr.xcodeproj -scheme xherdr -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES \
        > $run/build.log 2>&1; then
    grep -E "error:" $run/build.log | head -20
    echo "Build failed; see $run/build.log" >&2
    exit 1
fi
app=$derived/Build/Products/Release/xherdr.app/Contents/MacOS/xherdr

python3 $root/scripts/terminal-perf.py workloads $run

started_server=0
app_pid=
previous_session=$(defaults read dev.xherdr.app HerdrLastSession 2>/dev/null || true)
cleanup() {
    [[ -n $app_pid ]] && kill $app_pid 2>/dev/null || true
    # xherdr remembers the session it connected to; give the developer's own choice back.
    if [[ -n $previous_session ]]; then
        defaults write dev.xherdr.app HerdrLastSession -string $previous_session
    else
        defaults delete dev.xherdr.app HerdrLastSession 2>/dev/null || true
    fi
    [[ $started_server == 1 ]] && $herdr server stop > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! $herdr status server 2>/dev/null | grep -q "status: running"; then
    $herdr server > $run/server.log 2>&1 &
    started_server=1
    for _ in {1..100}; do
        [[ -S ~/.config/herdr/sessions/$session/herdr.sock ]] && break
        python3 -c 'import time; time.sleep(0.1)'
    done
fi
pane=$($herdr workspace create --cwd $run --label xherdr-perf --focus |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')
echo "Session $session, pane $pane"

XHERDR_METRICS_FILE=$metrics XHERDR_SURFACE_TRACE=$trace $app -HerdrLastSession $session -ApplePersistenceIgnoreState YES \
    > $run/app.log 2>&1 &
app_pid=$!

for _ in {1..300}; do
    grep -q '"e":"draw"' $metrics 2>/dev/null && break
    python3 -c 'import time; time.sleep(0.1)'
done
grep -q '"e":"draw"' $metrics 2>/dev/null || { echo "xherdr never drew a live surface" >&2; exit 1; }
python3 -c 'import time; time.sleep(1.5)'

for workload in $workloads; do
    play="python3 $root/scripts/terminal-perf.py play"
    case $workload in
        ascii|color|unicode) command="$play $run/$workload.txt --lines-per-second 250 --seconds 5" ;;
        typing) command="$play $run/ascii.txt --chars-per-second 40 --seconds 5" ;;
        burst) command="cat $run/ascii.txt" ;;
        *) echo "Unknown workload $workload" >&2; exit 1 ;;
    esac
    echo "Running $workload"
    start=$(now_ms)
    # The marker is assembled by printf, so the echoed command line never matches it.
    $herdr pane run $pane "clear; $command; printf 'XHERDR_%s_%s\\n' DONE $workload" > /dev/null
    $herdr pane wait-output $pane --match "XHERDR_DONE_$workload" --timeout 180000 > /dev/null
    python3 -c 'import time; time.sleep(1.5)' # let the last frames arrive and draw
    echo "{\"name\":\"$workload\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
done
python3 -c 'import time; time.sleep(1)' # metrics flush every 0.5 s
kill $app_pid 2>/dev/null || true
wait $app_pid 2>/dev/null || true
app_pid=

echo
if [[ $save_baseline == 1 ]]; then
    python3 $root/scripts/terminal-perf.py e2e $metrics $phases --json $run/summary.json
    mkdir -p ${baseline:h}
    cp $run/summary.json $baseline
    echo "Saved baseline: $baseline"
elif [[ -f $baseline ]]; then
    python3 $root/scripts/terminal-perf.py e2e $metrics $phases --json $run/summary.json --baseline $baseline
else
    python3 $root/scripts/terminal-perf.py e2e $metrics $phases --json $run/summary.json
fi

echo
echo "Replaying the trace ($(du -h $trace | cut -f1)) against the reference decoder"
if TEST_RUNNER_XHERDR_REPLAY_TRACE=$trace TEST_RUNNER_XHERDR_REPLAY_METRICS=$metrics \
    xcodebuild test-without-building -project $root/xherdr.xcodeproj -scheme xherdr -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
        -only-testing:xherdrTests/SurfaceTraceReplayTests > $run/replay.log 2>&1; then
    echo "Replay: every drawn revision matches what Herdr sent"
else
    grep -E "error:|XCTAssert|failed" $run/replay.log | head -20
    echo "Replay FAILED; see $run/replay.log" >&2
    exit 1
fi
echo "Run: $run"
