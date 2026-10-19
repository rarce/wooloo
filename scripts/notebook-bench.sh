#!/bin/zsh
# Measure the complete saved-output notebook preview in Release, without Python or a kernel.
set -euo pipefail
root=${0:A:h:h}
derived=${WOOLOO_DERIVED_DATA:-$root/build/DerivedData}
baseline=$root/docs/perf/notebook-baseline.jsonl
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
if [[ $save_baseline == 1 && ${#check} -gt 0 ]]; then
    echo "Choose either --save-baseline or --check; saving would replace the comparison reference." >&2
    exit 2
fi
if (( ${#check} )) && [[ ! -f $baseline ]]; then
    echo "Notebook baseline not found: $baseline" >&2
    exit 2
fi
mkdir -p $root/build/perf
stamp=$(date +%Y%m%d-%H%M%S)
results=$root/build/perf/notebook-$stamp.jsonl
log=$root/build/perf/notebook-$stamp.log
python3 - "$results" "$root" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[2]) / "scripts"))
from perf_support import capture
repo = Path(sys.argv[2])
record = {"machine": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
          "os": platform.mac_ver()[0],
          "commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"], text=True).strip(),
          "load_before": subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()}
record["package_revisions"] = {pin["identity"]: pin["state"]["revision"] for pin in json.loads(
    (repo / "wooloo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]}
sources = [repo / "wooloo/NotebookDocument.swift", repo / "wooloo/NotebookPreviewView.swift",
           *(repo / "wooloo/NotebookAssets").rglob("*"), *(repo / "Vendor/NotebookPreview").rglob("*")]
digest = hashlib.sha256()
for source in sorted(path for path in sources if path.is_file()):
    digest.update(source.relative_to(repo).as_posix().encode() + b"\0")
    digest.update(source.read_bytes())
record["source_sha256"] = digest.hexdigest()
record.update(capture(Path(sys.argv[2]), ["woolooTests/NotebookPreviewBenchmarks.swift"]))
Path(sys.argv[1]).write_text(json.dumps(record) + "\n")
PY
export TEST_RUNNER_WOOLOO_BENCH_NOTEBOOK=1 TEST_RUNNER_WOOLOO_BENCH_OUT=$results
export TEST_RUNNER_WOOLOO_BENCH_REPEAT=${WOOLOO_BENCH_REPEAT:-7}
echo "Notebook benchmarks (Release) — log: $log"
if ! xcodebuild test -project $root/wooloo.xcodeproj -scheme wooloo -configuration Release \
        -disableAutomaticPackageResolution -skipPackageUpdates \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived ONLY_ACTIVE_ARCH=YES \
        -only-testing:woolooTests/NotebookPreviewBenchmarks \
        -only-testing:woolooTests/NotebookPreviewInteractionTests \
        -only-testing:woolooTests/NotebookParsingTests \
        -only-testing:woolooTests/NotebookRenderingTests \
        -only-testing:woolooTests/NotebookResourceSlotTests \
        -only-testing:woolooTests/ViewSnapshotTests/testNotebookPreview \
        -only-testing:woolooTests/ViewSnapshotTests/testNotebookPreviewDocument \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES > $log 2>&1; then
    rg ': error:|Test Case.*failed|TEST FAILED' $log | head -20 || true
    echo "Notebook benchmarks failed; see $log" >&2
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
python3 $root/scripts/markdown-perf.py $results --kind Notebook $comparison $check
echo "Results: $results"
