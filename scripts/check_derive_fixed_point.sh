#!/usr/bin/env bash
# ONE STATE PER CELL. The derive solves the temperature at a pressure and states a pressure from that
# temperature; run it twice on the state it just wrote and it must return the same pair. A derive that
# moves is a world whose seed is undone by its own first step.
# EXIT 0 the derive is a fixed point * 1 it moves * 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
[ -f "$PASS" ] || { echo "ERROR: StateDerivePass.gd missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/run_sim_offscreen.sh" ] || { echo "ERROR: run_sim_offscreen.sh missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_derive_fixed_point.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"

const CELL: float = 2000.0
## Relative move a second pass may make: float32 on the pressure, and the ladder's own last bit on T.
const TOL_REL: float = 1.0e-5
const TOL_K: float = 1.0e-3

var _rd: RenderingDevice = null
var _owned: Array[RID] = []
var _fails: int = 0


func _f32(n: int, v: float = 0.0) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(maxi(n, 1))
	a.fill(v)
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _upload(rid: RID, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	_rd.buffer_update(rid, 0, b.size(), b)


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	_run()
	for r in _owned:
		if r.is_valid():
			_rd.free_rid(r)
	quit(1 if _fails > 0 else 0)


## A column of cells spanning air, an air/water mix and brim-full water, each at a different pressure:
## the gas branch of the equation of state, the mixed one and the condensed one.
func _run() -> void:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(12, 1, 1, CELL, Vector3(-6.0 * CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var scr: GDScript = load(PASS_PATH)
	var p: RefCounted = scr.new()
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(cc)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(cc)
	var want: Dictionary = p._buffers(cc)
	for name in want:
		var spec: Variant = want[name]
		bufs[String(name)] = _f32(int(spec["n"]) if spec is Dictionary else int(spec))
	var nbr_bytes: PackedByteArray = grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_owned.append(nbr)
	bufs["nbr"] = nbr
	bufs["gravity"] = _f32(cc * 3)
	bufs["g_rest"] = _f32(cc * 3)
	bufs["pos"] = _f32(cc * 3)
	bufs["cell_vol"] = _f32(cc, CELL * CELL * CELL)

	var full_h2o: float = LASubstances.full_mol_m3("h2o")
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var n2: PackedFloat32Array = PackedFloat32Array()
	var h: PackedFloat32Array = PackedFloat32Array()
	var pres: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		var wet: float = float(c) / float(cc - 1)
		h2o.append(wet * full_h2o)
		n2.append(40.0 * (1.0 - wet))
		pres.append(101325.0 * pow(10.0, 3.0 * wet))
		var kg: float = wet * full_h2o * LAPhysical.MOLAR_MASS_WATER_KG_MOL
		h.append(kg * LASubstances.enthalpy_at("h2o", 15.0, pres[c]))
	_upload(bufs["h2o"], h2o)
	_upload(bufs["n2"], n2)
	_upload(bufs["h_j_m3"], h)
	_upload(bufs["pressure"], pres)

	p.setup(_rd, bufs, cc)
	var groups: int = int(ceil(float(cc) / 64.0))
	var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "step_index": 0.0, "dt_s": 1.0}
	var t1: PackedFloat32Array = _pass_once(p, ctx, cc, groups, bufs, "temp")
	var p1: PackedFloat32Array = _rd.buffer_get_data(bufs["pressure"]).to_float32_array()
	var t2: PackedFloat32Array = _pass_once(p, ctx, cc, groups, bufs, "temp")
	var p2: PackedFloat32Array = _rd.buffer_get_data(bufs["pressure"]).to_float32_array()
	p.dispose(_rd)

	var worst_t: float = 0.0
	var worst_p: float = 0.0
	var moved: int = 0
	var live: int = 0
	for c in cc:
		if not is_finite(t1[c]) or not is_finite(p1[c]):
			_fails += 1
			continue
		if p1[c] <= 0.0:
			continue
		live += 1
		var dt: float = absf(t2[c] - t1[c])
		var dp: float = absf(p2[c] - p1[c]) / maxf(absf(p1[c]), 1.0)
		worst_t = maxf(worst_t, dt)
		worst_p = maxf(worst_p, dp)
		if dt > TOL_K or dp > TOL_REL:
			moved += 1
	if live <= 0:
		printerr("no cell held a pressure, so the derive was never asked anything.")
		_fails += 1
	if moved > 0:
		_fails += 1
	print('DERIVE_FIXED_POINT={"cells":%d,"live":%d,"moved":%d,"worst_k":%s,"worst_p_rel":%s,"failures":%d}'
		% [cc, live, moved, String.num(worst_t, 9), String.num(worst_p, 9), _fails])
	if moved > 0:
		printerr("The derive did not return the state it wrote: %d cell(s) moved. It solves T at a "
			% moved + "pressure and states a pressure from that T, so the two must be solved together.")


func _pass_once(p: RefCounted, ctx: Dictionary, cc: int, groups: int, bufs: Dictionary,
		key: String) -> PackedFloat32Array:
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, ctx, cc, groups)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return _rd.buffer_get_data(bufs[key]).to_float32_array()
GD

OUT="$(LA_DONE_RE='^DERIVE_FIXED_POINT=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
	--path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_derive_fixed_point.gd" 2>&1)"
RC=$?
printf '%s\n' "$OUT" | grep -E '^DERIVE_FIXED_POINT=|did not return|no cell held|no RenderingDevice' || true
# A rig that printed no reading examined nothing, whatever it exited with.
printf '%s\n' "$OUT" | grep -q '^DERIVE_FIXED_POINT=' || {
	echo "check_derive_fixed_point: the rig published no reading, so the derive was never run." >&2
	printf '%s\n' "$OUT" | tail -20 >&2
	exit 2
}
case "$RC" in
	0) ;;
	1) exit 1 ;;
	*) printf '%s\n' "$OUT" | tail -20 >&2; exit 2 ;;
esac

# THE SEEDED WORLD, not a rig's own inputs: the same derive over the matter the seed actually laid must
# write finite state in every cell. Rung 1 is the lowest that publishes the count.
world="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --rung 1 --frames 4 \
	--report nonfinite_cells 2>&1)"
nf="$(printf '%s\n' "$world" | sed -n "s/^nonfinite_cells  *= *//p" | head -1 \
	| sed -e "s/.*'cur': *//" -e 's/[,}].*//')"
printf 'DERIVE_SEEDED_WORLD={"nonfinite_cells":%s}\n' "${nf:-null}"
case "${nf:-}" in
	"" | *ABSENT*) echo "check_derive_fixed_point: the seeded world published no nonfinite_cells, so the" >&2
		echo "                          derive was never read over the matter the seed laid." >&2
		printf '%s\n' "$world" | tail -15 >&2
		exit 2 ;;
esac
if ! awk -v n="$nf" 'BEGIN{exit !(n == 0)}'; then
	echo "check_derive_fixed_point: the derive wrote non-finite state over the seeded world." >&2
	exit 1
fi
echo "check_derive_fixed_point: OK"
exit 0
