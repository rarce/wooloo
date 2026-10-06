#!/bin/zsh
# Measures the live terminal pipeline end to end: starts a dedicated Herdr session, opens an
# optimized xherdr build on it with metrics and a surface trace enabled, runs output workloads
# in the pane, then
#   1. summarizes frames in/out, main-thread costs, arrival-to-draw latency and an estimate of
#      when each draw reached the screen per workload, compared with
#      docs/perf/e2e-baseline.json when it exists;
#   2. replays the recorded trace through the reference decoder and checks that every drawn
#      revision showed exactly what Herdr sent, and that each workload's last frame was drawn.
#
#   scripts/terminal-e2e.sh [--save-baseline] [workload...]
#
# Workloads: ascii, color and unicode stream 250 log lines per second for 5 s; typing echoes
# 40 characters per second for 5 s; burst cats 60,000 lines at once; keys types 100 letters
# into `cat` through xherdr's own key handling and reports keystroke-to-screen latency; mouse
# splits the pane, enables mouse reporting in the new one, and plays 40 clicks in the other
# pane (which it already selected), 40 wheel events over the mouse-aware one and a 2 s drag of
# the split, as three phases that report store publishes and view updates per event and the
# event-to-screen latency of what Herdr redraws. split streams ascii and color output into two
# panes at once; selection drags a text selection across the pane during ascii output; resize
# changes the window size 16 times during ascii output; tabs switches 20 times between two tabs
# that show earlier output. All run by default.
#
# The xherdr window opens and must stay visible while it runs. XHERDR_E2E_WINDOW sets its
# content size (default 1600x1000). XHERDR_E2E_SESSION changes the
# session (default xherdr-perf); the primary session is refused.
set -euo pipefail

root=${0:A:h:h}
session=${XHERDR_E2E_SESSION:-xherdr-perf}
derived=${XHERDR_DERIVED_DATA:-$root/build/DerivedData}
baseline=$root/docs/perf/e2e-baseline.json
herdr=(herdr --session $session)
save_baseline=0
if [[ ${1:-} == --save-baseline ]]; then save_baseline=1; shift; fi
workloads=(ascii color unicode typing burst keys mouse split selection resize tabs)
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
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) XHERDR_PROBES' \
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
created=$($herdr workspace create --cwd $run --label xherdr-perf --focus |
    python3 -c 'import json, sys; pane = json.load(sys.stdin)["result"]["root_pane"]; print(pane["workspace_id"], pane["pane_id"])')
workspace=${created% *}
pane=${created#* }
echo "Session $session, pane $pane"

XHERDR_METRICS_FILE=$metrics XHERDR_SURFACE_TRACE=$trace XHERDR_TYPING_PROBE=1 \
    XHERDR_WINDOW_SIZE=${XHERDR_E2E_WINDOW:-1600x1000} $app -HerdrLastSession $session -ApplePersistenceIgnoreState YES \
    > $run/app.log 2>&1 &
app_pid=$!

for _ in {1..300}; do
    grep -q '"e":"draw"' $metrics 2>/dev/null && break
    python3 -c 'import time; time.sleep(0.1)'
done
grep -q '"e":"draw"' $metrics 2>/dev/null || { echo "xherdr never drew a live surface" >&2; exit 1; }
python3 -c 'import time; time.sleep(1.5)'

for workload in $workloads; do
    if [[ $workload == keys ]]; then
        echo "Running keys"
        $herdr pane run $pane "clear; cat" > /dev/null
        python3 -c 'import time; time.sleep(1)'
        start=$(now_ms)
        notifyutil -p dev.xherdr.typing-probe
        python3 -c 'import time; time.sleep(11.5)' # 100 keys, one every 100 ms
        echo "{\"name\":\"keys\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
        $herdr pane send-keys $pane ctrl+c > /dev/null
        continue
    fi
    if [[ $workload == mouse ]]; then
        echo "Running mouse"
        $herdr pane run $pane "clear; cat" > /dev/null
        # The new pane echoes the SGR mouse reports Herdr writes for wheel events, so each one
        # draws a frame whose latency can be measured.
        aware=$($herdr pane split $pane --direction right |
            python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
        $herdr pane run $aware "clear; printf '\\033[?1000h\\033[?1006h'; cat" > /dev/null
        python3 -c 'import time; time.sleep(1.5)'
        for kind seconds in click 5 scroll 5 drag 3; do
            start=$(now_ms)
            notifyutil -p dev.xherdr.mouse-probe.$kind
            python3 -c "import time; time.sleep($seconds)"
            echo "{\"name\":\"mouse-$kind\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
            python3 -c 'import time; time.sleep(0.5)'
        done
        $herdr pane close $aware > /dev/null
        $herdr pane send-keys $pane ctrl+c > /dev/null
        python3 -c 'import time; time.sleep(1)'
        continue
    fi
    play="python3 $root/scripts/terminal-perf.py play"
    if [[ $workload == split ]]; then
        echo "Running split"
        second=$($herdr pane split $pane --direction right |
            python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
        python3 -c 'import time; time.sleep(1)'
        start=$(now_ms)
        $herdr pane run $second "clear; $play $run/color.txt --lines-per-second 250 --seconds 5; printf 'XHERDR_%s_%s\\n' DONE right" > /dev/null
        $herdr pane run $pane "clear; $play $run/ascii.txt --lines-per-second 250 --seconds 5; printf 'XHERDR_%s_%s\\n' DONE left" > /dev/null
        $herdr pane wait-output $pane --match XHERDR_DONE_left --timeout 180000 > /dev/null
        $herdr pane wait-output $second --match XHERDR_DONE_right --timeout 180000 > /dev/null
        python3 -c 'import time; time.sleep(1.5)'
        echo "{\"name\":\"split\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
        $herdr pane close $second > /dev/null
        python3 -c 'import time; time.sleep(1)'
        continue
    fi
    if [[ $workload == selection || $workload == resize ]]; then
        echo "Running $workload"
        # The probe plays during 5 s of ascii output.
        $herdr pane run $pane "clear; $play $run/ascii.txt --lines-per-second 250 --seconds 7" > /dev/null
        python3 -c 'import time; time.sleep(1)'
        start=$(now_ms)
        [[ $workload == selection ]] && notifyutil -p dev.xherdr.mouse-probe.select || notifyutil -p dev.xherdr.ui-probe.resize
        python3 -c 'import time; time.sleep(5.5)'
        echo "{\"name\":\"$workload\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
        python3 -c 'import time; time.sleep(1.5)'
        continue
    fi
    if [[ $workload == tabs ]]; then
        echo "Running tabs"
        $herdr pane run $pane "clear; head -c 20000 $run/color.txt" > /dev/null
        other=$($herdr tab create --workspace $workspace |
            python3 -c 'import json, sys; result = json.load(sys.stdin)["result"]; print(result["tab"]["tab_id"], result["root_pane"]["pane_id"])')
        $herdr pane run ${other#* } "clear; head -c 20000 $run/unicode.txt" > /dev/null
        python3 -c 'import time; time.sleep(1.5)'
        start=$(now_ms)
        notifyutil -p dev.xherdr.ui-probe.tabs
        python3 -c 'import time; time.sleep(6.5)' # 20 switches, one every 300 ms
        echo "{\"name\":\"tabs\",\"start_ms\":$start,\"end_ms\":$(now_ms)}" >> $phases
        $herdr tab close ${other% *} > /dev/null
        python3 -c 'import time; time.sleep(1)'
        continue
    fi
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
