#!/bin/bash
# Builds the app with Xcode and leaves a short summary of the result in out/.
# usage: ci_xcodebuild.sh sim|device
set -uo pipefail
kind="$1"
mkdir -p out build
if [ "$kind" = sim ]; then
  destination='platform=iOS Simulator,name=iPhone 17 Pro Max'
  configuration=Debug
else
  destination='generic/platform=iOS'
  configuration=Release
fi
xcodebuild -project Minutes.xcodeproj -scheme Minutes -configuration "$configuration" \
  -destination "$destination" -derivedDataPath "build/$kind" -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "build/$kind.log" 2>&1
status=$?
grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" "build/$kind.log" | sort -u | head -200 > "out/$kind-build.log"
grep -A7 "error:" "build/$kind.log" | head -500 > "out/$kind-errors.log" || true
grep -E "^/.*App/Sources.*warning:" "build/$kind.log" | sort -u | head -120 > "out/$kind-warnings.log" || true
tail -40 "build/$kind.log" | cut -c1-300 > "out/$kind-tail.log"
cat "out/$kind-build.log"
exit $status
