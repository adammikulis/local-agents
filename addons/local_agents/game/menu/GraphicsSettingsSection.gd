class_name LAGraphicsSettingsSection
extends RefCounted

## LAGraphicsSettingsSection — the GRAPHICS (GPU-bound) category of the settings screen. It draws a five-step
## overall preset row (Potato / Low / Medium / High / Ultra) plus the individual GPU knobs those presets map
## to: field/render resolution, effects/particle density, shadow quality, ambient occlusion, bloom/glow,
## ocean water quality, atmospheric fog, vegetation density and draw distance. Picking an overall preset sets
## every knob; nudging any individual knob re-derives the preset (falling to "Custom" when the knobs no
## longer match a named preset). Every control carries a tooltip naming what it affects and that the cost is
## on the GPU. Numeric knobs show a live value readout.
##
## It edits an LAGameSettings in place and calls `on_changed` after every edit so the host menu can mark the
## screen dirty. Built from LASettingsWidgets so it shares the menu's control styling. (Explicit types only.)

const CUSTOM_LABEL: String = "Custom (individual settings)"

var _settings: LAGameSettings = null
var _on_changed: Callable = Callable()
var _suppress: bool = false

var _preset_group: ButtonGroup = null
var _preset_buttons: Dictionary = {}     # GraphicsPreset -> Button
var _preset_caption: Label = null

var _grid_slider: HSlider = null
var _grid_value: Label = null
var _veg_slider: HSlider = null
var _veg_value: Label = null
var _draw_slider: HSlider = null
var _draw_value: Label = null
var _effects_option: OptionButton = null
var _shadow_option: OptionButton = null
var _ssao_option: OptionButton = null
var _glow_option: OptionButton = null
var _ocean_option: OptionButton = null
var _fog_option: OptionButton = null


func setup(settings: LAGameSettings, on_changed: Callable) -> void:
	_settings = settings
	_on_changed = on_changed


func build(col: VBoxContainer) -> void:
	LASettingsWidgets.add_header(col, "Graphics — GPU")

	_preset_group = ButtonGroup.new()
	var row: HBoxContainer = LASettingsWidgets.add_row(col)
	_add_preset(row, LAGameSettings.GraphicsPreset.POTATO, "Potato", "Absolute minimum for weak / integrated GPUs — coarsest field, no shadows or post FX. GPU cost: lowest.")
	_add_preset(row, LAGameSettings.GraphicsPreset.LOW, "Low", "Low GPU load — coarse field, cheap water, no post FX. GPU cost: low.")
	_add_preset(row, LAGameSettings.GraphicsPreset.MEDIUM, "Medium", "Balanced default — playable field resolution, effects on, fill-rate killers off. GPU cost: moderate.")
	_add_preset(row, LAGameSettings.GraphicsPreset.HIGH, "High", "Fine field, translucent water, ambient occlusion + glow + shadows. GPU cost: high.")
	_add_preset(row, LAGameSettings.GraphicsPreset.ULTRA, "Ultra", "Maximum — finest field and the full post-FX stack. GPU cost: highest (strong GPUs only).")

	_preset_caption = LAMenuStyle.make_caption("")
	_preset_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(_preset_caption)

	# --- Individual GPU knobs ---
	var grid: Dictionary = LASettingsWidgets.add_slider(col, "Field resolution",
		"Field / render grid cells per axis — the single biggest GPU cost (per-cell compute + readback). GPU cost: very high.",
		24.0, 192.0, 12.0, float(_settings.grid_resolution), Callable(self, "_fmt_int"), Callable(self, "_on_grid"))
	_grid_slider = grid["slider"]
	_grid_value = grid["value"]

	_effects_option = LASettingsWidgets.add_option(col, "Effects / particle density",
		"How many atmosphere / weather particles draw (rain, spray, dust). Visual only. GPU cost: medium.",
		["Low", "Medium", "High"], int(_settings.effects_level), Callable(self, "_on_effects"))

	_shadow_option = LASettingsWidgets.add_option(col, "Shadow quality",
		"Sun shadow map — a second scene pass. Visual only. GPU cost: high.",
		["Off", "Low", "High"], int(_settings.shadow_quality), Callable(self, "_on_shadow"))

	_ssao_option = LASettingsWidgets.add_option(col, "Ambient occlusion",
		"Screen-space ambient occlusion contact shadows — a full-screen post pass. Visual only. GPU cost: high.",
		["Off", "On"], 1 if _settings.ssao_enabled else 0, Callable(self, "_on_ssao"))

	_glow_option = LASettingsWidgets.add_option(col, "Bloom / glow",
		"HDR bloom on bright pixels — a full-screen post pass. Visual only. GPU cost: medium.",
		["Off", "On"], 1 if _settings.glow_enabled else 0, Callable(self, "_on_glow"))

	_ocean_option = LASettingsWidgets.add_option(col, "Ocean water quality",
		"Opaque water is cheap; translucent water sees the seabed but adds heavy planet-filling overdraw. Visual only. GPU cost: opaque low / translucent very high.",
		["Opaque", "Translucent"], int(_settings.ocean_quality), Callable(self, "_on_ocean"))

	_fog_option = LASettingsWidgets.add_option(col, "Atmospheric fog",
		"Distance haze that adds depth and hides terrain LOD pop. Visual only. GPU cost: low.",
		["Off", "On"], 1 if _settings.fog_enabled else 0, Callable(self, "_on_fog"))

	var veg: Dictionary = LASettingsWidgets.add_slider(col, "Vegetation density",
		"Plant / foliage density scale. Visual + a little CPU to spawn. GPU cost: medium.",
		0.30, 1.50, 0.05, _settings.vegetation_density, Callable(self, "_fmt_percent"), Callable(self, "_on_veg"))
	_veg_slider = veg["slider"]
	_veg_value = veg["value"]

	var draw: Dictionary = LASettingsWidgets.add_slider(col, "Draw distance",
		"Camera far-plane budget — how far the world stays visible before it is clipped. GPU cost: medium.",
		2000.0, 20000.0, 500.0, _settings.draw_distance, Callable(self, "_fmt_metres"), Callable(self, "_on_draw"))
	_draw_slider = draw["slider"]
	_draw_value = draw["value"]

	refresh()


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_preset(preset: int) -> void:
	if _suppress:
		return
	_settings.apply_graphics_preset(preset as LAGameSettings.GraphicsPreset)
	refresh()
	_notify()


func _on_grid(value: float) -> void:
	_grid_value.text = _fmt_int(value)
	if _suppress:
		return
	_settings.grid_resolution = int(round(value))
	_after_individual()


func _on_veg(value: float) -> void:
	_veg_value.text = _fmt_percent(value)
	if _suppress:
		return
	_settings.vegetation_density = value
	_after_individual()


func _on_draw(value: float) -> void:
	_draw_value.text = _fmt_metres(value)
	if _suppress:
		return
	_settings.draw_distance = value
	_after_individual()


func _on_effects(index: int) -> void:
	if _suppress:
		return
	_settings.effects_level = index as LAGameSettings.EffectsLevel
	_after_individual()


func _on_shadow(index: int) -> void:
	if _suppress:
		return
	_settings.shadow_quality = index as LAGameSettings.ShadowQuality
	_after_individual()


func _on_ssao(index: int) -> void:
	if _suppress:
		return
	_settings.ssao_enabled = index == 1
	_after_individual()


func _on_glow(index: int) -> void:
	if _suppress:
		return
	_settings.glow_enabled = index == 1
	_after_individual()


func _on_ocean(index: int) -> void:
	if _suppress:
		return
	_settings.ocean_quality = index as LAGameSettings.OceanQuality
	_after_individual()


func _on_fog(index: int) -> void:
	if _suppress:
		return
	_settings.fog_enabled = index == 1
	_after_individual()


# An individual knob changed: re-derive the preset (may become Custom) and reflect it, without re-setting
# the control the player is dragging.
func _after_individual() -> void:
	_settings.resolve_graphics_preset()
	_refresh_preset_highlight()
	_notify()


func _notify() -> void:
	if _on_changed.is_valid():
		_on_changed.call()


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

## Push every settings value onto its control without re-firing the handlers, then reflect the preset.
func refresh() -> void:
	_suppress = true
	_grid_slider.set_value_no_signal(float(_settings.grid_resolution))
	_grid_value.text = _fmt_int(float(_settings.grid_resolution))
	_veg_slider.set_value_no_signal(_settings.vegetation_density)
	_veg_value.text = _fmt_percent(_settings.vegetation_density)
	_draw_slider.set_value_no_signal(_settings.draw_distance)
	_draw_value.text = _fmt_metres(_settings.draw_distance)
	_effects_option.select(int(_settings.effects_level))
	_shadow_option.select(int(_settings.shadow_quality))
	_ssao_option.select(1 if _settings.ssao_enabled else 0)
	_glow_option.select(1 if _settings.glow_enabled else 0)
	_ocean_option.select(int(_settings.ocean_quality))
	_fog_option.select(1 if _settings.fog_enabled else 0)
	_refresh_preset_highlight()
	_suppress = false


func _refresh_preset_highlight() -> void:
	var active: int = int(_settings.graphics_preset)
	for preset in _preset_buttons:
		(_preset_buttons[preset] as Button).set_pressed_no_signal(preset == active)
	if _preset_caption != null:
		_preset_caption.text = CUSTOM_LABEL if active == LAGameSettings.GraphicsPreset.CUSTOM else "Preset: %s" % _preset_name(active)


func _add_preset(row: HBoxContainer, preset: int, text: String, tooltip: String) -> void:
	_preset_buttons[preset] = LASettingsWidgets.add_preset_button(row, text, _preset_group, tooltip, Callable(self, "_on_preset").bind(preset))


func _preset_name(preset: int) -> String:
	match preset:
		LAGameSettings.GraphicsPreset.POTATO: return "Potato"
		LAGameSettings.GraphicsPreset.LOW: return "Low"
		LAGameSettings.GraphicsPreset.MEDIUM: return "Medium"
		LAGameSettings.GraphicsPreset.HIGH: return "High"
		LAGameSettings.GraphicsPreset.ULTRA: return "Ultra"
		_: return "Custom"


## Verification aid: move the field-resolution slider off its preset value so the section flips to Custom,
## driving the same value_changed handler a player drag would. Used by the --demo-custom shot.
func demo_nudge() -> void:
	if _grid_slider != null:
		_grid_slider.value = float(clampi(_settings.grid_resolution + 12, 24, 192))


func _fmt_int(v: float) -> String:
	return "%d" % int(round(v))


func _fmt_percent(v: float) -> String:
	return "%d%%" % int(round(v * 100.0))


func _fmt_metres(v: float) -> String:
	return "%d m" % int(round(v))
