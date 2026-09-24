class_name LAFieldVectorLegend
extends CanvasLayer

## The key the arrow glyphs are read against: the same ramp shader they are coloured by, the source it
## is a ramp OF, and the magnitude it saturates at. Absent when no vector source is drawn.

const RampShader: Shader = preload("res://addons/local_agents/game/ui/FieldRampBar.gdshader")
const HudTheme: Theme = preload("res://addons/local_agents/game/ui/HudTheme.tres")

# HudTheme.tres type variations.
const STYLE_TITLE: StringName = &"LegendTitle"
const STYLE_SCALE: StringName = &"LegendScale"

const BAR_SIZE: Vector2 = Vector2(180.0, 12.0)
const MARGIN: float = 14.0

var _vectors: LAFieldVectors = null
var _title: Label = null
var _top: Label = null
var _root: Control = null
var _shown: float = -1.0


func _ready() -> void:
	layer = 2
	_root = VBoxContainer.new()
	_root.name = "VectorLegend"
	_root.theme = HudTheme
	_root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_root.position = Vector2(MARGIN, -96.0)
	_root.add_theme_constant_override("separation", 2)
	_title = _label(STYLE_TITLE)
	_root.add_child(_title)
	var bar: ColorRect = ColorRect.new()
	bar.custom_minimum_size = BAR_SIZE
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = RampShader
	bar.material = mat
	_root.add_child(bar)
	var row: HBoxContainer = HBoxContainer.new()
	var calm: Label = _label(STYLE_SCALE)
	calm.text = "0"
	calm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(calm)
	_top = _label(STYLE_SCALE)
	row.add_child(_top)
	_root.add_child(row)
	add_child(_root)
	visible = false


## Bind the renderer whose scale this is a key to. Called by LAUiLayer; a run with no --ui has neither.
func bind_vectors(vectors: LAFieldVectors) -> void:
	_vectors = vectors
	refresh()


## Re-read the source and its reference. Cheap; called whenever the source changes.
func refresh() -> void:
	if _vectors == null or _vectors.reference() <= 0.0:
		visible = false
		_shown = -1.0
		return
	visible = true
	_shown = _vectors.reference()
	_title.text = "%s, one arrow per open cell" % _vectors.source
	_top.text = "%.2f %s" % [_shown, _vectors.unit()]


## The ramp is measured off the glyphs the renderer drew, so the key follows it rather than a constant.
func _process(_delta: float) -> void:
	if _vectors != null and not is_equal_approx(_shown, _vectors.reference()):
		refresh()


func _label(style: StringName) -> Label:
	var l: Label = Label.new()
	l.theme_type_variation = style
	return l
