class_name LATrackSystem
extends Node3D

# LATrackSystem — DECOUPLED OBSERVER footprint/track system.
#
# This node watches creatures from the outside and drops fading Decal
# footprints onto the terrain. It never modifies creature scripts: it only
# reads the `can_fly` property and the global transform of nodes in the
# "creature" group. All visuals are generated in code (no external assets).
#
# Usage:
#   var tracks := LATrackSystem.new()
#   add_child(tracks)
#   tracks.setup(terrain_service)   # terrain exposes surface_height(x, z) -> float
#
# Contract of the injected terrain service:
#   surface_height(x: float, z: float) -> float
#     Returns the world-space Y of the ground at (x, z), or NAN when unknown.

# --- Tunables ---------------------------------------------------------------

## World-space distance a creature must travel before a new footprint drops.
const STEP_DISTANCE: float = 1.2
## Seconds a footprint takes to fully fade before it is freed.
const FADE_SECONDS: float = 5.0
## Footprint decal box size. Y is the projection depth (SHALLOW so prints don't
## smear into long streaks on sloped voxel terrain); X/Z is the ground footprint.
const DECAL_SIZE: Vector3 = Vector3(0.4, 0.5, 0.4)
## Small vertical offset so the decal box straddles the surface cleanly.
const SURFACE_OFFSET: float = 0.25
## Hard cap on live decals. When exceeded, the oldest is freed immediately so
## tracks never accumulate unbounded (memory/perf guard for long sessions).
const MAX_DECALS: int = 300
## Pixel dimension of the generated footprint texture (square).
const TEX_SIZE: int = 32

# --- State ------------------------------------------------------------------

var _terrain = null
var _footprint_texture: ImageTexture = null

# instance_id -> last footprint drop position (Vector3, world space).
var _last_print_pos: Dictionary = {}

# Ordered list (oldest first) of live footprint records. Each record is a
# Dictionary: { "decal": Decal, "age": float }.
var _decals: Array = []


func setup(terrain) -> void:
	# Store the injected terrain service and build the one shared texture that
	# every decal reuses (no per-decal allocation of image data).
	_terrain = terrain
	if _footprint_texture == null:
		_footprint_texture = _build_footprint_texture()


func _build_footprint_texture() -> ImageTexture:
	# Generate a soft dark oval/paw shape with alpha. Most pixels are fully
	# transparent; only an elongated oval near the center carries opacity.
	var img: Image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var cx: float = float(TEX_SIZE) * 0.5
	var cy: float = float(TEX_SIZE) * 0.5
	# Radii of the oval (footprint is longer along Y than X).
	var rx: float = float(TEX_SIZE) * 0.28
	var ry: float = float(TEX_SIZE) * 0.42

	for y in range(TEX_SIZE):
		for x in range(TEX_SIZE):
			# Normalized distance from center in oval space (1.0 == edge).
			var dx: float = (float(x) - cx) / rx
			var dy: float = (float(y) - cy) / ry
			var d: float = sqrt(dx * dx + dy * dy)
			if d >= 1.0:
				continue
			# Soft falloff: opaque core, fading toward the oval edge.
			var alpha = clamp(1.0 - d, 0.0, 1.0)
			alpha = alpha * alpha  # ease-in for a softer edge
			alpha *= 0.8  # a footprint is a smudge, not pure black
			# Dark, slightly warm scuff color.
			img.set_pixel(x, y, Color(0.05, 0.04, 0.03, alpha))

	return ImageTexture.create_from_image(img)


func _physics_process(delta: float) -> void:
	_update_creatures()
	_update_decals(delta)


func _update_creatures() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var creatures: Array = tree.get_nodes_in_group("creature")

	# Track which ids are still alive this frame so we can prune stale entries.
	var seen: Dictionary = {}

	for node in creatures:
		if not is_instance_valid(node):
			continue
		if not (node is Node3D):
			continue
		# Skip fliers. Missing property is treated as ground-dweller only if it
		# is explicitly false; unknown/other values are skipped to be safe.
		var can_fly = node.get("can_fly")
		if can_fly == null or bool(can_fly):
			continue

		var id: int = node.get_instance_id()
		seen[id] = true

		var pos: Vector3 = (node as Node3D).global_transform.origin

		if not _last_print_pos.has(id):
			# First sighting: seed position, no print yet (avoids a print at
			# spawn before the creature has actually moved).
			_last_print_pos[id] = pos
			continue

		var last: Vector3 = _last_print_pos[id]
		# Compare planar (XZ) travel; vertical bob shouldn't trigger prints.
		var dx: float = pos.x - last.x
		var dz: float = pos.z - last.z
		if (dx * dx + dz * dz) < (STEP_DISTANCE * STEP_DISTANCE):
			continue

		if _drop_footprint(pos):
			_last_print_pos[id] = pos

	# Prune per-creature entries for creatures that vanished this frame.
	if _last_print_pos.size() != seen.size():
		for id in _last_print_pos.keys():
			if not seen.has(id):
				_last_print_pos.erase(id)


func _drop_footprint(creature_pos: Vector3) -> bool:
	# Returns true if a footprint was actually placed.
	if _terrain == null or _footprint_texture == null:
		return false

	var ground_y: float = creature_pos.y
	if _terrain.has_method("surface_height"):
		var h = _terrain.surface_height(creature_pos.x, creature_pos.z)
		# Guard NAN / non-finite surface heights: skip this print rather than
		# placing a decal at an invalid Y.
		if typeof(h) != TYPE_FLOAT and typeof(h) != TYPE_INT:
			return false
		var hf: float = float(h)
		if is_nan(hf) or is_inf(hf):
			return false
		ground_y = hf

	var decal: Decal = Decal.new()
	decal.texture_albedo = _footprint_texture
	decal.size = DECAL_SIZE
	# Decals project along their local -Y (downward), so sitting the box a
	# little above the surface lets it project cleanly onto the ground.
	decal.position = Vector3(creature_pos.x, ground_y + SURFACE_OFFSET, creature_pos.z)
	decal.rotation.y = randf() * TAU  # small/arbitrary yaw for variety
	decal.albedo_mix = 0.5            # subtle, not a hard grey stamp
	decal.modulate = Color(1.0, 1.0, 1.0, 0.5)
	add_child(decal)

	_decals.append({"decal": decal, "age": 0.0})

	# Enforce the live-decal cap: free oldest first so tracks stay bounded.
	while _decals.size() > MAX_DECALS:
		var oldest = _decals.pop_front()
		var od = oldest.get("decal")
		if is_instance_valid(od):
			od.queue_free()

	return true


func _update_decals(delta: float) -> void:
	if _decals.is_empty():
		return
	# Iterate a snapshot of indices; rebuild the survivors list in place so we
	# avoid per-frame allocations except when decals expire.
	var survivors: Array = []
	for record in _decals:
		var decal = record.get("decal")
		if not is_instance_valid(decal):
			continue
		var age: float = record["age"] + delta
		if age >= FADE_SECONDS:
			decal.queue_free()
			continue
		record["age"] = age
		# Fade both the projection strength and the alpha so the print softens
		# out over FADE_SECONDS.
		var t: float = 1.0 - (age / FADE_SECONDS)
		decal.albedo_mix = t
		var m: Color = decal.modulate
		m.a = t
		decal.modulate = m
		survivors.append(record)
	_decals = survivors
