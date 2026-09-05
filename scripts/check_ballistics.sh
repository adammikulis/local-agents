#!/usr/bin/env bash
# Free fall against t = sqrt(2h/g) and v = sqrt(2gh); the same fall under gravity_poisson.glsl solved,
# against the work that field does along the path; a closed orbit over four periods against the
# semi-implicit bound 2 omega dt; the seeded world's own reading of g. Controls: no gravity never lands,
# no central mass never orbits. Needs a device, so it runs through run_sim_offscreen.sh and its GPU lock.
# EXIT 0 within tolerance - 1 the integrator is wrong - 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
la_body_scoped "$(basename "$0")" || exit $?

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
SRC="$REPO_ROOT/addons/local_agents/gdextensions/localagents/src/LABallistics.cpp"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/GravityPass.gd"
[ -f "$SRC" ] || { echo "ERROR: LABallistics.cpp missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: GravityPass.gd missing." >&2; exit 2; }

la_cap_dir >/dev/null || la_godot --headless --path "$REPO_ROOT" --import >/dev/null 2>&1

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_ballistics_gate.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/GravityPass.gd"
const SOURCE_CHANNEL: String = "silicate"

# A. a body-sized field over a flat floor.
const A_N: int = 32
const A_CELL: float = 10.0
const A_BODY_R: float = 6.371e6          # m
const A_BODY_M: float = 5.972e24         # kg
const A_DROP_H: float = 200.0            # m above the rock
const A_DT: float = 0.01                 # s
# B. the solved sphere.
const B_N: int = 32
const B_CELL: float = 0.5
const B_DT: float = 1.0
# C. one orbit.
const C_R: float = 4.2e7                 # m
const C_STEPS_PER_PERIOD: int = 4000
const C_PERIODS: int = 4

var _rd: RenderingDevice = null
var _owned: Array[RID] = []


func _f32(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _vec3_flat(grid) -> RID:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(grid.cell_count * 3)
	for c in grid.cell_count:
		var v: Vector3 = grid.cell_world_pos(c)
		f[c * 3] = v.x
		f[c * 3 + 1] = v.y
		f[c * 3 + 2] = v.z
	var b: PackedByteArray = f.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


## GravityPass over `fill`, converged; hands back the drained mirror.
func _solve(grid, fill: PackedFloat32Array) -> PackedFloat32Array:
	var cc: int = grid.cell_count
	var p: RefCounted = load(PASS_PATH).new()
	var bufs: Dictionary = {}
	for key in p._buffers(cc):
		bufs[String(key)] = _f32(int(p._buffers(cc)[key]))
	for pair in [["nbr", grid.neighbours], ["slot_off", grid.slot_off], ["face_partner", grid.partners]]:
		var bytes: PackedByteArray = pair[1].to_byte_array()
		bufs[String(pair[0])] = _rd.storage_buffer_create(bytes.size(), bytes)
		_owned.append(bufs[String(pair[0])])
	var edge_b: PackedByteArray = grid.cell_edges().to_byte_array()
	bufs["cell_edge"] = _rd.storage_buffer_create(edge_b.size(), edge_b)
	_owned.append(bufs["cell_edge"])
	bufs["pos"] = _vec3_flat(grid)
	bufs["gravity"] = _f32(cc * 3)
	bufs["grav_phi"] = _f32(cc)
	bufs["grav_ref"] = _f32(cc)
	for name in LAMatterChannels.CHANNELS:
		bufs[String(name)] = _f32(cc)
	var src_bytes: PackedByteArray = fill.to_byte_array()
	_rd.buffer_update(bufs[SOURCE_CHANNEL], 0, src_bytes.size(), src_bytes)
	p.grid_dims = Vector3i(B_N, B_N, B_N)
	p.setup(_rd, bufs, cc)
	p.solve_converged(_rd, grid, cc, int(ceil(float(cc) / 64.0)))
	p._drain(_rd)
	var g: PackedFloat32Array = p.mirror()
	p.dispose(_rd)
	return g


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


## Run one body to the ground; [landed, time, speed] or [false, steps*dt, 0].
func _fall(pos: Vector3, dt: float, max_steps: int) -> Array:
	var id: int = LABallistics.drop(pos, Vector3.ZERO, 0.0, 0.0)
	for i in range(max_steps):
		var rows: Array = LABallistics.step(dt)
		if not rows.is_empty():
			var st: Dictionary = LABallistics.state(id)
			LABallistics.release(id)
			return [true, float(rows[0]["time"]), float(rows[0]["speed"]),
				(rows[0]["position"] as Vector3)]
	var out: Array = [false, float(max_steps) * dt, 0.0, LABallistics.state(id)["position"]]
	LABallistics.release(id)
	return out


func _init() -> void:
	QuietWindow.apply_if_automated()
	var big_g: float = LAPhysical.GRAVITATIONAL_CONSTANT
	var fail: int = 0

	# ---- A. free fall over a floor, in the field of a declared body -------------------------------
	var ga = LAVoxelGrid.new()
	var a_origin: Vector3 = Vector3(-0.5 * A_N * A_CELL, -5.0 * A_CELL, -0.5 * A_N * A_CELL)
	ga.build(A_N, A_N, A_N, A_CELL, a_origin)
	var centre: Vector3 = Vector3(0.0, -A_BODY_R, 0.0)
	var g_field: PackedFloat32Array = PackedFloat32Array()
	g_field.resize(ga.cell_count * 3)
	var solid: PackedByteArray = PackedByteArray()
	solid.resize(ga.cell_count)
	for c in ga.cell_count:
		var p: Vector3 = ga.cell_world_pos(c)
		var d: Vector3 = centre - p
		var r: float = d.length()
		var gv: Vector3 = d.normalized() * (big_g * A_BODY_M / (r * r))
		g_field[c * 3] = gv.x
		g_field[c * 3 + 1] = gv.y
		g_field[c * 3 + 2] = gv.z
		solid[c] = 1 if p.y < 0.0 else 0
	LABallistics.set_system([])
	LABallistics.set_field(ga, g_field, solid, [])
	var start: Vector3 = Vector3(0.0, A_DROP_H, 0.0)
	var g_here: float = LABallistics.g_at(start).length()
	var res: Array = _fall(start, A_DT, 200000)
	var h: float = A_DROP_H - (res[3] as Vector3).y
	var t_exact: float = sqrt(2.0 * h / g_here)
	var v_exact: float = sqrt(2.0 * g_here * h)
	var t_err: float = absf(float(res[1]) - t_exact)
	var v_rel: float = absf(float(res[2]) - v_exact) / v_exact
	if not bool(res[0]):
		fail += 1
	if t_err > A_DT:
		fail += 1
	# The semi-implicit method is first order, so its own bound on the impact speed is one step in t.
	if v_rel > A_DT / t_exact:
		fail += 1

	# CONTROL: no gravity, no landing.
	var zero_g: PackedFloat32Array = PackedFloat32Array()
	zero_g.resize(ga.cell_count * 3)
	LABallistics.set_field(ga, zero_g, solid, [])
	var control: Array = _fall(start, A_DT, 4000)
	if bool(control[0]):
		fail += 1

	# ---- B. the same fall, under the field gravity_poisson.glsl actually solved ------------------
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_fail("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		return
	var rows: Dictionary = LAChannels.rows()
	var sub: String = String(rows.get(SOURCE_CHANNEL, {}).get("substance", ""))
	var full: float = LASubstances.full_mol_m3(sub)
	if full <= 0.0:
		_fail("LASubstances gives \"%s\" no molar mass, so the gate has no source mass." % sub)
		return
	var gb = LAVoxelGrid.new()
	var b_origin: Vector3 = Vector3(-0.5 * B_N * B_CELL, -0.5 * B_N * B_CELL, -0.5 * B_N * B_CELL)
	gb.build(B_N, B_N, B_N, B_CELL, b_origin)
	var b_radius: float = 8.0 * B_CELL
	var fill: PackedFloat32Array = PackedFloat32Array()
	fill.resize(gb.cell_count)
	var b_solid: PackedByteArray = PackedByteArray()
	b_solid.resize(gb.cell_count)
	for c in gb.cell_count:
		var inside: bool = gb.cell_world_pos(c).length() < b_radius
		fill[c] = full if inside else 0.0
		b_solid[c] = 1 if inside else 0
	var solved: PackedFloat32Array = _solve(gb, fill)
	if solved.size() != gb.cell_count * 3:
		_fail("the gravity solve returned no field — refusing to report a pass.")
		return
	LABallistics.set_field(gb, solved, b_solid, [])
	var b_start: Vector3 = Vector3(0.0, 6.0, 0.0)
	var b_res: Array = _fall(b_start, B_DT, 200000)
	var b_land: Vector3 = b_res[3]
	# The work the same field does along the path. v^2 = 2 * int |g| dr is energy, not a uniform-g guess.
	var work: float = 0.0
	var samples: int = 4096
	var seg: Vector3 = b_start - b_land
	var step_m: float = seg.length() / float(samples)
	for i in range(samples):
		var mid: Vector3 = b_land + seg * ((float(i) + 0.5) / float(samples))
		work += LABallistics.g_at(mid).length() * step_m
	var b_v_exact: float = sqrt(2.0 * work)
	var b_rel: float = absf(float(b_res[2]) - b_v_exact) / maxf(b_v_exact, 1.0e-30)
	if not bool(b_res[0]):
		fail += 1
	if b_rel > B_DT / maxf(float(b_res[1]), 1.0e-30):
		fail += 1

	# ---- C. a closed orbit outside the box, under the point-mass sum ------------------------------
	LABallistics.clear_field()
	var mu: float = big_g * A_BODY_M
	var period: float = TAU * sqrt(pow(C_R, 3.0) / mu)
	var dt_c: float = period / float(C_STEPS_PER_PERIOD)
	var bound: float = 2.0 * TAU / float(C_STEPS_PER_PERIOD)
	LABallistics.set_system([{
		"center": Vector3.ZERO, "mass_kg": A_BODY_M, "radius_m": A_BODY_R, "frame": true,
	}])
	var v_circ: float = LABallistics.circular_speed(Vector3(C_R, 0.0, 0.0))
	var worst: float = _orbit_drift(A_BODY_M, dt_c, v_circ)
	# CONTROL: the same launch with the central mass taken away is a straight line, not an orbit.
	var worst_control: float = _orbit_drift(0.0, dt_c, v_circ)
	if worst > bound:
		fail += 1
	if worst_control <= bound:
		fail += 1

	print('BALLISTICS={"fall_t_err_s":%.6f,"fall_v_rel":%.6f,"fall_dt_s":%.4f,"no_g_landed":%s,'
		% [t_err, v_rel, A_DT, str(bool(control[0])).to_lower()]
		+ '"solved_v_rel":%.6f,"solved_landed":%s,"orbit_drift":%.6f,"orbit_bound":%.6f,'
		% [b_rel, str(bool(b_res[0])).to_lower(), worst, bound]
		+ '"no_mass_drift":%.6f,"failures":%d}' % [worst_control, fail])
	for r2 in _owned:
		if r2.is_valid():
			_rd.free_rid(r2)
	_rd.free()
	quit(1 if fail > 0 else 0)


## Largest relative departure of the orbital radius over C_PERIODS, for a central body of `mass_kg`.
func _orbit_drift(mass_kg: float, dt: float, v_circ: float) -> float:
	LABallistics.clear()
	LABallistics.set_system([{
		"center": Vector3.ZERO, "mass_kg": mass_kg, "radius_m": A_BODY_R, "frame": true,
	}])
	var pos: Vector3 = Vector3(C_R, 0.0, 0.0)
	var id: int = LABallistics.drop(pos, Vector3(0.0, v_circ, 0.0), 0.0, 0.0)
	var worst: float = 0.0
	for i in range(C_STEPS_PER_PERIOD * C_PERIODS):
		LABallistics.step(dt)
		var st: Dictionary = LABallistics.state(id)
		if st.is_empty() or bool(st["landed"]):
			LABallistics.release(id)
			return INF
		var r: float = (st["position"] as Vector3).length()
		worst = maxf(worst, absf(r - C_R) / C_R)
	LABallistics.release(id)
	return worst
GD

out="$(LA_DONE_RE='^BALLISTICS=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_ballistics_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^BALLISTICS=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no BALLISTICS line — refusing to report a pass." >&2
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
  echo "The one integrator does not reproduce free fall or a closed orbit. fall_t_err_s must be inside one"
  echo "step and fall_v_rel inside the method's own first-order bound; no_g_landed must be false, since a"
  echo "mass with no gravity never reaches the ground; solved_v_rel is the impact speed against the work"
  echo "the solved field does along the same path; orbit_drift must stay under orbit_bound over four"
  echo "periods while no_mass_drift, the same orbit with the central mass taken away, must not."
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM D — the world the SIM seeds, not one this script built. The field the run solves is handed to the
# integrator every step, so what LABallistics reads for g at a cell centre must be that cell's own value
# in the drained mirror. A run that never publishes its field falls back to the point-mass sum instead.
# ---------------------------------------------------------------------------------------------------
sim_out="$(la_report ballistics_read_rel,ballistics_live --body \
  --path "$REPO_ROOT" --frames "${LA_BALLISTICS_FRAMES:-20}" 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^ballistics_' || true
reading() { printf '%s\n' "$sim_out" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[^0-9eE.+-]//g'; }
numeric() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }
rel="$(reading ballistics_read_rel)"
# THE POSITIVE CONTROL. The gauge skips a cell whose solved g is zero, so a field of zeroes reads NAN
# rather than a perfect score, and `numeric` refuses it here rather than counting it as a pass.
if ! numeric "$rel"; then
  echo "ERROR: the run published no ballistics_read_rel (sim_run exit $sim_rc), so the integrator went" >&2
  echo "       unmeasured against the world the sim seeds. Refusing to report a pass." >&2
  printf '%s\n' "$sim_out" | tail -20 >&2
  exit 2
fi
echo "ballistics_read_rel = $rel"
if awk -v r="$rel" 'BEGIN{exit !(r > 0.001)}'; then
  echo
  echo "In the world the sim seeds, what the one integrator reads for g at a cell centre is not that"
  echo "cell's own solved value. Either the field never reaches LABallistics (LAGravity.publish_field off"
  echo "SystemOrbits.update), or the cell the reader picks is not the cell the point is in."
  exit 1
fi
echo "check_ballistics: OK"
