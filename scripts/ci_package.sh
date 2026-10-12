#!/bin/bash
# Wraps the device build as an .ipa that can be installed with Sideloadly or AltStore, which sign it
# with the installer's own Apple ID. Publishes it as the repository's "latest" release.
set -euo pipefail
app="build/device/Build/Products/Release-iphoneos/Minutes.app"
test -d "$app"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R "$app" build/ipa/Payload/
(cd build/ipa && zip -qry Minutes.ipa Payload)
{
  echo "size: $(du -h build/ipa/Minutes.ipa | cut -f1)"
  echo "sha256: $(shasum -a 256 build/ipa/Minutes.ipa | cut -d' ' -f1)"
  echo "commit: ${GITHUB_SHA:-local}"
  echo "architectures: $(lipo -archs "$app/Minutes")"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :MinimumOSVersion" -c "Print :UIBackgroundModes" \
    -c "Print :BGTaskSchedulerPermittedIdentifiers" -c "Print :NSMicrophoneUsageDescription" "$app/Info.plist"
} | tee out/ipa.txt

if [ "${1:-}" = "--release" ]; then
  notes="Unsigned build of Minutes for iPhone (iOS 26 or later), from commit ${GITHUB_SHA:0:7}. Install Minutes.ipa with Sideloadly; see the README."
  gh release delete latest --cleanup-tag -y 2>/dev/null || true
  gh release create latest build/ipa/Minutes.ipa --target "$GITHUB_SHA" --title "Minutes for iPhone" --notes "$notes"
  echo "released" | tee -a out/ipa.txt
fi
