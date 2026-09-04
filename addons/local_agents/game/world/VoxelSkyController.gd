class_name LAVoxelSkyController
extends Node


const SkyCycleScript: GDScript = preload("res://addons/local_agents/game/world/VoxelSkyCycle.gd")

var _star: Node3D = null    # LAStar, owned by the simulation — read, never created here
var _sky: Node = null       # LAVoxelSkyCycle — the scattering atmosphere and the sun that lights it


## Build the sky cycle as a child of `world`, lit by the simulation's `star` and `moon`.
func setup(world: Node, star: Node3D, moon: Node3D, render_opts: Dictionary = {}) -> void:
	_star = star
	_sky = SkyCycleScript.new()
	_sky.name = "SkyCycle"
	world.add_child(_sky)
	_sky.setup(world, render_opts)
	_sky.bind_bodies(star, moon)
	# The sky cycle draws the lighting; the star's own light stays hidden so they do not double up. Hiding it
	# does not affect the field — a hidden DirectionalLight3D still carries its transform and metadata.
	if _star != null and _star.has_method("light") and _star.light() != null:
		_star.light().visible = false


## THE ORBIT MOVED: re-derive the direction the sunlight travels, star -> body. The simulation's orbit
## integrator calls this every step; it is the only thing that aims the sun.
func enter_space_mode(body_center: Vector3) -> void:
	if _sky != null and _star != null:
		_sky.set_sun_shine((body_center - _star.global_position).normalized())


## The sky cycle reads the field each frame (cloud-cover dimming) + pushes the day/night colour tint to
## the water-particle renderer.
func bind_scene(material, water) -> void:
	if _sky != null and _sky.has_method("bind_scene"):
		_sky.bind_scene(material, water)


## The camera the frame is drawn through and the body it stands on: the sky's own altitude and its local
## vertical.
func bind_camera(camera: Node3D, planet_centre: Vector3, sea_radius: float) -> void:
	if _sky != null and _sky.has_method("bind_camera"):
		_sky.bind_camera(camera, planet_centre, sea_radius)


func update(delta: float) -> void:
	if _sky != null:
		_sky.update(delta)


func sky() -> Node:
	return _sky

func star() -> Node3D:
	return _star

## The VISUAL sun (the sky cycle's light). Not the field's solar input.
func sun():
	return _sky.sun() if _sky != null else null

func env():
	return _sky.env() if _sky != null else null

func time_of_day() -> float:
	return _sky.time_of_day() if _sky != null else 0.0

func set_shadows(on: bool) -> void:
	if _sky != null:
		_sky.set_shadows(on)

func set_ssao(on: bool) -> void:
	if _sky != null:
		_sky.set_ssao(on)
