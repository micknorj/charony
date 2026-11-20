#!/usr/bin/env bash
# Only a maintainer/CI-created disposable simulator is accepted.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${WQ_SIMULATOR_UDID:?Select a disposable, booted iOS simulator}"
source scripts/sources.sh
mkdir -p .work/tests
OUT=$(mktemp -d "$ROOT/.work/tests/ui.XXXXXX")
APP="$OUT/CHUITests.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET_ARCH=$(uname -m)
FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules" -target "$TARGET_ARCH-apple-ios26.0-simulator" -isysroot "$SDK" -Wall -Wextra -Werror -O1)
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" -Dmain=CHProductionMain -c main.m -o "$OUT/main.o"
SOURCES=(WQAccess.m WQScanTask.m WQDiscoveryState.m WQLocalization.m WQLaunchServices.m WQUI.m WQApps.m CHAppData.m)
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" "${FRAMEWORKS[@]}" "${SOURCES[@]}" tests/CHUITests.m "$OUT/main.o" -o "$APP/CHUITests"
cp Info.plist "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleSupportedPlatforms' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.micknorj.charony.ui-fixtures' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CHUITests' "$APP/Info.plist"
codesign --force --sign - "$APP"
BUNDLE=io.github.micknorj.charony.ui-fixtures
xcrun simctl install "$WQ_SIMULATOR_UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$WQ_SIMULATOR_UDID" "$BUNDLE" data)
# Markers must belong to this run. The installed fixture bundle is test-only.
rm -f -- "$DATA/Documents/ready-for-background" "$DATA/Documents/background-paused" \
    "$DATA/Documents/ready-to-terminate" "$DATA/Documents/recovery-passed" "$DATA/Documents/search-navigation.log" "$DATA/Documents/FAIL-"*
wait_marker() {
    local marker=$1
    for ((attempt=0; attempt<60; attempt++)); do
        if compgen -G "$DATA/Documents/FAIL-*" >/dev/null; then
            ls "$DATA/Documents/FAIL-"*
            if [[ -f "$DATA/Documents/search-navigation.log" ]]; then
                cp "$DATA/Documents/search-navigation.log" "$OUT/search-navigation.log"
                cat "$OUT/search-navigation.log"
            fi
            return 1
        fi
        if [[ -f "$DATA/Documents/$marker" ]]; then return 0; fi
        sleep 1
    done
    printf 'UIKit fixture harness timed out waiting for %s\n' "$marker" >&2
    return 1
}
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE"
wait_marker ready-for-background
xcrun simctl launch "$WQ_SIMULATOR_UDID" com.apple.Preferences
wait_marker background-paused
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE"
wait_marker ready-to-terminate
xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE" recover
wait_marker recovery-passed
xcrun simctl io "$WQ_SIMULATOR_UDID" screenshot "$OUT/recovery.png"
xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
printf 'UIKit, lifecycle and cold-relaunch fixtures passed. Artifacts in %s\n' "$OUT"
