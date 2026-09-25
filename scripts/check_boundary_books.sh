#!/usr/bin/env bash
# A CROSSING IS BOOKED, judged by the REAL evaluator: FluxPass dispatching flux.glsl over a
# rig whose CONSTANT face carries a real captured exterior, recorded here by a short global run. The rig
# holds every booked channel to per-dispatch closure and the differing state to a nonzero crossing; arm
# two runs the real slice on the same capture and holds the crossings to reaching the ledger.
# EXIT 0 clean · 1 a violation · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/flux.glsl"
[ -f "$KERNEL" ] || { echo "ERROR: flux.glsl missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/sim_run.sh" ] || { echo "ERROR: sim_run.sh missing." >&2; exit 2; }
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

# --- the capture: a short GLOBAL run records the slice box's exterior --------------------------------
# BSD mktemp only accepts XXXXXX at the END of the template, so the .json arrives by rename.
# A CROSSING NEEDS A WORLD THAT CAN CROSS: the rows that move matter through a face. Both arms run at
# the rung the capture was recorded in, or the exterior and the interior are two different worlds.
OWN_CAP=0
CAP_RUNG="${LA_BND_RUNG:-8}"
if la_cap_dir >/dev/null; then
  CAP="$(la_cap_state)" || exit 2
  CAP_RUNG="$(la_cap_rung)" || {
    echo "ERROR: the shared capture does not say which rung it was recorded in." >&2; exit 2; }
  cap_out=""
else
  CAP="$(mktemp "${TMPDIR:-/tmp}/la_bnd_cap.XXXXXX")" && mv "$CAP" "$CAP.json" && CAP="$CAP.json"
  OWN_CAP=1
  cap_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --body --frames "${LA_BND_CAP_FRAMES:-20}" \
    --rung "$CAP_RUNG" --slice-capture "$CAP" --report h2o_total 2>&1)"
fi
drop_cap() { [ "$OWN_CAP" -eq 1 ] && rm -f "$CAP"; return 0; }
if ! python3 -c "
import json, sys
d = json.load(open('$CAP'))
s = d.get('samples', [])
assert s and '0' in s[0].get('faces', {}), 'no face-0 sample'
" 2>/dev/null; then
  echo "ERROR: the capture run wrote no usable capture — refusing to report a pass." >&2
  printf '%s\n' "$cap_out" | tail -8 >&2
  drop_cap
  exit 2
fi

# --- arm one: rig closure against the real boundary provider and kernel ------------------------------
PROBE="$REPO_ROOT/addons/local_agents/tests/zz_boundary_books_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"
const CELL: float = 0.5
const P_IN: float = 101325.0
const T_C: float = 15.0
const TOL: float = 1.0e-5

var _rd: RenderingDevice = null
var _fails: int = 0


class StubGpu:
	extends RefCounted
	var _rd: RenderingDevice = null
	var _bufs: Dictionary = {}


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_boundary_books: " + msg)
		_fails += 1


func _filled(n: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


func _f32(vals: PackedFloat32Array, owned: Array[RID]) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	owned.append(r)
	return r


func _i32(vals: PackedInt32Array, owned: Array[RID]) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	owned.append(r)
	return r


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	var path: String = OS.get_environment("LA_BND_CAP")
	var means: Dictionary = LAFieldBoundaryCapture3D.constant_states(
		LAFieldBoundaryCapture3D.load_file(path))
	if not means.has(0):
		printerr("the capture carries no face-0 state; nothing to supply.")
		quit(2)
		return
	var st: Dictionary = means[0]

	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(2, 1, 1, CELL, Vector3(-CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var bnd: LAFieldBoundary3D = LAFieldBoundary3D.new()
	var modes: PackedInt32Array = PackedInt32Array([LAFieldBoundary3D.CONSTANT,
		LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT,
		LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT])
	if not bnd.configure(grid, modes, [st, null, null, null, null, null]):
		_expect(false, "boundary configure failed: " + bnd.error)
		quit(2)
		return
	var ng: int = bnd.ghost_count()
	var tc: int = cc + ng
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(tc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(tc, 0.0), owned)
	# EVERY DERIVED BUFFER FROM THE ONE DECLARATION -- StateDerivePass names them and gives their shapes.
	# A list copied into a rig is a second declaration that goes stale: none of the copies carried
	# "h_h2o_vap", which FieldBoundary3D writes on every constant face.
	var sd: RefCounted = (load("res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd") as GDScript).new()
	sd.ghost_count = ng
	var derived: Dictionary = sd._buffers(cc)
	for key in derived:
		var spec: Variant = derived[key]
		var dn: int = int(spec["n"]) if spec is Dictionary else int(spec)
		if spec is Dictionary and bool(spec.get("ghosts", false)):
			dn = (dn + ng) * int(spec.get("stride", 1))
		bufs[String(key)] = _f32(_filled(dn, 0.0), owned)
	bufs["ground_d"] = _f32(_filled(tc, 0.0), owned)   # flux.glsl binding 99: the driver's own
	bufs["gravity"] = _f32(_filled(tc * 3, 0.0), owned)
	bufs["g_rest"] = _f32(_filled(tc * 3, 0.0), owned)
	bufs["nbr"] = _i32(grid.neighbours, owned)
	bufs["slot_off"] = _i32(grid.slot_off, owned)
	bufs["face_partner"] = _i32(grid.partners, owned)
	bufs["cell_edge"] = _f32(grid.cell_edges(), owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(grid.neighbours.size())
	ghost_tbl.fill(-1)
	bufs["ghost"] = _i32(ghost_tbl, owned)

	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	p.ghost_count = ng
	p.face_count = grid.neighbours.size()
	var want: Dictionary = p._buffers(cc)
	# The temporal levels a world gets from StateDerivePass; this rig runs the transport pass alone.
	want.merge(LATemporalLevels.buffers(cc + ng, p.group_count()))
	for key in want:
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		var zeros: PackedByteArray = _filled(n, 0.0).to_byte_array()
		var r: RID = _rd.storage_buffer_create(zeros.size(), zeros,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		owned.append(r)
		bufs[String(key)] = r

	for pair: Array in [["pressure", P_IN], ["temp", T_C], ["gas_r", LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK],
			["gas_gamma", LAPhysical.AIR_ADIABATIC_INDEX]]:
		var vals: PackedByteArray = _filled(tc, float(pair[1])).to_byte_array()
		_rd.buffer_update(bufs[String(pair[0])], 0, vals.size(), vals)

	p.setup(_rd, LAFieldDriver.on(_rd), bufs, cc)
	var stub: StubGpu = StubGpu.new()
	stub._rd = _rd
	stub._bufs = bufs
	bnd.attach(stub)
	if bnd.error != "":
		_expect(false, "boundary attach failed: " + bnd.error)
	p._driver.open()
	# The step is a small fraction of CELL over the sound speed: inside the explicit acoustic regime.
	p.dispatch(_rd, {"cell_size": CELL, "sun_dir": Vector3.ZERO, "dt_s": 1.0e-4},
		cc, int(ceil(float(cc) / 64.0)))
	p._driver.close()

	# Matter closes per channel. The thermal field closes across every heat leg: matter that crosses
	# carries its joules into e_j_m3, booked under the MATTER channel's bnd_h_<ch>.
	var channels: PackedStringArray = LAReduceBoundaryRows.BOOKED.duplicate()
	channels.append_array(LAReduceBoundaryRows.BOOKED_SIGNED)
	var nonzero: int = 0
	var heat_booked: float = 0.0
	for ch in channels:
		var amt: PackedFloat32Array = _rd.buffer_get_data(bufs[String(ch)]).to_float32_array()
		var book: PackedFloat32Array = _rd.buffer_get_data(bufs["bnd_" + String(ch)]).to_float32_array()
		var gained: float = 0.0
		var booked: float = 0.0
		for c in cc:
			gained += amt[c]
			booked += book[c]
		if booked != 0.0:
			nonzero += 1
		if String(ch) == "e_j_m3":
			heat_booked += booked
			for hch in LAReduceBoundaryRows.BOOKED:
				if String(hch) == "e_j_m3":
					continue
				var hb: PackedFloat32Array = _rd.buffer_get_data(
					bufs["bnd_h_" + String(hch)]).to_float32_array()
				for c in cc:
					heat_booked += hb[c]
			# The radiative row is not a boundary book: it publishes rad_absorbed/rad_emitted, which the
			# energy ledger folds, and its emission through the box edge leaves for space.
			for rname in ["rad_absorbed", "radiogenic"]:
				var ra: PackedFloat32Array = _rd.buffer_get_data(bufs[String(rname)]).to_float32_array()
				for c in cc:
					heat_booked += ra[c]
			var re: PackedFloat32Array = _rd.buffer_get_data(bufs["rad_emitted"]).to_float32_array()
			for c in cc:
				heat_booked -= re[c]
			_expect(absf(gained - heat_booked) <= TOL * maxf(absf(gained), 1.0),
				"e_j_m3: the thermal field changed by %s and the heat legs plus the radiative pair "
				% String.num_scientific(gained)
				+ "account for %s." % String.num_scientific(heat_booked))
			continue
		_expect(absf(gained - booked) <= TOL * maxf(absf(gained), 1.0),
			"%s: the interior changed by %s and its book reads %s — the crossing is not booked."
			% [ch, String.num_scientific(gained), String.num_scientific(booked)])
	_expect(nonzero > 0, "a supplied state that differs from the interior booked no crossing on any channel.")

	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	print('BOUNDARY_BOOKS={"channels":%d,"nonzero":%d,"failures":%d}'
		% [channels.size(), nonzero, _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_BND_CAP="$CAP" LA_DONE_RE='^BOUNDARY_BOOKS=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_boundary_books_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^BOUNDARY_BOOKS=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no BOUNDARY_BOOKS line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  drop_cap
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_boundary_books:' >&2 || true
if [ "$rc" -eq 2 ]; then
  drop_cap
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  drop_cap
  exit 1
fi

# --- arm two: the real slice consumes the same capture and the crossings reach the ledger -------------
ERRLOG="$(mktemp "${TMPDIR:-/tmp}/la_bnd_books.XXXXXX")"
slice_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --slice-state "$CAP" \
  --rung "$CAP_RUNG" --frames "${LA_BND_SLICE_FRAMES:-60}" --raw 2>"$ERRLOG")"
slice_rc=$?
drop_cap
case "$slice_rc" in
  0|122|123|126) ;;
  *) echo "ERROR: the slice run failed (exit $slice_rc) — refusing to report a pass." >&2
     tail -12 "$ERRLOG" >&2; rm -f "$ERRLOG"; exit 2 ;;
esac
rm -f "$ERRLOG"
RAWFILE="$(mktemp "${TMPDIR:-/tmp}/la_bnd_books_raw.XXXXXX")"
printf '%s\n' "$slice_out" > "$RAWFILE"
python3 - "$RAWFILE" <<'PY'
import json, sys

raw = open(sys.argv[1]).read().strip()
if not raw.startswith("{"):
    print("ERROR: the slice run printed no report JSON — refusing to report a pass.", file=sys.stderr)
    raise SystemExit(2)
d = json.loads(raw)
crossed = {}
for blk in [d] + [v for v in d.values() if isinstance(v, dict)]:
    for k, v in blk.items():
        if k.endswith("_bnd_crossed") and isinstance(v, (int, float)):
            crossed[k] = float(v)
if len(crossed) < 5:
    print("ERROR: only %d crossing books published — the ledger shape changed under this gate." % len(crossed),
          file=sys.stderr)
    raise SystemExit(2)
hot = {k: v for k, v in crossed.items() if v != 0.0}
if not hot:
    print("FAIL: a CONSTANT face whose state differs from the interior crossed nothing —", file=sys.stderr)
    print("      the ledger sees no boundary at all.", file=sys.stderr)
    raise SystemExit(1)
print("BOUNDARY_BOOKS_SLICE={\"crossing_books\":%d,\"nonzero\":%d}" % (len(crossed), len(hot)))
PY
rc=$?
rm -f "$RAWFILE"
[ "$rc" -eq 0 ] && echo "check_boundary_books: OK"
exit "$rc"
