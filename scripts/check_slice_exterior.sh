#!/usr/bin/env bash
# A SLICE'S EXTERIOR IS OUTSIDE THE SLICE. Arm one is the geometry: the global cells each face resolves
# to, over a coarse grid, a grid finer than the box, and one so coarse it cannot tell the faces apart
# (which must be NAMED, never duplicated). Arm two is a real capture off a short global run: no two faces
# may read one place's state, and the column under the box must stand under more pressure than the one over.
# EXIT 0 clean · 1 a face reads another face's exterior · 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
CAPSRC="$REPO_ROOT/addons/local_agents/sim/material/FieldBoundaryCapture3D.gd"
[ -f "$CAPSRC" ] || { echo "ERROR: FieldBoundaryCapture3D.gd missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/sim_run.sh" ] || { echo "ERROR: sim_run.sh missing." >&2; exit 2; }
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

# --- arm one: which global cells each face resolves to -----------------------------------------------
PROBE_REL="addons/local_agents/tests/gate_slice_exterior_geom.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  out="$(la_headless slice_exterior_geom)" || exit 2
else
  out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)"
fi
line="$(printf '%s\n' "$out" | grep -m1 '^SLICE_EXTERIOR_GEOM=')"
if [ -z "$line" ]; then
  echo "ERROR: the geometry probe produced no SLICE_EXTERIOR_GEOM line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_slice_exterior:' >&2 || true
# The marker carries the verdict; a batched runner has no exit code of its own.
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the geometry probe published no failure count." >&2; exit 2; }
[ "$fails" -ne 0 ] && exit 1

# --- arm two: a real capture off a short global run ---------------------------------------------------
# BSD mktemp only accepts XXXXXX at the END of the template, so the .json arrives by rename.
OWN_CAP=0
if la_cap_dir >/dev/null; then
  CAP="$(la_cap_state)" || exit 2
  cap_out=""
else
  CAP="$(mktemp "${TMPDIR:-/tmp}/la_slice_ext.XXXXXX")" && mv "$CAP" "$CAP.json" && CAP="$CAP.json"
  OWN_CAP=1
  cap_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "${LA_EXT_CAP_FRAMES:-20}" \
    --slice-capture "$CAP" --report h2o_total 2>&1)"
fi
python3 - "$CAP" <<'PY'
import json, sys

try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print("ERROR: the capture run wrote no readable capture (%s)." % exc, file=sys.stderr)
    raise SystemExit(2)
samples = d.get("samples", [])
if not samples:
    print("ERROR: the capture holds no sample — refusing to report a pass.", file=sys.stderr)
    raise SystemExit(2)
faces = samples[-1].get("faces", {})
named = d.get("unresolved", {})
missing = [str(k) for k in range(6) if str(k) not in faces and str(k) not in named]
if missing:
    print("ERROR: face(s) %s are neither recorded nor named." % ",".join(missing), file=sys.stderr)
    raise SystemExit(2)
if len(faces) < 2:
    print("ERROR: fewer than two faces recorded, so no two can be compared.", file=sys.stderr)
    raise SystemExit(2)


# A FACE'S EXTERIOR IS A PLACE. The scalars are a function of radius, so two faces at equal depth read
# alike; gravity points at the centre from each one's own place, and a copied cell brings one place's.
def key(st):
    return (st["temp_c"], st["pressure_pa"], tuple(st["gravity"]), tuple(sorted(st["amounts"].items())))


fail = 0
seen = {}
for k, st in faces.items():
    sig = key(st)
    if sig in seen:
        print("FAIL: faces %s and %s recorded one place's exterior, gravity included — one cell on both."
              % (seen[sig], k), file=sys.stderr)
        fail = 1
    seen[sig] = k
# The run above places the default box on the +Y surface, so S_NEG_Y (2) is under it and S_POS_Y (3) over
# it, and 0/1/4/5 stand at the same depth. Pressure rises downward, so the vertical pair must separate by
# more than the four same-depth faces separate from each other.
if all(str(k) in faces for k in (0, 1, 2, 3, 4, 5)):
    lo, hi = faces["2"], faces["3"]
    if lo["pressure_pa"] <= hi["pressure_pa"]:
        print("FAIL: the exterior under the box is not under more pressure than the exterior over it —",
              file=sys.stderr)
        print("      the capture is not reading the column below and the column above.", file=sys.stderr)
        fail = 1
    flat = [faces[str(k)]["pressure_pa"] for k in (0, 1, 4, 5)]
    if lo["pressure_pa"] - hi["pressure_pa"] <= max(flat) - min(flat):
        print("FAIL: bottom and top separate by no more than the four faces at equal depth do —",
              file=sys.stderr)
        print("      the six faces are reading one global cell.", file=sys.stderr)
        fail = 1
print('SLICE_EXTERIOR_CAPTURE={"faces":%d,"named":%d,"failures":%d}' % (len(faces), len(named), fail))
raise SystemExit(fail)
PY
rc=$?
[ "$OWN_CAP" -eq 1 ] && rm -f "$CAP"
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$cap_out" | tail -8 >&2
  exit 2
fi
[ "$rc" -eq 0 ] || exit 1
echo "check_slice_exterior: OK"
