#!/bin/zsh
# Separate editable open, full Find and applied-cell-edit series; leaves read-only references alone.
set -euo pipefail
root=${0:A:h:h}
derived=${WOOLOO_DERIVED_DATA:-$root/build/DerivedData}
baseline=
check=()
while (( $# )); do
    case $1 in
        --baseline) baseline=$2; shift 2 ;;
        --check) check=(--check); shift ;;
        --no-baseline) baseline=; shift ;;
        *) echo "Usage: $0 [--baseline FILE] [--check] [--no-baseline]" >&2; exit 2 ;;
    esac
done
if (( ${#check} )) && [[ ! -f $baseline ]]; then
    echo "--check requires an existing editable baseline" >&2; exit 2
fi
mkdir -p $root/build/perf
stamp=$(date +%Y%m%d-%H%M%S)
results=$root/build/perf/notebook-editable-$stamp.jsonl
log=$root/build/perf/notebook-editable-$stamp.log
fixtures=(woolooTests/NotebookEditableBenchmarks.swift woolooTests/NotebookPreviewBenchmarks.swift woolooTests/MarkdownTableBenchmarks.swift)
python3 $root/scripts/perf_support.py $root $fixtures > $results
# Include bundled renderers and fonts; they can change the result independently of Swift.
# Assets are sources, not fixtures, so their hashes may differ between compared revisions.
assets_digest() { python3 - "$root" <<'PY'
import hashlib, sys
from pathlib import Path
root=Path(sys.argv[1]); digest=hashlib.sha256()
directories=[root/'wooloo/NotebookAssets', root/'Vendor/NotebookPreview']
for path in sorted(p for directory in directories for p in directory.rglob('*') if p.is_file()):
    digest.update(path.relative_to(root).as_posix().encode()+b'\0'); digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}
assets_before=$(assets_digest)
echo "{\"assets_sha256\":\"$assets_before\",\"assets_scope\":[\"wooloo/NotebookAssets\",\"Vendor/NotebookPreview\"]}" >> $results
export TEST_RUNNER_WOOLOO_BENCH_NOTEBOOK_EDITABLE=1 TEST_RUNNER_WOOLOO_BENCH_OUT=$results
export TEST_RUNNER_WOOLOO_BENCH_REPEAT=${WOOLOO_BENCH_REPEAT:-5}
echo "Editable notebook benchmarks (Release) — log: $log"
if ! xcodebuild test -disableAutomaticPackageResolution -skipPackageUpdates -project $root/wooloo.xcodeproj -scheme wooloo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived ONLY_ACTIVE_ARCH=YES \
    -only-testing:woolooTests/NotebookEditableBenchmarks \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_TESTABILITY=YES > $log 2>&1; then
    rg ': error:|Test Case.*failed|TEST FAILED' $log | head -20 || true
    echo "Editable notebook benchmarks failed; see $log" >&2; exit 1
fi
[[ $(assets_digest) == $assets_before ]] || { echo "Notebook assets changed during measurement" >&2; exit 1; }
python3 - "$results" <<'PY'
import json,os,sys
with open(sys.argv[1],'a') as out: out.write(json.dumps({'load_after':os.getloadavg()[0]})+'\n')
PY
python3 $root/scripts/perf_support.py $root $fixtures --verify $results
comparison=()
[[ -f $baseline ]] && comparison=(--baseline $baseline)
python3 $root/scripts/markdown-perf.py $results --kind Notebook $comparison $check
echo "Results: $results"
