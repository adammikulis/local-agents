class_name LAFieldGridBudget
extends RefCounted

## Cells one scale height is cut into at the target edge; a DISCRETISATION, docs/MODEL_PARAMETERS.md.
const CELLS_PER_SCALE_HEIGHT: float = 2.0


static func target_edge_m(body_key: String, radius_m: float, t_c: float) -> float:
	return LAGridGeometry.target_edge_m(float(LABodySeeds.of(body_key).get("mass_kg", 0.0)), radius_m, t_c,
		CELLS_PER_SCALE_HEIGHT)


static func refine_to_budget(grid: LAVoxelGrid, centre: Vector3, terrain: Object, below_m: float,
		above_m: float, target_m: float) -> void:
	var cap: int = LAGridGeometry.cell_budget()
	if cap <= 0:
		push_error("LAFieldGridBudget: docs/CELL_BUDGET declares no budget, so the grid stays coarse.")
		return
	var reached: float = grid.refine_graded(centre, terrain, below_m, above_m, target_m, cap)
	LASimReport.gauge("grid_cells", float(grid.cell_count))
	LASimReport.gauge("grid_max_level", float(grid.max_level))
	LASimReport.gauge("grid_target_edge_m", reached)
