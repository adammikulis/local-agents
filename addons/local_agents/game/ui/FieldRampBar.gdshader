shader_type canvas_item;

#include "res://addons/local_agents/game/render/FieldRamp.gdshaderinc"

void fragment() {
	COLOR = vec4(la_field_ramp(UV.x), 1.0);
}
