#!/usr/bin/env bash
# elm-datasource-matrix: build a device x datasource usage matrix for every
# datasource whose name matches a pattern. Rows are devices, columns are the
# matching datasources, cells are a tick (used) or X (not used).
#
# Usage:
#   elm-datasource-matrix.sh [PATTERN] [--profile PROFILE] [-i] [--csv]
#   elm-datasource-matrix.sh                 # PATTERN defaults to 'NTP'
#   elm-datasource-matrix.sh NTP --profile prod
#   elm-datasource-matrix.sh ntp -i          # case-insensitive match
#
# Arguments:
#   PATTERN             substring to match in the datasource NAME.
#                       Default: 'NTP'.
#
# Options:
#   --profile PROFILE   elm credential profile; defaults to 'config' (same
#                       default as elm -- reads config.ini, the sandbox).
#   -i, --ignore-case   match PATTERN case-insensitively. By default the match
#                       is case-SENSITIVE so that 'NTP' matches NTPv4/Cisco_NTP
#                       but NOT substrings like AccessPoi[ntP]erformance or
#                       OverCurre[ntP]rotectors. Pass -i to widen the match.
#   --csv               emit CSV (device,<datasource names...>) instead of the
#                       aligned grid. Cells are 1/0. Good for spreadsheets.
#   -h, --help          show this help and exit.
#
# How it works (efficient -- N_datasources API calls, not N_devices):
#   1. DatasourceList -F name~PATTERN          -> candidate datasources
#      (server-side ~ filter is case-insensitive; we then refine client-side
#       unless -i is given).
#   2. AssociatedDeviceListByDataSourceId --id  -> devices per datasource.
#   3. Pivot into a device x datasource matrix.
#
# Datasources with zero associated devices are dropped (empty columns). Only
# devices that use at least one matching datasource appear as rows.
#
# Status messages go to stderr; the table/CSV goes to stdout.
#
# NOTE: usage here means "the datasource is applied to the device" per LM's
# /setting/datasources/{id}/devices endpoint -- the live applied set, NOT the
# 24h-stale auto.activedatasources property.
set -euo pipefail

PATTERN="NTP"
PROFILE="config"
IGNORE_CASE=0
CSV=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -i|--ignore-case) IGNORE_CASE=1; shift ;;
    --csv) CSV=1; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) PATTERN="$1"; shift ;;
  esac
done

command -v elm >/dev/null 2>&1 || { echo "elm not found on PATH" >&2; exit 1; }

echo "profile: $PROFILE   pattern: '$PATTERN'   match: $([ $IGNORE_CASE -eq 1 ] && echo case-insensitive || echo case-sensitive)" >&2

# Step 1: candidate datasources (server-side filter is case-insensitive).
DS_JSON="$(elm --profile "$PROFILE" -f json DatasourceList -F "name~${PATTERN}" -f id,name -s0 2>/dev/null || true)"

PATTERN="$PATTERN" IGNORE_CASE="$IGNORE_CASE" PROFILE="$PROFILE" CSV="$CSV" \
python3 - "$DS_JSON" <<'PY'
import json, os, subprocess, sys

pattern = os.environ["PATTERN"]
ignore  = os.environ["IGNORE_CASE"] == "1"
profile = os.environ["PROFILE"]
as_csv  = os.environ["CSV"] == "1"

try:
    cands = json.loads(sys.argv[1]).get("DatasourceList", [])
except Exception:
    cands = []

# Client-side refine: server ~ is case-insensitive; honour case unless -i.
needle = pattern if not ignore else pattern.lower()
def matches(name):
    hay = name if not ignore else name.lower()
    return needle in hay
cands = [d for d in cands if matches(d["name"])]

if not cands:
    print(f"no datasources match '{pattern}'", file=sys.stderr)
    sys.exit(0)

# Step 2: devices per datasource.
ds_devices = []   # (datasource_name, {device_id: device_name})
for d in sorted(cands, key=lambda x: x["name"].lower()):
    out = subprocess.run(
        ["elm", "--profile", profile, "-f", "json",
         "AssociatedDeviceListByDataSourceId", "--id", str(d["id"]), "-s0"],
        capture_output=True, text=True)
    try:
        devs = json.loads(out.stdout).get("AssociatedDeviceListByDataSourceId", [])
    except Exception:
        devs = []
    dmap = {x["id"]: (x.get("displayName") or x.get("name") or str(x["id"])) for x in devs}
    if dmap:                       # drop empty columns
        ds_devices.append((d["name"], dmap))

if not ds_devices:
    print(f"{len(cands)} datasource(s) matched '{pattern}' but none are applied to any device", file=sys.stderr)
    sys.exit(0)

# Build the device universe (rows = devices using >=1 matching datasource).
dev_names = {}
for _, dmap in ds_devices:
    dev_names.update(dmap)
devices = sorted(dev_names.items(), key=lambda kv: kv[1].lower())   # (id, name)

cols = [name for name, _ in ds_devices]
used = {name: set(dmap.keys()) for name, dmap in ds_devices}

print(f"{len(devices)} device(s) x {len(cols)} datasource(s)", file=sys.stderr)

if as_csv:
    import csv
    w = csv.writer(sys.stdout)
    w.writerow(["device"] + cols)
    for did, dname in devices:
        w.writerow([dname] + [1 if did in used[c] else 0 for c in cols])
    sys.exit(0)

# Aligned grid with a numbered legend (datasource names are long).
labels = [f"D{i+1}" for i in range(len(cols))]
print("Datasources:")
for lab, name in zip(labels, cols):
    print(f"  {lab} = {name}")
print()

TICK, CROSS = "✓", "X"
dev_w = max([len("Device")] + [len(n) for _, n in devices])
col_w = [max(len(lab), 1) for lab in labels]

header = "Device".ljust(dev_w) + "  " + "  ".join(lab.center(w) for lab, w in zip(labels, col_w))
print(header)
print("-" * len(header))
for did, dname in devices:
    cells = []
    for c, w in zip(cols, col_w):
        cells.append((TICK if did in used[c] else CROSS).center(w))
    print(dname.ljust(dev_w) + "  " + "  ".join(cells))
PY
