#!/usr/bin/env bash
# THE TIDE OF THE DECLARED BODIES, against Murray & Dermott 1999 sections 4.2-4.3: the acceleration at
# the sub-, anti- and transverse points of the seeded planet and the equilibrium height a site traces
# over one turn, each the exact difference of pulls bracketed by its own leading term 2 G M R / d^3 and
# the tide (M_b/M_p)(R/d)^3 R (3cos^2-1)/2, then the same in the seeded world's own report. CONTROLS: a
# moon of no mass raises nothing. EXIT 0 the tide is the tide - 1 it is not - 2 the gate could not run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib_require.sh"
. "$REPO_ROOT/scripts/lib_godot.sh"
. "$REPO_ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/state_derive.glsl"
[ -f "$KERNEL" ] || { echo "ERROR: state_derive.glsl missing." >&2; exit 2; }
command -v "${GODOT:-godot}" >/dev/null 2>&1 || {
	echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
la_cap_dir >/dev/null || la_godot --headless --path "$REPO_ROOT" --import >/dev/null 2>&1

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_tides_gate.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

## Relative agreement demanded of two readings of one closed form. A Vector3 crossing the binding is
## binary32, so a reading taken as one is held to that; a potential comes back in double.
const CPU_TOL: float = 1.0e-6
## Sites the height is traced through over one turn, and the finite difference the gradient is taken at
## as a fraction of the body's radius: near the step where the difference's own second-order truncation
## meets the binary32 resolution of a radius, which is what GRAD_TOL then admits.
const TURN_SITES: int = 72
const GRAD_FRAC: float = 4.0e-3
const GRAD_TOL: float = 1.0e-3
var _fails: int = 0
## A gate that could not run FAILS, and never as a wrong answer: this outranks the count above.
var _unrunnable: bool = false


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_tides: " + msg)
		_fails += 1


func _fail(msg: String) -> void:
	printerr("check_tides: " + msg)
	_unrunnable = true
	quit(2)


## The system as the seed declares it, in the planet's own frame. `keys` picks which bodies stand in it,
## so the star's tide and the moon's can be read apart; `moon_mass` scales the moon's matter.
func _system(keys: Array, moon_mass: float) -> void:
	var rows: Array = []
	for k in keys:
		var row: Dictionary = LABodySeeds.of(String(k))
		var m: float = float(row.get("mass_kg", 0.0))
		if String(k) == "moon":
			m *= moon_mass
		rows.append({"center": row.get("position_m", Vector3.ZERO) as Vector3, "mass_kg": m,
			"radius_m": LABodySeeds.seed_radius_m(String(k)) if String(k) == "planet" else -1.0,
			"frame": String(k) == "planet"})
	LABallistics.set_system(rows)


## THE EXACT TIDE of one body at offset `b`, read at `s` from the frame centre: the pull there less the
## pull at the centre (Murray & Dermott 1999 eq. 4.1-4.3), written straight rather than in the reader's
## own rearrangement, and component by component because a Vector3 is binary32.
func _ref_accel(mu: float, b: Vector3, s: Vector3) -> Vector3:
	var dl: float = _ref_len(s.x - b.x, s.y - b.y, s.z - b.z)
	var bl: float = _ref_len(b.x, b.y, b.z)
	var k1: float = -mu / (dl * dl * dl)
	var k2: float = -mu / (bl * bl * bl)
	return Vector3(k1 * (float(s.x) - float(b.x)) + k2 * float(b.x),
		k1 * (float(s.y) - float(b.y)) + k2 * float(b.y),
		k1 * (float(s.z) - float(b.z)) + k2 * float(b.z))


## The potential that acceleration is minus the gradient of, J/kg. Same section, same care.
func _ref_phi(mu: float, b: Vector3, s: Vector3) -> float:
	var dl: float = _ref_len(s.x - b.x, s.y - b.y, s.z - b.z)
	var bl: float = _ref_len(b.x, b.y, b.z)
	var sb: float = float(s.x) * float(b.x) + float(s.y) * float(b.y) + float(s.z) * float(b.z)
	return -mu * (1.0 / dl - 1.0 / bl - sb / (bl * bl * bl))


func _ref_len(x: float, y: float, z: float) -> float:
	return sqrt(x * x + y * y + z * z)


func _rel(got: float, want: float) -> float:
	return absf(got - want) / maxf(absf(want), 1.0e-300)


func _init() -> void:
	QuietWindow.apply_if_automated()
	var big_g: float = LAPhysical.GRAVITATIONAL_CONSTANT
	var r_body: float = LABodySeeds.seed_radius_m("planet")
	var m_body: float = float(LABodySeeds.of("planet").get("mass_kg", 0.0))
	var moon: Dictionary = LABodySeeds.of("moon")
	var star: Dictionary = LABodySeeds.of("star")
	if not (r_body > 0.0 and m_body > 0.0 and float(moon.get("mass_kg", 0.0)) > 0.0):
		_fail("the seed declares no planet radius, planet mass or moon mass, so there is no tide to read.")
		return
	var b_moon: Vector3 = moon["position_m"]
	var b_star: Vector3 = star["position_m"]
	var mu_moon: float = big_g * float(moon["mass_kg"])
	var mu_star: float = big_g * float(star["mass_kg"])
	var g_surface: float = big_g * m_body / (r_body * r_body)

	# ---- 1. the four points, under the moon alone -------------------------------------------------
	_system(["planet", "moon"], 1.0)
	var toward: Vector3 = b_moon.normalized()
	var across: Vector3 = toward.cross(Vector3(0.0, 1.0, 0.0))
	if across.length() < 0.5:
		across = toward.cross(Vector3(1.0, 0.0, 0.0))
	across = across.normalized()
	var d_moon: float = b_moon.length()
	var x: float = r_body / d_moon
	var sub: Vector3 = toward * r_body
	var anti: Vector3 = -toward * r_body
	var tran: Vector3 = across * r_body
	var got_sub: Vector3 = LABallistics.tidal_at(sub)
	var got_anti: Vector3 = LABallistics.tidal_at(anti)
	var got_tran: Vector3 = LABallistics.tidal_at(tran)
	_expect(_rel(got_sub.length(), _ref_accel(mu_moon, b_moon, sub).length()) < CPU_TOL,
		"the sub-lunar acceleration is not the pull there less the pull at the centre.")
	_expect(_rel(got_anti.length(), _ref_accel(mu_moon, b_moon, anti).length()) < CPU_TOL,
		"the anti-lunar acceleration is not the pull there less the pull at the centre.")
	_expect(_rel(got_tran.length(), _ref_accel(mu_moon, b_moon, tran).length()) < CPU_TOL,
		"the transverse acceleration is not the pull there less the pull at the centre.")
	# THE SCALE, against the leading term of the same expansion. The exact reading stands above 2 G M R /
	# d^3 at the near point and below it at the far one, by no more than the next order in R/d.
	var lead: float = 2.0 * mu_moon * r_body / pow(d_moon, 3.0)
	var near_ratio: float = got_sub.dot(toward) / lead
	var far_ratio: float = got_anti.dot(-toward) / lead
	var tran_ratio: float = got_tran.dot(-across) / (0.5 * lead)
	_expect(near_ratio >= 1.0 and near_ratio <= 1.0 + 3.0 * x,
		"the sub-lunar tide is %.4f of 2 G M R / d^3, outside [1, 1+3R/d]." % near_ratio)
	_expect(far_ratio <= 1.0 and far_ratio >= 1.0 - 3.0 * x,
		"the anti-lunar tide is %.4f of 2 G M R / d^3, outside [1-3R/d, 1]." % far_ratio)
	_expect(tran_ratio <= 1.0 and tran_ratio >= 1.0 - 3.0 * x * x,
		"the transverse tide is %.4f of -G M R / d^3, outside [1-3(R/d)^2, 1]." % tran_ratio)

	# ---- 2. the potential, and the height a site traces over one turn -----------------------------
	var worst_phi: float = 0.0
	var worst_height: float = 0.0
	var worst_grad: float = 0.0
	var zeta_max: float = -INF
	var zeta_min: float = INF
	# The equilibrium tide's own amplitude, (M_b/M_p)(R/d)^3 R.
	var amp: float = (float(moon["mass_kg"]) / m_body) * pow(x, 3.0) * r_body
	for i in TURN_SITES:
		var th: float = TAU * float(i) / float(TURN_SITES)
		var s: Vector3 = (toward * cos(th) + across * sin(th)) * r_body
		var phi: float = LABallistics.tidal_potential_at(s)
		worst_phi = maxf(worst_phi, _rel(phi, _ref_phi(mu_moon, b_moon, s)))
		# The equilibrium tide: water stands on the total equipotential, so its height over the datum is
		# the tidal potential over the local g.
		var zeta: float = -phi / g_surface
		zeta_max = maxf(zeta_max, zeta)
		zeta_min = minf(zeta_min, zeta)
		# The leading term, M&D eq. 4.24: (M_b/M_p)(R/d)^3 R (3cos^2 - 1)/2.
		var lead_z: float = amp * (3.0 * cos(th) * cos(th) - 1.0) * 0.5
		worst_height = maxf(worst_height, absf(zeta - lead_z) / (3.0 * x * amp))
		# The acceleration is minus the gradient of that potential: a central difference along the radius.
		var h: float = r_body * GRAD_FRAC
		var up: Vector3 = s.normalized()
		var d_phi: float = (LABallistics.tidal_potential_at(s + up * h)
			- LABallistics.tidal_potential_at(s - up * h)) / (2.0 * h)
		var a_radial: float = LABallistics.tidal_at(s).dot(up)
		worst_grad = maxf(worst_grad, _rel(-d_phi, a_radial))
	_expect(worst_phi < CPU_TOL,
		"the tidal potential is not the one the pulls come from (%s)." % String.num_scientific(worst_phi))
	# The leading term is the exact one to within the next order in R/d, and no closer.
	_expect(worst_height <= 1.0,
		"the equilibrium height departs from (M_b/M_p)(R/d)^3 R P2 by more than the next order in R/d.")
	# High to low over one turn is the 3/2 of that amplitude P2 runs through, within the same order.
	_expect(absf((zeta_max - zeta_min) - 1.5 * amp) <= 3.0 * x * amp,
		"the height a site traces over one turn does not span 3/2 of (M_b/M_p)(R/d)^3 R.")
	_expect(worst_grad < GRAD_TOL, "the acceleration is not minus the gradient of the potential (%s)."
		% String.num_scientific(worst_grad))

	# ---- 3. superposition: every body, no special case for either ---------------------------------
	_system(["planet", "star"], 1.0)
	var sun_sub: Vector3 = LABallistics.tidal_at(sub)
	var sun_lead: float = 2.0 * mu_star * r_body / pow(b_star.length(), 3.0)
	_expect(_rel(sun_sub.length(), _ref_accel(mu_star, b_star, sub).length()) < CPU_TOL,
		"the star raises no tide of its own.")
	_system(["planet", "moon", "star"], 1.0)
	var both: Vector3 = LABallistics.tidal_at(sub)
	_expect((both - (got_sub + sun_sub)).length() / both.length() < CPU_TOL,
		"the tide of two bodies is not the sum of their two tides.")

	# ---- CONTROL: a moon of no mass raises nothing ------------------------------------------------
	_system(["planet", "moon"], 0.0)
	var flat_range: float = 0.0
	for i in TURN_SITES:
		var th2: float = TAU * float(i) / float(TURN_SITES)
		var s2: Vector3 = (toward * cos(th2) + across * sin(th2)) * r_body
		flat_range = maxf(flat_range, absf(LABallistics.tidal_potential_at(s2)))
	_expect(LABallistics.tidal_at(sub) == Vector3.ZERO and flat_range == 0.0,
		"a moon of no mass still raises a tide.")

	# The star's amplitude is the star's: at the epoch's separation it is not the moon's.
	_expect(sun_lead < lead, "the star's tidal amplitude is not smaller than the moon's at this epoch.")

	print('TIDES_CPU={"near_ratio":%.6f,"far_ratio":%.6f,"tran_ratio":%.6f,"phi_rel":%s,'
		% [near_ratio, far_ratio, tran_ratio, String.num_scientific(worst_phi)]
		+ '"grad_rel":%s,"height_span_m":%.2f,"lunar_lead_m_s2":%s,"solar_lead_m_s2":%s,'
		% [String.num_scientific(worst_grad), zeta_max - zeta_min, String.num_scientific(lead),
			String.num_scientific(sun_lead)]
		+ '"flat_when_massless":%s,"failures":%d}'
		% [str(flat_range == 0.0).to_lower(), _fails])

	quit(2 if _unrunnable else (1 if _fails > 0 else 0))
GD

out="$(LA_DONE_RE='^TIDES_CPU=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
	--path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_tides_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
cpu="$(printf '%s\n' "$out" | grep -m1 '^TIDES_CPU=')"
if [ -z "$cpu" ]; then
	echo "ERROR: the probe published no TIDES_CPU line — the tide went unmeasured." >&2
	printf '%s\n' "$out" | head -60 >&2
	exit 2
fi
echo "$cpu"
if [ "$rc" -eq 2 ]; then
	echo "The gate could not run. See the probe output above." >&2
	exit 2
fi
if [ "$rc" -ne 0 ]; then
	echo
	echo "The declared bodies do not raise the tide they raise. near_ratio/far_ratio/tran_ratio are the"
	echo "readings over Murray & Dermott's 2 G M R / d^3 and -G M R / d^3, which bracket them to the next"
	echo "order in R/d, and phi_rel and grad_rel hold the potential to the pulls it comes from."
	exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM 2 — the world the SIM seeds, not one this script built. tide_peak_ratio is the tide at the
# sub-body point of the strongest raiser over its own leading term 2 G M R / d^3, taken on the body
# positions the run's own integrator published: above 1, and under 1 + 3R/d, which at the epoch's
# separation is below 2.
sim_out="$(la_report tide_peak_ratio,moon_dist_m --slice --rung 1 \
	--path "$REPO_ROOT" --frames "${LA_TIDES_FRAMES:-4}" 2>&1)"
sim_rc=$?
ratio="$(printf '%s\n' "$sim_out" | sed -n "s/^tide_peak_ratio  *= *//p" | head -1 \
	| sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[^0-9eE.+-]//g')"
if ! printf '%s' "$ratio" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
	echo "ERROR: the seeded run published no tide_peak_ratio (sim_run exit $sim_rc), so the tide the" >&2
	echo "       world actually raises went unmeasured. Refusing to report a pass." >&2
	printf '%s\n' "$sim_out" | tail -20 >&2
	exit 2
fi
echo "tide_peak_ratio = $ratio"
if awk -v r="$ratio" 'BEGIN{exit !(r <= 1.0 || r >= 2.0)}'; then
	echo
	echo "In the world the sim seeds, the tide at the sub-body point is not the exact difference of pulls:"
	echo "it must stand ABOVE its own leading term 2 G M R / d^3 and below the next order in R/d. Either"
	echo "the system never reaches LABallistics (LAGravity.publish off SystemOrbits.update), or the frame"
	echo "body is not the one the coordinates are measured from."
	exit 1
fi
echo "check_tides: OK"
