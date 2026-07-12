class_name LAVoxelDebugWiring
extends Node

## LAVoxelDebugWiring — owns the debug menu (LADebugPanel, left dock) + its world-space gizmo overlay
## (LADebugOverlay), the panel→handler signal wiring, and the debug-view dispatch (temp/wind/scent views,
## type highlights, intended paths, perf toggles, the save-screenshot button) plus the V/T scent+temp
## toggles the interaction controller triggers. Factored out of LAVoxelWorld so the "debug views + behavior
## highlights" concern is one file. (Explicit types only — no ':=' inferred typing.)

const DebugPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugPanel.gd")
const DebugOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugOverlay.gd")
const FamilyTreePanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/FamilyTreePanel.gd")
const CreatureScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Creature.gd")

# The active field-channel keys (a heatmap in the DebugOverlay), distinct from temp (terrain shader),
# wind, and scent (own overlays). One is drawn at a time; enabling a new one replaces the last.
const FIELD_CHANNELS: Array = ["biomass", "water_phase", "snow", "lava", "rock_fill", "co2", "o2", "charge", "fertility"]

# Behavior-state highlight tints: category -> colour a matching creature is dyed. Foraging green +
# Hunting red are user-specified; the rest round out the state machine (flee/drink/sleep/nest).
const BEHAVIOR_COLORS: Dictionary = {
	"foraging": Color(0.30, 0.85, 0.30),
	"hunting": Color(0.95, 0.20, 0.15),
	"fleeing": Color(1.00, 0.60, 0.10),
	"drinking": Color(0.25, 0.55, 1.00),
	"sleeping": Color(0.55, 0.58, 0.62),
	"nesting": Color(0.72, 0.35, 0.92),
	# Local-LLM slow-brain highlight: cyan = consulting the on-device model now (thinking), amber = waiting
	# on the shared budget (queued). Distinct from the behavior tints so a live consult reads unambiguously.
	"llm_thinking": Color(0.15, 0.90, 0.95),
	"llm_queued": Color(0.98, 0.78, 0.20),
}

var _world: Node = null
var _material: Node = null
var _terrain = null
var _sky: LAVoxelSkyController = null
var _hud: CanvasLayer = null
var _input: LAVoxelInputController = null
var _ecology: Node = null               # LAEcologyService — owns the kinship graph the family tree reads
var _debug_panel: CanvasLayer = null    # LADebugPanel (left-docked debug menu)
var _debug_overlay: Node3D = null       # LADebugOverlay (world-space highlight/path/wind gizmos)
var _family_tree: LAFamilyTreePanel = null  # right-docked kinship family-tree inspector (on-select reader)
var _interaction: Node = null               # LAVoxelInteraction — for "select all thinking/queued" (late-bound)

var _scent_visible: bool = false
var _temp_debug_visible: bool = false   # T toggles the terrain temperature heatmap debug view
var _active_field_view: String = ""     # the single field-channel heatmap currently shown ("" = none)
var _drainage: Node = null              # LADrainageOverlay — the drainage-network debug highlight
var _user_shot_counter: int = 0         # numbers the screenshots the DebugPanel's save button writes


## Build the overlay + panel (as children of `world`) and wire the panel signals to the handlers here.
func setup(world: Node, material: Node, terrain, sky: LAVoxelSkyController, hud: CanvasLayer, input: LAVoxelInputController, ecology: Node) -> void:
	_world = world
	_material = material
	_terrain = terrain
	_sky = sky
	_hud = hud
	_input = input
	_ecology = ecology
	# Debug menu (left) + its world-space gizmo overlay: field views, type highlights, intended paths.
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	world.add_child(_debug_overlay)
	_debug_overlay.setup(_material, _terrain)
	_debug_panel = DebugPanelScript.new()
	_debug_panel.name = "DebugPanel"
	world.add_child(_debug_panel)
	_debug_panel.view_toggled.connect(_on_debug_view)
	_debug_panel.highlight_toggled.connect(_on_debug_highlight)
	_debug_panel.behavior_toggled.connect(_on_debug_behavior)
	_debug_panel.paths_toggled.connect(_on_debug_paths)
	_debug_panel.perf_toggled.connect(_on_debug_perf)
	_debug_panel.family_tree_toggled.connect(_on_debug_family_tree)
	_debug_panel.screenshot_requested.connect(_on_debug_screenshot)
	_debug_panel.select_llm_requested.connect(_on_select_llm)
	_debug_panel.perf_overlay_toggled.connect(_on_debug_perf_overlay)
	_debug_panel.render_debug_toggled.connect(_on_debug_render)
	# Family-tree inspector (right dock): a pure reader over the kinship graph, re-rooted on each selection.
	_family_tree = FamilyTreePanelScript.new()
	_family_tree.name = "FamilyTreePanel"
	world.add_child(_family_tree)
	if _ecology != null and _ecology.has_method("kinship"):
		_family_tree.set_kinship(_ecology.kinship())
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
	# Screenshot verification aids for the new debug tooling (mirrors --wind-view): pre-enable a field
	# heatmap and/or behavior-state highlights so a windowed --shoot captures them with no manual clicks.
	if _input != null and _input.debug_field() != "":
		_on_debug_view(_input.debug_field(), true)
	if _input != null and _input.debug_behaviors() != "":
		for beh in _input.debug_behaviors().split(",", false):
			_on_debug_behavior(beh.strip_edges(), true)
	# Screenshot verification aid: --debug-family pre-opens the family-tree inspector (the input controller
	# forces a real birth + selects a kin so the tree is populated for the shot).
	if _input != null and _input.debug_family() and _family_tree != null:
		_family_tree.set_enabled(true)

	# Anti-aliasing at BOOT (not only when a screenshot is taken): the low-poly, cel-shaded terrain/actors have
	# hard silhouettes that crawl and alias badly in normal play. MSAA 4x cleans the geometry edges — important
	# now the toon shader gives crisp light/shadow terminators. The scene is CPU-bound, so this GPU-side
	# smoothing is effectively free here.
	var boot_vp: Viewport = world.get_viewport()
	if boot_vp != null:
		boot_vp.msaa_3d = Viewport.MSAA_4X


## Late-bind the interaction controller (built after this wiring in the composition order) so the "select
## all thinking/queued" button can drive the shared single-selection path via a predicate.
func set_interaction(interaction: Node) -> void:
	_interaction = interaction


# "Select thinking / queued" button: pick out every creature currently consulting/waiting on the shared
# cognition scheduler and select the nearest through the normal selection path (the whole set is already
# tinted by the LLM highlight). Reuses LAVoxelInteraction.select_by_predicate; logs the match count.
func _on_select_llm(kind: String) -> void:
	if _interaction == null or not _interaction.has_method("select_by_predicate"):
		return
	var sched = null
	if _ecology != null and _ecology.has_method("cognition_scheduler"):
		sched = _ecology.cognition_scheduler()
	var pred: Callable = func(c) -> bool: return LALLMControl.matches(c, kind, sched)
	var count: int = _interaction.select_by_predicate(pred)
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Selected %d creature(s) using the local model." % count)
	print("LLM_SELECT={kind:%s, count:%d}" % [kind, count])


# Debug menu checkbox: show/hide the kinship family-tree inspector for the current selection.
func _on_debug_family_tree(on: bool) -> void:
	if _family_tree != null:
		_family_tree.set_enabled(on)


# Forwarded from the interaction controller's selection_changed signal: re-root the tree on the new selection.
func on_selection_changed(node: Node) -> void:
	if _family_tree != null:
		_family_tree.set_root(node)


# --- Debug menu handlers -----------------------------------------------------

## Register the drainage-network overlay (built by VoxelWorld under the planet body) + honour --debug-rivers.
func set_drainage(overlay: Node, show_now: bool) -> void:
	_drainage = overlay
	if show_now and _drainage != null:
		_drainage.set_shown(true)


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
		"drainage":
			if _drainage != null:
				_drainage.set_shown(on)
		_:
			# A substrate field-channel heatmap (biomass/lava/snow/…). Only one at a time: enabling a
			# channel shows it; disabling it clears the overlay only if it was the active one.
			if FIELD_CHANNELS.has(view):
				if on:
					_active_field_view = view
				elif _active_field_view == view:
					_active_field_view = ""
				if _debug_overlay != null:
					_debug_overlay.set_field_channel(_active_field_view)


func _on_debug_highlight(group: String, on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_highlight(group, on)


# Behavior-state highlight: register/clear the category tint on every creature, then refresh the live
# population once (a one-time pass on the click — NOT a per-frame scan) so already-alive creatures pick
# up or drop the tint immediately. New creatures apply it themselves on their next state change.
func _on_debug_behavior(behavior: String, on: bool) -> void:
	var col: Color = BEHAVIOR_COLORS.get(behavior, Color(1, 1, 1))
	CreatureScript.set_behavior_highlight(behavior, col, on)
	if _world == null:
		return
	for node in _world.get_tree().get_nodes_in_group("creature"):
		if is_instance_valid(node) and node.has_method("refresh_state_tint"):
			node.refresh_state_tint()


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


# DEBUG panel "Detailed perf readout": expand the HUD's FPS line to frame/field/physics ms + draw calls.
func _on_debug_perf_overlay(on: bool) -> void:
	if _hud != null and _hud.has_method("set_perf_detail"):
		_hud.set_perf_detail(on)


# DEBUG panel render-debug-draw modes (wireframe / overdraw). One at a time: enabling one wins; disabling the
# active one restores normal draw. Applied to the sim viewport.
func _on_debug_render(mode: String, on: bool) -> void:
	if _world == null:
		return
	var vp: Viewport = _world.get_viewport()
	if vp == null:
		return
	if on:
		match mode:
			"wireframe":
				vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			"overdraw":
				vp.debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
	else:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED


# Save-screenshot button (DebugPanel): capture the current viewport to a numbered PNG in the project
# folder and report the absolute path so it's easy to find.
func _on_debug_screenshot() -> void:
	_user_shot_counter += 1
	var path: String = ProjectSettings.globalize_path("res://volcano_shot_%d.png" % _user_shot_counter)
	if _world != null and _world.has_method("capture_screenshot"):
		_world.capture_screenshot(path)
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Saved screenshot → %s" % path)

	# Anti-aliasing: the low-poly terrain/actors have hard silhouettes that crawl and alias badly. MSAA 4x
	# cleans the geometry edges (matches the boot-time setting in setup(), so a shot never downgrades AA).
	# The scene is CPU-bound so this GPU-side smoothing is effectively free here.
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_4X
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
