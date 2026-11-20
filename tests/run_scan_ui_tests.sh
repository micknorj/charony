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
SOURCES=(WQScanTask.m WQDiscoveryState.m WQLocalization.m WQLaunchServices.m WQUI.m WQApps.m)
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" "${FRAMEWORKS[@]}" "${SOURCES[@]}" tests/CHUITests.m -o "$APP/CHUITests"
cp Info.plist "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleSupportedPlatforms' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.micknorj.charony.ui-fixtures' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CHUITests' "$APP/Info.plist"
xcrun actool icons/AppIcon.icon --compile "$APP" --platform iphonesimulator --minimum-deployment-target 26.0 \
    --target-device iphone --target-device ipad --app-icon AppIcon --standalone-icon-behavior all \
    --output-partial-info-plist "$OUT/icon-info.plist" --errors --warnings --output-format human-readable-text
xcrun assetutil --info "$APP/Assets.car" > "$OUT/icon-assets.json"
python3 scripts/verify_icon.py "$OUT/icon-assets.json"
python3 - "$APP/Info.plist" "$OUT/icon-info.plist" <<'PYICON'
import plistlib, sys
from pathlib import Path
info_path = Path(sys.argv[1])
info = plistlib.loads(info_path.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
info_path.write_bytes(plistlib.dumps(info))
PYICON
codesign --force --sign - "$APP"
BUNDLE=io.github.micknorj.charony.ui-fixtures
xcrun simctl install "$WQ_SIMULATOR_UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$WQ_SIMULATOR_UDID" "$BUNDLE" data)
retain_diagnostics() {
    local diagnostic
    for diagnostic in search-navigation ui-layout ui-phase ui-exception ui-search-context; do
        if [[ -f "$DATA/Documents/$diagnostic.log" ]]; then
            cp "$DATA/Documents/$diagnostic.log" "$OUT/$diagnostic.log"
            cat "$OUT/$diagnostic.log"
        fi
    done
}
wait_marker() {
    local marker=$1
    for ((attempt=0; attempt<60; attempt++)); do
        if compgen -G "$DATA/Documents/FAIL-*" >/dev/null; then
            ls "$DATA/Documents/FAIL-"*
            retain_diagnostics
            return 1
        fi
        if [[ -f "$DATA/Documents/$marker" ]]; then return 0; fi
        sleep 1
    done
    printf 'UIKit fixture harness timed out waiting for %s\n' "$marker" >&2
    retain_diagnostics
    # Diagnostic sampling never turns a missing required marker into success.
    if [[ "${UI_PID:-}" =~ ^[0-9]+$ ]]; then
        sample "$UI_PID" 1 -file "$OUT/ui-hang.log" || true
    fi
    return 1
}
for APPEARANCE in light dark; do
    printf 'UIKit fixtures: device=%s appearance=%s system-text=accessibility-extra-extra-extra-large\n' "$WQ_SIMULATOR_UDID" "$APPEARANCE"
    xcrun simctl ui "$WQ_SIMULATOR_UDID" appearance "$APPEARANCE"
    xcrun simctl ui "$WQ_SIMULATOR_UDID" content_size accessibility-extra-extra-extra-large
    # Markers and diagnostics must belong to this run, not the previous profile.
    rm -f -- "$DATA/Documents/navigation-passed" "$DATA/Documents/mutation-passed" "$DATA/Documents/ready-for-background" "$DATA/Documents/background-paused" \
        "$DATA/Documents/ready-to-terminate" "$DATA/Documents/recovery-passed" \
        "$DATA/Documents/search-navigation.log" "$DATA/Documents/ui-layout.log" "$DATA/Documents/ui-phase.log" "$DATA/Documents/ui-exception.log" "$DATA/Documents/ui-search-context.log" "$DATA/Documents/FAIL-"*
    LAUNCH=$(SIMCTL_CHILD_CH_EXPECTED_APPEARANCE="$APPEARANCE" xcrun simctl launch \
        --stdout="$OUT/$APPEARANCE-stdout.log" --stderr="$OUT/$APPEARANCE-stderr.log" "$WQ_SIMULATOR_UDID" "$BUNDLE")
    printf '%s\n' "$LAUNCH"
    UI_PID=${LAUNCH##*: }
    # Each asserted test group retains the same bound; individual UIKit
    # transitions still fail within 15 seconds. No state is skipped.
    wait_marker navigation-passed
    wait_marker mutation-passed
    wait_marker ready-for-background
    xcrun simctl launch "$WQ_SIMULATOR_UDID" com.apple.Preferences
    wait_marker background-paused
    xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE"
    wait_marker ready-to-terminate
    xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
    LAUNCH=$(SIMCTL_CHILD_CH_EXPECTED_APPEARANCE="$APPEARANCE" xcrun simctl launch \
        --stdout="$OUT/$APPEARANCE-recover-stdout.log" --stderr="$OUT/$APPEARANCE-recover-stderr.log" "$WQ_SIMULATOR_UDID" "$BUNDLE" recover)
    printf '%s\n' "$LAUNCH"
    UI_PID=${LAUNCH##*: }
    wait_marker recovery-passed
    retain_diagnostics
    xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
    printf 'UIKit, mutation, lifecycle and cold-relaunch fixtures: PASS (%s)\n' "$APPEARANCE"
done
printf 'Logs retained in %s\n' "$OUT"
