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


## A cell's volume in CUBIC METRES and its face in SQUARE METRES. The grid is metres, so these convert
## nothing; they exist so a caller reads the unit off the name.
static func cell_volume_m3(grid, c: int) -> float:
	return grid.cell_volume(c)


static func face_area_outward_m2(grid, c: int) -> float:
	return grid.cell_size * grid.cell_size


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
	return volume_sum(grid, arr, solid, which) * density
