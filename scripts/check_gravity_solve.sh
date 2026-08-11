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
# EXIT CODES. 0 within tolerance · 1 the solver is wrong · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/sim/voxel/FieldGravity.gd" ] || { echo "ERROR: FieldGravity.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_gravity_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

const N: int = 32
const CELL: float = 1.0
const MPU: float = 1.0          # solve in metres directly, so the analytic form needs no conversion
const RHO: float = 5.0e12       # kg/m^3; large so g is far above float32 noise at this toy scale
# Offset by half a cell so CELL CENTRES LAND ON INTEGERS, which puts a cell exactly at the origin. The
# first draft of this gate did not, so the "centre of the sphere" sample sat 0.87 cells out and read
# 10.6% of surface gravity — the solver's correct answer for that point, and a false failure.
const ORIGIN: Vector3 = Vector3(-0.5 * N * CELL - 0.5 * CELL, -0.5 * N * CELL - 0.5 * CELL, -0.5 * N * CELL - 0.5 * CELL)

func _init() -> void:
	var g = LAVoxelGrid.new()
	g.build(N, N, N, CELL, ORIGIN)
	var solver = LAFieldGravity.new()
	solver.setup(g, MPU)

	var radius: float = 8.0
	var rho: PackedFloat32Array = PackedFloat32Array()
	rho.resize(g.cell_count)
	for c in g.cell_count:
		rho[c] = RHO if g.cell_world_pos(c).length() < radius else 0.0
	solver.solve(rho, 400)

	var big_g: float = LAFieldGravity.G_SI
	var mass: float = (4.0 / 3.0) * PI * pow(radius, 3.0) * RHO
	var worst_in: float = 0.0
	var worst_out: float = 0.0
	var worst_radial: float = 0.0
	for c in g.cell_count:
		var p: Vector3 = g.cell_world_pos(c)
		var r: float = p.length()
		if r < 2.0 * CELL or r > 0.42 * float(N) * CELL:
			continue                                   # skip the centre cell and the boundary layer
		var got: Vector3 = solver.g_at(c)
		var want_mag: float = 0.0
		if r < radius - CELL:
			want_mag = (4.0 / 3.0) * PI * big_g * RHO * r
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
	var centre: int = g.cell_at(Vector3.ZERO)
	var g_centre: float = solver.g_at(centre).length()
	var g_surface: float = (4.0 / 3.0) * PI * big_g * RHO * radius
	var centre_ratio: float = g_centre / g_surface

	# No symmetry at all: two separated blobs must attract each other.
	var h = LAVoxelGrid.new()
	h.build(N, N, N, CELL, ORIGIN)
	var s2 = LAFieldGravity.new()
	s2.setup(h, MPU)
	var rho2: PackedFloat32Array = PackedFloat32Array()
	rho2.resize(h.cell_count)
	var a_c: Vector3 = Vector3(-6.0, 0.0, 0.0)
	var b_c: Vector3 = Vector3(6.0, 0.0, 0.0)
	for c in h.cell_count:
		var p: Vector3 = h.cell_world_pos(c)
		rho2[c] = RHO if (p - a_c).length() < 3.0 or (p - b_c).length() < 3.0 else 0.0
	s2.solve(rho2, 400)
	var ga: Vector3 = s2.g_at(h.cell_at(a_c))
	var gb: Vector3 = s2.g_at(h.cell_at(b_c))
	var attract: bool = ga.x > 0.0 and gb.x < 0.0

	var fail: int = 0
	if worst_in > 0.12: fail += 1
	if worst_out > 0.12: fail += 1
	if worst_radial > 0.05: fail += 1
	if centre_ratio > 0.02: fail += 1
	if not attract: fail += 1
	print('GRAVITY_SOLVE={"inside_rel":%.4f,"outside_rel":%.4f,"radial_err":%.4f,"centre_ratio":%.4f,"two_body_attracts":%s,"residual":%s,"failures":%d}'
		% [worst_in, worst_out, worst_radial, centre_ratio, str(attract).to_lower(), str(solver.last_residual), fail])
	quit(1 if fail > 0 else 0)
GD

out="$("$GODOT" --headless --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_gravity_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^GRAVITY_SOLVE=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no GRAVITY_SOLVE line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
if [ "$rc" -ne 0 ]; then
  echo
  echo "The solved field does not match the closed form for a uniform sphere. inside_rel/outside_rel are"
  echo "the magnitude errors; centre_ratio must vanish (only a real solve gives that, a GM/r^2 shortcut"
  echo "diverges there); two_body_attracts must hold for a distribution with no spherical symmetry."
  exit 1
fi
echo "check_gravity_solve: OK"
