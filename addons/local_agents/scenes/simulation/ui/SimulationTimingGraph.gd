extends Control
class_name LocalAgentsSimulationTimingGraph

@export_range(32, 720, 8) var history_size: int = 240
@export var show_total_series: bool = true
@export var graph_background_color: Color = Color(0.04, 0.05, 0.07, 0.72)
@export var graph_grid_color: Color = Color(0.28, 0.33, 0.42, 0.3)
@export var graph_border_color: Color = Color(0.62, 0.7, 0.88, 0.55)
@export var total_color: Color = Color(1.0, 1.0, 1.0, 0.95)
@export var weather_color: Color = Color(0.35, 0.78, 1.0, 0.9)
@export var hydrology_color: Color = Color(0.2, 1.0, 0.95, 0.9)
@export var erosion_color: Color = Color(0.95, 0.62, 0.24, 0.9)
@export var solar_color: Color = Color(1.0, 0.92, 0.28, 0.9)
@export var resource_color: Color = Color(0.5, 1.0, 0.44, 0.9)
@export var structure_color: Color = Color(0.95, 0.45, 0.8, 0.9)
@export var culture_color: Color = Color(0.88, 0.72, 1.0, 0.9)
@export var cognition_color: Color = Color(1.0, 0.36, 0.36, 0.9)
@export var snapshot_color: Color = Color(0.82, 0.82, 0.82, 0.8)

const _SERIES_KEYS := [
	"weather_ms",
	"hydrology_ms",
	"erosion_ms",
	"solar_ms",
	"resource_pipeline_ms",
	"structure_ms",
	"culture_ms",
	"cognition_ms",
	"snapshot_ms",
]

var _series_history: Dictionary = {}
var _y_max_ms: float = 5.0
var _series_visible: Dictionary = {
	"total_ms": true,
	"weather_ms": true,
	"hydrology_ms": true,
	"erosion_ms": true,
	"solar_ms": true,
	"resource_pipeline_ms": true,
	"structure_ms": true,
	"culture_ms": true,
	"cognition_ms": true,
	"snapshot_ms": true,
}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0.0, 128.0)

func push_profile(profile: Dictionary) -> void:
	if profile.is_empty():
		return
	for key in _SERIES_KEYS:
		_push_series_value(key, maxf(0.0, float(profile.get(key, 0.0))))
	if show_total_series:
		_push_series_value("total_ms", maxf(0.0, float(profile.get("total_ms", 0.0))))
	_update_scale()
	queue_redraw()

func clear_history() -> void:
	_series_history.clear()
	_y_max_ms = 5.0
	queue_redraw()

func set_series_visible(series_key: String, enabled: bool) -> void:
	_series_visible[String(series_key)] = enabled
	queue_redraw()

func _push_series_value(key: String, value: float) -> void:
	var arr = _series_history.get(key, [])
	if not (arr is Array):
		arr = []
	arr.append(value)
	while arr.size() > maxi(16, history_size):
		arr.remove_at(0)
	_series_history[key] = arr

func _update_scale() -> void:
	var observed = 0.0
	for key_variant in _series_history.keys():
		var arr_variant = _series_history.get(key_variant, [])
		if not (arr_variant is Array):
			continue
		for v in arr_variant:
			observed = maxf(observed, float(v))
	var target = maxf(1.0, observed * 1.15)
	_y_max_ms = lerpf(_y_max_ms, target, 0.18)
	_y_max_ms = clampf(_y_max_ms, 1.0, 200.0)

func _draw() -> void:
	var r = Rect2(Vector2.ZERO, size)
	if r.size.x < 20.0 or r.size.y < 20.0:
		return
	draw_rect(r, graph_background_color, true)
	_draw_grid(r)
	_draw_series(r, "weather_ms", weather_color)
	_draw_series(r, "hydrology_ms", hydrology_color)
	_draw_series(r, "erosion_ms", erosion_color)
	_draw_series(r, "solar_ms", solar_color)
	_draw_series(r, "resource_pipeline_ms", resource_color)
	_draw_series(r, "structure_ms", structure_color)
	_draw_series(r, "culture_ms", culture_color)
	_draw_series(r, "cognition_ms", cognition_color)
	_draw_series(r, "snapshot_ms", snapshot_color)
	if show_total_series and bool(_series_visible.get("total_ms", true)):
		_draw_series(r, "total_ms", total_color, 2.3)
	draw_rect(r, graph_border_color, false, 1.0)

func _draw_grid(r: Rect2) -> void:
	var h_lines = 4
	var v_lines = 6
	for i in range(1, h_lines):
		var y = r.position.y + (r.size.y * float(i) / float(h_lines))
		draw_line(Vector2(r.position.x, y), Vector2(r.position.x + r.size.x, y), graph_grid_color, 1.0)
	for i in range(1, v_lines):
		var x = r.position.x + (r.size.x * float(i) / float(v_lines))
		draw_line(Vector2(x, r.position.y), Vector2(x, r.position.y + r.size.y), graph_grid_color, 1.0)

func _draw_series(r: Rect2, key: String, color: Color, thickness: float = 1.6) -> void:
	if not bool(_series_visible.get(key, true)):
		return
	var arr_variant = _series_history.get(key, [])
	if not (arr_variant is Array):
		return
	var arr: Array = arr_variant
	if arr.size() < 2:
		return
	var n = arr.size()
	var denom = maxf(1.0, float(n - 1))
	var points := PackedVector2Array()
	points.resize(n)
	var y_max = maxf(1.0, _y_max_ms)
	for i in range(n):
		var v = clampf(float(arr[i]), 0.0, y_max)
		var x = r.position.x + (r.size.x * float(i) / denom)
		var y = r.position.y + r.size.y - ((v / y_max) * r.size.y)
		points[i] = Vector2(x, y)
	draw_polyline(points, color, thickness, true)
