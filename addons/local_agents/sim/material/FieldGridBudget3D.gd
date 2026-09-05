class_name LAFieldGridBudget
extends RefCounted

## Cells one scale height is cut into at the target edge; a DISCRETISATION, docs/MODEL_PARAMETERS.md.
const CELLS_PER_SCALE_HEIGHT: float = 2.0

## Cells of padding a refinement level carries around the terrain surface and around a box's focus axis;
## a DISCRETISATION of the grading, docs/MODEL_PARAMETERS.md.
const CELLS_PER_LEVEL_PAD: float = 4.0


static func target_edge_m(body_key: String, radius_m: float, t_c: float) -> float:
	return LAGridGeometry.target_edge_m(float(LABodySeeds.of(body_key).get("mass_kg", 0.0)), radius_m, t_c,
		CELLS_PER_SCALE_HEIGHT)


## The air a box holds, metres over the datum: where the seeded barometric profile leaves so little gas
## that a molecule crosses one target cell uncollided. Above it there is no fluid. NAN when unsolved.
static func air_extent_m(body_key: String, radius_m: float, t_c: float) -> float:
	return LAFieldLithostaticSeed.air_extent_m(body_key, radius_m, t_c,
		target_edge_m(body_key, radius_m, t_c))


## The rock a box refines into, metres under the surface: the conductive lid the geotherm solves. Below
## it the mantle convects. NAN when unsolved.
static func rock_extent_m(radius_m: float, t_c: float) -> float:
	return LAPlanetComposition.lid_thickness_m(radius_m, t_c)


## Refine `grid` to `target_m` in the surface band under docs/CELL_BUDGET, and any slab this world will
## record to that slab's edge; the extension caches the geometry under everything it depends on.
static func refine_to_budget(grid: LAVoxelGrid, centre: Vector3, terrain: Object, below_m: float,
		above_m: float, target_m: float, body_radius: float) -> void:
	var g: Dictionary = LAGridGeometry.refine_field_grid(grid, terrain, centre, body_radius, below_m, above_m,
		target_m, CELLS_PER_LEVEL_PAD, LAFieldBoundaryCapture3D.configured(
			LAFieldBoundaryCapture3D.CAPTURE_BOX_SETTING, LAFieldBoundaryCapture3D.ENV_CAPTURE_BOX), "")
	if not g.is_empty():
		grid.adopt_geometry(g)
