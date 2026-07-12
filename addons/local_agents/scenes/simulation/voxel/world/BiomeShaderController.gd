class_name LABiomeShaderController
extends Node

## Owns the biome climate texture and feeds it to the terrain's triplanar shader so the ground reads by
## CLIMATE (moisture + temperature) instead of altitude alone — deserts, savanna, jungle, steppe and tundra
## self-differentiate from where the emergent field is dry/wet/hot/cold. All the baking logic lives in the
## LABiomeTextureBaker MODULE; this controller is the thin driver + shader glue (VoxelWorld / MaterialField3D
## stay extract-only). Sphere-only; a no-op on the flat island (which has no cubed-sphere climate field).
##
## Cheap: rebakes on a ~2.5 Hz cadence off the field's live CPU readback (one O(surf_count) reduction), and
## pushes ONE texture the shader samples in place (uniform is bound once). (Explicit types only — no ':=' .)

const BiomeBakerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/BiomeTextureBaker.gd")

const REBAKE_PERIOD: float = 0.4      # seconds between climate rebakes (~2.5 Hz — biomes drift slowly)

# Field saturation curve constants — MUST match MaterialField3D.SAT_* so relative humidity is measured the
# same way the field condenses cloud/rain (keeps the biome wetness axis physically consistent with weather).
const SAT_BASE: float = 0.06
const SAT_TEMP_GAIN: float = 0.055
const EVAP_TEMP_REF: float = 22.0

var _field: Object = null
var _terrain: Object = null
var _baker: RefCounted = null
var _accum: float = 0.0
var _bound: bool = false
var _enabled: bool = false


## Wire the field + terrain service (VoxelWorld composition root calls this once). Silently idle until the
## field is a cubed-sphere with a live climate snapshot.
func setup(field: Object, terrain: Object) -> void:
	_field = field
	_terrain = terrain
	_enabled = _field != null and _terrain != null \
		and _field.has_method("is_sphere") and _field.has_method("climate_snapshot") \
		and _terrain.has_method("set_shader_param")
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
	if snap.is_empty():
		return
	var grid: RefCounted = _field.sphere_grid()
	if grid == null:
		return
	if _baker == null:
		var sea_r: float = 248.0
		if _terrain.has_method("sea_radius"):
			sea_r = _terrain.sea_radius()
		_baker = BiomeBakerScript.new()
		_baker.setup(grid, sea_r, SAT_BASE, SAT_TEMP_GAIN, EVAP_TEMP_REF)
	_baker.bake(snap["moisture"], snap["temp"], snap["snow"], snap["solid"], int(snap["cell_count"]))
	var tex: Texture2DArray = _baker.texture()
	if tex == null:
		return
	if not _bound:
		_terrain.set_shader_param("biome_tex", tex)
		_terrain.set_shader_param("biome_enabled", 1.0)
		_bound = true
