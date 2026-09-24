#!/usr/bin/env bash
# RUNG 0 — STATE. The smallest world there is: matter with an enthalpy and nothing that moves it. The
# derive on the device must say what the substance table says at every point of a sweep across a phase
# boundary, hold the temperature still across the latent plateau while the frozen share melts away, and
# write finite state everywhere — nothing has advected here, so a NaN is the derive's own or the seed's.
# EXIT 0 the derive is the table · 1 it is not · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/state_derive.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: state_derive.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: StateDerivePass.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_rung_state_gate.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"

const N: int = 8
const CELL: float = 1.0
const ID: String = "h2o"
## Kelvin the two ladders may differ by: float32 on the enthalpy, float64 on the reference.
const TOL_K: float = 0.5
## Probes across the fusion plateau, and the run of them one temperature must span.
const PROBES: int = 24
const PLATEAU_MIN: int = 3

var _rd: RenderingDevice = null
var _owned: Array[RID] = []


## A buffer holding the values it is given, rather than n copies of one.
func _write_f32(vals: PackedFloat32Array) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)


func _f32(n: int, v: float = 0.0) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(maxi(n, 1))
	a.fill(v)
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _upload(rid: RID, v: PackedFloat32Array) -> void:
	var b: PackedByteArray = v.to_byte_array()
	_rd.buffer_update(rid, 0, b.size(), b)


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_fail("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		return
	var grid = LAVoxelGrid.new()
	grid.build(N, N, N, CELL, Vector3(-0.5 * N, -0.5 * N, -0.5 * N))
	var cc: int = grid.cell_count
	if cc < PROBES:
		_fail("the grid holds fewer cells than the sweep has probes.")
		return

	# Half a cell of water under air at p_ref: the ice it freezes into still fits, so the solve's own
	# pressure stays near p_ref instead of the frost-wedging pressure a brim-full rigid cell would state.
	var amount: float = 0.5 * LASubstances.full_mol_m3(ID)
	var molar: float = float(LASubstances.table()[ID]["molar_mass"])
	var rho: float = amount * molar
	if rho <= 0.0:
		_fail("%s has no density in the table, so a cell of it carries no mass." % ID)
		return

	# THE SWEEP, in specific enthalpy: from well under the fusion plateau to well over it, so the
	# boundary is crossed rather than approached. The reference pressure only picks the probes; every
	# comparison below is made at the pressure the solve was handed.
	var p_ref: float = LAPhysical.STANDARD_PRESSURE_PA
	var melt: float = LASubstances.melt_c_at(ID, p_ref)
	var latent: float = float(LASubstances.table()[ID]["latent_fusion_j_kg"])
	if not is_finite(melt) or latent <= 0.0:
		_fail("%s has no fusion boundary in the table, so there is no plateau to cross." % ID)
		return
	var h_lo: float = LASubstances.enthalpy_at(ID, melt - 20.0, p_ref)
	var h_hi: float = LASubstances.enthalpy_at(ID, melt, p_ref) + latent * 1.2
	var h_cells: PackedFloat32Array = PackedFloat32Array()
	h_cells.resize(cc)
	for i in PROBES:
		var f: float = float(i) / float(PROBES - 1)
		h_cells[i] = (h_lo + f * (h_hi - h_lo)) * rho

	var scr: GDScript = load(PASS_PATH)
	var p: RefCounted = scr.new()
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(cc)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(cc)
	for name in (p._buffers(cc) as Dictionary):
		var spec: Variant = (p._buffers(cc) as Dictionary)[name]
		bufs[String(name)] = _f32(int(spec["n"]) if spec is Dictionary else int(spec))
	var nbr_bytes: PackedByteArray = grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_owned.append(nbr)
	bufs["nbr"] = nbr
	# THE FACE LIST'S OWN GEOMETRY: where a cell's faces begin, the face pointing back, and its edge.
	var off_b: PackedByteArray = grid.slot_off.to_byte_array()
	var par_b: PackedByteArray = grid.partners.to_byte_array()
	var edge_b: PackedByteArray = grid.cell_edges().to_byte_array()
	bufs["slot_off"] = _rd.storage_buffer_create(off_b.size(), off_b)
	bufs["face_partner"] = _rd.storage_buffer_create(par_b.size(), par_b)
	bufs["cell_edge"] = _rd.storage_buffer_create(edge_b.size(), edge_b)
	_owned.append(bufs["slot_off"])
	_owned.append(bufs["face_partner"])
	_owned.append(bufs["cell_edge"])
	bufs["gravity"] = _f32(cc * 3)
	bufs["g_rest"] = _f32(cc * 3)
	bufs["pos"] = _f32(cc * 3)
	bufs["cell_edge"] = _write_f32(grid.cell_edges())

	var amounts: PackedFloat32Array = PackedFloat32Array()
	amounts.resize(cc)
	amounts.fill(0.0)
	for i2 in PROBES:
		amounts[i2] = amount
	_upload(bufs[ID], amounts)
	var air: PackedFloat32Array = PackedFloat32Array()
	air.resize(cc)
	air.fill(0.0)
	var n2_amount: float = p_ref * 0.5 / (LAPhysical.GAS_CONSTANT_J_MOL_K * (melt + LAPhysical.KELVIN_OFFSET))
	for i3 in PROBES:
		air[i3] = n2_amount
	_upload(bufs["n2"], air)
	_upload(bufs["e_j_m3"], h_cells)
	# The solve reads the pressure standing in the cell and writes the EOS one after; the reference below
	# is taken at the pressure it READ, so both ladders answer the same question.
	var p_cells: PackedFloat32Array = PackedFloat32Array()
	p_cells.resize(cc)
	p_cells.fill(p_ref)
	_upload(bufs["pressure"], p_cells)

	p.setup(_rd, LAFieldDriver.on(_rd), bufs, cc)
	var groups: int = int(ceil(float(cc) / 64.0))
	var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "step_index": 0.0, "dt_s": 1.0}
	p._driver.open()
	p.dispatch(_rd, ctx, cc, groups)
	p._driver.close()
	var temp: PackedFloat32Array = _rd.buffer_get_data(bufs["temp"]).to_float32_array()
	var ice: PackedFloat32Array = _rd.buffer_get_data(bufs["h2o_solid"]).to_float32_array()
	var p_out: PackedFloat32Array = _rd.buffer_get_data(bufs["pressure"]).to_float32_array()
	var nonfinite: PackedFloat32Array = _rd.buffer_get_data(bufs["nonfinite"]).to_float32_array()
	p.dispose(_rd)

	# ARM ONE — the derive against the table, probe by probe.
	var worst_k: float = 0.0
	var worst_at: int = -1
	for c in PROBES:
		var h_kg: float = float(h_cells[c]) / rho
		# The table at the pressure the derive itself solved: one state, both sides.
		var want: float = float(LASubstances.enthalpy_to_state(ID, h_kg, maxf(float(p_out[c]), 0.0))["t_c"])
		var err: float = absf(float(temp[c]) - want)
		if err > worst_k:
			worst_k = err
			worst_at = c
	# ARM TWO — the plateau: the longest run of probes at ONE temperature, and what the ice share did
	# across it. A ladder that skipped its latent heat has no run; one with no boundary has no fall.
	var run: int = 1
	var best_run: int = 1
	var best_lo: int = 0
	var run_lo: int = 0
	for c2 in range(1, PROBES):
		if absf(float(temp[c2]) - float(temp[c2 - 1])) <= TOL_K:
			run += 1
		else:
			run = 1
			run_lo = c2
		if run > best_run:
			best_run = run
			best_lo = run_lo
	var span: float = absf(float(ice[best_lo]) - float(ice[best_lo + best_run - 1]))
	# ARM THREE — finite state, over the whole grid, empty cells included.
	var nf: float = 0.0
	for c3 in nonfinite.size():
		nf += float(nonfinite[c3])

	var fail: int = 0
	if worst_k > TOL_K: fail += 1
	if best_run < PLATEAU_MIN: fail += 1
	if span < 0.9: fail += 1
	if nf > 0.0: fail += 1
	print('RUNG_STATE={"worst_k":%.6f,"worst_probe":%d,"plateau_probes":%d,"plateau_ice_span":%.4f,"nonfinite":%s,"probes":%d,"failures":%d}'
		% [worst_k, worst_at, best_run, span, nf, PROBES, fail])
	for r in _owned:
		if r.is_valid():
			_rd.free_rid(r)
	_rd.free()
	quit(1 if fail > 0 else 0)
GD

out="$(LA_DONE_RE='^RUNG_STATE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_rung_state_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^RUNG_STATE=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no RUNG_STATE line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  echo
  echo "The derive is not the substance table. worst_k is the largest gap in kelvin between what"
  echo "state_derive.glsl calls the temperature of a cell and what LASubstances says that enthalpy is at"
  echo "the pressure the solve derived; plateau_probes is how many consecutive probes sat at one"
  echo "temperature while the enthalpy rose, which is the latent heat of fusion and must span at least a"
  echo "few of them; plateau_ice_span is how much of the frozen share melted across that plateau, which"
  echo "must be nearly all of it or no boundary was crossed; nonfinite must be zero, and at this rung"
  echo "nothing has moved, so a NaN here is the derive's own or the state it was handed."
  exit 1
fi

# ARM TWO — the world the SIM seeds, not one this script built. The rig above proves the kernel against
# the table; it cannot see whether the derive ran in the world at all. At this rung the derive is the
# only pass there is, so a published field-step time IS the derive having dispatched over the seeded
# world, and sim_run withholds every number from a run that logged an engine error.
. "$REPO_ROOT/scripts/lib_rung.sh"
sim_out="$(la_rung_report 0 "${LA_RUNG_FRAMES:-8}" "field_ms")"
printf '%s\n' "$sim_out" | grep -E '^field_ms' || true
la_rung_require "$sim_out" field_ms || exit 2
ms="$(la_rung_value "$sim_out" field_ms)"
if ! awk -v v="$ms" 'BEGIN{exit !(v > 0)}'; then
  echo
  echo "In the world the sim seeds, no field step took any time: the derive did not dispatch there."
  exit 1
fi
echo "check_rung_state: OK"
