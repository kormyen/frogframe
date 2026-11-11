#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Keychain remembers the signing identity. Ad-hoc signatures instead identify
# each build by its hash, which invalidates saved access after an update.
task_identity="${FROGFRAME_SIGNING_IDENTITY:-${PHOTOTAB_SIGNING_IDENTITY:-Apple Development}}"
if [ "$task_identity" = "-" ]; then
    printf '%s\n' 'Frogframe needs a persistent signing identity for saved Keychain access.' >&2
    exit 1
fi
swift build -c release --package-path macos
task_bin="$(swift build -c release --package-path macos --show-bin-path)"
task_app="$(pwd)/macos/build/Frogframe.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/Frogframe" "$task_app/Contents/MacOS/Frogframe"
cp macos/Info.plist "$task_app/Contents/Info.plist"
xcrun actool macos/Resources/FrogframePhoto.icon \
    --compile "$task_app/Contents/Resources" --platform macosx --target-device mac \
    --minimum-deployment-target 26.0 --app-icon FrogframePhoto \
    --output-partial-info-plist "$(pwd)/macos/build/icon-info.plist"
codesign --force --sign "$task_identity" --identifier nz.kor.frogframe.manager "$task_app"
codesign --verify --strict "$task_app"
printf '%s\n' "$task_app"
