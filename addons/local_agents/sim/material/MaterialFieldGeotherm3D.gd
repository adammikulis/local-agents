class_name LAMaterialFieldGeotherm3D
extends RefCounted

## LAMaterialFieldGeotherm3D: the planet's internal heat. A geotherm SEEDED as an initial condition, plus a
## finite interior reservoir that maintains it at its base and slowly cools.
##
## ===== WHY THE GEOTHERM IS AN INITIAL CONDITION, WHICH IS WHAT THE PREVIOUS VERSION MISSED ================
##
## Rock's thermal diffusivity is LAPhysical.THERMAL_DIFFUSIVITY_ROCK_M2_S = 1.026e-6 m^2/s. A thermal front
## travels a distance L in about L^2/alpha, so crossing this shell's 320 m takes 1.0e11 s — 3200 years. One
## 600-frame run at --fast=8 is 590 field steps of 43.2 real seconds: seven real hours, in which conduction
## moves a front sqrt(alpha*t) = 0.16 m. A hundredth of one cell.
##
## So no heat can propagate inward or outward during play, and the interior necessarily sits at exactly
## whatever it was seeded with. The previous version seeded nothing and expected a boundary flux to establish
## the gradient at runtime; that is not slow, it is impossible. Measured on it, `--no-fauna` seed 4242 at 600
## frames: rock_core_c 15.02, rock_q25_c 14.98 — a planet whose interior was room temperature — and
## hotspring_cells 2 against 1324 before the change, a 99.8% loss of a named 0.4 phenomenon.
##
## Earth does not have a geotherm because heat diffused out of it this week. It has one because it was BORN
## with one and has been cooling for 4.5 Gyr. That is an initial condition, so this seeds one.
##
## ===== THE ONE CONCEIT, STATED ONCE: DEPTH IS VERTICALLY EXAGGERATED ======================================
##
## Both literal readings of this planet's scale fail, which is why an exaggeration is the honest choice:
##   * Take the model's metres literally and the body is a 500 m asteroid. Earth's measured near-surface
##     gradient puts its centre at 19 C. No springs, no volcanism, no geology — correct for an asteroid, and
##     not the world this game is.
##   * Scale depth by the planet's own radius ratio instead (6371 km / 500 m = 12742:1) and the FIRST cell
##     below the surface is already 200 km down. Everything simulated is mantle and all of it is molten.
## Vertical exaggeration is what every relief map does for the same reason: the interesting structure is
## thinner than the frame.
##
## THE EXAGGERATION IS DERIVED, NOT PICKED. The field already names the one zone here with an unambiguous
## real-world referent: the REGOLITH band, LAMaterialField3D.REGOLITH_CELLS cells deep, whose own comment
## defines it as "the top solid shells of each column are PERMEABLE — groundwater lives + flows here;
## everything below is impermeable BEDROCK". On Earth that is the groundwater circulation zone,
## LAPhysical.GROUNDWATER_CIRCULATION_M = 2 km. So
##     exaggeration  = GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size) = 2000 / 64 = 31.25
##     model gradient = LAPhysical.GEOTHERMAL_GRADIENT_C_PER_KM * exaggeration  = 1.875 C per model metre
## Nothing about the OUTPUT enters that, and it re-derives correctly at another grid resolution, because the
## aquifer band still has to be 2 km whatever the cells are.
##
## THE FIRST VERSION OF THIS ANCHORED ON THE MOHO INSTEAD, and measurement is why it does not any more.
## Reading the whole 160 m rock band as Earth's 35 km continental crust gives 219:1, which puts the deepest
## aquifer cell at 219 C — 14 km of real crust, far below where groundwater exists. Measured, seed 4242 at 600
## frames, three identical runs: it worked as a geotherm (rock_core_c 568, rock_q25_c 263, rock_mid_c 54.5)
## and boiled the planet dry doing it — soil_total 286 against a baseline 2958 (-90%), water_total 1297
## against 2921, moisture_total 4879 against 578 (+743%), temp_ground_p90 93.7 against 18.0. The aquifer
## drained through the spring path and flashed to steam. Two scale claims were in force at once, and the
## aquifer's is the one with the harder referent.
##
## ===== THE PROFILE ========================================================================================
##
## Linear in depth below the LOCAL rock surface, at that one gradient. Linear-in-depth is what a real
## near-surface geotherm IS, and anchoring on the local surface is what makes shallow isotherms follow
## topography, as they do. A column's base temperature therefore depends on how much rock is over it: a thin
## ocean-basin crust has a cooler base than a mountain root, so the interior gives up heat fastest where the
## crust is thin — which is why vents are a seafloor phenomenon. Nothing here says "vent" or "spring".
##
## The spherical steady-state solution (T ~ 1/r) would be the right shape for a whole planet, but its
## curvature over a few kilometres of real upper crust is negligible, and here it would be curvature imported
## from the exaggeration rather than from the rock.
##
## ===== THE BOUNDARY BELOW IT ==============================================================================
##
## Everything below grid.core_radius is unsimulated. It is a CONVECTING ball, and a convecting body is nearly
## isothermal in its bulk with its whole temperature drop across a thin boundary layer at the top — so its
## conductive resistance is one cell of rock at the shell's base, not its 340 m radius. Earth says the same
## thing: its measured 0.087 W/m^2 (LAPhysical.GEOTHERMAL_FLUX_W_M2) is ~27x what pure conduction through
## 2890 km of mantle would deliver. Convection is why.
##
## So the boundary is exactly a seventh neighbour: a ghost cell of rock one shell below r = 0, at
## `core_boundary_c`, which heat_sphere3d.glsl bonds to with the same finite-volume expression it uses for
## every other neighbour. That makes the coupling PER CELL — a base cell under thin crust draws more than one
## under a mountain root — where the old scalar could not.
##
## WHAT THE OLD BOUNDARY WAS. `flux = lambda * (5200 - shell_mean) / 340` with shell_mean read from a shell
## that had been seeded at 15.0 and, by the argument at the top of this file, could never leave it. So the
## flux was a constant by construction: 2.5 * (5200 - 15) / 340 = 38.125 W/m^2 in every run, to the last
## digit, and `core_res_fall_c` was bit-identical 0.0021437 across runs with completely different disaster
## draws. It was a clock, not a coupling. It was also inert: 38 W/m^2 into a 16 m rock cell is 4.2e-5 C per
## step, which is why disarming the whole module changed nothing measurable.
##
## (Explicit types only, no ':=' inferred typing.)


## Acceptance CONTROL. `LA_NO_GEOTHERM=1` disarms the module completely: no profile is seeded and no boundary
## is published, so the interior stays at ambient and heat_sphere3d.glsl sees core_boundary_c <= 0 and skips
## its inward bond. Every gate on this module is supposed to FAIL in this arm — a gate that passes with the
## feature disabled is not a gate.
const DISARM_ENV: String = "LA_NO_GEOTHERM"


var _f = null                                            # back-reference to the owning LAMaterialField3D

# --- reservoir state ---------------------------------------------------------------------------------------
var _core_temp: float = 0.0          # THE state variable, deg C: the convecting interior. Falls. 0 = disarmed.
var _armed_temp: float = 0.0         # what it was seeded at, kept to report the fall and to scale the boundary
var _cell_equiv: float = 0.0         # reservoir thermal mass, in units of ONE grid cell's (see _build)
var _shell_cells: PackedInt32Array = PackedInt32Array()   # r == 0 cells (the shell's bottom face)

# --- the seeded geotherm -----------------------------------------------------------------------------------
var _boundary_seed: float = 0.0      # ghost-cell temperature at arming, on the reference geotherm
var _boundary_c: float = 0.0         # ...and now, scaled by how far the reservoir has cooled
var _grad_c_per_m: float = 0.0       # the reference geotherm's gradient, deg C per model metre
var _seeded_cells: int = 0

# --- per-step outputs (published to the GPU and to SIM_REPORT) ---------------------------------------------
var _flux_dt: float = 0.0            # degrees this step's boundary flux adds to ONE r == 0 cell (ledger only)
var _flux_w_m2: float = 0.0          # the flux itself, in W/m^2, so it can be read against LAPhysical
var _shell_c: float = 0.0            # mean temperature of the r == 0 face — the flux's other input
var _flux_min: float = 0.0
var _flux_max: float = 0.0
var _shell_min: float = 0.0
var _shell_max: float = 0.0
var _steps: int = 0


func setup(field) -> void:
	_f = field


## Seed the planet's internal heat: the reservoir temperature AND the geotherm through the rock above it. The
## hottest arming wins and it only ever seeds once; from then on the temperature is owned by `step()` and by
## the field. `temp` is the CONVECTING INTERIOR's temperature (the call site passes LAPhysical.INNER_CORE_C),
## which sets the reservoir's thermal scale and therefore how fast it cools; the profile through the rock is
## set by the gradient in `_derive_gradient()`, because the top of the shell is upper crust, not core.
func arm(temp: float) -> void:
	if OS.has_environment(DISARM_ENV) and OS.get_environment(DISARM_ENV) != "0":
		return
	if temp <= _core_temp:
		return
	_core_temp = temp
	_armed_temp = temp
	_build()
	_seeded_cells = _seed_profile()
	if _seeded_cells > 0 and _f._gpu != null and _f._gpu.has_method("mark_temp_dirty"):
		_f._gpu.mark_temp_dirty()          # the CPU mirror just changed under the gated begin_frame upload


## The reservoir's CURRENT temperature (0 when disarmed) — a state variable that falls, not a constant.
func core_temp() -> float:
	return _core_temp


## Advance the reservoir one field step and publish the boundary temperature to the GPU.
##
## The bookkeeping is exact because both sides are the same material: the shell's bottom cells are rock and
## the reservoir is rock, so a degree delivered to one cell costs the reservoir `1 / _cell_equiv` degrees.
## No Joules appear anywhere and none need to — the ratio of thermal masses is the ratio of volumes.
func step() -> void:
	if _core_temp <= 0.0 or not _f.is_sphere() or _f._dim_y <= 0:
		return
	if _shell_cells.is_empty():
		return
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	var cell_size: float = float(grid.cell_size)
	if cell_size <= 0.0:
		return

	# Mean temperature of the ROCK in the shell's bottom face. The GPU applies the boundary PER CELL against
	# each cell's own temperature and its own interface conductivity (heat_sphere3d.glsl); this scalar is only
	# the reservoir's LEDGER and the reported flux, and for a ledger a mean is the right shape.
	#
	# SOLID CELLS ONLY, and that is a correction. About 7% of the r == 0 face is open (voids at the base of
	# the crust), those cells were never seeded with the geotherm, and averaging them in at ambient dragged
	# the reported boundary temperature down ~28 C — so `core_flux_w_m2` read 9.0 where the seeded gradient
	# says lambda * 1.875 = 4.69. Worse, this side multiplies by rock's conductivity, while the kernel
	# correctly gives an open cell an AIR interface (harmonic mean 0.0515, 48x less). Mixing the two
	# populations under one conductivity is a ledger that does not describe either. The rock face is what
	# this scalar models, so it is what it averages.
	#
	# One GPU drain stale, the coupling lag the whole pipeline already sanctions.
	var shell_sum: float = 0.0
	var shell_n: int = 0
	var has_solid: bool = _f._solid.size() == _f._cell_count
	for c: int in _shell_cells:
		if has_solid and _f._solid[c] == 0:
			continue
		shell_sum += _f._temp[c]
		shell_n += 1
	if shell_n <= 0:
		return
	_shell_c = shell_sum / float(shell_n)

	# Fourier's law across ONE cell of rock — the boundary layer at the top of the convecting interior. At the
	# seeded profile this is exactly lambda * the geotherm's gradient, 2.5 * 1.875 = 4.69 W/m^2. That is 54x
	# LAPhysical.GEOTHERMAL_FLUX_W_M2 (0.087), and the factor is not slack: it is the 31.25 vertical
	# exaggeration in the header times the ratio of a volcanic province's conductive flux to Earth's global
	# mean (2.5 * 0.06 = 0.15 W/m^2 against 0.087). 0.15 * 31.25 / 0.087 = 54. Nothing else is in it.
	#
	# IT IS NOT A CONSTANT — it is a function of a measured field quantity, and `core_shell_c` is published
	# beside it so anyone can recompute it by hand. Measured over three 600-frame runs: 4.578 / 4.586 / 4.578
	# against the 4.6875 the seeded gradient predicts, the 2% being how far the base of the crust has warmed.
	# Its RANGE within a run is 4.58 to 48.25, because the step right after seeding still reads the pre-seed
	# CPU mirror at ambient (see report() below) and a 279 C colder boundary draws 10.5x the heat. That
	# transient is the cleanest demonstration in the report that the coupling is real; the settled value is
	# steady because the base of a crust is steady, which is the correct behaviour and not a stuck number.
	_flux_w_m2 = LAPhysical.THERMAL_CONDUCT_ROCK_W_MK * (_boundary_c - _shell_c) / cell_size
	# q * A * dt / (rho*c * V) with A = dx^2 and V = dx^3 collapses to q * dt / (rho*c * dx).
	# Through LAHeatCapacity rather than reading LAPhysical directly. This boundary IS solid rock by
	# definition, so it wants a pure-substance capacity rather than a mixture — but it must still come from
	# the ONE model, because nine independent copies of that model is what put the booked and the stock sides
	# of the energy ledger on different physics. Gated by scripts/check_heat_capacity_ssot.sh.
	_flux_dt = _flux_w_m2 * real_seconds_per_step() / (LAHeatCapacity.pure_rock() * cell_size)

	# The reservoir pays for it. (The cubed-sphere's r = 0 cells are not exactly dx^2 in area — summed they
	# come to about 8% more than 4*pi*core_radius^2 at res 32, the gnomonic area distortion — so the debit is
	# that much conservative. It is a discretisation error of the grid, not of this model.)
	_core_temp -= _flux_dt * float(shell_n) / _cell_equiv
	# ...and radioactive decay pays a little back. This is the term that keeps a real planet's interior hot
	# for 4.5 Gyr, and at this body's size it is utterly negligible against the loss — which is exactly why
	# asteroids are cold rock and planets are not. It is here because it is real, not because it is visible.
	_core_temp += (LAPhysical.RADIOGENIC_W_PER_KG / LAPhysical.ROCK_SPECIFIC_HEAT_J_KGK) * real_seconds_per_step()
	# The interior convects, so its whole adiabat rises and falls together: the ghost cell at the top of it
	# carries the same fractional change as the bulk.
	if _armed_temp > 0.0:
		_boundary_c = _boundary_seed * (_core_temp / _armed_temp)
	_steps += 1
	if _steps == 1:
		_flux_min = _flux_w_m2
		_flux_max = _flux_w_m2
		_shell_min = _shell_c
		_shell_max = _shell_c
	else:
		_flux_min = minf(_flux_min, _flux_w_m2)
		_flux_max = maxf(_flux_max, _flux_w_m2)
		_shell_min = minf(_shell_min, _shell_c)
		_shell_max = maxf(_shell_max, _shell_c)

	if _f._gpu != null and _f._gpu.has_method("set_core_boundary_c"):
		_f._gpu.set_core_boundary_c(_boundary_c)


## Real seconds one field step represents — the field's ONE clock, owned by the module that owns STEP_DT.
## This used to re-derive it here from a local copy of 86400; the thermal pass had a third copy and the solar
## kernel disagreed with both. One derivation, four readers.
func real_seconds_per_step() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


## Reservoir telemetry. `core_cool_k_per_kstep` is scaled per THOUSAND steps because the real fall is small:
## quoting it per step would round to zero and invite exactly the "the core does not cool" conclusion the
## number is there to refute. `core_res_fall_c` is the total fall since arming.
##
## `core_shell_c` and `core_boundary_c` are BOTH published deliberately: they are the flux's two inputs, so
## anyone can recompute `core_flux_w_m2 = 2.5 * (boundary - shell) / cell_size` by hand and see that it is a
## function of a measured field quantity rather than a literal. `core_flux_min/max_w_m2` and
## `core_shell_min/max_c` are the run's own range, which is the direct answer to "does it vary".
##
## `core_shell_min_c` READS ~15 AND `core_flux_max_w_m2` READS ~6x THE SETTLED VALUE. That is not a bug and
## it is the clearest evidence in the report that the coupling is real. Seeding writes the CPU temp mirror and
## marks it dirty; the very next field step uploads it, but its readback still scatters the PREVIOUS step's
## GPU result — computed before the seed — back over the mirror. So exactly ONE step measures the shell at the
## pre-seed ambient, and the flux answers a ~500 C colder boundary with ~6x the heat. From the step after, the
## mirror carries the seeded profile and the flux settles. One step of a 1e-4 C over-credit to a reservoir
## with 40,190 cells of thermal mass is not worth plumbing around, and losing the demonstration would be.
func report() -> Dictionary:
	if _armed_temp <= 0.0:
		return {}
	var fall: float = _armed_temp - _core_temp
	var per_k: float = (fall / float(_steps)) * 1000.0 if _steps > 0 else 0.0
	return {
		"core_res_c": _core_temp,
		"core_res_armed_c": _armed_temp,
		"core_res_fall_c": fall,
		"core_cool_k_per_kstep": per_k,
		"core_flux_w_m2": _flux_w_m2,
		"core_flux_dt": _flux_dt,
		"core_boundary_c": _boundary_c,
		"core_shell_c": _shell_c,
		"core_flux_min_w_m2": _flux_min,
		"core_flux_max_w_m2": _flux_max,
		"core_shell_min_c": _shell_min,
		"core_shell_max_c": _shell_max,
		"core_grad_c_per_m": _grad_c_per_m,
		"core_seeded_cells": _seeded_cells,
	}


# --- one-time geometry -------------------------------------------------------------------------------------

## Cell layout is `cell = surf*depth + r`, so `r = c % _dim_y` and `r == 0` is the shell's bottom face.
##
## `_cell_equiv` is the reservoir's thermal mass expressed in grid cells. Both are silicate rock, so it is
## purely geometric: the volume of the unsimulated ball over the volume of one cell. At the shipped planet
## (core_radius 340, cell_size 16) that is (4/3)*pi*340^3 / 16^3 = 40,190 cells, against the 6*res^2 cells
## in the face it feeds — 3456 at the default res 24, so the interior holds about 12x the heat of the
## layer it is warming, and the ratio moves with resolution exactly as it should.
func _build() -> void:
	if not _shell_cells.is_empty():
		return
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	var cell_size: float = float(grid.cell_size)
	var core_r: float = float(grid.core_radius)
	if cell_size <= 0.0 or core_r <= 0.0:
		return
	_cell_equiv = (4.0 / 3.0) * PI * core_r * core_r * core_r / (cell_size * cell_size * cell_size)
	for c: int in _f._cell_count:
		if c % _f._dim_y == 0:
			_shell_cells.append(c)


## Write the geotherm into `_temp` for every ROCK cell, and set the ghost-cell temperature below the shell.
## Returns the number of cells seeded.
##
## Per COLUMN (grid columns are contiguous, `cell = surf*depth + r`): find the outermost solid shell, treat
## the top face of that cell as the rock surface, and run a straight line downward from the field's ambient at
## a gradient of `_grad_c_per_m`. The gradient is derived in `_derive_gradient()`; the anchoring is per column,
## so shallow isotherms follow topography — see the header.
##
## OPEN cells are deliberately untouched. Air and sea are governed by the surface energy balance, and seeding
## them from a rock geotherm would bake the atmosphere. The one known gap is an open cell BELOW the surface (a
## cave or an eroded aquifer void): it keeps ambient while the rock around it is hot, and conduction is far
## too slow to correct that within a run. It is a small set and it is honest to name it rather than paper over
## it with a radius test that would also catch the sea.
##
## The ghost cell below the shell is seeded ONE gradient step below the mean of the base shell it has just
## written, so at t = 0 the boundary delivers exactly lambda * gradient — the flux a geotherm of that slope
## carries by Fourier's law, and no more. It is not a separate assumption; it is the same line, continued.
func _seed_profile() -> int:
	var grid: RefCounted = _f.sphere_grid()
	if grid == null or _f._solid.size() != _f._cell_count or _f._temp.size() != _f._cell_count:
		return 0
	var depth: int = int(grid.depth)
	var surf_count: int = int(grid.surf_count)
	var cell_size: float = float(grid.cell_size)
	if depth <= 0 or surf_count <= 0 or cell_size <= 0.0:
		return 0
	_grad_c_per_m = _derive_gradient(cell_size)
	if _grad_c_per_m <= 0.0:
		return 0
	var ambient: float = float(_f.INITIAL_TEMP)
	var n: int = 0
	var base_sum: float = 0.0
	var base_n: int = 0
	for s: int in range(surf_count):
		var base: int = s * depth
		var surf_r: int = -1
		for r: int in range(depth - 1, -1, -1):
			if _f._solid[base + r] != 0:
				surf_r = r
				break
		if surf_r < 0:
			continue                                   # an all-open column (open ocean over no floor)
		for r: int in range(0, surf_r + 1):
			var c: int = base + r
			if _f._solid[c] == 0:
				continue
			# Depth of this cell's CENTRE below the top face of the column's outermost rock cell.
			var t: float = ambient + _grad_c_per_m * (float(surf_r - r) + 0.5) * cell_size
			_f._temp[c] = t
			n += 1
			if r == 0:
				base_sum += t
				base_n += 1
	_boundary_seed = ((base_sum / float(base_n)) if base_n > 0 else ambient) + _grad_c_per_m * cell_size
	_boundary_c = _boundary_seed
	return n


## Degrees C per MODEL metre, derived — see the header's exaggeration block. Earth's near-surface gradient
## (LAPhysical.GEOTHERMAL_GRADIENT_C_PER_KM, per real kilometre) times the vertical exaggeration this world
## uses, which is fixed by requiring the field's own REGOLITH band to be the real groundwater circulation
## zone (LAPhysical.GROUNDWATER_CIRCULATION_M). At the shipped grid: 60/1000 * (2000 / (4*16)) = 1.875.
func _derive_gradient(cell_size: float) -> float:
	var band_m: float = float(LAMaterialField3D.REGOLITH_CELLS) * cell_size
	if band_m <= 0.0:
		return 0.0
	var exaggeration: float = LAPhysical.GROUNDWATER_CIRCULATION_M / band_m
	return (LAPhysical.GEOTHERMAL_GRADIENT_C_PER_KM / 1000.0) * exaggeration
