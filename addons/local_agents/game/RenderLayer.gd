class_name LARenderLayer
extends Node3D


var _world: Node = null
var _sim: LASimulation = null
var _input: LAVoxelInputController = null
var _render_opts: Dictionary = {}

# The node TREE is declared in RenderLayer.tscn; this script only wires it.
@onready var _camera: Camera3D = $CameraRig
@onready var _sky_ctrl: LAVoxelSkyController = $SkyController
@onready var _veg_renderer: Node3D = $VegetationRenderer
@onready var _weather: Node = $Weather
@onready var _ocean: Node = $OceanPlane
@onready var _water: Node = $WaterParticles
@onready var _water_surface: Node = $WaterSurface
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
	# A SECOND viewer, this one asking for visuals + collision meshing. The simulation's data-only viewer
	# already streams the SDF, so this adds drawing, never streaming the physics depends on.
	body.attach_viewer(_camera, true)
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(body.center(), body.radius())
	if _camera.has_method("set_ecology"):
		_camera.set_ecology(_sim.ecology())


func _build_sky() -> void:
	_sky_ctrl.setup(_world, _sim.star(), _input.time_of_day_seed(), _input.lunar_seed(), _render_opts)
	_sky_ctrl.enter_space_mode(_sim.body().center())
	# The orbit drives the sky's space-mode direction. The orbit runs without one; this only gives it a sink.
	if _sim.orbits() != null and _sim.orbits().has_method("set_sky_controller"):
		_sim.orbits().set_sky_controller(_sky_ctrl)
	if _camera != null and _camera.has_method("face_sun_on_start"):
		_camera.face_sun_on_start(_sky_ctrl.sun())


func _build_world_visuals() -> void:
	var body: Node3D = _sim.body()
	var material: Node = _sim.material_field()
	var terrain = _sim.terrain()

	_veg_renderer.reparent(_sim.actors_root())
	if _sim.ecology().has_method("set_vegetation_renderer"):
		_sim.ecology().set_vegetation_renderer(_veg_renderer)

	_weather.setup(_camera, _sky_ctrl.sun(), _sky_ctrl.env())
	if _weather.has_method("set_field"):
		_weather.set_field(material)

	# The calm sea: ONE GPU plane at sea level — a finite spherical shell at sea_radius.
	if terrain.is_planet():
		_ocean.setup_sphere(body.center(), body.sea_radius(), bool(_render_opts.get("ocean_transparent", true)))
	else:
		_ocean.setup(terrain.sea_level(), _camera)

	# The field's emergent condensate as ONE GPU particle system: cloud / fog / rain / snow, the phase a
	# per-particle property classified from the field's baked cover texture.
	_water.setup(material, _camera, _sky_ctrl.sun(), body.center(), body.sea_radius())

	# The dynamic FLUID SURFACE: springs/rivers/waterfalls/lakes/floods meshed from the field's water column.
	_water_surface.setup(material, _camera, terrain, _sky_ctrl.sun(), body.center(), body.sea_radius())

	_sky_ctrl.bind_scene(_weather, material, _water)
	if _sim.orbits() != null:
		_sim.orbits().set_tide_targets(_ocean, _water_surface, body.sea_radius())

	# The terrain shader's climate basis: up is radial, altitude is height above the sea shell.
	terrain.set_shader_param("planet_center", body.center())
	terrain.set_shader_param("planet_sea_radius", body.sea_radius())
	# Hot ground glows — the live per-cell temperature as a 3D texture over the field box.
	_heat_tex.setup(material, terrain)

	# Effects density onto the atmosphere particles + the difficulty-scaled ambient-disaster cadence.
	_sim.settings_applier().bind(_world, _sim.disasters(), terrain, _water)
	# The screen-ray casts the disaster controller accepts but never requires.
	if _sim.disasters() != null and _sim.disasters().has_method("set_presentation"):
		_sim.disasters().set_presentation(_camera, null)
	if _sim.spawn_controller() != null and _sim.spawn_controller().has_method("set_presentation"):
		_sim.spawn_controller().set_presentation(_camera, null)


func step(delta: float) -> void:
	if _sky_ctrl != null:
		_sky_ctrl.update(delta)


func camera() -> Camera3D: return _camera
func sky_controller() -> LAVoxelSkyController: return _sky_ctrl
func water_particles() -> Node: return _water
func ocean() -> Node: return _ocean
func water_surface() -> Node: return _water_surface
