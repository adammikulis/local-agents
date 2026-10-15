extends RefCounted

class Medium extends RefCounted:
	var temperature: float = NAN
	var oxygen_reads: int = 0
	func temp_at(_position: Vector3) -> float:
		return temperature
	func o2_at(_x: float, _y: float, _z: float) -> float:
		oxygen_reads += 1
		return 0.0
	func biomass_at(_x: float, _y: float, _z: float) -> float:
		return 0.0

class Body extends Node3D:
	var _material = null
	var body_temp: float = 28.0
	var health: float = 1.0
	var _panic_timer: float = 0.0
	var breath_capacity: float = 1.0
	var _breath: float = 1.0


func run_test(tree: SceneTree) -> bool:
	var medium: Medium = Medium.new()
	var body: Body = Body.new()
	tree.root.add_child(body)
	body._material = medium
	var ok: bool = not LACognizerAdapter.senses(body).has("temp")
	body._material = null
	ok = is_nan(LACreatureRagdoll._decomp_env(body)) and ok
	body._material = medium
	ok = is_finite(LACreatureRagdoll._decomp_env(body)) and ok
	body.body_temp = -30.0
	ok = LACreatureRagdoll._decomp_env(body) == 0.0 and ok
	body.body_temp = NAN
	ok = is_nan(LACreatureRagdoll._decomp_env(body)) and ok
	medium.temperature = 18.0
	ok = LACognizerAdapter.senses(body).get("temp") == 18.0 and ok
	var ecology: LAEcologyService = LAEcologyService.new()
	var spawner: LAEcologySpawner = LAEcologySpawner.new()
	spawner.setup(ecology)
	ok = is_nan(spawner._forest_suitability(Vector3.ZERO)) and ok
	ecology._material = medium
	ok = is_finite(spawner._forest_suitability(Vector3.ZERO)) and ok
	medium.temperature = NAN
	ok = is_nan(spawner._forest_suitability(Vector3.ZERO)) and ok
	var fish: LAFish = LAFish.new()
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "BodyShape"
	fish.add_child(shape)
	tree.root.add_child(fish)
	fish.set_physics_process(false)
	fish.material = medium
	var energy: float = fish.energy
	fish._physics_process(0.1)
	ok = fish.energy == energy and medium.oxygen_reads == 0 and ok
	var carcasses: Array = []
	for i in range(128):
		var carcass: Body = Body.new()
		tree.root.add_child(carcass)
		carcasses.append(carcass)
		LACreatureRagdoll._register_carcass(carcass)
	for carcass in carcasses:
		ok = not carcass.is_queued_for_deletion() and ok
		LACreatureRagdoll._forget_carcass(carcass)
		carcass.free()
	fish.free()
	ecology.free()
	body.free()
	if not ok:
		push_error("absent measurements changed creature physiology or carcasses were evicted")
	return ok
