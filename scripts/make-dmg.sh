#!/bin/bash
# Builds the app and packages it as dist/ZoomRecorder-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/ZoomRecorder-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto "build/Zoom Recorder.app" "$STAGING/Zoom Recorder.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Zoom Recorder" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

# Keep only the installed app registered with Launch Services.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/build/Zoom Recorder.app" >/dev/null 2>&1 || true
rm -rf "build/Zoom Recorder.app"

echo "Created $DMG"
