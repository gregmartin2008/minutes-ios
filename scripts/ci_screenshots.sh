#!/bin/bash
# Installs the simulator build and photographs every screen using the app's built-in sample content.
# Every simulator command runs under a time limit, and progress is logged as it happens, so a
# stalled simulator shows up in the published log instead of hanging the build.
set -uo pipefail
app="build/sim/Build/Products/Debug-iphonesimulator/Minutes.app"
device="iPhone 17 Pro Max"
bundle="app.minutes.recorder"
mkdir -p out/shots
log=out/shots.log
: > "$log"
note() { echo "$(date -u +%T) $*" | tee -a "$log"; }

limited() {  # limited <seconds> <command...>: runs the command, killing it if it takes too long
  local limit=$1; shift
  "$@" &
  local pid=$!
  ( sleep "$limit"; kill -9 "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return $status
}

note "booting $device"
limited 60 xcrun simctl boot "$device" >> "$log" 2>&1 || true
limited 420 xcrun simctl bootstatus "$device" > /dev/null 2>&1 || note "bootstatus did not finish cleanly"
note "installing"
limited 180 xcrun simctl install "$device" "$app" >> "$log" 2>&1 || { note "install failed"; exit 1; }
limited 30 xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >> "$log" 2>&1 || true

failures=0
missing=0
shoot() {  # name appearance scenario wait
  limited 30 xcrun simctl ui "$device" appearance "$2" >> "$log" 2>&1 || true
  limited 30 xcrun simctl terminate "$device" "$bundle" > /dev/null 2>&1 || true
  local pid=""
  local attempt
  for attempt in 1 2 3; do
    # The first launch after installing can take the simulator a long time; try again rather than fail.
    if limited 90 xcrun simctl launch "$device" "$bundle" -demo "$3" > out/launch.txt 2>> "$log"; then
      pid=$(awk '{print $NF}' out/launch.txt 2>/dev/null | tail -1)
      [ -n "$pid" ] && break
    fi
    note "launch of $1 did not return (attempt $attempt)"
    limited 30 xcrun simctl terminate "$device" "$bundle" > /dev/null 2>&1 || true
  done
  sleep "$4"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # The simulator sometimes stalls on a capture; that is not a fault in the app, so try again.
    local captured=no
    for attempt in 1 2 3; do
      if limited 60 xcrun simctl io "$device" screenshot "out/shots/$1.png" > /dev/null 2>&1 && [ -s "out/shots/$1.png" ]; then
        captured=yes
        break
      fi
      sleep 3
    done
    if [ "$captured" = yes ]; then
      sips -Z 1434 "out/shots/$1.png" > /dev/null 2>&1
      note "ok       $1"
    else
      note "NO IMAGE $1 (the app was running; the simulator did not return a picture)"
      missing=$((missing + 1))
    fi
  else
    note "CRASHED  $1 (pid '$pid')"
    failures=$((failures + 1))
  fi
}

shoot home light home 15
for screen in empty recording paused processing waiting failed notes transcript speakers settings vocabulary; do
  shoot "$screen" light "$screen" 5
done
for screen in home recording notes transcript speakers; do
  shoot "$screen-dark" dark "$screen" 5
done
rm -f out/launch.txt

# Keep any crash reports so a failure can be diagnosed from the published results.
cp ~/Library/Logs/DiagnosticReports/Minutes*.ips out/ 2>/dev/null || true
note "done: $failures screens crashed, $missing pictures missing"
# Only a screen that crashed fails the build; a missing picture or two is the simulator's doing.
[ "$missing" -le 3 ] || failures=$((failures + 1))
exit $failures
