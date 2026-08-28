class_name LAFieldGridBudget
extends RefCounted

## Cells one scale height is cut into at the target edge; a DISCRETISATION, docs/MODEL_PARAMETERS.md.
const CELLS_PER_SCALE_HEIGHT: float = 2.0


static func target_edge_m(body_key: String, radius_m: float, t_c: float) -> float:
	return LAGridGeometry.target_edge_m(float(LABodySeeds.of(body_key).get("mass_kg", 0.0)), radius_m, t_c,
		CELLS_PER_SCALE_HEIGHT)


## Refine `grid` to `target_m` in the surface band under docs/CELL_BUDGET, and any slab this world will
## record to that slab's edge; the extension caches the geometry under everything it depends on.
static func refine_to_budget(grid: LAVoxelGrid, centre: Vector3, terrain: Object, below_m: float,
		above_m: float, target_m: float, body_radius: float) -> void:
	var g: Dictionary = LAGridGeometry.refine_field_grid(grid, terrain, centre, body_radius, below_m, above_m,
		target_m, LAFieldBoundaryCapture3D.configured(LAFieldBoundaryCapture3D.CAPTURE_BOX_SETTING,
			LAFieldBoundaryCapture3D.ENV_CAPTURE_BOX), "")
	if not g.is_empty():
		grid.adopt_geometry(g)
