class_name LAMaterialFieldGeotherm3D
extends RefCounted

## LAMaterialFieldGeotherm3D: the planet's internal heat, as a FINITE RESERVOIR THAT COOLS.
##
## The grid is a shell (core_radius .. core_radius + depth*cell_size). Everything below its innermost radial
## layer is not simulated, and this module is the boundary condition standing in for it: a ball of silicate
## rock of radius `core_radius`, carrying a real thermal mass, at a temperature that is a STATE VARIABLE.
## Each step it conducts heat up into the bottom face of the shell and loses exactly that much, and gains a
## little back from radioactive decay. Nothing is held at a constant temperature.
##
## WHAT IT REPLACED, and why the replacement is not a refinement but a different model:
##
##   `_temp[c] = _core_temp` on the innermost two shells, every step, forever — later softened to "warm
##   toward `_core_temp` by at most 10 C per step". Both are an INFINITE reservoir behind a tap: no amount of
##   radiating to space can cool a planet whose centre is re-asserted ten times a second. `temp_max` read
##   exactly the armed constant in every run because a set of cells literally WAS that constant, and every
##   global temperature statistic was partly a reading of it.
##
##   The armed value was 1300 C — LAPhysical.UPPER_MANTLE_C, an ERUPTING BASALT temperature, about a quarter
##   of a real inner core's 5200 C. It had been chosen because a hotter one baked the surface.
##
## WHY A TEMPERATURE BOUNDARY COULD NEVER HAVE WORKED, which is the part worth keeping:
##
##   A conductive path carries q = lambda * dT / L in steady state. Putting 5200 C at 340 m under a 15 C
##   surface demands q = 2.5 * 5185 / 340 = 38 W/m^2, against Earth's measured geothermal 0.087 W/m^2
##   (LAPhysical.GEOTHERMAL_FLUX_W_M2) and a mean absorbed 340 W/m^2 of sunlight. Earth carries a 5200 C core
##   under a 15 C surface because L is 6371 KILOMETRES. Rock does not insulate; distance attenuates. So the
##   boundary here is a FLUX, computed from the reservoir's temperature and the real conduction path, and the
##   surface temperature it implies is an output rather than something the model has to be protected from.
##
## THE HONEST CONSEQUENCE, measured and reported rather than tuned away: for a body this size the flux is
## small and the reservoir's cooling time is short in geological terms and endless in a run's terms. Read
## `core_res_c` / `core_flux_w_m2` / `core_cool_k_per_kstep` out of SIM_REPORT and the numbers speak for
## themselves. A 500 m rock ball cannot hold a molten core; that it does here is a game conceit, and this
## module makes the conceit visible instead of hiding it inside a fitted conductivity.
##
## (Explicit types only, no ':=' inferred typing.)


## Real seconds one field step represents. NOT a property of matter — it is this world's time compression,
## and it is DERIVED rather than typed: the sim clock declares a day is LASimClock.DAY_LENGTH simulated
## seconds, a real day is 86400, and the field advances LAMaterialFieldSphereStep3D.STEP_DT per step. At the
## shipped 200 s day that is 0.1 * 432 = 43.2 real seconds per field step.
const REAL_SECONDS_PER_DAY: float = 86400.0


var _f = null                                            # back-reference to the owning LAMaterialField3D

# --- reservoir state ---------------------------------------------------------------------------------------
var _core_temp: float = 0.0          # THE state variable, deg C. Falls. 0 = disarmed.
var _armed_temp: float = 0.0         # what it was seeded at, kept only for reporting the fall
var _cell_equiv: float = 0.0         # reservoir thermal mass, in units of ONE grid cell's (see _build)
var _shell_cells: PackedInt32Array = PackedInt32Array()   # r == 0 cells (the shell's bottom face)

# --- per-step outputs (published to the GPU and to SIM_REPORT) ---------------------------------------------
var _flux_dt: float = 0.0            # degrees this step's flux adds to ONE r == 0 cell
var _flux_w_m2: float = 0.0          # the flux itself, in W/m^2, so it can be read against LAPhysical
var _steps: int = 0


func setup(field) -> void:
	_f = field


## Seed the reservoir. The hottest arming wins, and it only ever seeds — once running, the temperature is
## owned by `step()`. `world_pos`/`rate` are irrelevant: the reservoir is the whole interior, not a point.
func arm(temp: float) -> void:
	if temp > _core_temp:
		_core_temp = temp
		_armed_temp = temp


## The reservoir's CURRENT temperature (0 when disarmed) — a state variable that falls, not a constant.
func core_temp() -> float:
	return _core_temp


## Advance the reservoir one field step and publish the boundary flux to the GPU.
##
## The bookkeeping is exact because both sides are the same material: the shell's bottom cells are rock and
## the reservoir is rock, so a degree delivered to one cell costs the reservoir `1 / _cell_equiv` degrees.
## No Joules appear anywhere and none need to — the ratio of thermal masses is the ratio of volumes.
func step() -> void:
	if _core_temp <= 0.0 or not _f.is_sphere() or _f._dim_y <= 0:
		return
	if _shell_cells.is_empty():
		_build()
		if _shell_cells.is_empty():
			return
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	var cell_size: float = float(grid.cell_size)
	var path_m: float = float(grid.core_radius)          # conduction path through the unsimulated ball
	if cell_size <= 0.0 or path_m <= 0.0:
		return

	# Mean temperature of the shell's bottom face. One GPU drain stale (the same coupling lag the whole
	# pipeline already sanctions) and a shell at r = 0 is very nearly isothermal, so a single scalar is the
	# right shape here — the flux depends on the boundary's mean, not on any one cell.
	var shell_sum: float = 0.0
	for c: int in _shell_cells:
		shell_sum += _f._temp[c]
	var shell_temp: float = shell_sum / float(_shell_cells.size())

	# Fourier's law across the unsimulated interior. This is the ONLY place the core's heat enters the world.
	_flux_w_m2 = LAPhysical.THERMAL_CONDUCT_ROCK_W_MK * (_core_temp - shell_temp) / path_m
	# q * A * dt / (rho*c * V) with A = dx^2 and V = dx^3 collapses to q * dt / (rho*c * dx).
	_flux_dt = _flux_w_m2 * real_seconds_per_step() / (LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K * cell_size)

	# The reservoir pays for it. (The cubed-sphere's r = 0 cells are not exactly dx^2 in area — summed they
	# come to about 8% more than 4*pi*core_radius^2 at res 32, the gnomonic area distortion — so the debit is
	# that much conservative. It is a discretisation error of the grid, not of this model.)
	_core_temp -= _flux_dt * float(_shell_cells.size()) / _cell_equiv
	# ...and radioactive decay pays a little back. This is the term that keeps a real planet's interior hot
	# for 4.5 Gyr, and at this body's size it is utterly negligible against the loss — which is exactly why
	# asteroids are cold rock and planets are not. It is here because it is real, not because it is visible.
	_core_temp += (LAPhysical.RADIOGENIC_W_PER_KG / LAPhysical.ROCK_SPECIFIC_HEAT_J_KGK) * real_seconds_per_step()
	_steps += 1

	if _f._gpu != null and _f._gpu.has_method("set_core_flux_dt"):
		_f._gpu.set_core_flux_dt(_flux_dt)


## Real seconds one field step represents, derived from the sim clock rather than typed.
func real_seconds_per_step() -> float:
	var day: float = float(LASimClock.DAY_LENGTH)
	if day <= 0.0:
		return 0.0
	return LAMaterialFieldSphereStep3D.STEP_DT * (REAL_SECONDS_PER_DAY / day)


## Reservoir telemetry. `core_cool_k_per_kstep` is scaled per THOUSAND steps because the real fall is small:
## quoting it per step would round to zero and invite exactly the "the core does not cool" conclusion the
## number is there to refute. `core_res_fall_c` is the total fall since arming.
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
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	var cell_size: float = float(grid.cell_size)
	var path_m: float = float(grid.core_radius)
	if cell_size <= 0.0 or path_m <= 0.0:
		return
	_cell_equiv = (4.0 / 3.0) * PI * path_m * path_m * path_m / (cell_size * cell_size * cell_size)
	for c: int in _f._cell_count:
		if c % _f._dim_y == 0:
			_shell_cells.append(c)
