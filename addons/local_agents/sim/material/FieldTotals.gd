class_name LAFieldTotals
extends RefCounted

## A TOTAL IS A MASS, NOT A COUNT. One place that turns a channel into an amount of matter.
##
## Every conservation total in this project is currently `sum += arr[c]` over cells, and this grid's cells
## are not the same size: largest over smallest is 6.30 / 7.91 / 8.76 at res 8 / 16 / 32, and the ratio
## grows with resolution (scripts/check_sphere_grid.sh). Water moving from the shell floor into a cloud
## therefore changes the "total" with no water created or destroyed, and a drift percentage read off it
## measures the geometry as much as the physics.
##
## A channel value is INTENSIVE — how full of that substance the cell is. The extensive quantity is
##     value * cell_volume * density
## which is what a ledger has to sum and what `substance_kg` returns.
##
## The masks are a PARAMETER here rather than a policy, because the four legs of H2O currently disagree
## about which cells count (water and snow on solid == 0, soil mask-free, moisture on solid != 0) and
## unifying that is a physics question about where each phase can be, not something this file should
## decide by picking a default.

## Which cells a sum includes. An enum, not three int consts: these are TAGS, and the model-parameters
## gate is right to treat a bare `const NAME: int = 1` as a quantity somebody chose.
enum {
	CELLS_ALL = -1,    # every cell, rock and void alike
	CELLS_OPEN = 0,    # void cells only (solid == 0)
	CELLS_SOLID = 1,   # rock cells only (solid != 0)
}


## Volume-weighted sum of a channel, in model units cubed. This is the quantity that is conserved when
## matter moves between cells; the raw sum is not.
static func volume_sum(grid, arr: PackedFloat32Array, solid: PackedByteArray, which: int = CELLS_ALL) -> float:
	if grid == null or arr.size() < grid.cell_count:
		return 0.0
	var use_mask: bool = which != CELLS_ALL and solid.size() >= grid.cell_count
	var total: float = 0.0
	for c in grid.cell_count:
		if use_mask and (1 if solid[c] != 0 else 0) != which:
			continue
		total += arr[c] * grid.cell_volume(c)
	return total


## Mass of a substance held in a channel, in KILOGRAMS. `substance` is a key in LASubstances.table().
static func substance_kg(grid, arr: PackedFloat32Array, solid: PackedByteArray, which: int,
		substance: String) -> float:
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var density: float = float(entry.get("density", 0.0))
	if density <= 0.0:
		push_error("LAFieldTotals.substance_kg: '%s' has no density in LASubstances" % substance)
		return 0.0
	# ISOTROPIC, WHICH THE GRID IS NOT. MaterialFieldGeotherm3D carries an implicit vertical exaggeration of
	# ~31 (GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size)), so one model unit is not the same
	# distance radially as laterally and this cube is wrong by that factor. Declaring the two scales
	# separately is its own track; this line is where the answer lands when it does.
	var m3_per_unit: float = LAPhysical.METRES_PER_MODEL_UNIT
	var m3: float = volume_sum(grid, arr, solid, which) * m3_per_unit * m3_per_unit * m3_per_unit
	return m3 * density


## The raw sum every ledger currently takes — kept ONLY so the two can be compared, never as an answer.
static func flat_sum(arr: PackedFloat32Array, solid: PackedByteArray, cell_count: int,
		which: int = CELLS_ALL) -> float:
	if arr.size() < cell_count:
		return 0.0
	var use_mask: bool = which != CELLS_ALL and solid.size() >= cell_count
	var total: float = 0.0
	for c in cell_count:
		if use_mask and (1 if solid[c] != 0 else 0) != which:
			continue
		total += arr[c]
	return total


## How wrong the flat sum is for THIS field, as a ratio (flat-equivalent volume over real volume). It is 1.0
## only when the channel happens to be distributed so the size differences cancel; it is not a constant, which
## is why the flat sum cannot be corrected with a factor and has to be replaced.
static func flat_sum_error(grid, arr: PackedFloat32Array, solid: PackedByteArray,
		which: int = CELLS_ALL) -> float:
	if grid == null:
		return 0.0
	var real: float = volume_sum(grid, arr, solid, which)
	if real <= 0.0:
		return 0.0
	var flat: float = flat_sum(arr, solid, grid.cell_count, which) * grid.mean_cell_volume()
	return flat / real
