class_name LAFieldTotals
extends RefCounted

## A TOTAL IS A MASS, NOT A COUNT. One place that turns a channel into an amount of matter.

## Which cells a sum includes. Tags, not quantities, which is why they are an enum.
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
## The REFERENCE density: this sums a whole grid with no per-cell temperature or pressure in hand, so it
## answers what the channel units weigh, not what the matter weighs where it sits.
static func substance_kg(grid, arr: PackedFloat32Array, solid: PackedByteArray, which: int,
		substance: String) -> float:
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var density: float = float(entry.get("density", 0.0))
	if density <= 0.0:
		push_error("LAFieldTotals.substance_kg: '%s' has no density in LASubstances" % substance)
		return 0.0
	return volume_sum(grid, arr, solid, which) * density
