extends Resource
class_name LocalAgentsTargetWallProfileResource

@export var wall_height_levels: int = 6
@export var column_extra_levels: int = 4
@export var column_span_interval: int = 3
@export var material_profile_key: String = "rock"
@export var destructible_tag: String = "target_wall"
@export var brittleness: float = 1.0
@export var pillar_height_scale: float = 1.0
@export var pillar_density_scale: float = 1.0

func to_dict() -> Dictionary:
	return {
		"wall_height_levels": maxi(1, wall_height_levels),
		"column_extra_levels": maxi(0, column_extra_levels),
		"column_span_interval": maxi(1, column_span_interval),
		"material_profile_key": material_profile_key.strip_edges(),
		"destructible_tag": destructible_tag.strip_edges(),
		"brittleness": clampf(brittleness, 0.1, 3.0),
		"pillar_height_scale": clampf(pillar_height_scale, 0.25, 3.0),
		"pillar_density_scale": clampf(pillar_density_scale, 0.25, 3.0),
	}
