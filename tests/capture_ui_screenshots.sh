#!/usr/bin/env bash
# Build a fixture host from the reviewed production UIKit controllers.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${SIMULATOR_RUNTIME:?Use the verified available simulator runtime}"
mkdir -p .work/tests
OUT=$(mktemp -d "$ROOT/.work/tests/gallery.XXXXXX")
APP="$OUT/CharonyGallery.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules" -target "$ARCH-apple-ios26.0-simulator" -isysroot "$SDK" -Wall -Wextra -Werror -O1)
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" -framework UIKit -framework Foundation -framework Security \
    WQScanTask.m WQDiscoveryState.m WQLocalization.m WQLaunchServices.m WQUI.m WQApps.m tests/CHUIScreenshots.m \
    -o "$APP/CharonyGallery"
python3 - "$APP/Info.plist" <<'PY'
from pathlib import Path
import plistlib,sys
info=plistlib.loads(Path('Info.plist').read_bytes())
info.pop('CFBundleSupportedPlatforms',None)
info.update(CFBundleIdentifier='io.github.micknorj.charony.gallery',CFBundleExecutable='CharonyGallery',CFBundleDisplayName='charony (fixtures)')
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
python3 tests/capture_ui_screenshots.py --app "$APP" --runtime "$SIMULATOR_RUNTIME" --output "$ROOT/.work/ui-gallery"
