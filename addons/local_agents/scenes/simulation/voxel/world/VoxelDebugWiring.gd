class_name LAVoxelDebugWiring
extends Node

## LAVoxelDebugWiring — owns the debug menu (LADebugPanel, left dock) + its world-space gizmo overlay
## (LADebugOverlay), the panel→handler signal wiring, and the debug-view dispatch (temp/wind/scent views,
## type highlights, intended paths, perf toggles, the save-screenshot button) plus the V/T scent+temp
## toggles the interaction controller triggers. Factored out of LAVoxelWorld so the "debug views + behavior
## highlights" concern is one file. (Explicit types only — no ':=' inferred typing.)

const DebugPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugPanel.gd")
const DebugOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugOverlay.gd")

var _world: Node = null
var _material: Node = null
var _terrain = null
var _sky: LAVoxelSkyController = null
var _hud: CanvasLayer = null
var _input: LAVoxelInputController = null
var _debug_panel: CanvasLayer = null    # LADebugPanel (left-docked debug menu)
var _debug_overlay: Node3D = null       # LADebugOverlay (world-space highlight/path/wind gizmos)

var _scent_visible: bool = false
var _temp_debug_visible: bool = false   # T toggles the terrain temperature heatmap debug view
var _user_shot_counter: int = 0         # numbers the screenshots the DebugPanel's save button writes


## Build the overlay + panel (as children of `world`) and wire the panel signals to the handlers here.
func setup(world: Node, material: Node, terrain, sky: LAVoxelSkyController, hud: CanvasLayer, input: LAVoxelInputController) -> void:
	_world = world
	_material = material
	_terrain = terrain
	_sky = sky
	_hud = hud
	_input = input
	# Debug menu (left) + its world-space gizmo overlay: field views, type highlights, intended paths.
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	world.add_child(_debug_overlay)
	_debug_overlay.setup(_material)
	_debug_panel = DebugPanelScript.new()
	_debug_panel.name = "DebugPanel"
	world.add_child(_debug_panel)
	_debug_panel.view_toggled.connect(_on_debug_view)
	_debug_panel.highlight_toggled.connect(_on_debug_highlight)
	_debug_panel.paths_toggled.connect(_on_debug_paths)
	_debug_panel.perf_toggled.connect(_on_debug_perf)
	_debug_panel.screenshot_requested.connect(_on_debug_screenshot)
	if _input != null and _input.debug_demo():
		# Verification aid: pre-enable a spread of gizmos so a screenshot shows them working.
		_debug_overlay.set_wind(true)
		_debug_overlay.set_paths(true)
		_debug_overlay.set_highlight("species_bird", true)
		_debug_overlay.set_highlight("species_fox", true)
		_debug_overlay.set_highlight("nest", true)
	elif _input != null and _input.wind_view():
		# Wind-field verification: ONLY the emergent wind-arrow overlay (clean shot of funneling/fronts).
		_debug_overlay.set_wind(true)


# --- Debug menu handlers -----------------------------------------------------

func _on_debug_view(view: String, on: bool) -> void:
	match view:
		"temp":
			_temp_debug_visible = on
			if _terrain != null and _terrain.has_method("set_shader_param"):
				_terrain.set_shader_param("heat_debug", 1.0 if on else 0.0)
		"wind":
			if _debug_overlay != null:
				_debug_overlay.set_wind(on)
		"scent":
			_scent_visible = on
			if _debug_overlay != null:
				_debug_overlay.set_scent(on)


func _on_debug_highlight(group: String, on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_highlight(group, on)


func _on_debug_paths(on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_paths(on)


func _on_debug_perf(key: String, on: bool) -> void:
	match key:
		"shadows":
			if _sky != null:
				_sky.set_shadows(on)
		"ssao":
			if _sky != null:
				_sky.set_ssao(on)


# Save-screenshot button (DebugPanel): capture the current viewport to a numbered PNG in the project
# folder and report the absolute path so it's easy to find.
func _on_debug_screenshot() -> void:
	_user_shot_counter += 1
	var path: String = ProjectSettings.globalize_path("res://volcano_shot_%d.png" % _user_shot_counter)
	if _world != null and _world.has_method("capture_screenshot"):
		_world.capture_screenshot(path)
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Saved screenshot → %s" % path)

	# Anti-aliasing: the low-poly terrain/actors have hard silhouettes that crawl and alias badly. MSAA 2x
	# cleans the geometry edges. The scene is CPU-bound so this GPU-side smoothing is effectively free here.
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_2X
	# Enable per-viewport GPU render-time measurement so the perf probe can report the rendering cost
	# isolated from the (highly variable) CPU sim load.
	if _input != null and _input.shoot_path() != "":
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


# --- V/T toggles (from the interaction controller, forwarded through the world) ---

## V key: toggle the emergent scent-field debug gizmos (DebugOverlay).
func toggle_scent_view() -> void:
	_scent_visible = not _scent_visible
	if _debug_overlay != null:
		_debug_overlay.set_scent(_scent_visible)
	if _hud != null:
		_hud.set_status("Scent view: %s" % ("ON" if _scent_visible else "off"))


## T key: toggle the terrain temperature heatmap debug view.
func toggle_temp_view() -> void:
	_temp_debug_visible = not _temp_debug_visible
	if _terrain != null and _terrain.has_method("set_shader_param"):
		_terrain.set_shader_param("heat_debug", 1.0 if _temp_debug_visible else 0.0)
	if _hud != null:
		_hud.set_status("Temperature view: %s" % ("ON" if _temp_debug_visible else "off"))
