#!/bin/bash
# Installs the simulator build and photographs every screen using the app's built-in sample content.
set -uo pipefail
app="build/sim/Build/Products/Debug-iphonesimulator/Minutes.app"
device="iPhone 17 Pro Max"
bundle="app.minutes.recorder"
mkdir -p out/shots
: > out/shots.log

xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b > /dev/null
xcrun simctl install "$device" "$app"
xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true

failures=0
shoot() {  # name appearance scenario wait
  xcrun simctl ui "$device" appearance "$2"
  xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
  pid=$(xcrun simctl launch "$device" "$bundle" -demo "$3" 2>>out/shots.log | awk '{print $NF}')
  sleep "$4"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    xcrun simctl io "$device" screenshot "out/shots/$1.png" > /dev/null 2>&1
    sips -Z 1434 "out/shots/$1.png" > /dev/null 2>&1
    echo "ok       $1" | tee -a out/shots.log
  else
    echo "CRASHED  $1" | tee -a out/shots.log
    failures=$((failures + 1))
  fi
}

shoot home light home 12
for screen in empty recording paused processing waiting failed notes transcript speakers settings; do
  shoot "$screen" light "$screen" 5
done
for screen in home recording notes transcript speakers; do
  shoot "$screen-dark" dark "$screen" 5
done

# Keep any crash reports so a failure can be diagnosed from the published results.
cp ~/Library/Logs/DiagnosticReports/Minutes*.ips out/ 2>/dev/null || true
exit $failures
