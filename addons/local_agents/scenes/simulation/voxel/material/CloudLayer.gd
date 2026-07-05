class_name LACloudLayer
extends MeshInstance3D

## Renders one condensate sheet (clouds aloft, or ground fog) from an LAMaterialField density grid.
## A flat plane spans the whole field at the layer's base height; each refresh copies the field's
## cloud/fog grid into an R-float density texture that CloudLayer.gdshader samples world-aligned, so
## the sheet shows exactly what the field grew and drifts as the field advects it. One class serves
## both layers — clouds sit at cloud_base_y, fog hugs the ground at fog_base_y (pooling in valleys /
## over water, mountains poking through the flat sheet).

const CLOUD_SHADER: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/CloudLayer.gdshader"
const REFRESH_HZ: float = 12.0

var _field = null
var _is_fog: bool = false
var _dim: int = 0
var _img: Image = null
var _tex: ImageTexture = null
var _mat: ShaderMaterial = null
var _accum: float = 0.0


## Build the plane + density texture for `field`. is_fog picks which grid/height/look to use.
func setup(field, is_fog: bool) -> void:
	_field = field
	_is_fog = is_fog
	_dim = field.grid_dim()
	if _dim <= 0:
		return
	var extent: float = field.grid_half_extent()

	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(extent * 2.0, extent * 2.0)
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var base_y: float = field.fog_base_y() if is_fog else field.cloud_base_y()
	position = Vector3(0.0, base_y, 0.0)

	_img = Image.create(_dim, _dim, false, Image.FORMAT_RF)
	_tex = ImageTexture.create_from_image(_img)

	_mat = ShaderMaterial.new()
	_mat.shader = load(CLOUD_SHADER)
	_mat.set_shader_parameter("density_tex", _tex)
	_mat.set_shader_parameter("world_extent", extent)
	_mat.set_shader_parameter("tint", Color(1.0, 1.0, 1.0))
	if is_fog:
		# Fog: a softer, more transparent ground haze that appears at a lower density. Only genuinely
		# dense fog reads as a sheet, so clear air stays clear (no whiteout).
		_mat.set_shader_parameter("edge_lo", 0.06)
		_mat.set_shader_parameter("edge_hi", 0.3)
		_mat.set_shader_parameter("max_alpha", 0.5)
		_mat.set_shader_parameter("detail_scale", 0.05)
	material_override = _mat


## Day/night tint (white by day, orange at dusk, dark at night) driven by VoxelWorld.
func set_tint(c: Color) -> void:
	if _mat != null:
		_mat.set_shader_parameter("tint", c)


func _process(delta: float) -> void:
	if _field == null or _mat == null:
		return
	_accum += delta
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	var grid: PackedFloat32Array = _field.fog_grid() if _is_fog else _field.cloud_grid()
	if grid.size() != _dim * _dim:
		return
	_img.set_data(_dim, _dim, false, Image.FORMAT_RF, grid.to_byte_array())
	_tex.update(_img)
	_mat.set_shader_parameter("wind", _field.wind())
