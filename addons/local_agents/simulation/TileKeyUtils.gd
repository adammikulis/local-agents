extends RefCounted
class_name LocalAgentsTileKeyUtils

static func tile_id(x: int, y: int) -> String:
	return "%d:%d" % [x, y]

static func parse_tile_id(value: String) -> Vector2i:
	var parts = value.split(":")
	if parts.size() != 2:
		return Vector2i(2147483647, 2147483647)
	return Vector2i(int(parts[0]), int(parts[1]))

static func from_world_xz(world_position: Vector3) -> String:
	return tile_id(int(round(world_position.x)), int(round(world_position.z)))

