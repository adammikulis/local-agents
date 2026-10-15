extends SceneTree

## The event-view host held to its contract: what each record draws, what a rung without its processes
## offers, the budget, the switch, a rock's view, and the cyclone ring's frame, axis, bounds and size.

const REGISTRY_PATH: String = "res://addons/local_agents/game/render/events/EventViews.tres"
const HOST_SCRIPT: String = "res://addons/local_agents/game/render/events/PhenomenaMarkers.gd"
const RENDER_LAYER: String = "res://addons/local_agents/game/RenderLayer.tscn"
const BUDGET: int = 3

var _fail: int = 0
var _walked: bool = false
var _absent_seen: int = 0
var _present_seen: int = 0
var _registry: LAEventViewRegistry = null


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


func _process(_delta: float) -> bool:
	if _walked:
		return true
	_walked = true
	_walk()
	print('EVENT_VIEWS={"absent_seen":%d,"present_seen":%d,"failures":%d}'
		% [_absent_seen, _present_seen, _fail])
	quit(1 if _fail > 0 else 0)
	return true


func _walk() -> void:
	_registry = load(REGISTRY_PATH) as LAEventViewRegistry
	if _registry == null or _registry.views.is_empty():
		_say("No event-view registry at %s, so nothing is drawn." % REGISTRY_PATH)
		return
	_check_records()
	if _fail > 0:
		return
	_walk_rungs()
	LAProcessSet.declare(LAProcessSet.TOP)
	var planet: Dictionary = LABodySeeds.of("planet")
	var radius_m: float = LABodySeeds.seed_radius_m("planet")
	LABallistics.set_system([{"mass_kg": float(planet.get("mass_kg", 0.0)), "center": Vector3.ZERO,
		"radius_m": radius_m, "frame": true}])
	_check_cyclone(radius_m)
	_check_budget_and_switch(Vector3(radius_m + 10.0, 0.0, 0.0))
	_check_rocks()


## Every record: an LAEventView scene naming its switch, needs spelled as processes the ladder holds, and
## a signal its source carries with as many arguments as the record names.
func _check_records() -> void:
	LAProcessSet.declare(LAProcessSet.TOP)
	var ladder: PackedStringArray = LAProcessSet.process_names(LAProcessSet.ANY)
	var field: LAMaterialField3D = LAMaterialField3D.new()
	for kind: StringName in _registry.views:
		var rec: LAEventViewRecord = _registry.views[kind]
		var view: Node = rec.scene.instantiate() if rec != null and rec.scene != null else null
		if not view is LAEventView or (view as LAEventView).ablation_name.is_empty():
			_say("'%s' is not drawn by an LAEventView naming its switch." % kind)
		if view != null:
			view.free()
		if rec == null:
			continue
		for n: String in rec.needs:
			if not ladder.has(n):
				_say("'%s' needs '%s', which no rung of the ladder holds." % [kind, n])
		var carrier: Object = null
		if rec.source == LAEventViewRecord.Source.FIELD:
			carrier = field
		elif rec.source == LAEventViewRecord.Source.ARRIVAL:
			carrier = _instance_of(rec.arrival_class)
		if carrier == null:
			continue
		var argc: int = -1
		for sig: Dictionary in carrier.get_signal_list():
			if StringName(sig["name"]) == rec.signal_name:
				argc = (sig["args"] as Array).size()
		if argc != rec.args.size():
			_say("'%s' is fed by %s.%s, which carries %d arguments against the %d it names."
				% [kind, carrier.get_class(), rec.signal_name, argc, rec.args.size()])
		if carrier != field:
			carrier.free()
	field.free()


func _instance_of(cls: StringName) -> Object:
	for row: Dictionary in ProjectSettings.get_global_class_list():
		if StringName(row["class"]) == cls:
			return (load(String(row["path"])) as Script).new()
	return null


## Whether this world holds a record's processes, asked of the ladder, not of the record.
func _expected(rec: LAEventViewRecord) -> bool:
	for n: String in rec.needs:
		if not LAProcessSet.process_names(LAProcessSet.ANY).has(n):
			return false
	return rec.offered_by == &"" or bool(LAEventViewRecord.Offers.call(rec.offered_by))


func _host(field: LAMaterialField3D, actors: Node3D) -> LAPhenomenaMarkers:
	var host: LAPhenomenaMarkers = (load(HOST_SCRIPT) as GDScript).new() as LAPhenomenaMarkers
	host.registry = _registry
	host.max_drawn_per_kind = BUDGET
	root.add_child(host)
	host.setup(field, actors)
	return host


## Bottom rung up: a kind whose processes the world lacks has no switch, no view and no wiring.
func _walk_rungs() -> void:
	for row: Dictionary in LAProcessSet.rungs():
		LAProcessSet.declare(int(row["rung"]))
		var field: LAMaterialField3D = LAMaterialField3D.new()
		var actors: Node3D = Node3D.new()
		root.add_child(actors)
		var host: LAPhenomenaMarkers = _host(field, actors)
		var names: PackedStringArray = LAAblate.names()
		var arrivals: bool = false
		for kind: StringName in _registry.views:
			var rec: LAEventViewRecord = _registry.views[kind]
			var want: bool = _expected(rec)
			if want:
				_present_seen += 1
			else:
				_absent_seen += 1
			var switch: String = _switch_of(rec)
			var wired: bool = host._kinds.has(kind)
			if rec.source == LAEventViewRecord.Source.FIELD:
				wired = wired and not field.get_signal_connection_list(rec.signal_name).is_empty()
			elif rec.source == LAEventViewRecord.Source.OBSERVED:
				wired = wired and host._polled.has(kind)
			elif rec.source == LAEventViewRecord.Source.ARRIVAL:
				arrivals = arrivals or want
			if wired != want:
				_say("Rung \"%s\": '%s' is %s, and its processes are %s." % [row["name"], kind,
					"drawn" if wired else "not drawn", "present" if want else "absent"])
			if not want and names.has(switch):
				_say("Rung \"%s\" offers the '%s' switch for a kind it cannot produce." % [row["name"], switch])
			if not want and host.show_kind(kind, {"pos": Vector3.ONE}) != null:
				_say("Rung \"%s\" drew '%s', whose processes it lacks." % [row["name"], kind])
		if actors.child_entered_tree.get_connections().is_empty() == arrivals:
			_say("Rung \"%s\" watches arrivals: %s, and holds an arrival kind: %s."
				% [row["name"], not actors.child_entered_tree.get_connections().is_empty(), arrivals])
		if host._detector != null and host._polled.is_empty():
			_say("Rung \"%s\" reads the detector for no kind." % row["name"])
		field.free()


func _switch_of(rec: LAEventViewRecord) -> String:
	var view: LAEventView = rec.scene.instantiate() as LAEventView
	var out: String = view.ablation_name
	view.free()
	return out


## A closed low on a graded grid: the ring is sized from its own cell, stands up the local vertical,
## swirls, and is not culled.
func _check_cyclone(radius_m: float) -> void:
	var field: LAMaterialField3D = LAMaterialField3D.new()
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(5, 5, 5, 20.0, Vector3(radius_m + 100.0, -50.0, -50.0))
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(125)
	mask[grid.index(2, 2, 2)] = 1
	grid.refine(mask)
	field._grid = grid
	var actors: Node3D = Node3D.new()
	root.add_child(actors)
	var host: LAPhenomenaMarkers = _host(field, actors)
	var fine: int = grid.leaf_at(2, 2, 2)
	var edge: float = grid.cell_edge(fine)
	if not (edge < grid.cell_size):
		_say("The graded grid's fine cell is not finer than its root, so no sizing is told apart.")
	var pos: Vector3 = field.cell_world_pos_linear(fine)
	var key: String = host._stand(&"cyclones", {"pos": pos})
	var view: LACycloneView = host._sites.get(key) as LACycloneView
	if view == null:
		_say("No cyclone view stood on an observed low.")
		field.free()
		return
	if absf(view.particles.scale.x - edge) > 1.0e-3 * edge:
		_say("The cyclone ring is scaled %.3f m against its cell's %.3f m edge (root %.3f m)."
			% [view.particles.scale.x, edge, grid.cell_size])
	var up: Vector3 = -LABallistics.g_at(pos).normalized()
	if absf(up.dot(Vector3.UP)) > 0.9:
		_say("The low's local vertical is world +Y, so it cannot tell the two apart.")
	if view.global_basis.y.normalized().dot(up) < 0.999:
		_say("The cyclone stands on %s, not the local vertical %s." % [view.global_basis.y, up])
	var pm: ParticleProcessMaterial = view.particles.process_material as ParticleProcessMaterial
	if not view.particles.local_coords:
		_say("The ring's particles are in world coordinates, so they swirl about world +Y.")
	if pm.gravity == Vector3.ZERO or not (pm.tangential_accel_max > 0.0):
		_say("The ring cannot swirl: tangential acceleration turns about the gravity, which is %s." % pm.gravity)
	elif absf(pm.gravity.normalized().dot(pm.emission_ring_axis.normalized())) < 0.999:
		_say("The ring swirls about %s, not its own axis %s." % [pm.gravity, pm.emission_ring_axis])
	var r: float = pm.emission_ring_radius
	var h: float = 0.5 * pm.emission_ring_height
	var box: AABB = view.particles.visibility_aabb
	for p: Vector3 in [Vector3(r, h, 0.0), Vector3(-r, -h, 0.0), Vector3(0.0, h, r), Vector3(0.0, -h, -r)]:
		if not box.has_point(p):
			_say("The ring's visibility box %s culls its own emission at %s." % [box, p])
	field.free()


## Each kind stands no more than its budget, and a kind switched off draws nothing.
func _check_budget_and_switch(at: Vector3) -> void:
	var field: LAMaterialField3D = LAMaterialField3D.new()
	var actors: Node3D = Node3D.new()
	root.add_child(actors)
	var host: LAPhenomenaMarkers = _host(field, actors)
	var obs: Dictionary = {"pos": at, "joules": 1.0e6, "into_water": false, "cell_m": 10.0}
	for kind: StringName in _registry.views:
		if not host._kinds.has(kind):
			_say("The top rung does not draw '%s'." % kind)
			continue
		var box: Node3D = host._kinds[kind]
		var switch: String = _switch_of(_registry.views[kind])
		LAAblate.set_on(switch, false)
		if host.show_kind(kind, obs) != null or box.get_child_count() != 0:
			_say("'%s' drew with its switch off." % kind)
		LAAblate.set_on(switch, true)
		var drawn: int = 0
		for i in BUDGET + 1:
			if host.show_kind(kind, obs) != null:
				drawn += 1
		if drawn != BUDGET or box.get_child_count() != BUDGET:
			_say("'%s' stood %d views against a budget of %d." % [kind, drawn, BUDGET])
	field.free()


## A rock is drawn whether it is in the actors root before the render layer wires it or arrives after.
func _check_rocks() -> void:
	# Untyped: the render layer compiles against autoloads a -s script is parsed before.
	var layer: Node = (load(RENDER_LAYER) as PackedScene).instantiate()
	var actors: Node3D = Node3D.new()
	root.add_child(actors)
	var before: LARock = LARock.new()
	actors.add_child(before)
	before.setup(null)
	layer.call("_draw_actors", actors)
	var after: LARock = LARock.new()
	actors.add_child(after)
	after.setup(null)
	for pair: Array in [["before", before], ["after", after]]:
		var visual: LARockVisual = null
		for c: Node in (pair[1] as Node).get_children():
			if c is LARockVisual:
				visual = c
		if visual == null:
			_say("A rock present %s the render layer has no view." % pair[0])
		elif not (visual.get_node("Stone") as MeshInstance3D).mesh is ArrayMesh:
			_say("A rock present %s the render layer is drawn unshaped." % pair[0])
	layer.free()
