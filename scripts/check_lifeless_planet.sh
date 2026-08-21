#!/usr/bin/env bash
# THE REFERENT IS A LIFELESS POST-THEIA EARTH: free O2 at zero, no biosphere. Life may not ignite from
# sunlight and minerals. Rig arm, via the REAL ReactionsPass over the LIVE table: a lit, warm, wet,
# fertile, CO2-rich cell with biomass present fixes carbon (the positive control), and the same cell with
# ZERO biomass produces no O2 and no organic matter of any kind. Seeded arm: the world the sim seeds
# holds free O2 and biomass at exactly zero.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: reactions_sphere3d.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: ReactionsPass.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_lifeless_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd"
const CELL: float = 1.0
const H2O_MOL_M3: float = LAPhysical.WATER_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
const PORE_WATER: float = 0.3 * H2O_MOL_M3
const CO2_AT_CELL: float = 0.25 * LAPhysical.AIR_MOLAR_DENSITY_MOL_M3
const FERT_AT_CELL: float = 10.0
const BIOMASS_ALIVE: float = 100.0

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


## One dispatch of the real reactions pass over a 1x3x1 column, sun overhead, the LIVE record table.
func _run(cond: Dictionary) -> Dictionary:
	var cc: int = _grid.cell_count
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in ["col_e", "strike"]:
		bufs[name] = _f32(_filled(cc, 0.0), owned)
	bufs["cell_vol"] = _f32(_filled(cc, CELL * CELL * CELL), owned)
	var grav: PackedFloat32Array = PackedFloat32Array()
	grav.resize(cc * 3)
	for c in cc:
		grav[c * 3 + 1] = -1.0
	bufs["gravity"] = _f32(grav, owned)
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	owned.append(nbr)
	bufs["nbr"] = nbr

	for key in cond:
		var vals: PackedFloat32Array = _filled(cc, 0.0)
		var per: Dictionary = cond[key]
		for c in per:
			vals[int(c)] = float(per[c])
		_rd.buffer_update(bufs[String(key)], 0, vals.to_byte_array().size(), vals.to_byte_array())

	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	p.setup(_rd, bufs, cc)
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, {"sun_dir": Vector3(0.0, 1.0, 0.0)}, cc, int(ceil(float(cc) / 64.0)))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var out: Dictionary = {}
	for key in ["o2", "biomass", "fungus", "detritus", "fuel", "co2"]:
		out[key] = _rd.buffer_get_data(bufs[key]).to_float32_array()
	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	return out


## A lit open cell at the photosynthetic optimum on wet fertile regolith, holding `biomass_mol_m3`.
func _arm(biomass_mol_m3: float) -> Dictionary:
	var t: float = LABioRecords.PHOTO_T_OPT
	var top: int = _grid.index(0, 2, 0)
	var out: Dictionary = _run({
		"solid": {_bottom: 1.0},
		"silicate": {_bottom: LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CASIO3_KG_MOL},
		"regolith": {_bottom: 1.0},
		"h2o": {_bottom: PORE_WATER},
		"h2o_liquid": {_bottom: 1.0},
		"temp": {_bottom: t, _mid: t, top: t},
		"pressure": {_bottom: LAPhysical.STANDARD_PRESSURE_PA, _mid: LAPhysical.STANDARD_PRESSURE_PA,
			top: LAPhysical.STANDARD_PRESSURE_PA},
		"co2": {_mid: CO2_AT_CELL},
		"fert": {_mid: FERT_AT_CELL},
		"biomass": {_mid: biomass_mol_m3},
	})
	return {"o2": float(out["o2"][_mid]), "biomass": float(out["biomass"][_mid]),
		"fungus": float(out["fungus"][_mid]), "detritus": float(out["detritus"][_mid]),
		"fuel": float(out["fuel"][_mid]), "co2": float(out["co2"][_mid])}


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_lifeless_planet: " + msg)
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

	var alive: Dictionary = _arm(BIOMASS_ALIVE)
	var lifeless: Dictionary = _arm(0.0)

	_expect(float(alive["o2"]) > 0.0, "the positive control fixed no carbon: a lit, warm, wet, fertile, "
		+ "CO2-rich cell HOLDING BIOMASS credited no O2 — photosynthesis is dead, so the lifeless arm "
		+ "below proves nothing.")
	_expect(float(alive["co2"]) < CO2_AT_CELL, "the positive control drew no CO2 while crediting O2.")
	_expect(float(lifeless["o2"]) == 0.0, "life ignites from nothing: a cell with ZERO biomass credited "
		+ "O2 (%s) — a bio record runs without its living catalyst." % String.num_scientific(float(lifeless["o2"])))
	for key in ["biomass", "fungus", "detritus", "fuel"]:
		_expect(float(lifeless[key]) == 0.0, "organic matter from minerals and sunlight: %s is %s in a "
			% [String(key), String.num_scientific(float(lifeless[key]))] + "cell holding no life.")

	print('LIFELESS_PLANET={"alive_o2":%s,"lifeless_o2":%s,"lifeless_biomass":%s,"failures":%d}'
		% [String.num_scientific(float(alive["o2"])), String.num_scientific(float(lifeless["o2"])),
			String.num_scientific(float(lifeless["biomass"])), _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^LIFELESS_PLANET=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_lifeless_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^LIFELESS_PLANET=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no LIFELESS_PLANET line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_lifeless_planet:' >&2 || true
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the world the SIM seeds is lifeless and unoxygenated, and must stay so.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_LIFELESS_FRAMES:-20}"
sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "$SIM_FRAMES" \
  --report o2_total,biomass_total 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^(o2_total|biomass_total)' || true
fail=0
for key in o2_total biomass_total; do
  val="$(printf '%s\n' "$sim_out" | sed -n "s/^$key  *= *//p" | head -1 \
    | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[^0-9eE.+-]//g')"
  if ! printf '%s' "$val" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
    echo "ERROR: the run published no $key (sim_run exit $sim_rc), so the seeded world went unmeasured." >&2
    printf '%s\n' "$sim_out" | tail -20 >&2
    exit 2
  fi
  if ! awk -v c="$val" 'BEGIN{exit !(c == 0)}'; then
    echo
    echo "The seeded world is a lifeless post-Theia Earth: nothing seeds biomass and free O2 is zero,"
    echo "yet $key reads $val after $SIM_FRAMES frames. A record is creating life or free oxygen."
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
echo "check_lifeless_planet: OK"
