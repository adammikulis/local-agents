class_name LAVoxelSkyController
extends Node

## LAVoxelSkyController — owns the STAR (positioned light + gravity + solar driver) and the sky-cycle
## (LAVoxelSkyCycle: sky shader, WorldEnvironment, sun/moon, day/night clock) plus the space-mode wiring.
## Factored out of LAVoxelWorld so the "visible sun / sky" concern is one file. The world composition root
## instantiates it, then reads sun()/env()/star() to wire the rest of the scene. (Explicit types only.)

const SkyCycleScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSkyCycle.gd")
const StarScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/Star.gd")

const STAR_POSITION: Vector3 = Vector3(900.0, 320.0, 620.0)

# Visible-sun body: a bright unshaded emissive sphere sitting AT the star so you actually SEE the sun in the
# sky (the DirectionalLight alone is invisible). Its emission energy sits above the environment's glow HDR
# threshold, so the WorldEnvironment bloom wraps it in a natural corona. Radius is chosen so the disc reads
# from planet-orbit distance (~5-6° across); no texture needed — the glow does the halo.
const SUN_BODY_RADIUS: float = 60.0
const SUN_EMISSION_ENERGY: float = 6.0
const SUN_CORE_COLOR: Color = Color(1.0, 0.94, 0.72)

var _star: Node3D = null    # LAStar — positioned light + gravity + solar driver
var _sun_body: MeshInstance3D = null  # the glowing disc you see in the sky, parented to the star
var _sky: Node = null       # LAVoxelSkyCycle — owns ALL sky/sun/moon/environment + day/night clock


## Build the sky cycle + the star as children of `world` (so the star's light/gravity live in world space,
## exactly as the inline composition did). The cmdline-seeded clocks are threaded into the sky here.
func setup(world: Node, time_of_day: float, lunar_phase: float, render_opts: Dictionary = {}) -> void:
	# --- Sun + sky + day/night: owned by LAVoxelSkyCycle. It builds the sky shader material, the
	# WorldEnvironment (tonemap/SSAO/glow/fog/ambient), the sun (PSSM cascade-blend shadows) and the moon.
	# render_opts (quality preset) gates the heavy fill-rate effects — see LAVoxelSettingsApplier.render_opts.
	_sky = SkyCycleScript.new()
	_sky.name = "SkyCycle"
	world.add_child(_sky)
	_sky.setup(world, time_of_day, lunar_phase, render_opts)
	# --- The star (positioned light + gravity + solar driver) ---
	_star = StarScript.new()
	_star.name = "Star"
	world.add_child(_star)
	_star.setup({"position": STAR_POSITION, "energy": 1.4})
	# The sky cycle owns the visual sun for now; the star supplies position/gravity/solar math. Hide its own
	# light so they don't double up (wiring the sky's sun to follow the star = the sky/solar fan-out unit).
	if _star.light() != null:
		_star.light().visible = false
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
	# Never fade/cull the sun — it should stay lit at whatever orbit distance the camera pulls to.
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
