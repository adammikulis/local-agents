#!/usr/bin/env python3
# SIM_REPORT keys, printed. sim_run.sh and lib_capture.sh both call this, so a run's report and the
# lint capture's copy of it cannot be formatted differently.
# argv[1] is a run log or a bare report JSON; REPORT_KEYS and RAW come from the environment.
import json, os, sys


def _report(path):
    text = open(path, errors="replace").read()
    if text.lstrip().startswith("{"):
        return json.loads(text)
    line = None
    for ln in text.splitlines():
        if ln.startswith("SIM_REPORT="):
            line = ln
    if line is None:
        return None
    return json.loads(line.strip()[len("SIM_REPORT="):])


# Gauges live under a nested "gauges" key, so a flat lookup reported <ABSENT> for every one of them.
def _lookup(rep, key):
    if key in rep:
        return rep[key]
    for sub in ("gauges", "events"):
        block = rep.get(sub)
        if isinstance(block, dict) and key in block:
            return block[key]
    return "<ABSENT>"


d = _report(sys.argv[1])
if d is None:
    print("sim_run: NO SIM_REPORT in this run.", file=sys.stderr)
    raise SystemExit(0)
if os.environ.get("RAW") == "1":
    print(json.dumps(d, indent=2, sort_keys=True))
    raise SystemExit(0)

for k in os.environ.get("REPORT_KEYS", "").split(","):
    k = k.strip()
    if not k:
        continue
    print(f"{k:26} = {_lookup(d, k)}")
# DRIFT, SPELLED OUT. A `_first`/`_total` pair is the whole point of the seal, and computing the ratio by
# hand every time is how a sign error survives.
print("--- drift vs sealed baseline ---")
for now_k, first_k in [("o2_total", "o2_first"), ("mineral_total", "mineral_first"),
                       ("h2o_total", "h2o_first"), ("element_C_total", "element_C_total_first")]:
    a, b = _lookup(d, now_k), _lookup(d, first_k)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b:
        print(f"{now_k:26} = {100.0 * (a - b) / b:+8.3f}%")
