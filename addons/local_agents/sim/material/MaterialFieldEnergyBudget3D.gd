class_name LAMaterialFieldEnergyBudget3D
extends RefCounted

## LAMaterialFieldEnergyBudget3D — THE PLANET'S ENERGY BOOKS. Absorbed shortwave in, emitted longwave out,
## and the difference, summed over the same surface cells the solar kernel acts on.
##
## WHY IT EXISTS. `feature/energy-balance` replaced a relax-to-target thermostat with a real radiative sink
## (`dT = (absorbed - sigma*eps*T^4) * dt / C`), and NOTHING IN THIS REPOSITORY MEASURED ENERGY. A grep for
## energy_in / energy_out / radiated / absorbed returned zero hits outside the kernels themselves. Every
## climate claim was therefore argued from temperature — a state variable, which tells you where the planet
## HAS got to and never why, nor which way it is heading. A sink you cannot measure is a sink you cannot
## verify, and the last time this project reasoned about climate from an unmeasured quantity it moved water's
## freezing point to 12.5 C in five files.
##
## WHAT IT IS, EXACTLY: a CPU REFERENCE COMPUTATION OF A GPU KERNEL'S OWN ARITHMETIC. Every expression below
## is transcribed from `kernels3d/heat3d_solar_sphere3d.glsl` (line citations inline), evaluated on the CPU
## mirrors of the same channels, over the same surface set. It computes NOTHING the kernel does not, and it
## writes NOTHING back — it is a voltmeter across the circuit, not part of it.
##   * IF THE TWO EVER DISAGREE, THE KERNEL IS AUTHORITATIVE. It is what actually moves the temperature; this
##     is a restatement of it in another language, one commit away from drifting. A mismatch is a bug HERE
##     until proven otherwise, and the fix is to re-read the kernel and correct this file — never to "fix"
##     the kernel so it agrees with the instrument.
##   * The CPU mirrors it reads are one GPU drain behind the kernel's own view, so a fast transient is
##     smoothed. That is a resolution limit, not an error, and it does not affect the running totals.
##
## THE UNITS. *(Corrected 2026-08-03. This paragraph used to say `SOLAR_CONSTANT` in the kernel is 600.0
## rather than the measured 1361, "sized to this world's cell scale". That stopped being true when the
## kernel was reconciled to the real value, and this file went on mirroring 600 — under-reporting absorbed
## shortwave by 2.27x in every energy number it published.)* The irradiance and the Stefan-Boltzmann
## constant are now the measured ones, so a per-cell flux really is in W/m^2. The TOTALS are still sums
## over cells rather than an integral over area, so they are not watts; the MEANS
## (`energy_absorbed_mean`, `energy_emitted_mean`) are the numbers that compare against real physics —
## an Earth-like planet sits near 240 W/m^2 absorbed on the global mean.
##
## THE ONE THING THIS MEASURES THAT TEMPERATURE CANNOT: `energy_net` is the planet's instantaneous heating
## rate. Positive means it is still warming toward equilibrium, negative that it is shedding. At equilibrium
## it is small against `energy_absorbed`, which is what `energy_imbalance` reports. A planet whose temperature
## has stopped moving and whose imbalance is 40% is not in equilibrium — it is being held by something else
## (conduction from the pinned geothermal core, lava, a clamp), and only the books show that.
##
## READ `*_cool` FOR THE CLIMATE. THE GLOBAL TOTALS ARE A LAVA THERMOMETER. Emission goes as T⁴, so one cell
## of erupting basalt at 1573 K radiates about 900 times what a 288 K surface does, and a few hundred of them
## swamp every other cell on the planet. Measured on the first run of this instrument, seed 4242, 600 frames:
## 8923 surface cells, `energy_emitted_mean` 10223 against a mean surface temperature of 88 °C — a temperature
## whose OWN blackbody flux is 756. The gap is entirely the tail; the T⁴-weighted mean temperature was 420 °C
## while the arithmetic mean was 88 °C. The instrument was arithmetically correct and told you almost nothing,
## which is the failure mode this whole lane exists to avoid. So every total is ALSO reported over the
## sub-solidus surface only (`< LAPhysical.BASALT_SOLIDUS_C` — a real material property, not a fitted cut),
## and that is the pair to read for anything about climate. `energy_cells_magma` says how many cells the split
## moved, so nobody mistakes a quiet planet's numbers for a suppressed one.
##
## AND `energy_clamped_cells` IS THE INSTRUMENT'S OWN INTEGRITY CHECK. The kernel guards one step's dT with
## `clamp(dT, -MAX_DT_PER_STEP, MAX_DT_PER_STEP)` and calls it "numerical guard ONLY (not a physics clamp)"
## (heat3d_solar_sphere3d.glsl:210-212). That claim is true only while the guard never binds. This counts the
## cells where it does. A non-zero count means energy is being silently discarded and the books below do NOT
## describe what the field actually did.
##
## COST. One O(open cells) scan. The CALLER gates it (LAMaterialFieldReport3D._heavy_block), because the
## report provider turns out to be polled every rendered frame rather than "at snapshot time" — see that
## function for the measurement. `energy_scan_ms` reports what one sweep actually costs, so the cadence can be
## re-argued from a number. The per-column insolation is hoisted out of the inner loop (radial is per-column,
## `SphereGrid.cell_radial` is `_dir[c / depth]`), so the Vector3 work is O(columns), not O(cells).
## (Explicit types only, no ':=' inferred typing.)

# --- CONSTANTS FROM LAPhysical -----------------------------------------------------------------------------
# These are properties of matter, so they live in one place and are read, never re-typed. Each is equal to the
# kernel's own copy (the kernel must declare its own because GLSL cannot read GDScript):
#   LAPhysical.STEFAN_BOLTZMANN 5.670374419e-8  vs  glsl:91  STEFAN         5.670374419e-8  (equal)
#   LAPhysical.KELVIN_OFFSET    273.15          vs  glsl:97  KELVIN         273.15
#   LAPhysical.ALBEDO_BARE_GROUND 0.15          vs  glsl:100 ALBEDO_GROUND  0.15
#   LAPhysical.ALBEDO_OCEAN       0.06          vs  glsl:101 ALBEDO_WATER   0.06
#   LAPhysical.ALBEDO_SNOW_ICE    0.65          vs  glsl:102 ALBEDO_ICE     0.65
#   LAPhysical.ATMOS_OPTICAL_DEPTH 0.835        vs  glsl:132 TAU_SEA        0.835
#   LAPhysical.TWO_STREAM_COEFF    0.75         vs  glsl:133 TAU_TWO_STREAM 0.75

# --- CONSTANTS MIRRORED FROM THE KERNEL --------------------------------------------------------------------
# These are MODEL parameters of this world (cell scale, thermal inertia, step size), not properties of matter,
# so they are NOT in LAPhysical and are transcribed here with their kernel line. If you change one in the
# kernel, change it here in the same edit — nothing else keeps them equal.
# CORRECTED 2026-08-03. This read 600.0, described as "this world's solar constant, NOT LAPhysical's 1361".
# The kernel had already been reconciled to the measured 1361 (heat3d_solar_sphere3d.glsl:92,
# `// LAPhysical.SOLAR_CONSTANT_W_M2`) and nobody updated the instrument, so for as long as that gap
# existed this file under-reported absorbed shortwave by 2.27x — and with it energy_net, energy_net_cool,
# energy_imbalance and energy_imbalance_cool, which are the numbers every climate argument is made from.
# It is read from the authority now rather than transcribed, so it cannot drift again.
const K_SOLAR_CONSTANT: float = LAPhysical.SOLAR_CONSTANT_W_M2   # glsl:92
const K_ICE_ALBEDO_GAIN: float = 40.0      # glsl — snow mass -> reflectivity; a dusting already whitens
# AREAL heat capacities, J/m^2/K. These were 800/1400/9000/2500 in no units at all, paired with a K_STEP_DT of
# 0.1 (the SIMULATED step) while the conduction kernel next to them ran on 43.2 REAL seconds. Both halves
# state the same clock now; the values are the old ones times exactly 432, so the instrument still mirrors the
# kernel exactly and its output is unchanged. The kernel's own block records what depth of material each
# implies and which one is wrong (water: ~0.93 m against a 20-100 m ocean mixed layer).
const K_HEAT_CAP_AIR: float = 345600.0     # glsl CAP_AIR
const K_HEAT_CAP_ROCK: float = 604800.0    # glsl CAP_ROCK
const K_HEAT_CAP_WATER: float = 3888000.0  # glsl CAP_WATER — the ocean's thermal inertia
const K_HEAT_CAP_SNOW: float = 1080000.0   # glsl CAP_SNOW
const K_P_REF: float = 100.0               # glsl P_REF — sea-level column pressure in this world's units
const K_MAX_DT_PER_STEP: float = 5.0       # glsl MAX_DT_PER_STEP — the guard whose binding this file counts

var _f = null                                # back-reference to the owning LAMaterialField3D
var _samples: int = 0                        # recomputes so far

# Running integrals. Integrated against `field_sim_s` — the FIELD's own simulated clock — because the kernel
# applies its flux over STEP_DT per field step. Integrating against wall time or render frames would make the
# totals track framerate and `--fast`, which is the error the physics-clock rule in CLAUDE.md exists to stop.
var _cum_absorbed: float = 0.0
var _cum_emitted: float = 0.0
var _last_sim_s: float = -1.0


func setup(field) -> void:
	_f = field


## The books. THE CALLER OWNS THE CADENCE — LAMaterialFieldReport3D._heavy_block() gates and caches this, so
## every call here does the full scan. One owner for the gate, on purpose: two gates at the same period beat
## against each other the moment one of the two constants is edited, which is the same failure shape as two
## owners of one global.
func report() -> Dictionary:
	return _compute()


## World-space unit vector toward the sun, magnitude carrying insolation, ROTATED INTO THE FIELD'S FRAME.
##
## The frame conversion is the whole point and is easy to get wrong: the grid is body-local (it rides the
## spinning planet), so `LAMaterialField3D.cell_radial` returns a BODY-LOCAL vector, while the sun node lives
## in the system frame. LAMaterialFieldSphereStep3D.gd:158 hands the kernel `dir_to_field(basis.z * insol)`
## for exactly this reason, and this mirrors it so the insolation measured here is the insolation the kernel
## computed. Dotting a world-frame sun against a body-local radial gives a number that is right only at the
## instant the body's rotation happens to be identity.
func sun_field_dir() -> Vector3:
	if _f == null or _f._sun_light == null:
		return Vector3.ZERO
	var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
	return _f.dir_to_field(_f._sun_light.global_transform.basis.z * insol)


func _compute() -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._sphere == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var depth: int = int(_f._sphere.depth)
	if depth <= 0:
		return out
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var snow: PackedFloat32Array = _f._snow
	var pressure: PackedFloat32Array = _f._pressure
	var rock_fill: PackedFloat32Array = _f._rock_fill
	if solid.size() != cc or temp.size() != cc:
		return out
	var has_water: bool = water.size() == cc
	var has_snow: bool = snow.size() == cc
	var has_rock: bool = rock_fill.size() == cc
	# `pressure` is GPU-owned and is only read back while REQUESTED (MaterialSphereGPU3D.SITUATIONAL_CHANNELS).
	# Ask for it here so the next recompute sees the live column mass. Until it arrives the mirror is all
	# zeroes, and the kernel's own step-0 fallback (glsl:200-203) applies: p_col <= 0 -> P_REF. That is the
	# honest degradation — a uniform sea-level emissivity, no altitude structure — and `energy_pressure_live`
	# reports which of the two the numbers below were built from, so nobody reads a flat profile as a result.
	if _f._gpu != null and _f._gpu.has_method("request_channel"):
		_f._gpu.request_channel("pressure")
	var has_pressure: bool = pressure.size() == cc
	var pressure_live: int = 0
	var sun: Vector3 = sun_field_dir()

	var abs_toa: float = 0.0
	var abs_ground: float = 0.0
	var emit_toa: float = 0.0
	var emit_ground: float = 0.0
	var surf_toa: int = 0
	var surf_ground: int = 0
	var lit_cells: int = 0
	var albedo_sum: float = 0.0
	var emis_sum: float = 0.0
	var cap_sum: float = 0.0
	var dt_sum: float = 0.0
	var dt_abs_max: float = 0.0
	var clamped: int = 0
	var t_sum: float = 0.0
	# The sub-solidus (non-magmatic) surface, tracked in parallel — the climate half of the books. See the
	# header: T⁴ makes a few lava cells dominate every global total, so a total that mixes them answers a
	# question nobody asked.
	var abs_cool: float = 0.0
	var emit_cool: float = 0.0
	var cells_cool: int = 0
	var t_cool_sum: float = 0.0
	var emit_magma: float = 0.0

	var columns: int = cc / depth
	for surf in columns:
		var base: int = surf * depth
		# Per-COLUMN insolation: `SphereGrid.cell_radial(c)` is `_dir[c / depth]`, one vector per column, so the
		# only Vector3 work in this scan is O(columns). Same expression as glsl:163.
		var insolation: float = maxf(0.0, _f.cell_radial(base).dot(sun))
		for r in depth:
			var c: int = base + r
			if solid[c] != 0:
				continue                                    # glsl:140-142 — rock is not a sky cell
			# glsl:153-157. Column layout is c = surf * depth + r (LAMaterialField3D._compute_regolith), so the
			# outward neighbour (nbr slot 5) is c+1 and the inward one (slot 0) is c-1; -1 means space/core.
			var up: int = c + 1 if r < depth - 1 else -1
			var down: int = c - 1 if r > 0 else -1
			var top_of_atm: bool = (up < 0) or (solid[up] != 0)
			var ground_hug: bool = (down >= 0) and (solid[down] != 0)
			if not (top_of_atm or ground_hug):
				continue                                    # interior air: conduction + buoyancy only

			var wet: float = clampf(water[c], 0.0, 1.0) if has_water else 0.0
			var snow_m: float = snow[c] if has_snow else 0.0
			var icy: float = clampf(snow_m * K_ICE_ALBEDO_GAIN, 0.0, 1.0)
			# glsl:184-186 — ice/snow reflect, open water absorbs nearly everything, bare ground between.
			var albedo: float = lerpf(lerpf(LAPhysical.ALBEDO_BARE_GROUND, LAPhysical.ALBEDO_OCEAN, wet), LAPhysical.ALBEDO_SNOW_ICE, icy)
			# glsl:191-194 — thermal inertia from channels that already exist.
			var cap: float = K_HEAT_CAP_AIR \
				+ K_HEAT_CAP_ROCK * (clampf(rock_fill[c], 0.0, 1.0) if has_rock else 0.0) \
				+ K_HEAT_CAP_WATER * wet \
				+ K_HEAT_CAP_SNOW * clampf(snow_m, 0.0, 1.0)
			# glsl:200-204 — greenhouse from the air actually overhead; the altitude dependence is an OUTPUT.
			var p_col: float = pressure[c] if has_pressure else 0.0
			if p_col <= 0.0:
				p_col = K_P_REF
			else:
				pressure_live += 1
			var emissivity: float = 1.0 / (1.0 + LAPhysical.TWO_STREAM_COEFF * LAPhysical.ATMOS_OPTICAL_DEPTH * (p_col / K_P_REF))
			# glsl:206-208.
			var t_k: float = maxf(temp[c] + LAPhysical.KELVIN_OFFSET, 1.0)
			var absorbed: float = K_SOLAR_CONSTANT * (1.0 - albedo) * insolation
			var emitted: float = LAPhysical.STEFAN_BOLTZMANN * emissivity * t_k * t_k * t_k * t_k
			# The step the kernel would apply, and whether its numerical guard binds. The dt is the field's ONE
			# clock, read from its owner rather than transcribed — this used to be a local K_STEP_DT of 0.1
			# mirroring a kernel constant that disagreed with the conduction kernel dispatched beside it.
			var d_t: float = (absorbed - emitted) * LAMaterialFieldSphereStep3D.real_seconds_per_step() / cap
			if absf(d_t) > K_MAX_DT_PER_STEP:
				clamped += 1
			dt_sum += d_t
			dt_abs_max = maxf(dt_abs_max, absf(d_t))
			albedo_sum += albedo
			emis_sum += emissivity
			cap_sum += cap
			t_sum += temp[c]
			if temp[c] < LAPhysical.BASALT_SOLIDUS_C:
				cells_cool += 1
				abs_cool += absorbed
				emit_cool += emitted
				t_cool_sum += temp[c]
			else:
				emit_magma += emitted
			if insolation > 0.0:
				lit_cells += 1
			# TOP-OF-ATMOSPHERE vs GROUND-HUGGING, kept apart. They are the kernel's two distinct surfaces
			# (glsl:143-152) and they behave nothing alike: the TOA set sits under almost no air, so its
			# emissivity approaches 1 and it radiates as a bare blackbody, while ground sits under the full
			# column. Summed together they average into a number that describes neither.
			if top_of_atm:
				surf_toa += 1
				abs_toa += absorbed
				emit_toa += emitted
			else:
				surf_ground += 1
				abs_ground += absorbed
				emit_ground += emitted

	var n: int = surf_toa + surf_ground
	if n <= 0:
		return out
	var absorbed_total: float = abs_toa + abs_ground
	var emitted_total: float = emit_toa + emit_ground
	var net: float = absorbed_total - emitted_total
	var fn: float = float(n)

	# RUNNING TOTALS. Rectangle rule over the field's own simulated seconds. The global sums are smooth in time
	# (half the sphere is lit at every instant, so the planet-wide absorbed total barely breathes over a day),
	# which is what makes a coarse sample rate adequate here — unlike a single cell, which swings.
	var sim_s: float = LASimReport.gauge_cur("field_sim_s", 0.0)
	if _last_sim_s >= 0.0 and sim_s > _last_sim_s:
		var d_s: float = sim_s - _last_sim_s
		_cum_absorbed += absorbed_total * d_s
		_cum_emitted += emitted_total * d_s
	_last_sim_s = sim_s
	_samples += 1

	out["energy_absorbed"] = absorbed_total
	out["energy_emitted"] = emitted_total
	out["energy_net"] = net
	# The dimensionless read of "how far from balance". At equilibrium this is near zero; the SIGN says which
	# way the planet is going, which no temperature reading gives you.
	out["energy_imbalance"] = net / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	out["energy_absorbed_mean"] = absorbed_total / fn
	out["energy_emitted_mean"] = emitted_total / fn
	out["energy_abs_toa"] = abs_toa
	out["energy_abs_ground"] = abs_ground
	out["energy_emit_toa"] = emit_toa
	out["energy_emit_ground"] = emit_ground
	out["energy_cells_toa"] = surf_toa
	out["energy_cells_ground"] = surf_ground
	out["energy_cells"] = n
	out["energy_lit_cells"] = lit_cells
	out["energy_lit_frac"] = float(lit_cells) / fn
	out["energy_albedo_mean"] = albedo_sum / fn
	out["energy_emissivity_mean"] = emis_sum / fn
	out["energy_cap_mean"] = cap_sum / fn
	out["energy_surf_temp_mean"] = t_sum / fn
	out["energy_dt_mean"] = dt_sum / fn
	out["energy_dt_absmax"] = dt_abs_max
	# NON-ZERO MEANS THE BOOKS BELOW ARE FICTION for that many cells — the kernel threw the excess away.
	out["energy_clamped_cells"] = clamped
	# THE CLIMATE HALF — the same books over the sub-solidus surface only. Read these for anything about
	# whether the planet is warming, cooling or in balance; the totals above are dominated by open lava.
	var fc: float = float(maxi(cells_cool, 1))
	out["energy_abs_cool"] = abs_cool
	out["energy_emit_cool"] = emit_cool
	out["energy_net_cool"] = abs_cool - emit_cool
	out["energy_imbalance_cool"] = (abs_cool - emit_cool) / abs_cool if abs_cool > 1.0e-9 else 0.0
	out["energy_absorbed_cool_mean"] = abs_cool / fc
	out["energy_emitted_cool_mean"] = emit_cool / fc
	out["energy_temp_cool_mean"] = t_cool_sum / fc
	out["energy_cells_cool"] = cells_cool
	out["energy_cells_magma"] = n - cells_cool
	out["energy_emit_magma"] = emit_magma
	# How much of the whole planet's longwave leaves through molten rock. Near 1.0 means the global totals
	# above describe volcanism and nothing else.
	out["energy_magma_share"] = emit_magma / emitted_total if emitted_total > 1.0e-9 else 0.0
	out["energy_cum_absorbed"] = _cum_absorbed
	out["energy_cum_emitted"] = _cum_emitted
	out["energy_cum_net"] = _cum_absorbed - _cum_emitted
	out["energy_samples"] = _samples
	# Provenance, so a flat emissivity profile is never mistaken for a physical result: the share of surface
	# cells whose greenhouse came from a LIVE pressure readback rather than the kernel's sea-level fallback.
	out["energy_pressure_live"] = float(pressure_live) / fn
	out["energy_scan_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return out


func _blank() -> Dictionary:
	return {
		"energy_absorbed": 0.0, "energy_emitted": 0.0, "energy_net": 0.0, "energy_imbalance": 0.0,
		"energy_absorbed_mean": 0.0, "energy_emitted_mean": 0.0,
		"energy_abs_toa": 0.0, "energy_abs_ground": 0.0, "energy_emit_toa": 0.0, "energy_emit_ground": 0.0,
		"energy_cells_toa": 0, "energy_cells_ground": 0, "energy_cells": 0,
		"energy_lit_cells": 0, "energy_lit_frac": 0.0,
		"energy_albedo_mean": 0.0, "energy_emissivity_mean": 0.0, "energy_cap_mean": 0.0,
		"energy_surf_temp_mean": 0.0, "energy_dt_mean": 0.0, "energy_dt_absmax": 0.0,
		"energy_clamped_cells": 0,
		"energy_abs_cool": 0.0, "energy_emit_cool": 0.0, "energy_net_cool": 0.0, "energy_imbalance_cool": 0.0,
		"energy_absorbed_cool_mean": 0.0, "energy_emitted_cool_mean": 0.0, "energy_temp_cool_mean": 0.0,
		"energy_cells_cool": 0, "energy_cells_magma": 0, "energy_emit_magma": 0.0, "energy_magma_share": 0.0,
		"energy_cum_absorbed": _cum_absorbed, "energy_cum_emitted": _cum_emitted,
		"energy_cum_net": _cum_absorbed - _cum_emitted, "energy_samples": _samples,
		"energy_pressure_live": 0.0, "energy_scan_ms": 0.0,
	}
