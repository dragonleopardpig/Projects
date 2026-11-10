#!/usr/bin/env python3
import sys, json, subprocess

if len(sys.argv) < 2:
    sys.exit(0)

target = sys.argv[1].lower()

if target == "open":
    subprocess.call(["/home/thinky/.local/bin/filelu-toggle"])
    sys.exit(0)

try:
    watcher = subprocess.check_output(
        ["busctl", "--user", "get-property", "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"],
        text=True
    )
except Exception as e:
    sys.exit(1)

bus = None
for part in watcher.split('"'):
    if "FileLu" in part or ":1." in part:
        candidate = part.split("/")[0]
        try:
            subprocess.check_output(["busctl", "--user", "call", candidate, "/MenuBar", "com.canonical.dbusmenu", "AboutToShow", "i", "0"], stderr=subprocess.DEVNULL)
            bus = candidate
            break
        except Exception:
            pass

if not bus:
    sys.exit(1)

try:
    out = subprocess.check_output(
        ["busctl", "--user", "--json=pretty", "call", bus, "/MenuBar", "com.canonical.dbusmenu", "GetLayout", "iias", "0", "--", "-1", "0"],
        text=True
    )
    data = json.loads(out)
    items = data["data"][1][2]
except Exception as e:
    sys.exit(1)

# Keywords to match
match_keywords = {
    "pause": ["pause", "resume"],
    "resume": ["resume", "pause"],
    "upload": ["upload"],
    "unlock": ["unlock", "lock"],
    "lock": ["lock", "unlock"],
    "quit": ["quit", "exit"],
}

keywords = match_keywords.get(target, [target])

for it in items:
    id_val = it["data"][0]
    lbl = it["data"][1].get("label", {}).get("data", "").lower()
    if any(k in lbl for k in keywords):
        subprocess.call(["busctl", "--user", "call", bus, "/MenuBar", "com.canonical.dbusmenu", "Event", "isvu", str(id_val), "clicked", "s", "", "0"])
        break
