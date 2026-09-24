class_name LARenderLayer
extends Node3D


var _world: Node = null
var _sim: LASimulation = null
var _input: LAVoxelInputController = null
var _render_opts: Dictionary = {}
var _draw_m: float = 0.0                   # the streamed distance last asked for, metres
## The vector field the world this layer draws declares. UNSET defers to the shell's --vectors flag.
var declared_vectors: String = LAFieldVectors.SOURCE_UNSET

@export_group("Terrain")
## The planet's surface material.
@export var terrain_material: ShaderMaterial

# The node TREE is declared in RenderLayer.tscn; this script only wires it.
@onready var _camera: Camera3D = $CameraRig
@onready var _sky_ctrl: LAVoxelSkyController = $SkyController
@onready var _veg_renderer: Node3D = $VegetationRenderer
@onready var _water: Node = $WaterParticles
@onready var _water_surface: Node = $WaterSurface
@onready var _vectors: LAFieldVectors = $FieldVectors
@onready var _heat_tex: LAHeatFieldTexture = $HeatFieldTexture
@onready var _test_masses: LATestMassView = $TestMassView


func build(world: Node, sim: LASimulation, input: LAVoxelInputController) -> void:
	_world = world
	_sim = sim
	_input = input
	_render_opts = sim.settings_applier().render_opts()
	_build_camera()
	_build_sky()
	_build_world_visuals()


func _build_camera() -> void:
	# The controls read what they may offer off this world's field; bind it before any is built.
	LAWorldOffers.bind_field(_sim.material_field())
	var body: Node3D = _sim.body()
	_camera.current = true
	# THE POSE COMES FIRST: a viewer attached at the origin streams the body's core, not its surface.
	if _camera.has_method("set_geosync_body"):
		_camera.set_geosync_body(body)
	var box: AABB = _slice_box()
	if box.size.length() > 0.0 and _camera.has_method("frame_slice"):
		# The eye is given the box's body-frame site, so the pose rides the body's rotation.
		_camera.call("frame_slice", body.center(), body.radius(), box,
			slice_site_dir(_sim.material_field()))
	elif _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(body.center(), body.radius())
	body.attach_viewer(_camera, true)


## The slice box in the BODY's own frame, its COARSE cells across; a zero AABB when there is no slice.
static func slice_body_aabb(field: Node, body: Node3D) -> AABB:
	var slice = field._slice if "_slice" in field else null
	if slice == null or body == null:
		return AABB()
	var size: Vector3 = Vector3(slice.dims) * slice.cell_size
	return AABB(body.center() + slice.resolved_offset(body) - 0.5 * size, size)


## Where on the body the box sits, in the body's own frame: its resolved offset is that direction.
static func slice_site_dir(field: Node) -> Vector3:
	var slice = field._slice if "_slice" in field else null
	return Vector3.ZERO if slice == null else Vector3(slice.offset).normalized()


func _slice_box() -> AABB:
	return slice_body_aabb(_sim.material_field(), _sim.body())


func _build_sky() -> void:
	_sky_ctrl.setup(_world, _sim.star(), _sim.moon(), _render_opts)
	# The sky follows THIS camera, never a viewport lookup: a photographed run draws through an
	# off-screen SubViewport whose parent window holds no camera.
	_sky_ctrl.bind_camera(_camera, _sim.body().center(), _sim.body().sea_radius())
	_sky_ctrl.enter_space_mode(_sim.body().center())
	if _sim.orbits() != null and _sim.orbits().has_method("set_sky_controller"):
		_sim.orbits().set_sky_controller(_sky_ctrl)
	# A SLICE has already been framed: the box says where this world is looked at, and nothing re-aims it.
	if _slice_box().size.length() > 0.0:
		return
	if _camera != null and _camera.has_method("face_sun_on_start"):
		_camera.face_sun_on_start(_sky_ctrl.sun())
	# OPEN ON THE COAST, in the world frame the rig steers in: most bearings on this body are open water.
	var terrain = _sim.terrain()
	if terrain == null or not terrain.has_method("coast_site_world_dir") \
			or not _camera.has_method("orient_toward"):
		return
	var site: Vector3 = terrain.coast_site_world_dir()
	if site != Vector3.ZERO:
		_camera.orient_toward(site)


func _build_world_visuals() -> void:
	var body: Node3D = _sim.body()
	var material: Node = _sim.material_field()
	var terrain = _sim.terrain()

	_veg_renderer.reparent(_sim.actors_root())
	if _sim.ecology().has_method("set_vegetation_renderer"):
		_sim.ecology().set_vegetation_renderer(_veg_renderer)

	# The field's condensate as ONE GPU particle system; phase is per-particle, off the cover texture.
	_water.setup(material, _camera, _sky_ctrl.sun(), body.center(), body.sea_radius())

	# One arrow glyph per open cell, at every altitude, over the chosen vector field. The scene's own
	# declaration outranks the shell's flag; only an undeclared scene defers to it.
	_vectors.setup(material, _camera, body.center(), body.sea_radius())
	_vectors.set_source(_input.vectors() if declared_vectors == LAFieldVectors.SOURCE_UNSET
		else declared_vectors)

	# THE FREE SURFACE OF EVERY BODY OF WATER THIS WORLD HOLDS, meshed from the field's own water column:
	# a stream, a lake and an ocean are the same liquid standing at whatever level it stands at.
	_water_surface.setup(material, _camera, terrain, _sky_ctrl.sun(), body.center(),
		bool(_render_opts.get("ocean_transparent", true)))

	_sky_ctrl.bind_scene(material, _water)

	# The ground's look, before any uniform below is written to it.
	if terrain_material == null:
		push_error("LARenderLayer: Terrain Material is unset, so the planet draws with godot_voxel's default material.")
	terrain.set_terrain_material(terrain_material)
	# The ground's reflectance, from the one place this world declares it.
	terrain.set_shader_param("albedo_bare_ground", LAPhysical.ALBEDO_BARE_GROUND)
	terrain.set_shader_param("albedo_snow_ice", LAPhysical.ALBEDO_SNOW_ICE)
	# The test masses: a marker where each probe stands and the line it fell down.
	_test_masses.setup(_sim.test_masses(), _camera)

	# Hot ground glows — the live per-cell temperature as a 3D texture over the field box.
	_heat_tex.setup(material, terrain)

	# The simulated box where it meets the world: ground edges on the relief, corner pillars fading up.
	var outline: LAFieldBoxOutline = LAFieldBoxOutline.build(material, terrain, _camera, body)
	add_child(outline)

	for pair in [["terrain", terrain.terrain_node()], ["camera", _camera], ["sky", _sky_ctrl], ["vegetation", _veg_renderer],
			["water_particles", _water], ["water_surface", _water_surface],
			["vectors", _vectors], ["heat_texture", _heat_tex], ["test_masses", _test_masses],
			["box_outline", outline]]:
		LAAblate.adopt(pair[0], pair[1])
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


## THE GROUND IS STREAMED AS FAR AS THE EYE CAN SEE. The quality setting is the floor, not the ceiling.
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
func water_surface() -> Node: return _water_surface
