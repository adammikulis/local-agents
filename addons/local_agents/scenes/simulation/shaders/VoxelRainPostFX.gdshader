shader_type canvas_item;

uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_speed : hint_range(0.0, 2.0) = 0.5;
uniform float lightning_flash : hint_range(0.0, 2.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 456.21));
	p += dot(p, p + 34.45);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 w = normalize(wind_dir);
	float t = TIME * (1.8 + wind_speed * 1.8);
	float streak_sum = 0.0;
	for (int i = 0; i < 4; i++) {
		float fi = float(i);
		vec2 p = vec2(uv.x * (12.0 + fi * 5.0), uv.y * 28.0 + t * (3.0 + fi));
		p += vec2(w.x * fi * 0.9, -w.y * fi * 0.6);
		float n = hash21(floor(p));
		float streak = smoothstep(0.94, 1.0, n) * (1.0 - fract(p.y));
		streak_sum += streak;
	}
	float rain_alpha = clamp(streak_sum * rain_intensity * 0.16, 0.0, 0.35);
	vec3 rain_color = mix(vec3(0.62, 0.72, 0.82), vec3(0.9, 0.95, 1.0), lightning_flash * 0.35);
	COLOR = vec4(rain_color, rain_alpha);
}
