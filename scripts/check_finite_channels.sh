#!/usr/bin/env bash
# CONSERVED MATTER AND ENERGY ARE FINITE REAL NUMBERS. A cell cannot hold infinite enthalpy or a
# not-a-number amount of water, so a single non-finite value anywhere in the conserved state is a defect,
# and every total taken over it is void.
#
# Nothing caught it for a whole session because the only symptom was a REPORT key: Godot's JSON.stringify
# writes a non-finite float as `null`, so `energy_stock` and every watt beside it printed null and the
# energy row read UNMEASURED. That is a reader noticing, not a gate firing.
#
# TWO ARMS, both off one short run of the real world.
#   THE FIELD. state_derive.glsl counts, per cell, how many of that cell's channel amounts, its enthalpy
#   and its three momentum components are NaN or infinite; the `nonfinite_cells` reduce row sums them.
#   It must read exactly 0.
#   THE READER. `energy_stock` must arrive as a finite number rather than null, which is what the ledger
#   publishes when the sum it reduced was not finite.
#
# POSITIVE CONTROLS. Both readings must be PRESENT, and the box must hold cells: a run that published no
# nonfinite_cells row did not measure anything, and this exits 2 rather than reporting a pass.
#
# EXIT 0 the conserved state is finite · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_finite_channels: python3 absent." >&2; exit 2; }
[ -x "$ROOT/scripts/sim_run.sh" ] || { echo "check_finite_channels: no scripts/sim_run.sh." >&2; exit 2; }

FRAMES="${LA_FINITE_FRAMES:-20}"
out="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --frames "$FRAMES" --raw 2>/dev/null)"
if [ -z "$out" ]; then
  echo "check_finite_channels: the run published no SIM_REPORT, so nothing was measured." >&2
  exit 2
fi

printf '%s' "$out" | python3 -c '
import json, math, sys

try:
    rep = json.loads(sys.stdin.read())
except Exception as e:
    print("check_finite_channels: the report did not parse (%s)." % e, file=sys.stderr)
    raise SystemExit(2)

def look(key):
    if key in rep:
        return rep[key]
    for sub in ("gauges", "events"):
        block = rep.get(sub)
        if isinstance(block, dict) and key in block:
            return block[key]
    return None

def scalar(v):
    if isinstance(v, dict):
        v = v.get("cur", v.get("value"))
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

cells = scalar(look("field_cells"))
if cells is None or cells <= 0:
    print("check_finite_channels: the run reports no field cells, so no state was examined.",
          file=sys.stderr)
    raise SystemExit(2)

raw_nf = look("nonfinite_cells")
nf = scalar(raw_nf)
if nf is None:
    print("check_finite_channels: no nonfinite_cells row in the report (got %r). The detector did not"
          % (raw_nf,), file=sys.stderr)
    print("                       run, so a pass would mean nothing.", file=sys.stderr)
    raise SystemExit(2)

stock_present = "energy_stock" in rep or any(
    isinstance(rep.get(s), dict) and "energy_stock" in rep[s] for s in ("gauges", "events"))
stock = look("energy_stock")
if not stock_present:
    print("check_finite_channels: the report carries no energy_stock, so the ledger did not fold the"
          " enthalpy at all.", file=sys.stderr)
    raise SystemExit(2)

bad = []
if nf != 0:
    bad.append("the field holds non-finite conserved values (nonfinite_cells is not 0)")
if scalar(stock) is None or not math.isfinite(float(scalar(stock))):
    bad.append("energy_stock did not arrive as a finite number (JSON.stringify writes a non-finite"
               " float as null)")

if bad:
    print("check_finite_channels: FAILED", file=sys.stderr)
    for b in bad:
        print("  - " + b, file=sys.stderr)
    print("\nMatter and energy are finite reals. Find the write that produced NaN or infinity — a division"
          "\nby a mass that went to zero, a cell carrying enthalpy with nothing in it to hold it — and fix"
          "\nit there. Do NOT clamp or sanitise the channel: that hides the value and keeps the defect.",
          file=sys.stderr)
    raise SystemExit(1)

print("check_finite_channels: OK (the conserved state is finite and energy_stock folded)")
'
rc=$?
exit $rc
