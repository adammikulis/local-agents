class_name LARenderLayer
extends Node3D


var _world: Node = null
var _sim: LASimulation = null
var _input: LAVoxelInputController = null
var _render_opts: Dictionary = {}
var _draw_m: float = 0.0                   # the streamed distance last asked for, metres
## The vector field the world this layer draws declares. UNSET defers to the shell's --vectors flag.
var declared_vectors: String = LAFieldVectors.SOURCE_UNSET

# The node TREE is declared in RenderLayer.tscn; this script only wires it.
@onready var _camera: Camera3D = $CameraRig
@onready var _sky_ctrl: LAVoxelSkyController = $SkyController
@onready var _veg_renderer: Node3D = $VegetationRenderer
@onready var _ocean: Node = $OceanPlane
@onready var _water: Node = $WaterParticles
@onready var _water_surface: Node = $WaterSurface
@onready var _vectors: LAFieldVectors = $FieldVectors
@onready var _heat_tex: LAHeatFieldTexture = $HeatFieldTexture


func build(world: Node, sim: LASimulation, input: LAVoxelInputController) -> void:
	_world = world
	_sim = sim
	_input = input
	_render_opts = sim.settings_applier().render_opts()
	_build_camera()
	_build_sky()
	_build_world_visuals()


func _build_camera() -> void:
	var body: Node3D = _sim.body()
	_camera.current = true
	# THE POSE COMES FIRST: a viewer attached at the origin streams the body's core, not its surface.
	if _camera.has_method("set_geosync_body"):
		_camera.set_geosync_body(body)
	var box: AABB = _slice_box()
	if box.size.length() > 0.0 and _camera.has_method("frame_slice"):
		_camera.call("frame_slice", body.center(), body.radius(), box)
	elif _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(body.center(), body.radius())
	body.attach_viewer(_camera, true)


## The configured slice box in world space, or a zero AABB when the field covers the whole body.
func _slice_box() -> AABB:
	var field: Node = _sim.material_field()
	var slice = field._slice if "_slice" in field else null
	if slice == null:
		return AABB()
	var body: Node3D = _sim.body()
	return slice.world_aabb(body.center(), body.radius())


func _build_sky() -> void:
	_sky_ctrl.setup(_world, _sim.star(), _sim.moon(), _render_opts)
	# The sky's altitude and its zenith follow THIS camera, never a viewport lookup: a photographed run
	# draws through an off-screen SubViewport, whose parent window holds no camera at all.
	_sky_ctrl.bind_camera(_camera, _sim.body().center(), _sim.body().sea_radius())
	_sky_ctrl.enter_space_mode(_sim.body().center())
	# The orbit re-aims the sun as the bodies move. The orbit runs without one; this only gives it a sink.
	if _sim.orbits() != null and _sim.orbits().has_method("set_sky_controller"):
		_sim.orbits().set_sky_controller(_sky_ctrl)
	# A SLICE has already been framed: the box says where this world is looked at, and nothing re-aims it.
	if _slice_box().size.length() > 0.0:
		return
	if _camera != null and _camera.has_method("face_sun_on_start"):
		_camera.face_sun_on_start(_sky_ctrl.sun())
	# OPEN OVER DAYLIT LAND. The sea shell sits at the mean radius, so most of the sphere is open ocean
	# and a view that opens on an arbitrary bearing opens on water.
	var terrain = _sim.terrain()
	if terrain != null and terrain.has_method("land_direction") and _camera.has_method("orient_toward"):
		var sun: Node3D = _sky_ctrl.sun()
		var sunward: Vector3 = sun.global_transform.basis.z if sun != null else Vector3.ZERO
		_camera.orient_toward(terrain.land_direction(sunward))


func _build_world_visuals() -> void:
	var body: Node3D = _sim.body()
	var material: Node = _sim.material_field()
	var terrain = _sim.terrain()

	_veg_renderer.reparent(_sim.actors_root())
	if _sim.ecology().has_method("set_vegetation_renderer"):
		_sim.ecology().set_vegetation_renderer(_veg_renderer)

	# The sea: the shell at sea_radius, meshed as the cap the eye can see.
	_ocean.setup(_camera, body.center(), body.sea_radius(), bool(_render_opts.get("ocean_transparent", true)))

	# The field's condensate as ONE GPU particle system; phase is per-particle, off the cover texture.
	_water.setup(material, _camera, _sky_ctrl.sun(), body.center(), body.sea_radius())

	# One arrow glyph per open cell, at every altitude, over the chosen vector field. The scene's own
	# declaration outranks the shell's flag; only an undeclared scene defers to it.
	_vectors.setup(material, _camera, body.center(), body.sea_radius())
	_vectors.set_source(_input.vectors() if declared_vectors == LAFieldVectors.SOURCE_UNSET
		else declared_vectors)

	# The dynamic FLUID SURFACE: springs/rivers/waterfalls/lakes/floods meshed from the field's water column.
	_water_surface.setup(material, _camera, terrain, _sky_ctrl.sun(), body.center(), body.sea_radius())

	_sky_ctrl.bind_scene(material, _water)

	# The ground's reflectance, from the one place this world declares it.
	terrain.set_shader_param("albedo_bare_ground", LAPhysical.ALBEDO_BARE_GROUND)
	terrain.set_shader_param("albedo_snow_ice", LAPhysical.ALBEDO_SNOW_ICE)
	# Hot ground glows — the live per-cell temperature as a 3D texture over the field box.
	_heat_tex.setup(material, terrain)

	# Effects density onto the atmosphere particles.
	_sim.settings_applier().bind(_world, terrain, _water)
	# The screen-ray casts the impact controller accepts but never requires.
	if _sim.meteor_impacts() != null:
		_sim.meteor_impacts().set_presentation(_camera)
	if _sim.spawn_controller() != null and _sim.spawn_controller().has_method("set_presentation"):
		_sim.spawn_controller().set_presentation(_camera, null)


func step(delta: float) -> void:
	if _sky_ctrl != null:
		_sky_ctrl.update(delta)
	_stream_to_the_horizon()


## THE GROUND IS STREAMED AS FAR AS THE EYE CAN SEE. The camera's far plane is the horizon from its own
## altitude; a draw distance held under it leaves the eye standing over ground nothing ever built. The
## quality setting is the floor, not the ceiling. Visuals only — the field samples the generator's SDF.
func _stream_to_the_horizon() -> void:
	var terrain = _sim.terrain()
	if terrain == null or _camera == null or not terrain.has_method("set_view_distance"):
		return
	var want: float = maxf(_camera.far, _sim.settings_applier().draw_distance())
	if absf(want - _draw_m) <= 0.05 * maxf(_draw_m, 1.0):
		return
	_draw_m = want
	terrain.set_view_distance(want)


func camera() -> Camera3D: return _camera
func field_vectors() -> LAFieldVectors: return _vectors
func sky_controller() -> LAVoxelSkyController: return _sky_ctrl
func water_particles() -> Node: return _water
func ocean() -> Node: return _ocean
func water_surface() -> Node: return _water_surface
