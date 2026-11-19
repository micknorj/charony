#!/usr/bin/env bash
# All host-side fixtures are disposable; no iOS app/container operation is run.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/.work/tests"
OUT=$(mktemp -d "$ROOT/.work/tests/all.XXXXXX")
mkdir -p "$OUT/fixtures"
export TMPDIR="$OUT/fixtures/"
export PYTHONDONTWRITEBYTECODE=1
MAC_SDK=$(xcrun --sdk macosx --show-sdk-path)
ASAN_FLAG=""
if [[ "${WQ_ASAN:-0}" == "1" ]]; then
    ASAN_FLAG="-fsanitize=address -fno-omit-frame-pointer"
    export ASAN_OPTIONS="detect_leaks=0"
fi

# Every test program runs with a time limit (seconds; WQ_TEST_TIMEOUT
# overrides), so one hung fixture can't stall the suite or build preflight.
TEST_TIMEOUT=${WQ_TEST_TIMEOUT:-900}

# Runs "$@" and kills it after $1 seconds. Exit status 124 means it timed out.
run_bounded() {
    local limit=$1
    shift
    local fired
    fired=$(mktemp "${TMPDIR:-/tmp}/wq-timeout.XXXXXX")
    rm -f -- "$fired"
    "$@" &
    local pid=$!
    (
        sleep "$limit" &
        local sleeper=$!
        trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
        wait "$sleeper" 2>/dev/null || exit 0
        : > "$fired"
        kill -TERM "$pid" 2>/dev/null || exit 0
        sleep 5
        kill -KILL "$pid" 2>/dev/null || true
    ) &
    local watchdog=$!
    local status=0
    wait "$pid" 2>/dev/null || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if [[ -e "$fired" ]]; then
        rm -f -- "$fired"
        return 124
    fi
    return "$status"
}

compile_run() {
    local name=$1
    shift
    printf '\n== %s ==\n' "$name"
    xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" \
        -isysroot "$MAC_SDK" -Wall -Wextra -Werror $ASAN_FLAG -I. "$@" \
        -framework Foundation -o "$OUT/$name" > "$OUT/$name-build.log" 2>&1 || {
            cat "$OUT/$name-build.log" >&2
            return 1
        }
    local status=0
    run_bounded "$TEST_TIMEOUT" "$OUT/$name" > "$OUT/$name-run.log" 2>&1 || status=$?
    if [[ $status -ne 0 ]]; then
        cat "$OUT/$name-run.log" >&2
        if [[ $status -eq 124 ]]; then
            echo "TIMEOUT: $name did not finish within ${TEST_TIMEOUT}s (last phase above)" >&2
        fi
        return 1
    fi
    tail -3 "$OUT/$name-run.log"
}

compile_run WQEnglishPresentationTests WQLocalization.m tests/WQEnglishPresentationTests.m
compile_run WQAccessSafetyTests tests/WQAccessSafetyTests.m
compile_run WQPurgeTests WQLocalization.m WQDiscoveryState.m tests/WQPurgeTests.m
compile_run CHAppDataTests WQLocalization.m WQDiscoveryState.m tests/CHAppDataTests.m
compile_run WQAccessMeasureTests WQLocalization.m WQDiscoveryState.m tests/WQAccessMeasureTests.m
compile_run WQAccessScanTests WQLocalization.m WQDiscoveryState.m tests/WQAccessScanTests.m
compile_run WQScanRecoveryTests -DWQ_ACCESS_TESTING WQScanTask.m WQLocalization.m WQDiscoveryState.m tests/WQScanRecoveryTests.m
compile_run WQScanInodeCheckpointTests WQLocalization.m WQDiscoveryState.m tests/WQScanInodeCheckpointTests.m
compile_run WQCacheSafetyTests tests/WQCacheSafetyTests.m
compile_run WQLaunchServicesTests -DWQ_LS_TESTING WQLaunchServices.m WQLocalization.m WQDiscoveryState.m tests/WQLaunchServicesTests.m

printf '\n== Python release and static UI checks ==\n'
python_status=0
run_bounded "$TEST_TIMEOUT" python3 -m unittest discover -s tests -p 'test_*.py' -v > "$OUT/python-tests.log" 2>&1 || python_status=$?
if [[ $python_status -ne 0 ]]; then
    cat "$OUT/python-tests.log" >&2
    [[ $python_status -eq 124 ]] && echo "TIMEOUT: Python tests did not finish within ${TEST_TIMEOUT}s" >&2
    exit 1
fi
tail -5 "$OUT/python-tests.log"
python3 scripts/privacy_audit.py | tee "$OUT/privacy.log"

if [[ "${WQ_SKIP_IOS_CHECK:-0}" != 1 ]]; then
    printf '\n== Strict iOS arm64 syntax/link checks ==\n'
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' Info.plist)
    source scripts/sources.sh
    FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules-ios" -arch arm64 "-miphoneos-version-min=$MIN_OS" -isysroot "$IOS_SDK" -Wall -Wextra -Werror -O2)
    xcrun --sdk iphoneos clang -fsyntax-only "${FLAGS[@]}" "${SOURCES[@]}" > "$OUT/ios-syntax.log" 2>&1 || {
        cat "$OUT/ios-syntax.log" >&2
        exit 1
    }
    xcrun --sdk iphoneos clang "${FLAGS[@]}" "${FRAMEWORKS[@]}" \
        "${SOURCES[@]}" -o "$OUT/charony-link-check" > "$OUT/ios-link.log" 2>&1 || {
        cat "$OUT/ios-link.log" >&2
        exit 1
    }
    printf 'iOS syntax and link checks: PASS\n'
else
    printf '\niOS syntax/link checks explicitly skipped (WQ_SKIP_IOS_CHECK=1).\n'
fi
plutil -lint Info.plist entitlements.plist | tee "$OUT/plist-lint.log"
bash -n build.sh scripts/sources.sh tests/run_all_tests.sh tests/run_scan_ui_tests.sh
printf '\nAll requested regression suites passed. Logs retained in: %s\n' "$OUT"
