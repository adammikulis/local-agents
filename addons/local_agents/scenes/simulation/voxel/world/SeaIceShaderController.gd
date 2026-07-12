class_name LASeaIceShaderController
extends Node

## Owns the emergent sea-ice texture and feeds it to the ocean shell (VoxelWaterSphere.gdshader) so frozen
## sea reads WHITE from orbit — polar caps in the cold hemisphere / at the poles, open blue sea in the warm
## tropics. The ice itself is NOT simulated here: it is the conserved `_snow` channel the generic freeze
## reaction accumulates on cold static-sea cells (and thaws where warm). All baking lives in the
## LASeaIceTextureBaker MODULE; this controller is the thin driver + shader glue (VoxelWorld / MaterialField3D
## / OceanPlane stay extract-only). Sphere-only; a no-op on the flat island (no cubed-sphere sea).
##
## Cheap: rebakes on a ~2 Hz cadence off the field's live CPU readback (one O(surf_count) reduction) and pushes
## ONE small texture the shell samples in place. Disable with the LA_NO_SEAICE env var (open blue sea, no caps)
## for A/B comparison or a warm-planet look. (Explicit types only — no ':=' .)

const SeaIceBakerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/SeaIceTextureBaker.gd")

const REBAKE_PERIOD: float = 0.5      # seconds between sea-ice rebakes (~2 Hz — caps drift slowly with climate/season)

var _field: Object = null
var _targets: Array = []               # nodes with set_sea_ice_texture(tex): the ocean shell + the near-cap surface
var _baker: RefCounted = null
var _accum: float = REBAKE_PERIOD     # bake on the first eligible frame
var _bound: bool = false
var _enabled: bool = false


## Wire the field + the sea render targets (ocean shell + near-cap surface). VoxelWorld composition root calls
## this once. Silently idle unless the field is a cubed-sphere; fully disabled by LA_NO_SEAICE. Any target that
## exposes set_sea_ice_texture(tex) gets fed the SAME coverage texture so the two seas read as one frozen cap.
func setup(field: Object, ocean: Object, near_surface: Object = null) -> void:
	_field = field
	_targets = []
	for t in [ocean, near_surface]:
		if t != null and t.has_method("set_sea_ice_texture"):
			_targets.append(t)
	if OS.has_environment("LA_NO_SEAICE"):
		_enabled = false
		set_process(false)
		return
	_enabled = _field != null and not _targets.is_empty() \
		and _field.has_method("is_sphere") and _field.has_method("climate_snapshot")
	set_process(_enabled)


func _process(delta: float) -> void:
	if not _enabled:
		return
	_accum += delta
	if _accum < REBAKE_PERIOD:
		return
	_accum = 0.0
	if not _field.is_sphere():
		return
	var snap: Dictionary = _field.climate_snapshot()
	if snap.is_empty() or not snap.has("static"):
		return
	var grid: RefCounted = _field.sphere_grid()
	if grid == null:
		return
	if _baker == null:
		_baker = SeaIceBakerScript.new()
		_baker.setup(grid)
	_baker.bake(snap["snow"], snap["solid"], snap["static"], int(snap["cell_count"]))
	var tex: Texture2DArray = _baker.texture()
	if tex == null:
		return
	if not _bound:
		for t in _targets:
			t.set_sea_ice_texture(tex)
		_bound = true
