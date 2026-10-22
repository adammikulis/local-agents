class_name LAMeteorImpacts
extends Node

## The one cause that is genuinely outside the system: a rock arriving from space. It carries mass and
## momentum in at the boundary. Nothing here makes weather or geology happen, and nothing here consults
## the camera: where a rock comes down is not a function of who is watching.

const MeteorScene: PackedScene = preload("res://addons/local_agents/sim/actors/Meteor.tscn")

# Named once per run, by whichever path asked first.
static var _refused: bool = false
# Rocks this run let in, by every path.
static var _arrived: int = 0

var _terrain = null
var _ecology = null
var _actors_root: Node3D = null
var _camera: Camera3D = null


## Neither refused nor arrived, as a fresh process holds it.
static func forget() -> void:
	_refused = false
	_arrived = 0


## Whether a rock may arrive at all. A world without the gravity that brings it down, the conduction that
## carries its impact heat away or the transport that moves the rock it throws cannot receive one, and
## says which is absent rather than dropping it anyway.
static func offered() -> bool:
	if LAWorldOffers.has_impacts():
		return true
	if not _refused:
		_refused = true
		print("METEOR_REFUSED={rung:\"%s\", missing:%s}" % [
			LAProcessSet.name_of(LAProcessSet.active()),
			JSON.stringify(LAWorldOffers.impacts_missing())])
	return false


## THE ONE PLACE A ROCK ENTERS A WORLD, whichever path aimed it. False when the world refused it.
static func arrive(actors_root: Node3D, terrain, ecology, target: Vector3, from_pos: Vector3,
		size_scale: float) -> bool:
	if not offered():
		return false
	if actors_root == null:
		push_error("MeteorImpacts: no actors root for a rock to arrive in.")
		return false
	var m: LAMeteor = MeteorScene.instantiate() as LAMeteor
	actors_root.add_child(m)
	m.setup(terrain, ecology)
	# ONLY A ROCK THAT LAUNCHED IS A ROCK THAT ARRIVED.
	if not m.launch(target, from_pos, size_scale):
		m.queue_free()
		return false
	_arrived += 1
	return true


func _ready() -> void:
	LASimReport.register(Callable(self, "report"))


## What this world let in from outside.
func report() -> Dictionary:
	return {"meteors": _arrived}


func setup(terrain, ecology, actors_root: Node3D, camera: Camera3D) -> void:
	_terrain = terrain
	_ecology = ecology
	_actors_root = actors_root
	_camera = camera


## The camera is PRESENTATION — the trailer's cinematic shot casts along it. It stays null without --ui.
func set_presentation(camera: Camera3D) -> void:
	_camera = camera


## One arrival from outside. Its approach direction is drawn from the seeded planet stream and the impact
## point is that direction's own surface, so the run needs no camera and one seed lands one rock in one place.
func fire_ambient_meteor() -> void:
	if not offered():
		return
	var target: Vector3 = _arrival_point()
	if is_nan(target.x):
		return
	_drop(target)


## A volley: independent arrivals, each drawn from the same stream, not a spread around one aimed point.
func fire_barrage(count: int = 18) -> void:
	if not offered():
		return
	for i in count:
		var target: Vector3 = _arrival_point()
		if is_nan(target.x):
			continue
		_drop(target)


## Fling one toward `target` FROM an explicit world position. It then coasts under real N-body gravity.
func fire_meteor_at(target: Vector3, from_pos: Vector3, size_scale: float = 1.0) -> void:
	arrive(_actors_root, _terrain, _ecology, target, from_pos, size_scale)


## An arrival with no launch point: it falls in along the direction it came from, at the flux's own draw.
func _drop(target: Vector3) -> void:
	arrive(_actors_root, _terrain, _ecology, target, Vector3(INF, INF, INF), 1.0)


func _arrival_point() -> Vector3:
	var nan3: Vector3 = Vector3(NAN, NAN, NAN)
	if _terrain == null or _actors_root == null:
		push_error("MeteorImpacts: no terrain for a rock to arrive at.")
		return nan3
	if not _terrain.has_method("surface_point"):
		push_error("MeteorImpacts: the terrain service resolves no surface point.")
		return nan3
	return _terrain.surface_point(_arrival_direction())


# Isotropic: rejection-sampled inside the unit ball, so no direction on the sphere is favoured.
func _arrival_direction() -> Vector3:
	var rng: LASimRng = LASimRng.for_domain("planet")
	var v: Vector3 = rng.rand_dir()
	while v.length() > 1.0 or v.length() < 0.001:
		v = rng.rand_dir()
	return v.normalized()
