class_name LAMaterialFieldGeotherm3D
extends RefCounted

## LAMaterialFieldGeotherm3D: the planet's INTERNAL heat source — the geothermal boundary at the innermost
## radial shells, factored out of the extract-only field hub. Same pattern as the query / atmos / ledger /
## channels modules: no geometry of its own, it reaches into the owning LAMaterialField3D `_f` for the shared
## per-cell arrays. Conduction (heat_sphere3d.glsl) then carries whatever this supplies outward through the
## crust, so the geothermal GRADIENT is emergent — nothing here shapes it.
##
## Split out 2026-08-03 because the core is about to stop being a boundary condition and start being a
## RESERVOIR, and that work needs a file of its own rather than another method on the field hub.
##
## WHAT IS HONEST HERE AND WHAT IS NOT, stated plainly so the next reader does not have to re-derive it:
##
##   HONEST — the supply is finite per step. CORE_FLUX bounds how fast a core cell can be re-warmed, so the
##   core can be drawn down by a lava draw or a seabed vent and takes real time to recover. That is what made
##   a global energy budget closable at all; before it, `_temp[c] = _core_temp` was a hard assign every step
##   forever, and no amount of radiating to space can cool a planet whose centre is re-set ten times a second.
##
##   NOT HONEST YET — the core never DEPLETES. It warms toward `_core_temp` indefinitely, so it is still an
##   unbounded reservoir behind a bounded tap, and `_core_temp` is armed at 1300 C, which is an erupting-basalt
##   temperature (LAPhysical.UPPER_MANTLE_C) rather than a core temperature: a real inner core is ~5200 C
##   (LAPhysical.INNER_CORE_C) and the core-mantle boundary ~3700 C. The real mechanism is a finite reservoir
##   that COOLS as it conducts outward, plus a small radiogenic term, which is what actually keeps a planet's
##   interior hot for 4.5 Gyr. Until that lands, `temp_max` reads exactly the armed value and any global
##   temperature mean is partly a reading of this constant.


const CORE_LAYERS: int = 2               # innermost radial shells treated as "the core" (cell = surf*depth + r)

## Maximum degrees a core cell may gain in one field step — what turns the geothermal boundary from an
## infinite source into a large finite one. Sized so the core still recovers quickly from a lava draw
## (1300 C in ~130 steps from cold) while no longer being able to supply unbounded energy per step.
const CORE_FLUX: float = 10.0

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _core_temp: float = 0.0                              # geothermal source temperature (0 = disarmed)
var _core_cells: PackedInt32Array = PackedInt32Array()   # static innermost-shell cell indices (built once)


func setup(field) -> void:
	_f = field


## Arm the geothermal boundary at `temp`. The core is the whole innermost shell, not a point, so a caller's
## world position and rate are irrelevant — only the temperature is kept, and the hottest arming wins.
func arm(temp: float) -> void:
	_core_temp = maxf(_core_temp, temp)


## The armed source temperature (0 when disarmed). Read by diagnostics; the reservoir work will make this a
## state variable that falls rather than a constant that is held.
func core_temp() -> float:
	return _core_temp


## Warm the innermost CORE_LAYERS radial shells toward the geothermal temperature, by at most CORE_FLUX
## degrees per field step. Cell layout is `cell = surf*depth + r`, so `r = c % _dim_y` and `r < CORE_LAYERS`
## is the core; the static cell list is built once. Called each step before begin_frame so the upload carries
## it, after which conduction propagates it up through the rock.
func step() -> void:
	if _core_temp <= 0.0 or not _f.is_sphere() or _f._dim_y <= 0:
		return
	if _core_cells.is_empty():
		for c in _f._cell_count:
			if c % _f._dim_y < CORE_LAYERS:
				_core_cells.append(c)
	for c in _core_cells:
		var gap: float = _core_temp - _f._temp[c]
		if gap > 0.0:
			_f._temp[c] += minf(gap, CORE_FLUX)
