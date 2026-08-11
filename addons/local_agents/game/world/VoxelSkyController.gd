class_name LAVoxelSkyController
extends Node

## PRESENTATION ONLY: the sky cycle (LAVoxelSkyCycle — sky shader, WorldEnvironment, visible sun/moon,
## day/night tint) and the glowing sun disc. It does NOT own the star and does NOT own the sun the physics
## reads: LAStar is a simulation node, its light carries the direction and the `insolation` meta, and
## MaterialField3D reads THAT. This node only draws.
##
## It used to build the star itself and hand `_sky.sun()` — a light owned by the sky cycle — to the field, so
## skipping presentation left the planet with no solar input at all.

const SkyCycleScript: GDScript = preload("res://addons/local_agents/game/world/VoxelSkyCycle.gd")

# Visible-sun body: a bright unshaded emissive sphere sitting AT the star so the sun is visible (the
# DirectionalLight alone is invisible). Emission sits above the environment's glow HDR threshold, so the
# WorldEnvironment bloom wraps it in a corona. Radius reads ~5-6° across from planet-orbit distance.
const SUN_BODY_RADIUS: float = 60.0
const SUN_EMISSION_ENERGY: float = 6.0
const SUN_CORE_COLOR: Color = Color(1.0, 0.94, 0.72)

var _star: Node3D = null    # LAStar, owned by the simulation — read, never created here
var _sun_body: MeshInstance3D = null  # the glowing disc, parented to the star
var _sky: Node = null       # LAVoxelSkyCycle — sky/sun/moon/environment + day/night clock


## Build the sky cycle as a child of `world` and hang the sun disc on the simulation's `star`.
func setup(world: Node, star: Node3D, time_of_day: float, lunar_phase: float, render_opts: Dictionary = {}) -> void:
	_star = star
	_sky = SkyCycleScript.new()
	_sky.name = "SkyCycle"
	world.add_child(_sky)
	_sky.setup(world, time_of_day, lunar_phase, render_opts)
	# The sky cycle draws the lighting; the star's own light stays hidden so they do not double up. Hiding it
	# does not affect the field — a hidden DirectionalLight3D still carries its transform and metadata.
	if _star != null and _star.has_method("light") and _star.light() != null:
		_star.light().visible = false
	if _star != null:
		_build_sun_body(_star)


## Attach the glowing sun disc as a child of the star node so it always sits at the star's world position.
func _build_sun_body(star: Node3D) -> void:
	_sun_body = MeshInstance3D.new()
	_sun_body.name = "SunBody"
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = SUN_BODY_RADIUS
	sphere.height = SUN_BODY_RADIUS * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	_sun_body.mesh = sphere
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = SUN_CORE_COLOR
	mat.emission_enabled = true
	mat.emission = SUN_CORE_COLOR
	mat.emission_energy_multiplier = SUN_EMISSION_ENERGY
	mat.disable_receive_shadows = true
	_sun_body.material_override = mat
	_sun_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Never fade/cull the sun — it stays lit at whatever orbit distance the camera pulls to.
	_sun_body.extra_cull_margin = 16384.0
	star.add_child(_sun_body)


## PLANETARY SKY: view from space (dark starfield + low ambient) with the sun FIXED shining star->planet;
## the spinning planet turns under it → a stark star-lit day/night terminator sweeps the surface.
func enter_space_mode(body_center: Vector3) -> void:
	if _sky != null and _sky.has_method("set_space_mode") and _star != null:
		_sky.set_space_mode((body_center - _star.global_position).normalized())


## The sky cycle reads the field each frame (cloud-cover dimming) + pushes the day/night colour tint to
## the water-particle renderer.
func bind_scene(weather, material, water) -> void:
	if _sky != null and _sky.has_method("bind_scene"):
		_sky.bind_scene(weather, material, water)


func update(delta: float) -> void:
	if _sky != null:
		_sky.update(delta)


func sky() -> Node:
	return _sky

func star() -> Node3D:
	return _star

## The VISUAL sun (the sky cycle's light). Not the field's solar input — see the class doc.
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
