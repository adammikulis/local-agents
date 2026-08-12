class_name LAMaterialFieldGeotherm3D
extends RefCounted

## LAMaterialFieldGeotherm3D: the planet's internal heat — a seeded geotherm plus the finite reservoir that
## feeds it, and that volcanic vents draw on.


const DISARM_ENV: String = "LA_NO_GEOTHERM"


var _f = null                                            # back-reference to the owning LAMaterialField3D

# --- reservoir state ---------------------------------------------------------------------------------------
var _core_temp: float = 0.0          # THE state variable, deg C: the convecting interior. Falls. 0 = disarmed.
var _armed_temp: float = 0.0         # what it was seeded at, kept to report the fall and to scale the boundary
var _drawn_j: float = 0.0            # joules drawn out of it by draw_heat_j, cumulative
var _refusals: int = 0               # draws the store was too cold to pay for
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
	_build()
	# SEEDING: the interior's heat is handed to a planet that does not have it yet, so it is declared. After
	# the seal this store may only be drawn DOWN — see draw_heat_j.
	if _f != null and _f._seal != null:
		if not _f._seal.note_creation("geotherm_core_heat_j", temp * heat_capacity_j_per_k()):
			return
	_core_temp = temp
	_armed_temp = temp
	_seeded_cells = _seed_profile()
	if _seeded_cells > 0 and _f._gpu != null and _f._gpu.has_method("mark_temp_dirty"):
		_f._gpu.mark_temp_dirty()          # the CPU mirror just changed under the gated begin_frame upload


## The reservoir's CURRENT temperature (0 when disarmed) — a state variable that falls, not a constant.
func core_temp() -> float:
	return _core_temp


## What it was seeded at.
func armed_temp() -> float:
	return _armed_temp


## Radius of the un-simulated interior, in metres. LASphereGrid answers in model units.
func _core_radius_m() -> float:
	var grid: RefCounted = _f.sphere_grid() if _f != null else null
	if grid == null:
		return 0.0
	return maxf(0.0, float(grid.core_radius)) * LAPhysical.METRES_PER_MODEL_UNIT


## Reservoir heat capacity, J/K: the interior's volume times rock's volumetric heat capacity.
func heat_capacity_j_per_k() -> float:
	var r: float = _core_radius_m()
	return (4.0 / 3.0) * PI * r * r * r * LAHeatCapacity.pure_rock()


## Take `joules` out of the reservoir. It grants no more than what it holds above `floor_c`: a store at that
## temperature cannot drive a transfer to it. Returns the joules actually granted.
func draw_heat_j(joules: float, floor_c: float) -> float:
	var cap: float = heat_capacity_j_per_k()
	if joules <= 0.0:
		return 0.0
	if cap <= 0.0 or _core_temp <= floor_c:
		_refusals += 1
		return 0.0
	var grant: float = minf(joules, (_core_temp - floor_c) * cap)
	_core_temp -= grant / cap
	_drawn_j += grant
	if _armed_temp > 0.0:
		_boundary_c = _boundary_seed * (_core_temp / _armed_temp)
	return grant


func step() -> void:
	if _core_temp <= 0.0 or not _f.is_sphere() or _f._dim_y <= 0:
		return
	if _shell_cells.is_empty():
		return
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	# The flux crosses the INNERMOST shell's own face, so its thickness is that shell's, not the mean.
	var dr0: float = float(grid.shell_dr[0]) * LAPhysical.METRES_PER_MODEL_UNIT
	if dr0 <= 0.0:
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

	var dt: float = real_seconds_per_step()
	_flux_w_m2 = LAPhysical.THERMAL_CONDUCT_ROCK_W_MK * (_boundary_c - _shell_c) / dr0
	_flux_dt = _flux_w_m2 * dt / (LAHeatCapacity.pure_rock() * dr0)

	# The reservoir pays for it, over the fraction of its surface that is in contact with rock.
	var r_m: float = _core_radius_m()
	var area: float = 4.0 * PI * r_m * r_m * float(shell_n) / float(_shell_cells.size())
	var cap: float = heat_capacity_j_per_k()
	if cap > 0.0:
		_core_temp -= _flux_w_m2 * area * dt / cap
	# Radioactive decay pays a little back — the term that keeps a real planet's interior hot for 4.5 Gyr.
	_core_temp += (LAPhysical.RADIOGENIC_W_PER_KG / LAPhysical.ROCK_SPECIFIC_HEAT_J_KGK) * dt
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
		"core_drawn_j": _drawn_j,
		"core_heat_cap_j_k": heat_capacity_j_per_k(),
		"core_heat_stock_j": _core_temp * heat_capacity_j_per_k(),
		"core_heat_seed_j": _armed_temp * heat_capacity_j_per_k(),
		"core_draw_refused": _refusals,
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
	var dr0: float = float(grid.shell_dr[0]) if int(grid.depth) > 0 else 0.0
	if dr0 <= 0.0 or float(grid.core_radius) <= 0.0:
		return
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
			var t: float = ambient + _grad_c_per_m * (float(grid.shell_face[surf_r + 1]) - float(grid.shell_mid[r]))
			_f._temp[c] = t
			n += 1
			if r == 0:
				base_sum += t
				base_n += 1
	_boundary_seed = ((base_sum / float(base_n)) if base_n > 0 else ambient) \
		+ _grad_c_per_m * float(grid.shell_dr[0])
	_boundary_c = _boundary_seed
	return n


func _derive_gradient(cell_size: float) -> float:
	var band_m: float = float(LAMaterialField3D.REGOLITH_CELLS) * cell_size
	if band_m <= 0.0:
		return 0.0
	var exaggeration: float = LAPhysical.GROUNDWATER_CIRCULATION_M / band_m
	return (LAPhysical.GEOTHERMAL_GRADIENT_C_PER_KM / 1000.0) * exaggeration
