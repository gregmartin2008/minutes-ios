#!/bin/bash
# Builds the app with Xcode and leaves a short summary of the result in out/.
# usage: ci_xcodebuild.sh sim|device
set -uo pipefail
kind="$1"
mkdir -p out build
# The bundle identifier the app is built with. A re-signing tool that changes it breaks the
# continued-processing task (its identifier must begin with the installed bundle id), so the
# owner can set MINUTES_BUNDLE_ID to the id their tool uses and install with that id instead.
bundle_id="${MINUTES_BUNDLE_ID:-app.minutes.recorder}"
if [ "$kind" = sim ]; then
  destination='platform=iOS Simulator,name=iPhone 17 Pro Max'
  configuration=Debug
  # Signed "to run locally" (no certificate needed), so the simulator build can use the Keychain.
  signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)
else
  destination='generic/platform=iOS'
  configuration=Release
  # Left unsigned: the installer (Sideloadly, AltStore) signs it with the owner's Apple ID.
  signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
fi
xcodebuild -project Minutes.xcodeproj -scheme Minutes -configuration "$configuration" \
  -destination "$destination" -derivedDataPath "build/$kind" -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation \
  "${signing[@]}" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  build > "build/$kind.log" 2>&1
status=$?
grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" "build/$kind.log" | sort -u | head -200 > "out/$kind-build.log"
grep -A7 "error:" "build/$kind.log" | head -500 > "out/$kind-errors.log" || true
grep -E "^/.*App/Sources.*warning:" "build/$kind.log" | sort -u | head -120 > "out/$kind-warnings.log" || true
tail -40 "build/$kind.log" | cut -c1-300 > "out/$kind-tail.log"
cat "out/$kind-build.log"
exit $status
