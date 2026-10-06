#!/bin/bash
# Builds build/Zoom Recorder.app. Set SIGN_IDENTITY to a codesigning identity so macOS
# privacy permissions survive rebuilds. Falls back to the identity from
# scripts/create-signing-cert.sh, then to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release "$@"

APP="build/Zoom Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ZoomRecorder "$APP/Contents/MacOS/ZoomRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

LOCAL_IDENTITY="Zoom Recorder Local Signing"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
    IDENTITY="$LOCAL_IDENTITY"
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.anaralik.ZoomRecorder "$APP"

echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
