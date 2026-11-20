#!/usr/bin/env bash
# Development IPA, ad-hoc signed. Re-sign with an App Group before sideloading.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
source scripts/sources.sh
bash tests/run_all_tests.sh
FINAL_IPA=${CHARONY_FINAL_IPA:-"$ROOT/charony.ipa"}
[[ "$FINAL_IPA" == /* ]] || FINAL_IPA="$ROOT/$FINAL_IPA"
if [[ ! -d "$(dirname -- "$FINAL_IPA")" ]]; then
    echo 'The IPA output parent directory must exist.' >&2
    exit 1
fi
OUT=$(mktemp -d "$(dirname -- "$FINAL_IPA")/.charony-build.XXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
APP="$OUT/Payload/charony.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_OS=$(python3 - <<'PY'
import plistlib
from pathlib import Path
print(plistlib.loads(Path('Info.plist').read_bytes())['MinimumOSVersion'])
PY
)
if [[ "$MIN_OS" != 26.0 ]]; then
    echo 'MinimumOSVersion must remain 26.0.' >&2
    exit 1
fi
xcrun --sdk iphoneos clang -fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules" \
    -arch arm64 "-miphoneos-version-min=$MIN_OS" -isysroot "$SDK" -Wall -Wextra -Werror -O2 \
    "${FRAMEWORKS[@]}" "${SOURCES[@]}" -o "$APP/charony"
BINARY_ARCHITECTURES=$(xcrun lipo -archs "$APP/charony")
if [[ "$BINARY_ARCHITECTURES" != arm64 ]]; then
    echo 'Expected exactly arm64 in the development executable.' >&2
    exit 1
fi
cp Info.plist LICENSE NOTICE.md "$APP/"
# Compile the editable Icon Composer project; no flattened source/fallback catalog.
xcrun actool icons/AppIcon.icon --compile "$APP" --platform iphoneos --minimum-deployment-target "$MIN_OS" \
    --target-device iphone --target-device ipad --app-icon AppIcon --standalone-icon-behavior all \
    --output-partial-info-plist "$OUT/icon-info.plist" --errors --warnings --output-format human-readable-text
if [[ ! -f "$APP/Assets.car" ]]; then
    echo 'Asset catalog was not compiled.' >&2
    exit 1
fi
xcrun assetutil --info "$APP/Assets.car" > "$OUT/icon-assets.json"
python3 scripts/verify_icon.py "$OUT/icon-assets.json"
python3 - "$APP/Info.plist" "$OUT/icon-info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
target = Path(sys.argv[1])
info = plistlib.loads(target.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
target.write_bytes(plistlib.dumps(info))
PY
python3 scripts/privacy_audit.py --binary "$APP/charony"
plutil -convert binary1 "$APP/Info.plist"
codesign --force --sign - --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - --xml "$APP" > "$OUT/signed-entitlements.plist"
python3 - "$OUT/signed-entitlements.plist" <<'PY'
import plistlib,sys
from pathlib import Path
signed=plistlib.loads(Path(sys.argv[1]).read_bytes())
expected=plistlib.loads(Path('entitlements.plist').read_bytes())
if signed != expected:
    raise SystemExit('Signed entitlements differ from the reviewed App Group policy')
PY
(cd "$OUT" && zip -qry "$OUT/charony.ipa" Payload)
python3 scripts/verify_ipa.py "$OUT/charony.ipa"
mkdir "$OUT/unpacked"
unzip -q "$OUT/charony.ipa" -d "$OUT/unpacked"
codesign --verify --deep --strict "$OUT/unpacked/Payload/charony.app"
python3 - "$OUT/charony.ipa" "$FINAL_IPA" <<'PY'
import os, sys
os.replace(sys.argv[1], sys.argv[2])
PY
printf 'Development IPA written to %s. Native icon compiled; final signing and physical-device gates remain pending.\n' "$FINAL_IPA"
