#!/usr/bin/env bash
# Render the real editable project with Apple's renderer, never a recreated icon.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/.ci-results/icons"
mkdir -p "$OUT"
DEV=${DEVELOPER_DIR:-$(xcode-select -p)}
TOOL="${DEV%/Contents/Developer}/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$TOOL" --version | tee "$OUT/tool-version.log"
render() {
    local name=$1 rendition=$2
    shift 2
    "$TOOL" icons/AppIcon.icon --export-image --output-file "$OUT/$name.png" \
        --platform iOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 \
        --light-angle -45 "$@"
}
render default Default
render dark Dark
render clear-light ClearLight
render clear-dark ClearDark
render tinted-light TintedLight --tint-color 0.58 --tint-strength 0.7
render tinted-dark TintedDark --tint-color 0.58 --tint-strength 0.7
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit tests/CHIconTests.m -o "$OUT/native-icon-tests"
"$OUT/native-icon-tests" "$OUT/default.png" "$OUT/dark.png" "$OUT/clear-light.png" \
    "$OUT/clear-dark.png" "$OUT/tinted-light.png" "$OUT/tinted-dark.png"
