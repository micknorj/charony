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
    local name=$1 rendition=$2 strength=$3
    "$TOOL" icons/AppIcon.icon --export-image --output-file "$OUT/$name.png" \
        --platform iOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 \
        --light-angle -45 --tint-color 0.58 --tint-strength "$strength"
}
render default Default 0
render dark Dark 0
render mono-light TintedLight 0
render mono-dark TintedDark 0
render tinted-light TintedLight 0.7
render tinted-dark TintedDark 0.7
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit tests/CHIconTests.m -o "$OUT/native-icon-tests"
"$OUT/native-icon-tests" "$OUT/default.png" "$OUT/dark.png" "$OUT/mono-light.png" \
    "$OUT/mono-dark.png" "$OUT/tinted-light.png" "$OUT/tinted-dark.png"
