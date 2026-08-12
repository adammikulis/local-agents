class_name LABiomeShaderController
extends Node


const BiomeBakerScript: GDScript = preload("res://addons/local_agents/sim/material/BiomeTextureBaker.gd")

const REBAKE_PERIOD: float = 0.4      # seconds between climate rebakes (~2.5 Hz — biomes drift slowly)


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
		if not _terrain.has_method("sea_radius"):
			push_error("LABiomeShaderController: terrain has no sea_radius — biome bake disabled")
			_enabled = false
			set_process(false)
			return
		var sea_r: float = _terrain.sea_radius()
		_baker = BiomeBakerScript.new()
		_baker.setup(grid, sea_r)
	_baker.bake(snap["moisture"], snap["temp"], snap["snow"], snap["solid"], int(snap["cell_count"]))
	var tex: Texture2DArray = _baker.texture()
	if tex == null:
		return
	if not _bound:
		_terrain.set_shader_param("biome_tex", tex)
		_terrain.set_shader_param("biome_enabled", 1.0)
		_bound = true
