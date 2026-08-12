class_name LAMaterialFieldGeotherm3D
extends RefCounted

## Radiogenic heat, and the gradient it is observed to produce. Rock warms itself; conduction carries it and
## the surface radiates it. Nothing here writes a temperature profile.

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

# The source table: rock cells and the watts each one's own mass decays at. Rebuilt from the mass table the
# gravity solve publishes, on that solve's cadence, because there is one mass table and it has one owner.
var _cells: PackedInt32Array = PackedInt32Array()
var _watts_of: PackedFloat32Array = PackedFloat32Array()
var _watts: float = 0.0
var _built_at: int = -1

var _banked_s: float = 0.0                               # real seconds since the last deposit
var _applied_j: float = 0.0                              # joules the field accepted, cumulative


func setup(field) -> void:
	_f = field


## Radiogenic power the modelled rock produces, W. The energy books read this and nothing else.
func watts() -> float:
	return _watts


func step() -> void:
	_banked_s += LAMaterialFieldSphereStep3D.real_seconds_per_step()
	if not _rebuild():
		return
	if _cells.is_empty() or _f._inject == null or _banked_s <= 0.0:
		return
	var joules: PackedFloat32Array = PackedFloat32Array()
	joules.resize(_cells.size())
	for i in _cells.size():
		joules[i] = _watts_of[i] * _banked_s
	_applied_j += _f._inject.add_heat_per_cell(_cells, joules)
	_banked_s = 0.0


## Rebuild the source table on the gravity solve's cadence. True on a rebuild. The decaying mass is the
## ROCK in the cell — its fill fraction less its pore space, times the silicate density — not the cell's
## bulk mass, because the water, ice and organic matter sharing the cell carry no U, Th or K.
func _rebuild() -> bool:
	var g = _f._gravity if _f != null else null
	if g == null or not g.has_method("solves"):
		return false
	var n: int = int(g.solves())
	if n == _built_at:
		return false
	var cc: int = int(_f._cell_count)
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if cc <= 0 or vol.size() != cc or _f._silicate.size() != cc:
		return false
	var rock: Dictionary = LASubstances.table().get("silicate", {})
	var rho_rock: float = float(rock.get("density", 0.0))
	# The rate FALLS: the nuclides are a finite store, so this is what is left at the current epoch.
	var w_per_kg: float = LARadiogenicDecay.heat_production_w_kg_at(_epoch_years())
	if rho_rock <= 0.0 or w_per_kg <= 0.0:
		return false
	_built_at = n
	_cells = PackedInt32Array()
	_watts_of = PackedFloat32Array()
	_watts = 0.0
	for c in cc:
		var w: float = _f._silicate[c] * rho_rock * vol[c] * w_per_kg
		if w <= 0.0:
			continue
		_cells.append(c)
		_watts_of.append(w)
		_watts += w
	return true


func report() -> Dictionary:
	var out: Dictionary = {
		"geo_radiogenic_w": _watts,
		"geo_radiogenic_cells": _cells.size(),
		"geo_radiogenic_j": _applied_j,
	}
	out.merge(_gradient())
	return out


## THE DETECTOR. Radial temperature gradient across each rock cell and the rock one step outward, deg C per
## metre, over the cells that have one. An imposed geotherm would read the seeded value here; an emergent one
## reads whatever the source and the losses left.
func _gradient() -> Dictionary:
	var out: Dictionary = {"geo_grad_c_per_m": 0.0, "geo_grad_max_c_per_m": 0.0, "geo_grad_pairs": 0}
	var cc: int = int(_f._cell_count) if _f != null else 0
	if cc <= 0 or _f._temp.size() != cc or _f._solid.size() != cc:
		return out
	var sum: float = 0.0
	var mx: float = 0.0
	var n: int = 0
	for c in cc:
		if _f._solid[c] == 0:
			continue
		var hi: int = LAFieldGeometry.above(_f, c)
		if hi < 0 or _f._solid[hi] == 0:
			continue
		var dr: float = LAFieldGeometry.radius_of(_f, hi) - LAFieldGeometry.radius_of(_f, c)
		if dr <= 0.0:
			continue
		var grad: float = (_f._temp[c] - _f._temp[hi]) / dr
		sum += grad
		mx = maxf(mx, grad)
		n += 1
	if n == 0:
		return out
	out["geo_grad_c_per_m"] = sum / float(n)
	out["geo_grad_max_c_per_m"] = mx
	out["geo_grad_pairs"] = n
	return out


## Years since the epoch the nuclide abundances are quoted at. The sim clock runs in simulated seconds,
## which the geologic time scale stretches.
func _epoch_years() -> float:
	var clock = LASimClock.active()
	if clock == null:
		return 0.0
	return clock.elapsed() * LASimClock.REAL_SECONDS_PER_SIM_SECOND / LAPhysical.SECONDS_PER_YEAR
