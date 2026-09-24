#!/usr/bin/env bash
# THE WEATHERING RATE LAW, judged by the REAL evaluator: ReactionsPass dispatching
# reactions_sphere3d.glsl over the live record table on a one-column rig, extents read off the device.
# Chemical arm: positive at 25 C, monotone in T, Q10 ~2, zero with no liquid water, stoichiometric.
# Frost arm: fires below the tensile threshold over liquid pore water, conserves rock and water, and
# reads zero above the threshold or over frozen pores. Competition arm: two records drawing one scarce
# reactant land on the same state whichever way the table is ordered. Arm two reads the seeded world's
# own gauge.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: reactions_sphere3d.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: ReactionsPass.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_weathering_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd"
const CELL: float = 1.0
# A channel amount is moles. Rig stimuli, mol/m^3: a damp cell (so the CO2 cap never saturates the Q10
# measurement) over CO2-rich ground air.
const H2O_MOL_M3: float = LAPhysical.WATER_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
const H2O_AT_CELL: float = 0.01 * H2O_MOL_M3
const CO2_AT_CELL: float = 0.25 * LAPhysical.AIR_MOLAR_DENSITY_MOL_M3
const PORE_WATER: float = 0.3 * H2O_MOL_M3
const GROUND_WARM_C: float = 1.0
const TOL: float = 1.0e-6
const ORDER_REL_TOL: float = 1.0e-5

var _rd: RenderingDevice = null
var _grid: LAVoxelGrid = null
var _bottom: int = 0
var _mid: int = 0
var _fails: int = 0


func _f32(vals: PackedFloat32Array, owned: Array[RID]) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	owned.append(r)
	return r


func _filled(n: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


## One dispatch of the real reactions pass over a 1x3x1 column: bedrock, the reacting open cell, air.
## `cond` carries per-buffer overrides; `recs` a table override. Returns the channels read off the device.
func _run(cond: Dictionary, recs: Array = []) -> Dictionary:
	var cc: int = _grid.cell_count
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in ["col_e", "strike"]:
		bufs[name] = _f32(_filled(cc, 0.0), owned)
	# A record that fires says WHERE, so the transport mask cannot leave that cell asleep. The reaction
	# pass binds the wake queue, so a rig that drives that pass builds it.
	var act: Dictionary = LAActiveCells.buffers(cc, 1)
	for key in act:
		var spec: Variant = act[key]
		bufs[String(key)] = _f32(_filled(int(spec["n"]) if spec is Dictionary else int(spec), 0.0), owned)
	bufs["cell_edge"] = _f32(_grid.cell_edges(), owned)
	var grav: PackedFloat32Array = PackedFloat32Array()
	grav.resize(cc * 3)
	for c in cc:
		grav[c * 3 + 1] = -1.0
	bufs["gravity"] = _f32(grav, owned)
	bufs["g_rest"] = _f32(grav, owned)
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	owned.append(nbr)
	bufs["nbr"] = nbr
	# THE FACE LIST'S OWN GEOMETRY: where a cell's faces begin, the face pointing back, and its edge.
	var off_b: PackedByteArray = _grid.slot_off.to_byte_array()
	var par_b: PackedByteArray = _grid.partners.to_byte_array()
	var edge_b: PackedByteArray = _grid.cell_edges().to_byte_array()
	bufs["slot_off"] = _rd.storage_buffer_create(off_b.size(), off_b)
	bufs["face_partner"] = _rd.storage_buffer_create(par_b.size(), par_b)
	bufs["cell_edge"] = _rd.storage_buffer_create(edge_b.size(), edge_b)
	owned.append(bufs["slot_off"])
	owned.append(bufs["face_partner"])
	owned.append(bufs["cell_edge"])
	# The vertical relation GravityPass publishes on the real world: up is the slot along -g, and below is
	# that map's scattered inverse. The reaction kernel reads these two, so a rig declaring g builds them.
	var vup: PackedInt32Array = PackedInt32Array()
	var vdn: PackedInt32Array = PackedInt32Array()
	vup.resize(cc)
	vdn.resize(cc)
	vdn.fill(-1)
	for c in cc:
		vup[c] = _grid.neighbours[_grid.slot_begin(c, LAVoxelGrid.S_POS_Y)]
	for c in cc:
		var u: int = vup[c]
		if u >= 0 and (vdn[u] < 0 or c < vdn[u]):
			vdn[u] = c
	for pair in [["vert_up", vup], ["vert_down", vdn]]:
		var by: PackedByteArray = (pair[1] as PackedInt32Array).to_byte_array()
		var rid: RID = _rd.storage_buffer_create(by.size(), by)
		owned.append(rid)
		bufs[String(pair[0])] = rid

	for key in cond:
		var vals: PackedFloat32Array = _filled(cc, 0.0)
		var per: Dictionary = cond[key]
		for c in per:
			vals[int(c)] = float(per[c])
		_rd.buffer_update(bufs[String(key)], 0, vals.to_byte_array().size(), vals.to_byte_array())

	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	if not recs.is_empty():
		bufs["reaction_records"] = recs
	p.setup(_rd, LAFieldDriver.on(_rd), bufs, cc)
	p._driver.open()
	p.dispatch(_rd, {"sun_dir": Vector3.ZERO}, cc, int(ceil(float(cc) / 64.0)))
	p._driver.close()
	var out: Dictionary = {}
	for key in ["silicate", "carbonate", "silica", "h2o", "o2", "co2", "fuel", "detritus", "fungus"]:
		out[key] = _rd.buffer_get_data(bufs[key]).to_float32_array()
	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	return out


## The Urey record at temperature t_c: wet sky-open cell on bare bedrock. Liquid exists only above the
## freezing point — the state the ladder itself would derive. Returns the carbonate credited.
func _chem(t_c: float) -> Dictionary:
	var liq: float = 1.0 if t_c > LAPhysical.WATER_FREEZE_C else 0.0
	var bedrock: float = LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL
	var out: Dictionary = _run({
		"solid": {_bottom: 1.0},
		"silicate": {_bottom: bedrock},
		"grain": {_bottom: LAPhysical.GRAIN_D_LOWLAND_M},
		"temp": {_bottom: t_c, _mid: t_c, _grid.index(0, 2, 0): t_c},
		"pressure": {_bottom: LAPhysical.STANDARD_PRESSURE_PA, _mid: LAPhysical.STANDARD_PRESSURE_PA,
			_grid.index(0, 2, 0): LAPhysical.STANDARD_PRESSURE_PA},
		"h2o": {_mid: H2O_AT_CELL},
		"h2o_liquid": {_mid: liq},
		"h2o_solid": {_mid: 1.0 - liq},
		"co2": {_mid: CO2_AT_CELL},
	})
	return {"carbonate": float(out["carbonate"][_mid]), "silica": float(out["silica"][_mid]),
		"bedrock_removed": bedrock - float(out["silicate"][_bottom])}


## The frost record: cold open surface on wet regolith-bedrock. The pore water below is liquid or frozen
## according to the GROUND temperature, which is the state that starves deep cold.
func _frost(surface_c: float, ground_c: float) -> Dictionary:
	var liq: float = 1.0 if ground_c > LAPhysical.WATER_FREEZE_C else 0.0
	var bedrock: float = LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL
	var out: Dictionary = _run({
		"solid": {_bottom: 1.0},
		"silicate": {_bottom: bedrock},
		"grain": {_bottom: LAPhysical.GRAIN_D_LOWLAND_M},
		"regolith": {_bottom: 1.0},
		"h2o": {_bottom: PORE_WATER},
		"h2o_liquid": {_bottom: liq},
		"h2o_solid": {_bottom: 1.0 - liq},
		"temp": {_bottom: ground_c, _mid: surface_c, _grid.index(0, 2, 0): surface_c},
		"pressure": {_bottom: LAPhysical.STANDARD_PRESSURE_PA, _mid: LAPhysical.STANDARD_PRESSURE_PA,
			_grid.index(0, 2, 0): LAPhysical.STANDARD_PRESSURE_PA},
	})
	return {"debris": float(out["silicate"][_mid]),
		"bedrock_removed": bedrock - float(out["silicate"][_bottom]),
		"pore_debit": PORE_WATER - float(out["h2o"][_bottom]),
		"water_credit": float(out["h2o"][_mid])}


## Decomposition and combustion drawing one scarce oxygen pool, with the record table in a given order.
func _compete(recs: Array) -> Dictionary:
	var t_c: float = 300.0
	var out: Dictionary = _run({
		"temp": {_bottom: t_c, _mid: t_c, _grid.index(0, 2, 0): t_c},
		"pressure": {_bottom: LAPhysical.STANDARD_PRESSURE_PA, _mid: LAPhysical.STANDARD_PRESSURE_PA,
			_grid.index(0, 2, 0): LAPhysical.STANDARD_PRESSURE_PA},
		"fuel": {_mid: 1.0e2},
		"detritus": {_mid: 4.0e4},
		"fungus": {_mid: 4.0e4},
		"org_h": {_mid: 2.0 * (1.0e2 + 4.0e4)},
		"org_o": {_mid: 1.0 * (1.0e2 + 4.0e4)},
		"o2": {_mid: 5.0},
	}, recs)
	return {"o2": float(out["o2"][_mid]), "co2": float(out["co2"][_mid]),
		"fuel": float(out["fuel"][_mid]), "detritus": float(out["detritus"][_mid]),
		"fungus": float(out["fungus"][_mid])}


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_weathering_rate_law: " + msg)
		_fails += 1


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	_grid = LAVoxelGrid.new()
	_grid.build(1, 3, 1, CELL, Vector3(-0.5, -1.5, -0.5))
	_bottom = _grid.index(0, 0, 0)
	_mid = _grid.index(0, 1, 0)
	LAReactionDefs.cell_size_m = CELL

	var sweep: PackedFloat64Array = PackedFloat64Array([5.0, 15.0, 25.0, 35.0, 60.0])
	var chem: Dictionary = {}
	for t in sweep:
		chem[t] = _chem(float(t))
	var frozen: Dictionary = _chem(-10.0)
	var c25: float = float(chem[25.0]["carbonate"])
	var q10: float = float(chem[35.0]["carbonate"]) / maxf(c25, 1.0e-30)

	_expect(c25 > 0.0, "the Urey record credited no carbonate at 25 C — the positive control: either the "
		+ "pass did not run or chemical weathering is dead.")
	var prev: float = -1.0
	for t in sweep:
		var v: float = float(chem[t]["carbonate"])
		_expect(v >= prev, "chemical weathering is not monotone in temperature at %.1f C." % t)
		prev = v
	_expect(q10 > 1.8 and q10 < 2.8, "chemical weathering Q10 is %.2f, expected ~2.2 from the measured "
		% q10 + "activation energy.")
	_expect(float(frozen["carbonate"]) == 0.0, "aqueous dissolution proceeds at -10 C with no liquid "
		+ "water in the cell (%s)." % String.num_scientific(float(frozen["carbonate"])))
	var c: Dictionary = chem[25.0]
	var scale_c: float = maxf(float(c["carbonate"]), 1.0)
	# The bedrock delta is read off a float32 field holding the rock's full molar density, so its noise
	# floor is that field's ulp, not the credit fields' near-zero one.
	var rock_ulp: float = LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL \
		* 4.0 / 8388608.0
	_expect(absf(float(c["silica"]) - float(c["carbonate"])) <= TOL * scale_c,
		"Urey stoichiometry broke: carbonate %s and silica %s moles should be equal." % [
			String.num_scientific(float(c["carbonate"])), String.num_scientific(float(c["silica"]))])
	_expect(absf(float(c["bedrock_removed"]) - float(c["carbonate"])) <= maxf(TOL * scale_c, rock_ulp),
		"Urey stoichiometry broke: bedrock %s and carbonate %s moles should be equal." % [
			String.num_scientific(float(c["bedrock_removed"])), String.num_scientific(float(c["carbonate"]))])

	var f: Dictionary = _frost(-5.0, GROUND_WARM_C)
	var warm: Dictionary = _frost(-0.5, GROUND_WARM_C)
	var starved: Dictionary = _frost(-5.0, -5.0)
	var scale_f: float = maxf(float(f["debris"]), 1.0)
	_expect(float(f["debris"]) > 0.0, "frost shattering detached nothing at -5 C over liquid pore water.")
	_expect(absf(float(f["bedrock_removed"]) - float(f["debris"])) <= TOL * scale_f,
		"frost shattering does not conserve rock: %s left the bedrock, %s arrived as debris." % [
			String.num_scientific(float(f["bedrock_removed"])), String.num_scientific(float(f["debris"]))])
	_expect(absf(float(f["pore_debit"]) - float(f["water_credit"])) <= TOL * maxf(float(f["pore_debit"]), 1.0),
		"frost shattering does not conserve water: %s left the pores, %s arrived with the debris." % [
			String.num_scientific(float(f["pore_debit"])), String.num_scientific(float(f["water_credit"]))])
	_expect(float(warm["debris"]) == 0.0, "frost shattering runs at -0.5 C, above the tensile threshold "
		+ "segregation pressure must pass.")
	_expect(float(starved["debris"]) == 0.0, "frost shattering runs over FROZEN pore water — the supply "
		+ "must leave the state, not survive it.")

	# --- ORDER INDEPENDENCE: the same competition, the table forward and reversed --------------------------
	var table: Array = LAMaterialReactions3D.records()
	_expect(not table.is_empty(), "the live record table refused to build; the competition arm ran nothing.")
	var reversed_table: Array = table.duplicate()
	reversed_table.reverse()
	var fwd: Dictionary = _compete(table)
	var rev: Dictionary = _compete(reversed_table)
	_expect(float(fwd["o2"]) < 5.0 - 1.0, "the competition arm drew almost no oxygen (o2 %s of 5.0) — "
		% String.num_scientific(float(fwd["o2"])) + "nothing competed, so order independence was not tested.")
	for key in fwd:
		var a: float = float(fwd[key])
		var b: float = float(rev[key])
		_expect(absf(a - b) <= ORDER_REL_TOL * maxf(maxf(absf(a), absf(b)), 1.0e-3),
			"two records competing for one reactant depend on table order: %s is %s forward, %s reversed."
			% [String(key), String.num_scientific(a), String.num_scientific(b)])

	print('WEATHERING_RATE_LAW={"carbonate_25c":%s,"q10":%.3f,"carbonate_frozen":%s,"frost_debris":%s,"frost_warm":%s,"frost_starved":%s,"order_o2_fwd":%s,"order_o2_rev":%s,"failures":%d}'
		% [String.num_scientific(c25), q10, String.num_scientific(float(frozen["carbonate"])),
			String.num_scientific(float(f["debris"])), String.num_scientific(float(warm["debris"])),
			String.num_scientific(float(starved["debris"])), String.num_scientific(float(fwd["o2"])),
			String.num_scientific(float(rev["o2"])), _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^WEATHERING_RATE_LAW=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_weathering_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^WEATHERING_RATE_LAW=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no WEATHERING_RATE_LAW line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_weathering_rate_law:' >&2 || true
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the world the SIM seeds. The seed lays no carbonate, and the Urey record is its only
# writer, so a non-zero cell count is the reaction engine running against the sim's own field.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_WEATHERING_FRAMES:-20}"
# The Urey record arrives with the chemistry rung; the default one holds no reaction pass at all.
sim_out="$(la_report carbonate_cells --path "$REPO_ROOT" --rung "${LA_WEATHERING_RUNG:-8}" \
  --frames "$SIM_FRAMES" 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^carbonate_cells' || true
cells="$(printf '%s\n' "$sim_out" | sed -n "s/^carbonate_cells  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[^0-9eE.+-]//g')"
if ! printf '%s' "$cells" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
  echo "ERROR: the run published no carbonate_cells (sim_run exit $sim_rc), so the seeded world went" >&2
  echo "       unmeasured. Refusing to report a pass." >&2
  printf '%s\n' "$sim_out" | tail -20 >&2
  exit 2
fi
if ! awk -v c="$cells" 'BEGIN{exit !(c > 0)}'; then
  echo
  echo "In the world the sim seeds, no cell holds any carbonate after $SIM_FRAMES frames. The Urey record"
  echo "is carbonate's only writer, so chemical weathering is not running against the sim's own field —"
  echo "the rig above proved the kernel and this proves the wiring."
  exit 1
fi
echo "check_weathering_rate_law: OK"
