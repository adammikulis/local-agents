class_name LAFieldVectorLegend
extends CanvasLayer

## The key the arrow glyphs are read against: the same ramp shader they are coloured by, the source it
## is a ramp OF, and the magnitude it saturates at. Absent when no vector source is drawn.

const RampShader: Shader = preload("res://addons/local_agents/game/ui/FieldRampBar.gdshader")

const BAR_SIZE: Vector2 = Vector2(180.0, 12.0)
const MARGIN: float = 14.0

var _vectors: LAFieldVectors = null
var _title: Label = null
var _top: Label = null
var _root: Control = null


func _ready() -> void:
	layer = 2
	_root = VBoxContainer.new()
	_root.name = "VectorLegend"
	_root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_root.position = Vector2(MARGIN, -96.0)
	_root.add_theme_constant_override("separation", 2)
	_title = _label(LAUiStyle.COL_TEXT)
	_root.add_child(_title)
	var bar: ColorRect = ColorRect.new()
	bar.custom_minimum_size = BAR_SIZE
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = RampShader
	bar.material = mat
	_root.add_child(bar)
	var row: HBoxContainer = HBoxContainer.new()
	var calm: Label = _label(LAUiStyle.COL_TEXT_DIM)
	calm.text = "calm"
	calm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(calm)
	_top = _label(LAUiStyle.COL_TEXT_DIM)
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
		return
	visible = true
	_title.text = "%s, one arrow per open cell" % _vectors.source
	_top.text = "%.0f %s" % [_vectors.reference(), _vectors.unit()]


func _label(col: Color) -> Label:
	var l: Label = Label.new()
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", 12)
	return l
