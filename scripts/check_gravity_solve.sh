#!/usr/bin/env bash
# =====================================================================================================
# GRAVITY SOLVE — checked against the one mass distribution with an exact closed-form answer.
#
# A uniform sphere of density rho and radius R has, EXACTLY:
#     inside  (r < R):  g = (4/3) pi G rho r      linear in r, zero at the centre
#     outside (r > R):  g = G M / r^2             and M = (4/3) pi R^3 rho
#
# So the solver can be checked rather than believed. This matters more here than for most gates: the
# thing being tested is that gravity comes OUT of the mass distribution. A centre-of-mass shortcut would
# also pass the outside test — it is the INSIDE profile, linear in r and vanishing at the centre, that
# only a real solve produces, because it is the enclosed mass that falls off, not the distance.
#
# It also checks a distribution with NO spherical symmetry at all: two separated blobs must produce a
# field that points from each toward the other, which the shell-theorem shortcut cannot represent.
#
# The mass is a silicate fill, so the SOURCE TERM is checked with the solve: the kernel weighs the same
# kg per unit fill that every other pass weighs, off LASubstances, and no density is written here.
#
# ARM TWO IS THE SIM'S OWN FIELD. Everything above builds its own sphere and its own sweep budget, so it
# says nothing about the world the sim seeds. The second arm boots the real world and reads Gauss's law
# off it: the flux of g out of the box is -4 pi G times the mass inside, so `gravity_gauss_rel` is +1
# when gravity points at the planet and -1 when it points away.
#
# The solve is a compute kernel, so this needs a real device: headless has none. It runs through
# run_sim_offscreen.sh, which takes the machine-wide GPU lock.
#
# EXIT CODES. 0 within tolerance · 1 the solver is wrong · 2 could not run.
# =====================================================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/gravity_poisson.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/GravityPass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: gravity_poisson.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: GravityPass.gd missing." >&2; exit 2; }

# A .glsl edited since its last import leaves the compiled .res stale, and the probe below would then
# check the PREVIOUS kernel and report a pass on it.
la_godot --headless --path "$REPO_ROOT" --import >/dev/null 2>&1

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_gravity_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

const N: int = 32
const CELL: float = 1.0
# Offset by half a cell so CELL CENTRES LAND ON INTEGERS, which puts a cell exactly at the origin. The
# first draft of this gate did not, so the "centre of the sphere" sample sat 0.87 cells out and read
# 10.6% of surface gravity — the solver's correct answer for that point, and a false failure.
const ORIGIN: Vector3 = Vector3(-0.5 * N * CELL - 0.5 * CELL, -0.5 * N * CELL - 0.5 * CELL, -0.5 * N * CELL - 0.5 * CELL)
const SWEEP_BUDGET: int = 400
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/GravityPass.gd"
const SOURCE_CHANNEL: String = "silicate"

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


## Solve for `fill` of the source channel and hand back the flat g field plus the drain's readings.
func _solve(grid, fill: PackedFloat32Array) -> Array:
	var cc: int = grid.cell_count
	var scr: GDScript = load(PASS_PATH)
	var p: RefCounted = scr.new()
	var bufs: Dictionary = {}
	var declared: Dictionary = p._buffers(cc)
	for key in declared:
		bufs[String(key)] = _f32(int(declared[key]))
	var nbr_bytes: PackedByteArray = grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_owned.append(nbr)
	bufs["nbr"] = nbr
	bufs["pos"] = _vec3_flat(grid)
	bufs["gravity"] = _f32(cc * 3)
	for name in LAMatterChannels.CHANNELS:
		bufs[String(name)] = _f32(cc)
	var src_bytes: PackedByteArray = fill.to_byte_array()
	_rd.buffer_update(bufs[SOURCE_CHANNEL], 0, src_bytes.size(), src_bytes)

	p.setup(_rd, bufs, cc)
	var groups: int = int(ceil(float(cc) / 64.0))
	var ctx: Dictionary = {"cell_size": CELL, "step_index": 0.0}
	var rounds: int = int(ceil(float(SWEEP_BUDGET) / float(scr.SWEEPS)))
	for _i in rounds:
		var cl: int = _rd.compute_list_begin()
		p.dispatch(_rd, cl, ctx, cc, groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
	var readings: Dictionary = p._drain(_rd)
	var g: PackedFloat32Array = p.mirror()
	p.dispose(_rd)
	return [g, readings]


func _g_at(g: PackedFloat32Array, c: int) -> Vector3:
	var b: int = c * 3
	if b + 2 >= g.size():
		return Vector3.ZERO
	return Vector3(g[b], g[b + 1], g[b + 2])


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


func _init() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_fail("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		return
	var rows: Dictionary = LAChannels.rows()
	var sub: String = String(rows.get(SOURCE_CHANNEL, {}).get("substance", ""))
	var rho: float = float(LASubstances.table().get(sub, {}).get("density", 0.0))
	if rho <= 0.0:
		_fail("LASubstances gives \"%s\" no density, so the gate has no source mass." % sub)
		return

	var g0 = LAVoxelGrid.new()
	g0.build(N, N, N, CELL, ORIGIN)
	var radius: float = 8.0
	var fill: PackedFloat32Array = PackedFloat32Array()
	fill.resize(g0.cell_count)
	var filled: float = 0.0
	for c in g0.cell_count:
		fill[c] = 1.0 if g0.cell_world_pos(c).length() < radius else 0.0
		filled += fill[c]
	var res: Array = _solve(g0, fill)
	var field: PackedFloat32Array = res[0]
	var readings: Dictionary = res[1]
	if field.size() != g0.cell_count * 3:
		_fail("the solve returned no field — refusing to report a pass.")
		return

	var big_g: float = LAPhysical.GRAVITATIONAL_CONSTANT
	# The body the solver was handed is the FILLED CELLS, whose volume is a lattice count rather than
	# (4/3) pi R^3. Its exterior field is GM/r^2 for that mass, so that is the mass the outside form uses.
	var mass: float = filled * rho * pow(CELL, 3.0)
	var worst_in: float = 0.0
	var worst_out: float = 0.0
	var worst_radial: float = 0.0
	for c in g0.cell_count:
		var p: Vector3 = g0.cell_world_pos(c)
		var r: float = p.length()
		if r < 2.0 * CELL or r > 0.42 * float(N) * CELL:
			continue                                   # skip the centre cell and the boundary layer
		var got: Vector3 = _g_at(field, c)
		var want_mag: float = 0.0
		if r < radius - CELL:
			want_mag = (4.0 / 3.0) * PI * big_g * rho * r
		elif r > radius + CELL:
			want_mag = big_g * mass / (r * r)
		else:
			continue                                   # the shell straddling the surface is discretised
		var rel: float = absf(got.length() - want_mag) / maxf(want_mag, 1.0e-30)
		if r < radius - CELL:
			worst_in = maxf(worst_in, rel)
		else:
			worst_out = maxf(worst_out, rel)
		# and it must point INWARD
		var radial_err: float = (got.normalized() + p.normalized()).length()
		worst_radial = maxf(worst_radial, radial_err)

	# Centre of a uniform sphere: g must vanish. Only a real solve gives this.
	var g_centre: float = _g_at(field, g0.cell_at(Vector3.ZERO)).length()
	var g_surface: float = (4.0 / 3.0) * PI * big_g * rho * radius
	var centre_ratio: float = g_centre / g_surface

	# The mass the kernel weighed, against the mass the fill carries.
	var mass_rel: float = absf(float(readings.get("gravity_total_mass_kg", 0.0)) - mass) / mass

	# No symmetry at all: two separated blobs must attract each other.
	var h = LAVoxelGrid.new()
	h.build(N, N, N, CELL, ORIGIN)
	var fill2: PackedFloat32Array = PackedFloat32Array()
	fill2.resize(h.cell_count)
	var a_c: Vector3 = Vector3(-6.0, 0.0, 0.0)
	var b_c: Vector3 = Vector3(6.0, 0.0, 0.0)
	for c in h.cell_count:
		var p2: Vector3 = h.cell_world_pos(c)
		fill2[c] = 1.0 if (p2 - a_c).length() < 3.0 or (p2 - b_c).length() < 3.0 else 0.0
	var res2: Array = _solve(h, fill2)
	var field2: PackedFloat32Array = res2[0]
	var ga: Vector3 = _g_at(field2, h.cell_at(a_c))
	var gb: Vector3 = _g_at(field2, h.cell_at(b_c))
	var attract: bool = ga.x > 0.0 and gb.x < 0.0

	var fail: int = 0
	if worst_in > 0.12: fail += 1
	if worst_out > 0.12: fail += 1
	if worst_radial > 0.05: fail += 1
	if centre_ratio > 0.02: fail += 1
	if mass_rel > 0.01: fail += 1
	if not attract: fail += 1
	print('GRAVITY_SOLVE={"inside_rel":%.4f,"outside_rel":%.4f,"radial_err":%.4f,"centre_ratio":%.4f,"source_mass_rel":%.4f,"two_body_attracts":%s,"sweeps":%d,"residual":%s,"failures":%d}'
		% [worst_in, worst_out, worst_radial, centre_ratio, mass_rel, str(attract).to_lower(),
			SWEEP_BUDGET, str(readings.get("gravity_residual_rel", "absent")), fail])
	for r2 in _owned:
		if r2.is_valid():
			_rd.free_rid(r2)
	_rd.free()
	quit(1 if fail > 0 else 0)
GD

out="$(LA_DONE_RE='^GRAVITY_SOLVE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_gravity_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^GRAVITY_SOLVE=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no GRAVITY_SOLVE line — refusing to report a pass." >&2
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
  echo "The solved field does not match the closed form for a uniform sphere. inside_rel/outside_rel are"
  echo "the magnitude errors; centre_ratio must vanish (only a real solve gives that, a GM/r^2 shortcut"
  echo "diverges there); source_mass_rel is the kernel's own weighing of the fill against the closed-form"
  echo "mass; two_body_attracts must hold for a distribution with no spherical symmetry."
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the field the SIM seeds, not one this script built.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_GRAVITY_FRAMES:-20}"
sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "$SIM_FRAMES" \
  --report gravity_gauss_rel,gravity_total_mass_kg 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^gravity_' || true
# A pass reading arrives as a gauge, so the value is behind a 'cur' key; a plain scalar has none.
reading() { printf '%s\n' "$sim_out" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[^0-9eE.+-]//g'; }
# `reading` strips every non-numeric character, so an absent gauge leaves a FRAGMENT that is non-empty and
# floors to 0 in awk. Emptiness is not the test; being a number is.
numeric() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }
gauss="$(reading gravity_gauss_rel)"
mass="$(reading gravity_total_mass_kg)"
if ! numeric "$gauss" || ! numeric "$mass"; then
  echo "ERROR: the run published no gravity_gauss_rel (sim_run exit $sim_rc), so the sim's own field went" >&2
  echo "       unmeasured. Refusing to report a pass." >&2
  printf '%s\n' "$sim_out" | tail -20 >&2
  exit 2
fi
# THE POSITIVE CONTROL. With no mass in the box the ratio is 0 by construction, which is not a verdict.
if ! awk -v m="$mass" 'BEGIN{exit !(m > 0)}'; then
  echo "ERROR: the box holds no mass, so Gauss's law asserts nothing about the sign of g." >&2
  exit 2
fi
if ! awk -v r="$gauss" 'BEGIN{exit !(r > 0)}'; then
  echo
  echo "In the world the sim seeds, the flux of g out of the box has the WRONG SIGN. Gauss's law puts that"
  echo "flux at -4 pi G times the mass inside, so the ratio printed above is +1 when gravity points at the"
  echo "planet and -1 when it points away. Gravity is pointing away, and every column walk that asks"
  echo "LAFieldGeometry.below()/above() — pressure, the regolith burial march, the lake flood, the surface"
  echo "seed — is running upward."
  exit 1
fi
echo "check_gravity_solve: OK"
