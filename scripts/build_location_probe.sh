#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project NMEAPad.xcodeproj -target LocationProbe -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/.build/Products" OBJROOT="$PWD/.build/Intermediates" build
ldid -SLocationProbe/entitlements.plist .build/Products/Release-iphoneos/LocationProbe.app/LocationProbe
probe_stage=$(mktemp -d /tmp/nmeapad-probe-ipa.XXXXXX)
mkdir -p "$probe_stage/Payload" dist
cp -R .build/Products/Release-iphoneos/LocationProbe.app "$probe_stage/Payload/"
probe_output="$PWD/dist/LocationProbe.ipa"
(cd "$probe_stage" && zip -qry "$probe_output" Payload)
shasum -a 256 "$probe_output"
# Retain the small staging directory for inspection, avoiding destructive cleanup.
