class_name LAFieldTotals
extends RefCounted

## Turns a channel into an amount of matter.

## Which cells a sum includes.
enum {
	CELLS_ALL = -1,    # every cell, rock and void alike
	CELLS_OPEN = 0,    # void cells only (solid == 0)
	CELLS_SOLID = 1,   # rock cells only (solid != 0)
}


## Volume-weighted sum of a channel, in model units cubed.
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


## Mass of a substance held in a channel, kg, at the substance's reference density.
static func substance_kg(grid, arr: PackedFloat32Array, solid: PackedByteArray, which: int,
		substance: String) -> float:
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var density: float = float(entry.get("density", 0.0))
	if density <= 0.0:
		push_error("LAFieldTotals.substance_kg: '%s' has no density in LASubstances" % substance)
		return 0.0
	return volume_sum(grid, arr, solid, which) * density
