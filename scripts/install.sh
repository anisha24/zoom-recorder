#!/bin/bash
# Builds the app, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "$@"

DEST="/Applications/Zoom Recorder.app"
osascript -e 'tell application id "com.anaralik.ZoomRecorder" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto "build/Zoom Recorder.app" "$DEST"

# Drop the build copy so Spotlight and Launchpad only list the installed app.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/build/Zoom Recorder.app" >/dev/null 2>&1 || true
rm -rf "build/Zoom Recorder.app"
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

echo "Installed $DEST"
open "$DEST"
