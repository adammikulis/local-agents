class_name LAVoxelSpawnController
extends Node


const INITIAL_COUNTS: Dictionary = {
	"plant": 260, "shrub": 28, "flower_daisy": 36, "flower_clover": 26,
	# TOXIC vegetation is a deliberate MINORITY (nightshade/deathcap) among the wholesome majority above — enough
	# for a grazer to meet, learn from, and avoid, without denting a herd that thrives on the wholesome plants.
	"nightshade": 14, "deathcap": 10,
	# Rabbits open just UNDER their pop_cap (85) rather than over it — a founding herd that grows toward
	# carrying capacity, not one that starts over-cap and mass-starves in a crash before it can settle.
	"rabbit": 50, "mouse": 12, "fox": 10, "bird": 55, "swallow": 10, "villager": 12, "vulture": 12,
	"beetle": 10, "ant": 12, "grasshopper": 10, "butterfly": 10, "fly": 12, "bee": 14,
}
const FOREST_CLUSTERS: int = 16

const CAMPAIGN_INITIAL_COUNTS: Dictionary = {
	"rabbit": 12,
}
const CAMPAIGN_FOREST_CLUSTERS: int = 0

var _world: Node = null
var _body: Node3D = null
var _terrain = null
var _ecology: Node = null
var _camera: Camera3D = null
var _material: Node = null
var _hud: CanvasLayer = null

var _spawned_initial: bool = false


func setup(world: Node, body: Node3D, terrain, ecology: Node, camera: Camera3D, material: Node, hud: CanvasLayer) -> void:
	_world = world
	_body = body
	_terrain = terrain
	_ecology = ecology
	_camera = camera
	_material = material
	_hud = hud


## Camera + HUD are PRESENTATION — the opening camera framing and the status line. Both stay null without
## --ui; where life is placed is physics and does not consult either.
func set_presentation(camera: Camera3D, hud: CanvasLayer) -> void:
	_camera = camera
	_hud = hud


func is_spawned() -> bool:
	return _spawned_initial


## SAVE-LOAD: mark the initial population as already spawned so try_spawn() is a no-op. A loaded world already
## carries its own creatures/vegetation (restored by LAWorldSaveController) — seeding a fresh founding stock on
## top would double the population and desync it from the restored kinship/field.
func suppress_initial_spawn() -> void:
	_spawned_initial = true


## THE WORLD'S OWN ANSWERS, never a tick count. A vegetation placement reads the ground under the site
## and the temperature in the cell above it; a count of frames says only that time passed, so under load
## the same world seeds a different census. Both answers exist or the seeding waits.
func _world_ready() -> bool:
	if _material == null or not _material.has_method("seeding_ready") or not _material.seeding_ready():
		return false
	if _terrain == null or not _terrain.has_method("surface_radius") \
			or not _terrain.has_method("planet_center"):
		return false
	var site: Vector3 = _material.cell_world_pos(0, 0, 0) - _terrain.planet_center()
	if is_nan(site.x) or site.length() < 0.001:
		return false
	return not is_nan(_terrain.surface_radius(site.normalized()))


func try_spawn(_overview: bool, _farview: bool, _auto_meteor: bool, _auto_select: bool) -> void:
	if _spawned_initial or _body == null:
		return
	# Gate on the body being built; the ground under a spawn is the SDF's, drawn or not.
	if _body.radius() <= 0.0:
		return
	if not _world_ready():
		return
	LASimReport.reset()
	var no_fauna: bool = LAAblate.fauna_off()
	var no_flora: bool = LAAblate.flora_off()
	if no_fauna or no_flora:
		print("LIFE_MODE={mode:%s, fauna:%s, flora:%s}" % [
			LAAblate.life_mode(), str(not no_fauna), str(not no_flora)])
	if _is_campaign():
		if not no_fauna:
			_ecology.spawn_initial(CAMPAIGN_INITIAL_COUNTS)
		_ecology.populate_environment(0 if no_flora else CAMPAIGN_FOREST_CLUSTERS)
	else:
		if not no_fauna:
			_ecology.spawn_initial(INITIAL_COUNTS)
		_ecology.populate_environment(0 if no_flora else FOREST_CLUSTERS)
		if not no_fauna and _ecology.has_method("stock_initial_aquatic"):
			_ecology.stock_initial_aquatic()
	# NOTHING RE-FRAMES THE VIEW HERE: the render layer framed the camera off the body or off the slice
	# box, and a second framing at spawn undoes it.
	# CAMPAIGN opens looking AT the herd; orient_toward clears the deferred sunnyside so the aim wins.
	if _camera != null and _is_campaign() and _camera.has_method("orient_toward"):
		var herd_dir: Vector3 = _campaign_herd_dir()
		if herd_dir != Vector3.ZERO:
			_camera.orient_toward(herd_dir)
	_seed_diseases()
	_spawned_initial = true
	LAVoxelHarness.emit_founding(_world)
	if _hud != null:
		_hud.set_status("World ready. Spawn things, click to inspect, press V for scent.")


const DISEASE_SEED_SANDBOX: int = 3

func _seed_diseases() -> void:
	var count: int = DISEASE_SEED_SANDBOX if not _is_campaign() else 0
	var env: String = OS.get_environment("LA_DISEASE_SEED")
	if env != "":
		count = maxi(0, int(env))
	if count <= 0:
		return
	var strains: Array = LADiseaseLibrary.known_strains()
	if strains.is_empty():
		return
	var creatures: Array = get_tree().get_nodes_in_group("creature")
	if creatures.is_empty():
		return
	var forced: String = OS.get_environment("LA_DISEASE_STRAIN")   # test hook: seed only this strain
	var seeded: int = 0
	for i in range(count):
		var c = creatures[LASimRng.shared().randi_range(0, creatures.size() - 1)]
		if not is_instance_valid(c) or c.get("disease") == null:
			continue
		var strain_id: String = forced if forced != "" else String(strains[LASimRng.shared().randi_range(0, strains.size() - 1)])
		c.disease.infect(strain_id, 0.6)               # a solid starting dose so the infection establishes
		seeded += 1
	print("DISEASE_SEED={seeded:%d, strains:%d}" % [seeded, strains.size()])


func _is_campaign() -> bool:
	var prog: LAGameProgression = LAGameProgression.active()
	return prog != null and not prog.is_sandbox()


func _campaign_herd_dir() -> Vector3:
	if _body == null:
		return Vector3.ZERO
	var center: Vector3 = _body.center()
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for node in get_tree().get_nodes_in_group("creature"):
		if node is Node3D:
			sum += (node as Node3D).global_position - center
			n += 1
	if n == 0:
		return Vector3.ZERO
	return sum.normalized()


