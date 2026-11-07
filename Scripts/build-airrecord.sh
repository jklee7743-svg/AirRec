#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash Scripts/build-native.sh
bash Tests/Policy/run.sh
xcodegen generate --quiet
xcodebuild build -project AirRec.xcodeproj -scheme AirRec -configuration Release \
  -derivedDataPath build/airrec-ios -destination 'generic/platform=iOS' ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='AIRRECORD_AUTOMATION' \
  MARKETING_VERSION=1.3.0 CURRENT_PROJECT_VERSION=29.1
APP="$ROOT/build/airrec-ios/Build/Products/Release-iphoneos/AirRec.app"
[[ -d "$APP" ]] || { echo "App bundle missing" >&2; exit 1; }
# This target must remain a normal app with no XCTest dependency or test plugin.
if find "$APP" -name '*.xctest' -print -quit | grep -q .; then exit 1; fi
if find "$APP" -name '*.appex' -print -quit | grep -q .; then
  echo "The location standby build must not contain Helper extensions" >&2; exit 1
fi
if otool -L "$APP/AirRec" | grep -E 'XCTest|XCUIAutomation'; then exit 1; fi
find "$APP" -type f \( -name '*.dylib' -o -name '*.debug.dylib' \) -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/Extras/release"
# A fresh staging directory and archive prevent an older Helper from surviving
# a local rebuild that previously packaged an extension.
PAYLOAD="$(mktemp -d "$ROOT/build/airrec-payload.XXXXXX")"
[[ "$PAYLOAD" == "$ROOT/build/airrec-payload."* ]] || exit 1
trap 'rm -rf -- "$PAYLOAD"' EXIT
mkdir "$PAYLOAD/Payload"
cp -R "$APP" "$PAYLOAD/Payload/"
rm -f -- "$ROOT/Extras/release/AirRec-unsigned.ipa"
(cd "$PAYLOAD" && zip -qr "$ROOT/Extras/release/AirRec-unsigned.ipa" Payload)
python3 Scripts/verify-airrecord-ipa.py Extras/release/AirRec-unsigned.ipa
echo 'AirRec 1.3.0 build 29.1 packaged; incoming-call wait action and experimental incoming options.'
