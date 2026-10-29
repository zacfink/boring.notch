#!/bin/bash
# Build Zac's fork, sign it ad hoc (no hardened runtime, so the bundled frameworks load), install over /Applications.
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" ENABLE_HARDENED_RUNTIME=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
NEW="build/Build/Products/Release/Boring Notch.app" A=/Applications/boringNotch.app
pkill -9 -f "$A/Contents/MacOS" || true
rm -rf "$A" && ditto "$NEW" "$A"
codesign -d --entitlements :- "$NEW" > /tmp/bn-ent.plist 2>/dev/null
find "$A/Contents/Frameworks" -maxdepth 1 -name "*.framework" -exec codesign --force --deep -s - {} \;
codesign --force -s - "$A/Contents/XPCServices/"*.xpc
codesign --force -s - --entitlements /tmp/bn-ent.plist "$A"
open "$A"
