#!/bin/bash
# Prints the name of the iPhone simulator to use: the newest "Pro Max" the build machine has,
# else any iPhone. The runner image renames its simulators with each iOS release.
# Set MINUTES_SIMULATOR to force one.
set -uo pipefail
if [ -n "${MINUTES_SIMULATOR:-}" ]; then echo "$MINUTES_SIMULATOR"; exit 0; fi
names=$(xcrun simctl list devices available -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
out = []
for runtime, devices in d.get("devices", {}).items():
    if "iOS" not in runtime: continue
    for dev in devices:
        if dev.get("isAvailable", True) and dev["name"].startswith("iPhone"):
            out.append((runtime, dev["name"]))
# Newest runtime first, Pro Max before Pro before plain.
def rank(item):
    runtime, name = item
    return (runtime, "Pro Max" in name, "Pro" in name, name)
for runtime, name in sorted(out, key=rank, reverse=True):
    print(name)
')
first=$(echo "$names" | head -1)
if [ -z "$first" ]; then echo "iPhone 17 Pro Max"; else echo "$first"; fi
