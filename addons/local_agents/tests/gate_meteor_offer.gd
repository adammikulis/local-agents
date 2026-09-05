extends SceneTree

## Rung by rung: the offer is asked, then a rock is aimed at that world, so the answer is held to what
## the world does.

class StubGround extends RefCounted:
	var radius: float = 0.0

	func surface_point(dir: Vector3) -> Vector3:
		return dir * radius

	func up_at(pos: Vector3) -> Vector3:
		return pos.normalized() if pos.length() > 0.001 else Vector3.UP


## The body a rock falls toward. A world with no mass in it has no arrival speed, so the walk would be
## measuring a refusal it caused itself.
class StubBody extends Node3D:
	var _mass: float = 0.0
	var _radius: float = 0.0

	func mass() -> float:
		return _mass

	func radius() -> float:
		return _radius

	func center() -> Vector3:
		return Vector3.ZERO

	func is_gravity_reference() -> bool:
		return true


var _fail: int = 0
var _walked: bool = false


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


# On the first iteration, not at _init: a rock reads its own global transform as it launches.
func _process(_delta: float) -> bool:
	if _walked:
		return true
	_walked = true
	_walk()
	quit(1 if _fail > 0 else 0)
	return true


func _walk() -> void:
	var mass_kg: float = float(LABodySeeds.of("planet").get("mass_kg", 0.0))
	var radius_m: float = LABodySeeds.seed_radius_m("planet")
	if not (mass_kg > 0.0 and radius_m > 0.0):
		_say("The seeded planet has no measured mass or radius, so no rock has a body to fall toward.")
		return
	var body: StubBody = StubBody.new()
	body._mass = mass_kg
	body._radius = radius_m
	body.add_to_group(LAGravity.GROUP)
	root.add_child(body)
	var ground: StubGround = StubGround.new()
	ground.radius = radius_m
	var actors: Node3D = Node3D.new()
	root.add_child(actors)
	var impacts: LAMeteorImpacts = LAMeteorImpacts.new()
	root.add_child(impacts)
	impacts.setup(ground, null, actors, null)

	var rows: PackedStringArray = PackedStringArray()
	var first_offering: int = LAProcessSet.UNSET
	for rec: Dictionary in LAProcessSet.rungs():
		var rung: int = int(rec["rung"])
		LAProcessSet.declare(rung)
		var offers: bool = LAWorldOffers.has_impacts()
		var before: int = actors.get_child_count()
		impacts.fire_ambient_meteor()
		var arrived: int = actors.get_child_count() - before
		if offers and arrived == 0:
			_say("Rung \"%s\" offers an impact and received no rock." % rec["name"])
		if not offers and arrived > 0:
			_say("Rung \"%s\" lacks %s and received a rock anyway."
				% [rec["name"], ", ".join(LAWorldOffers.impacts_missing())])
		if offers and first_offering == LAProcessSet.UNSET:
			first_offering = rung
		rows.append('{"rung":%d,"name":"%s","offers":%s,"arrived":%d,"missing":%s}'
			% [rung, rec["name"], str(offers).to_lower(), arrived,
				JSON.stringify(LAWorldOffers.impacts_missing())])

	LAProcessSet.declare(LAProcessSet.STATE)
	if LAWorldOffers.has_impacts():
		_say("The state rung offers an impact, and it holds none of an impact's processes.")
	if first_offering == LAProcessSet.UNSET:
		_say("No rung on the ladder receives a rock, so nothing here separates refusal from silence.")

	print('METEOR_OFFER={"rungs":[%s],"first_offering":%d,"failures":%d}'
		% [",".join(rows), first_offering, _fail])
