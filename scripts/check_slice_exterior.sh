#!/usr/bin/env bash
# A SLICE'S EXTERIOR IS OUTSIDE THE SLICE. Arm one is the geometry: the global cells each face resolves
# to, over a coarse grid, a grid finer than the box, and one so coarse it cannot tell the faces apart
# (which must be NAMED, never duplicated). Arm two is a real capture off a short global run: no two faces
# may read alike, and the column under the box must stand under more pressure than the column over it.
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

# --- arm one: which global cells each face resolves to -----------------------------------------------
PROBE="$REPO_ROOT/addons/local_agents/tests/zz_slice_exterior_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

const Cap: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundaryCapture3D.gd")
const BODY_R: float = 2.4397e6
const DOMAIN_R: float = BODY_R + 1.0e5

var _fails: int = 0


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_slice_exterior: " + msg)
		_fails += 1


func _why(faces: Array, d: int) -> String:
	return String((faces[d] as Dictionary).get("unresolved", ""))


## Every global cell face `d` draws on, as grid coordinates.
func _coords(grid: LAVoxelGrid, faces: Array, d: int) -> Array:
	var out: Array = []
	for c in (faces[d] as Dictionary)["cells"] as PackedInt32Array:
		out.append(grid.coords(c))
	return out


func _box(spec: String) -> LAFieldSlice3D:
	var b: LAFieldSlice3D = LAFieldSlice3D.parse(spec)
	if b == null or b.error != "":
		printerr("check_slice_exterior: box spec \"%s\" did not parse" % spec)
		quit(2)
	return b


## A global grid whose cells dwarf the slice box: the vertical faces must still draw on different cells.
func _coarse() -> void:
	var box: LAFieldSlice3D = _box("0,%f,0,24,32,24,4000" % BODY_R)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build_centred(Vector3.ZERO, DOMAIN_R, 2.0 * DOMAIN_R / 24.0)
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	for d in LAVoxelGrid.SLOTS:
		_expect(_why(faces, d) == "",
			"the default box's face %d resolves to no exterior on the default global grid (%s)."
			% [d, _why(faces, d)])
	if _fails > 0:
		return
	var lo_y: float = box.offset.y - 0.5 * float(box.dims.y) * box.cell_size
	var below: int = 0
	for v: Vector3i in _coords(grid, faces, LAVoxelGrid.S_NEG_Y):
		if grid.origin.y + float(v.y + 1) * grid.cell_size <= lo_y:
			below += 1
	_expect(below > 0, "the bottom face draws on no global cell that lies wholly under the box: "
		+ "its exterior is the box's own cell, which is also the top face's.")
	for d in LAVoxelGrid.SLOTS:
		for e in range(d + 1, LAVoxelGrid.SLOTS):
			_expect(String(faces[d]["sig"]) != String(faces[e]["sig"]),
				"faces %d and %d resolve to the same weighted cells and neither was named." % [d, e])


## A global grid finer than the slice box: every face's exterior lies wholly beyond that face.
func _fine() -> void:
	var box: LAFieldSlice3D = _box("0,10000,0,8,8,8,100")
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(40, 40, 40, 100.0, Vector3(-2000.0, 8000.0, -2000.0))
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	var half: Vector3 = 0.5 * Vector3(box.dims) * box.cell_size
	var lo: Vector3 = box.offset - half
	var hi: Vector3 = box.offset + half
	for d in LAVoxelGrid.SLOTS:
		if _why(faces, d) != "":
			_expect(false, "face %d of a box inside a finer global grid resolved nothing (%s)."
				% [d, _why(faces, d)])
			continue
		var a: int = d >> 1
		for v: Vector3i in _coords(grid, faces, d):
			var c_lo: float = grid.origin[a] + float(v[a]) * grid.cell_size
			var inside: bool = c_lo + grid.cell_size > lo[a] if (d & 1) == 0 else c_lo < hi[a]
			_expect(not inside, "face %d draws on a global cell that is not outside it." % d)


## A global grid of one cell: it cannot tell the faces apart, so every face is NAMED, not copied.
func _unresolvable() -> void:
	var box: LAFieldSlice3D = _box("0,%f,0,24,32,24,4000" % BODY_R)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(1, 1, 1, 4.0 * DOMAIN_R, Vector3(-2.0 * DOMAIN_R, -2.0 * DOMAIN_R, -2.0 * DOMAIN_R))
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	for d in LAVoxelGrid.SLOTS:
		_expect(_why(faces, d) != "",
			"face %d silently took the one global cell the whole box sits in as its exterior." % d)
		_expect(not (faces[d] as Dictionary).has("cells"),
			"face %d carries cells as well as a name; an unresolved face supplies nothing." % d)


func _init() -> void:
	_coarse()
	_fine()
	_unresolvable()
	print('SLICE_EXTERIOR_GEOM={"failures":%d}' % _fails)
	quit(1 if _fails > 0 else 0)
GD

out="$(la_godot --headless --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_slice_exterior_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^SLICE_EXTERIOR_GEOM=')"
if [ -z "$line" ]; then
  echo "ERROR: the geometry probe produced no SLICE_EXTERIOR_GEOM line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_slice_exterior:' >&2 || true
[ "$rc" -eq 2 ] && { echo "The geometry probe could not run." >&2; exit 2; }
[ "$rc" -ne 0 ] && exit 1

# --- arm two: a real capture off a short global run ---------------------------------------------------
# BSD mktemp only accepts XXXXXX at the END of the template, so the .json arrives by rename.
CAP="$(mktemp "${TMPDIR:-/tmp}/la_slice_ext.XXXXXX")" && mv "$CAP" "$CAP.json" && CAP="$CAP.json"
cap_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "${LA_EXT_CAP_FRAMES:-20}" \
  --slice-capture "$CAP" --report h2o_total 2>&1)"
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


def key(st):
    return (st["temp_c"], st["pressure_pa"], tuple(sorted(st["amounts"].items())))


fail = 0
seen = {}
for k, st in faces.items():
    sig = key(st)
    if sig in seen:
        print("FAIL: faces %s and %s recorded an identical exterior — one cell copied onto both."
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
rm -f "$CAP"
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$cap_out" | tail -8 >&2
  exit 2
fi
[ "$rc" -eq 0 ] || exit 1
echo "check_slice_exterior: OK"
