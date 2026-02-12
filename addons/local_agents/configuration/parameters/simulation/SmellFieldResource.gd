extends Resource
class_name LocalAgentsSmellFieldResource

@export var schema_version: int = 2
@export var grid_layout: String = "hex_pointy"
@export var half_extent: float = 10.0
@export var hex_size: float = 0.45
@export var width: int = 28
@export var height: int = 28
@export var lod_levels: int = 3
@export var subdivision_ratio: int = 2
@export var subdivision_trigger_strength: float = 0.55
@export var food_channel: PackedFloat32Array = PackedFloat32Array()
@export var rabbit_channel: PackedFloat32Array = PackedFloat32Array()
@export var danger_channel: PackedFloat32Array = PackedFloat32Array()
@export var sparse_layers: Dictionary = {}

func setup(next_half_extent: float, next_hex_size: float) -> void:
	half_extent = maxf(1.0, next_half_extent)
	hex_size = maxf(0.1, next_hex_size)
	grid_layout = "hex_pointy"
	var horizontal_spacing: float = sqrt(3.0) * hex_size
	var vertical_spacing: float = 1.5 * hex_size
	width = maxi(3, int(ceil((half_extent * 2.0) / horizontal_spacing)) + 4)
	height = maxi(3, int(ceil((half_extent * 2.0) / vertical_spacing)) + 4)
	var size: int = width * height
	food_channel.resize(size)
	rabbit_channel.resize(size)
	danger_channel.resize(size)
	clear_channels()

func clear_channels() -> void:
	for i in range(width * height):
		food_channel[i] = 0.0
		rabbit_channel[i] = 0.0
		danger_channel[i] = 0.0
	sparse_layers.clear()

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"grid_layout": grid_layout,
		"half_extent": half_extent,
		"hex_size": hex_size,
		"width": width,
		"height": height,
		"lod_levels": lod_levels,
		"subdivision_ratio": subdivision_ratio,
		"subdivision_trigger_strength": subdivision_trigger_strength,
		"food_channel": food_channel,
		"rabbit_channel": rabbit_channel,
		"danger_channel": danger_channel,
		"sparse_layers": sparse_layers.duplicate(true),
	}

func from_dict(payload: Dictionary) -> void:
	schema_version = int(payload.get("schema_version", schema_version))
	grid_layout = String(payload.get("grid_layout", grid_layout))
	half_extent = maxf(1.0, float(payload.get("half_extent", half_extent)))
	hex_size = maxf(0.1, float(payload.get("hex_size", hex_size)))
	width = maxi(3, int(payload.get("width", width)))
	height = maxi(3, int(payload.get("height", height)))
	lod_levels = maxi(1, int(payload.get("lod_levels", lod_levels)))
	subdivision_ratio = maxi(2, int(payload.get("subdivision_ratio", subdivision_ratio)))
	subdivision_trigger_strength = clampf(float(payload.get("subdivision_trigger_strength", subdivision_trigger_strength)), 0.01, 2.0)
	var target_size: int = width * height
	food_channel = _array_with_size(payload.get("food_channel", PackedFloat32Array()), target_size)
	rabbit_channel = _array_with_size(payload.get("rabbit_channel", PackedFloat32Array()), target_size)
	danger_channel = _array_with_size(payload.get("danger_channel", PackedFloat32Array()), target_size)
	var sparse_variant = payload.get("sparse_layers", {})
	if sparse_variant is Dictionary:
		sparse_layers = sparse_variant.duplicate(true)
	else:
		sparse_layers = {}

func setup_from_grid_config(grid_config: Resource) -> void:
	if grid_config == null:
		setup(half_extent, hex_size)
		return
	var layout = String(grid_config.get("grid_layout"))
	if layout == "":
		layout = "hex_pointy"
	if layout != "hex_pointy":
		push_error("SmellFieldResource requires hex_pointy grid layout")
		return
	setup(
		maxf(1.0, float(grid_config.get("half_extent"))),
		maxf(0.1, float(grid_config.get("cell_size")))
	)

func _array_with_size(value: Variant, target_size: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if value is PackedFloat32Array:
		result = value
	result.resize(target_size)
	for i in range(target_size):
		result[i] = maxf(0.0, float(result[i]))
	return result
