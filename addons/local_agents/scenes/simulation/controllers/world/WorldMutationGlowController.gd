extends Node3D

const DEFAULT_TTL_SECONDS: float = 0.9
const DEFAULT_MAX_MARKERS: int = 32
const DEFAULT_MARKER_SCALE: float = 0.45

@export var chunk_size: int = 12
@export var ttl_seconds: float = DEFAULT_TTL_SECONDS
@export var max_markers: int = DEFAULT_MAX_MARKERS
@export var marker_scale: float = DEFAULT_MARKER_SCALE
@export var glow_color: Color = Color(1.0, 0.65, 0.18, 1.0)

var _markers: Array = []
var _idle_nodes: Array = []
var _marker_mesh: SphereMesh
var _marker_material: StandardMaterial3D

func _ready() -> void:
	_marker_mesh = SphereMesh.new()
	_marker_mesh.radius = 0.5
	_marker_material = StandardMaterial3D.new()
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.emission_enabled = true
	_marker_material.emission = glow_color
	_marker_material.albedo_color = glow_color
	_marker_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	set_process(true)

func set_chunk_size(size: int) -> void:
	chunk_size = max(1, size)

func spawn_markers(world_positions: Array) -> void:
	if world_positions.is_empty():
		return
	var now = float(Time.get_ticks_usec()) / 1000.0
	var ttl = maxf(0.05, ttl_seconds)
	for world_pos in world_positions:
		if not world_pos is Vector3:
			continue
		if _markers.size() >= max_markers:
			_remove_oldest_marker()
		var node = _reserve_marker_node()
		var transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * marker_scale), world_pos)
		node.global_transform = transform
		node.visible = true
		var material = _marker_material.duplicate()
		node.material_override = material
		_markers.append({
			"node": node,
			"start": now,
			"expires": now + ttl,
			"ttl": ttl,
		})
	_update_marker_visuals(now)

func _process(delta: float) -> void:
	if _markers.is_empty():
		return
	var now = float(Time.get_ticks_usec()) / 1000.0
	var alive: Array = []
	for marker in _markers:
		if marker.get("expires", 0.0) > now:
			alive.append(marker)
		else:
			var node = marker.get("node", null)
			if node is MeshInstance3D:
				node.visible = false
				_idle_nodes.append(node)
	_markers = alive
	if _markers.is_empty():
		return
	_update_marker_visuals(now)

func _reserve_marker_node() -> MeshInstance3D:
	if not _idle_nodes.is_empty():
		return _idle_nodes.pop_back() as MeshInstance3D
	var node = MeshInstance3D.new()
	node.mesh = _marker_mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = false
	add_child(node)
	return node

func _remove_oldest_marker() -> void:
	if _markers.is_empty():
		return
	var oldest = _markers.pop_front()
	var node = oldest.get("node", null)
	if node is MeshInstance3D:
		node.visible = false
		_idle_nodes.append(node)

func _update_marker_visuals(now: float) -> void:
	for marker in _markers:
		var node = marker.get("node", null)
		if not (node is MeshInstance3D):
			continue
		var start = marker.get("start", now)
		var ttl = marker.get("ttl", 1.0)
		var remaining = clampf((marker.get("expires", now) - now) / ttl, 0.0, 1.0)
		var intensity = clampf(remaining, 0.0, 1.0)
		var material = node.material_override
		if material is StandardMaterial3D:
			var color = glow_color
			color.a = intensity
			material.set("albedo_color", color)
			material.set("emission", Color(color.r, color.g, color.b, intensity))
