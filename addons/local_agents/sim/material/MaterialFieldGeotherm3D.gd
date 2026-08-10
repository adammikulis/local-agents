class_name LAMaterialFieldGeotherm3D
extends RefCounted

## LAMaterialFieldGeotherm3D: the planet's internal heat. A geotherm SEEDED as an initial condition, plus a
## Rock's thermal diffusivity is LAPhysical.THERMAL_DIFFUSIVITY_ROCK_M2_S = 1.026e-6 m^2/s. A thermal front
## LAPhysical.GROUNDWATER_CIRCULATION_M = 2 km. So
##     exaggeration  = GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size) = 2000 / 64 = 31.25
## thing: its measured 0.087 W/m^2 (LAPhysical.GEOTHERMAL_FLUX_W_M2) is ~27x what pure conduction through
## flux was a constant by construction: 2.5 * (5200 - 15) / 340 = 38.125 W/m^2 in every run, to the last
## draws. It was a clock, not a coupling. It was also inert: 38 W/m^2 into a 16 m rock cell is 4.2e-5 C per


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

	# seeded profile this is exactly lambda * the geotherm's gradient, 2.5 * 1.875 = 4.69 W/m^2. That is 54x
	# mean (2.5 * 0.06 = 0.15 W/m^2 against 0.087). 0.15 * 31.25 / 0.087 = 54. Nothing else is in it.
	_flux_w_m2 = LAPhysical.THERMAL_CONDUCT_ROCK_W_MK * (_boundary_c - _shell_c) / cell_size
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
## kernel disagreed with both. One derivation, four readers.
func real_seconds_per_step() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


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


func _derive_gradient(cell_size: float) -> float:
	var band_m: float = float(LAMaterialField3D.REGOLITH_CELLS) * cell_size
	if band_m <= 0.0:
		return 0.0
	var exaggeration: float = LAPhysical.GROUNDWATER_CIRCULATION_M / band_m
	return (LAPhysical.GEOTHERMAL_GRADIENT_C_PER_KM / 1000.0) * exaggeration
