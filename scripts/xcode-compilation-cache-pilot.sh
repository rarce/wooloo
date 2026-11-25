#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$(pwd -P)
pilot="$root/build/xcode-compilation-cache-pilot"
derived="$pilot/DerivedData"
cas="$pilot/CAS"
packages="$root/build/DerivedData/SourcePackages"
mkdir -p "$pilot"

xcode=(xcodebuild -project wooloo.xcodeproj -scheme wooloo
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$packages"
    -disableAutomaticPackageResolution -skipPackageUpdates)

phase=${1:-}
case "$phase" in
    prepare)
        sh scripts/bundle-herdr.sh --prepare
        "${xcode[@]}" -resolvePackageDependencies COMPILATION_CACHE_ENABLE_CACHING=NO
        exit 0
        ;;
    control)
        cache_settings=(COMPILATION_CACHE_ENABLE_CACHING=NO)
        ;;
    cold|warm)
        if [ "$phase" = cold ]; then
            test ! -e "$cas"
        else
            test -d "$cas"
        fi
        cache_settings=(COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$cas"
            COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES)
        ;;
    *)
        printf 'Usage: %s prepare|control|cold|warm\n' "$0" >&2
        exit 2
        ;;
esac

# Reset this pilot's DerivedData. The measured build starts with package downloads and the
# selected CAS state. Both live outside DerivedData, at the same paths on each runner.
rm -rf "$derived"
status=0
SECONDS=0
"${xcode[@]}" test -configuration Debug -destination 'platform=macOS' \
    -showBuildTimingSummary -parallel-testing-enabled NO \
    -only-testing:woolooTests/WorkspaceTreeTests \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
    "${cache_settings[@]}" \
    SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    2>&1 | tee "$pilot/$phase.log" || status=$?
elapsed=$SECONDS
audit_status=0
if [ "$status" -eq 0 ]; then
    python3 scripts/concurrency_audit.py "$pilot/$phase.log" 2>&1 \
        | tee "$pilot/$phase-audit.log" || audit_status=$?
fi

# Swift Build versions differ in whether they emit the short marker, the diagnostic, or both.
# Use the larger count for each result to avoid double counting.
read -r hits misses < <(awk '
    /^Cache hit$/ { short_hits++ }
    /^Cache miss$/ { short_misses++ }
    /: replay cache hit$/ { replay_hits++ }
    /: replay cache miss$/ { replay_misses++ }
    END {
        print (short_hits > replay_hits ? short_hits : replay_hits) + 0,
              (short_misses > replay_misses ? short_misses : replay_misses) + 0
    }
' "$pilot/$phase.log")

cache_kib=0
if [ -d "$cas" ]; then
    cache_kib=$(du -sk "$cas" | cut -f 1)
fi
{
    printf '### Xcode compilation cache · %s\n\n' "$phase"
    printf '| Build + test (s) | Cache on disk (KiB) | Cache hit remarks | Cache miss remarks | Xcode status | Audit |\n'
    printf '| ---: | ---: | ---: | ---: | ---: | --- |\n'
    audit_result=skipped
    if [ "$status" -eq 0 ]; then
        audit_result=passed
        if [ "$audit_status" -ne 0 ]; then
            audit_result=failed
        fi
    fi
    printf '| %s | %s | %s | %s | %s | %s |\n' "$elapsed" "$cache_kib" "$hits" "$misses" "$status" "$audit_result"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$audit_status" -ne 0 ]; then
    printf '::warning::The concurrency audit failed on the %s sample. See its audit log.\n' "$phase"
fi
exit "$status"
