class_name LAGeneratingPlanetScreen
extends CanvasLayer

## A full-screen "Generating planet" loading overlay so the player never watches the world ASSEMBLE (terrain
## streaming in, the camera arc settling, the initial spawn). It covers everything from launch until the world
## reports ready, then fades out. Built entirely in code (no scene asset); owned by VoxelWorld (a one-line
## add_child in the composition root). The bar crawls toward 90% over the expected load and snaps to 100% the
## moment the world is actually ready, so it feels responsive and never sits stuck. (Explicit types only.)

const EXPECTED_LOAD_SEC: float = 6.0      # the bar crawls toward 90% over ~this; real "ready" snaps it to 100
const FADE_SEC: float = 0.6

var _bg: ColorRect = null
var _bar: ProgressBar = null
var _label: Label = null
var _t: float = 0.0
var _done: bool = false
var _fade: float = 0.0


func _ready() -> void:
	layer = 512                                # above every HUD/menu layer
	_bg = ColorRect.new()
	_bg.color = Color(0.02, 0.02, 0.03, 1.0)   # near-black
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow input while loading
	add_child(_bg)

	var box: VBoxContainer = VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 18)
	box.custom_minimum_size = Vector2(360, 0)
	_bg.add_child(box)

	_label = Label.new()
	_label.text = "Generating planet"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	box.add_child(_label)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(360, 10)
	box.add_child(_bar)


func _process(delta: float) -> void:
	if _done:
		_fade += delta
		var a: float = clampf(1.0 - _fade / FADE_SEC, 0.0, 1.0)
		_bg.modulate.a = a
		_bar.value = 100.0
		if _fade >= FADE_SEC:
			queue_free()
		return
	_t += delta
	# Ease toward 90% over the expected load; never reach 100 until finish() (real readiness) is called.
	_bar.value = 90.0 * (1.0 - exp(-_t / (EXPECTED_LOAD_SEC * 0.5)))


## Called by VoxelWorld the moment the world is actually ready (terrain meshed + initial spawn done). Snaps the
## bar full and fades the overlay out. Idempotent.
func finish() -> void:
	_done = true
