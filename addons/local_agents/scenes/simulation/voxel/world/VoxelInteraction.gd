class_name LAVoxelInteraction
extends Node3D

# Input + selection + the player's "hand" (Black & White) for the voxel world, factored out of the root.
# Owns: LMB click-to-select / hold-to-carry / release-to-drop-or-throw, Tab/Shift+Tab selection cycling,
# palette hotkeys, and the selection highlight ring. RMB painting is delegated to the spawn brush; the
# V/T/M view toggles are delegated back to the world. This node defines _unhandled_input so Godot routes
# input straight here. Dependency-free of the LAVoxelWorld type (dynamic access, no cyclic class
# reference). (Explicit types only — project rule: no ':=' inferred typing.)

const GRAB_MOVE_THRESHOLD: float = 6.0       # px of motion that turns a click into a carry
const GRAB_HOLD_MSEC: int = 220              # or this long held still commits to a carry
const HOLD_LIFT: float = 3.0                 # height above the ground the hand carries at
const THROW_MIN_SPEED: float = 4.0           # below this a release is a gentle drop, not a throw
const THROW_MAX_SPEED: float = 40.0          # clamp on horizontal throw speed
const THROW_ARC: float = 0.4                 # upward velocity as a fraction of throw speed

signal selection_changed(node: Node)         # the selected entity changed (or null on deselect)

var _world = null            # LAVoxelWorld (dynamic; method calls only)
var _terrain = null
var _camera: Camera3D = null
var _ecology: Node = null
var _hud: CanvasLayer = null
var _game_hud: CanvasLayer = null   # LAGameHud — the objective/summary overlay (H toggles it alongside the palette)
var _audio = null
var _brush = null            # LAVoxelSpawnBrush

var _selection_ring: MeshInstance3D = null
var _selected: Node = null

# --- the player's hand (LMB): click a creature to select, hold to pick it up, release to
# drop or throw it. ---
var _grab_candidate: Node = null             # creature under the cursor at LMB-press
var _held_creature: Node = null              # creature currently carried
var _grabbing: bool = false                  # committed to a carry (moved / held past threshold)
var _grab_press_pos: Vector2 = Vector2.ZERO
var _grab_press_msec: int = 0
var _hold_point: Vector3 = Vector3.ZERO      # world point the hand holds at
var _hold_velocity: Vector3 = Vector3.ZERO   # smoothed hand velocity → throw impulse


func setup(world, terrain, camera: Camera3D, ecology: Node, hud: CanvasLayer, audio, brush) -> void:
	_world = world
	_terrain = terrain
	_camera = camera
	_ecology = ecology
	_hud = hud
	_audio = audio
	_brush = brush
	_selection_ring = _make_selection_ring()
	_selection_ring.visible = false
	add_child(_selection_ring)


## Wire the gamified objective/summary overlay so the H key can show/hide it (the composition root passes
## the instance it created — this node holds no cyclic type reference).
func set_game_hud(game_hud: CanvasLayer) -> void:
	_game_hud = game_hud


func selected() -> Node:
	return _selected


func selection_ring_visible() -> bool:
	return _selection_ring != null and _selection_ring.visible


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_world.toggle_scent_view()
		return
	# Debug view: T paints the terrain by temperature (heatmap). More field views (wind, pressure)
	# hang off the same toggle set as those systems come online.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_world.toggle_temp_view()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		if _hud != null and _hud.has_method("toggle_audio_menu"):
			_hud.toggle_audio_menu()
		return
	# C: hide/show the streamer entirely. Hiding gates its local-LLM commentary + TTS compute off (and the
	# choice persists). Forwarded through the world so this node stays free of the streamer host reference.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		if _world != null and _world.has_method("toggle_streamer"):
			_world.toggle_streamer()
		return
	# H: show/hide the whole HUD — the spawn palette (+ inspector + status) AND the gamified objective/
	# summary overlay, so one key clears the screen for an unobstructed look at the world.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_H:
		if _hud != null and _hud.has_method("toggle_visible"):
			_hud.toggle_visible()
		if _game_hud != null and _game_hud.has_method("toggle_visible"):
			_game_hud.toggle_visible()
		return
	# [ / ]: shrink / grow the spawn brush from the keyboard (same action as Ctrl + wheel).
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_BRACKETRIGHT):
		_brush.adjust_radius(event.keycode == KEY_BRACKETRIGHT)
		return
	# Palette / selection hotkeys: Esc -> Select, digit keys arm a palette entry (Shift for the disasters
	# cluster), Tab / Shift+Tab cycle the selection through on-screen entities. The key->kind mapping and
	# the progression lock both live in the shared hotkey registry / HUD, so nothing is duplicated here.
	if event is InputEventKey and event.pressed and not event.echo:
		var key_ev: InputEventKey = event as InputEventKey
		if key_ev.keycode == KEY_ESCAPE:
			if _hud != null and _hud.has_method("arm_kind"):
				_hud.arm_kind("")
			return
		if key_ev.keycode == KEY_TAB:
			_cycle_selection(-1 if key_ev.shift_pressed else 1)
			return
		var kind: String = LAHotkeyRegistry.spawn_kind_for_key(key_ev.keycode, key_ev.shift_pressed)
		if kind != "":
			_arm_hotkey(kind)
			return
	# While painting, drag the brush across the terrain to keep applying the armed kind.
	if event is InputEventMouseMotion and _brush.is_painting() and _brush.armed_kind() != "":
		_brush.paint_drag((event as InputEventMouseMotion).position)
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		var mpos: Vector2 = mb.position
		# Ctrl + wheel resizes the spawn brush instead of zooming (the camera rig skips zoom whenever
		# Ctrl is held, and we consume the event so it can never also zoom). Plain wheel still zooms.
		if mb.pressed and mb.ctrl_pressed \
				and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_brush.adjust_radius(mb.button_index == MOUSE_BUTTON_WHEEL_UP)
			get_viewport().set_input_as_handled()
			return
		# RMB: paint / cast the armed kind onto the terrain (Black & White right-hand miracle).
		# Press starts a paint stroke (drag keeps painting); release ends it.
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(mpos):
					return
				if _brush.armed_kind() != "":
					_brush.start_paint(mpos)
			else:
				_brush.stop_paint()
			return
		# LMB: double-click frames the entity; single press begins a click-or-grab; release
		# resolves it (select vs drop/throw).
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					_frame_focus_at(mpos)
					return
				_on_lmb_press(mpos)
			else:
				_on_lmb_release(mpos)


func on_spawn_selected(kind: String) -> void:
	_brush.set_armed_kind(kind)
	if kind == "":
		_hud.set_status("Select mode — left-click a creature to inspect, hold to pick it up.")
	else:
		_hud.set_status("Cast %s — right-click the ground to place." % kind)


# Digit-select: arm `kind` through the HUD so the palette button, the armed state, and the progression
# lock all stay in sync (arm_kind refuses a not-yet-unlocked entry). The key->kind mapping is resolved by
# the shared hotkey registry, so this stays a thin router.
func _arm_hotkey(kind: String) -> void:
	if _hud == null or not _hud.has_method("arm_kind"):
		return
	_hud.arm_kind(kind)


# Tab / Shift+Tab: walk the selection through on-screen selectables (nearest camera-first) and
# focus the camera on each, so a busy world can be inspected without hunting for click targets.
func _cycle_selection(dir: int) -> void:
	var nodes: Array = []
	for n in get_tree().get_nodes_in_group("selectable"):
		if n is Node3D and is_instance_valid(n) and (n as Node).has_method("get_inspector_payload"):
			nodes.append(n)
	if nodes.is_empty():
		_set_selected(null)
		return
	var origin: Vector3 = _camera.global_position
	nodes.sort_custom(func(a, b):
		return origin.distance_squared_to((a as Node3D).global_position) \
			< origin.distance_squared_to((b as Node3D).global_position))
	var idx: int = nodes.find(_selected)
	if idx < 0:
		idx = 0 if dir >= 0 else nodes.size() - 1
	else:
		idx = (idx + dir) % nodes.size()
		if idx < 0:
			idx += nodes.size()
	var target: Node = nodes[idx]
	_set_selected(target)
	if _camera.has_method("focus_on"):
		_camera.focus_on((target as Node3D).global_position)


# Double-click: select the entity under the cursor (if any) and frame the camera on it.
func _frame_focus_at(screen_pos: Vector2) -> void:
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(screen_pos):
		return
	select_at(screen_pos)
	if _selected is Node3D and _camera.has_method("focus_on"):
		_camera.focus_on((_selected as Node3D).global_position)


# --- the player's hand -------------------------------------------------------
# LMB press: remember what's under the cursor. A quick click selects; holding/dragging
# commits to a carry (see update_hand).
func _on_lmb_press(pos: Vector2) -> void:
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(pos):
		return
	_grab_candidate = _creature_at(pos)
	_grab_press_pos = pos
	_grab_press_msec = Time.get_ticks_msec()
	_grabbing = false


# LMB release: a carry drops or throws (by hand speed); a plain click selects.
func _on_lmb_release(pos: Vector2) -> void:
	if _grabbing and _held_creature != null and is_instance_valid(_held_creature):
		var flat: Vector3 = Vector3(_hold_velocity.x, 0.0, _hold_velocity.z)
		var fspeed: float = flat.length()
		if fspeed > THROW_MIN_SPEED:
			fspeed = minf(fspeed, THROW_MAX_SPEED)
			var throw_vel: Vector3 = flat.normalized() * fspeed
			throw_vel.y = fspeed * THROW_ARC       # arc upward with throw strength
			_held_creature.call("throw", throw_vel)
			_hud.set_status("Threw the %s!" % _creature_species(_held_creature))
		else:
			_held_creature.call("hold_end")        # gentle set-down
			_hud.set_status("Set the %s down." % _creature_species(_held_creature))
	elif _grab_candidate != null and is_instance_valid(_grab_candidate):
		_set_selected(_grab_candidate)             # a click — just inspect it
	else:
		select_at(pos)                             # empty ground — select/deselect via ray
	_grab_candidate = null
	_held_creature = null
	_grabbing = false


# Called every frame from the world's _process: commit a pending press to a carry, then keep the held
# creature under the cursor and estimate hand velocity for throwing.
func update_hand(delta: float) -> void:
	if _grab_candidate == null and _held_creature == null:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var mpos: Vector2 = vp.get_mouse_position()

	if not _grabbing and _grab_candidate != null:
		if not is_instance_valid(_grab_candidate):
			_grab_candidate = null
			return
		var moved: float = mpos.distance_to(_grab_press_pos)
		var held_ms: int = Time.get_ticks_msec() - _grab_press_msec
		if moved >= GRAB_MOVE_THRESHOLD or held_ms >= GRAB_HOLD_MSEC:
			_begin_carry(_grab_candidate)

	if _grabbing and _held_creature != null:
		if not is_instance_valid(_held_creature):
			_held_creature = null
			_grabbing = false
			return
		var target: Vector3 = _hand_world_point(mpos)
		if is_finite(target.x):
			if delta > 0.0001:
				var inst_vel: Vector3 = (target - _hold_point) / delta
				_hold_velocity = _hold_velocity.lerp(inst_vel, 0.5)
			_hold_point = target
			(_held_creature as Node3D).global_position = target


func _begin_carry(creature: Node) -> void:
	_grabbing = true
	_held_creature = creature
	creature.call("hold_begin")
	_hold_point = (creature as Node3D).global_position
	_hold_velocity = Vector3.ZERO
	_set_selected(creature)
	if _audio != null:
		_audio.play_sfx("ui_click")


# World point the hand carries at: the terrain surface under the cursor, lifted a little so
# the creature hovers above the ground where you point. Returns INF if the cursor misses terrain.
func _hand_world_point(screen_pos: Vector2) -> Vector3:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 2000.0)
	if not bool(hit.get("hit", false)):
		return Vector3(INF, INF, INF)
	return (hit["position"] as Vector3) + Vector3(0.0, HOLD_LIFT, 0.0)


# Physics-ray pick that resolves to a living creature (group "creature" with the hand API),
# or null if the cursor isn't over one.
func _creature_at(screen_pos: Vector2) -> Node:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["dir"] * 2000.0)
	q.collision_mask = 0xFFFFFFFF
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return null
	return _resolve_creature(r.get("collider", null))


func _resolve_creature(collider) -> Node:
	var n = collider
	while n != null and n is Node:
		if (n as Node).is_in_group("creature") and (n as Node).has_method("hold_begin"):
			return n
		n = (n as Node).get_parent()
	return null


func _creature_species(creature: Node) -> String:
	if creature != null and "species" in creature:
		return String(creature.get("species"))
	return "creature"


func select_at(screen_pos: Vector2) -> void:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["dir"] * 2000.0)
	q.collision_mask = 0xFFFFFFFF
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		_set_selected(null)
		return
	var node: Node = _resolve_selectable(r.get("collider", null))
	_set_selected(node)


func _resolve_selectable(collider) -> Node:
	var n = collider
	while n != null and n is Node:
		if (n as Node).is_in_group("selectable") and (n as Node).has_method("get_inspector_payload"):
			return n
		n = (n as Node).get_parent()
	return null


## Programmatic selection (harness / debug driver): select `node` through the same path a click would take.
func select_node(node: Node) -> void:
	_set_selected(node)


## Select-by-predicate: over every creature, gather those matching `predicate` (Callable(Node) -> bool),
## select the NEAREST match through the normal single-selection path (ring + inspector + thought panel
## light up on it), focus the camera on it, and return the total match count. The whole matching SET is
## what a companion highlight (e.g. the LLM thinking/queued tint) is already dyeing; this hands the player
## a concrete entry point into it. Returns 0 (and clears nothing) when nothing matches.
func select_by_predicate(predicate: Callable) -> int:
	var found: Array = []
	for n in get_tree().get_nodes_in_group("creature"):
		if n is Node3D and is_instance_valid(n) and bool(predicate.call(n)):
			found.append(n)
	if found.is_empty():
		return 0
	var origin: Vector3 = _camera.global_position if _camera != null else Vector3.ZERO
	found.sort_custom(func(a, b):
		return origin.distance_squared_to((a as Node3D).global_position) \
			< origin.distance_squared_to((b as Node3D).global_position))
	var target: Node = found[0]
	_set_selected(target)
	if _camera != null and _camera.has_method("focus_on"):
		_camera.focus_on((target as Node3D).global_position)
	return found.size()


func _set_selected(node: Node) -> void:
	_selected = node
	selection_changed.emit(node)
	if node == null:
		_hud.clear_inspector()
		_selection_ring.visible = false
		return
	_hud.show_inspector(node.call("get_inspector_payload"))
	_selection_ring.visible = true
	if _audio != null:
		_audio.play_sfx("ui_click")


func update_selection_ring() -> void:
	if _selected == null or not is_instance_valid(_selected):
		_selection_ring.visible = false
		_selected = null
		return
	if _selected is Node3D:
		var p: Vector3 = (_selected as Node3D).global_position
		# Lay the flat torus in the tangent plane at the selected point: its Y (flat-plane normal) tracks
		# the local radial normal, so on a sphere the ring hugs the surface instead of the world XZ plane.
		var up: Vector3 = _terrain.up_at(p) if _terrain != null and _terrain.has_method("up_at") else Vector3.UP
		_selection_ring.global_transform = Transform3D(_ring_basis_from_up(up), p + up * 0.1)
		if _selected.has_method("get_inspector_payload"):
			_hud.show_inspector(_selected.call("get_inspector_payload"))


func _make_selection_ring() -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.2
	mi.mesh = torus
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.92, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.1)
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	return mi


# An orthonormal basis whose Y axis is the given surface normal, so a flat (XZ-plane) mesh laid on it
# sits in the tangent plane at that point. The in-plane X/Z axes are an arbitrary but stable tangent
# pair (the ring is rotationally symmetric, so their heading doesn't matter).
func _ring_basis_from_up(up: Vector3) -> Basis:
	var n: Vector3 = up.normalized() if up.length() > 0.0001 else Vector3.UP
	var ref: Vector3 = Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
	var t: Vector3 = ref.cross(n).normalized()
	var b: Vector3 = n.cross(t)
	return Basis(t, n, b)
