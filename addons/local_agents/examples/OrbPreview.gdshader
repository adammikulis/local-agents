shader_type canvas_item;
render_mode unshaded;

void fragment() {
    vec4 tint = COLOR;
    vec2 position = UV * 2.0 - 1.0;
    float radius = length(position);
    float body = 1.0 - smoothstep(0.62, 0.66, radius);
    float glow = exp(-radius * radius * 5.0) * 0.35;
    float highlight = exp(-length(position - vec2(-0.22, -0.25)) * 8.0);
    COLOR = vec4(tint.rgb * (0.65 + (1.0 - radius) * 0.55) + vec3(highlight * 0.6), max(body, glow) * tint.a);
}
