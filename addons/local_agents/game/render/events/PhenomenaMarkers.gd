@tool
class_name LAPhenomenaMarkers
extends Node3D

## Draws what the world was seen to do: the registered view of each observed kind this world holds, where
## it happened.

@export_group("Views")
## One record per observed kind: the scene that draws it, what it needs and what feeds it.
@export var registry: LAEventViewRegistry = null
## Views of one kind standing at once. A renderer budget: every view carries a light.
@export var max_drawn_per_kind: int = 24
@export_group("Detector")
## Seconds between readings of the detector. A display cadence: its reading changes once per field step.
@export var refresh_s: float = 0.5

var _field: LAMaterialField3D = null
var _detector: LAFieldPhenomena = null
var _kinds: Dictionary = {}                # kind -> the node its views stand under, switched by LAAblate
var _polled: Array[StringName] = []        # adopted kinds read off the detector
var _sites: Dictionary = {}                # "kind:cell" -> the view standing on that observed site
var _cd: float = 0.0


## Adopt every registered kind this world's processes can produce, and wire each to what feeds it: the
## field's signals, the arrivals `actors` holds or receives, or the detector reading `field`.
func setup(field: LAMaterialField3D, actors: Node3D) -> void:
	if registry == null:
		push_error("PhenomenaMarkers: no registry, so no observed kind has a view to be drawn with.")
		return
	_field = field
	var arrivals: bool = false
	for kind: StringName in registry.views:
		var rec: LAEventViewRecord = registry.views[kind]
		if rec == null or not rec.offered() or not _adopt(kind, rec.scene):
			continue
		match rec.source:
			LAEventViewRecord.Source.OBSERVED:
				_polled.append(kind)
			LAEventViewRecord.Source.FIELD:
				field.connect(rec.signal_name, _fed.bind(kind))
			LAEventViewRecord.Source.ARRIVAL:
				arrivals = true
	if not _polled.is_empty():
		_detector = LAFieldPhenomena.new()
		_detector.setup(field)
	if arrivals:
		actors.child_entered_tree.connect(_watch_arrival)
		for actor: Node in actors.get_children():
			_watch_arrival(actor)


## One kind's views stand under one node, switched by the ablation name its scene declares. False where
## the scene is no LAEventView naming one.
func _adopt(kind: StringName, scene: PackedScene) -> bool:
	var probe: Node = scene.instantiate() if scene != null else null
	var switch: String = (probe as LAEventView).ablation_name if probe is LAEventView else ""
	if probe != null:
		probe.free()
	if switch.is_empty():
		push_error("PhenomenaMarkers: '%s' is drawn by no LAEventView naming its ablation switch." % kind)
		return false
	var box: Node3D = Node3D.new()
	box.name = switch
	add_child(box)
	_kinds[kind] = box
	LAAblate.adopt(switch, box)
	return true


## A signal's arguments, then the kind it was bound to: the observation its record names them as.
func _fed(...args: Array) -> void:
	var kind: StringName = args.pop_back()
	var keys: PackedStringArray = (registry.views[kind] as LAEventViewRecord).args
	var observation: Dictionary = {}
	for i in mini(keys.size(), args.size()):
		observation[keys[i]] = args[i]
	show_kind(kind, observation)


## Draw one event of `kind` from `observation`. Null where no view is registered for it, its switch is
## off, or its kind is at the budget.
func show_kind(kind: StringName, observation: Dictionary) -> LAEventView:
	var box: Node3D = _kinds.get(kind) as Node3D
	if box == null or not box.can_process() or box.get_child_count() >= max_drawn_per_kind:
		return null
	var view: LAEventView = (registry.views[kind] as LAEventViewRecord).scene.instantiate() as LAEventView
	box.add_child(view)
	view.show_event(observation)
	return view


## An actor of an adopted arrival kind's class is drawn by that kind whenever its signal fires.
func _watch_arrival(actor: Node) -> void:
	var s: Script = actor.get_script() as Script
	var cls: StringName = s.get_global_name() if s != null else &""
	for kind: StringName in _kinds:
		var rec: LAEventViewRecord = registry.views[kind]
		if rec.source == LAEventViewRecord.Source.ARRIVAL and rec.arrival_class == cls:
			actor.connect(rec.signal_name, _fed.bind(kind))


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _detector == null:
		return
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = refresh_s
	var watched: Array[StringName] = []
	for kind: StringName in _polled:
		if (_kinds[kind] as Node3D).can_process():
			watched.append(kind)
	var obs: Dictionary = _detector.observe() if not watched.is_empty() else {}
	var seen: Dictionary = {}
	for kind: StringName in watched:
		if not bool(obs.get(String(kind) + "_live", false)):
			continue
		for o: Dictionary in obs.get(String(kind), []):
			var key: String = _stand(kind, o)
			if not key.is_empty():
				seen[key] = true
	for key: String in _sites.keys():
		if seen.has(key):
			continue
		# Untyped: a freed node fails a typed check before is_instance_valid can answer.
		var gone: Variant = _sites[key]
		_sites.erase(key)
		if is_instance_valid(gone):
			(gone as LAEventView).finish()


## Stand `kind`'s view on an observed site, keyed by the cell that named it, so one site keeps one view.
## Empty where the site names no cell of this field or no view could stand.
func _stand(kind: StringName, observation: Dictionary) -> String:
	var c: int = _field.world_to_cell(observation["pos"])
	if c < 0:
		return ""
	var key: String = "%s:%d" % [kind, c]
	var at: Dictionary = observation.duplicate()
	at["cell_m"] = _field._grid.cell_edge(c)
	var standing: Variant = _sites.get(key)
	if is_instance_valid(standing):
		(standing as LAEventView).show_event(at)
		return key
	var view: LAEventView = show_kind(kind, at)
	if view == null:
		return ""
	_sites[key] = view
	return key


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if registry == null:
		out.append("No Registry: nothing says which scene draws which observed kind.")
		return out
	for kind: StringName in registry.views:
		var rec: LAEventViewRecord = registry.views[kind]
		if rec == null or rec.scene == null:
			out.append("The record for '%s' holds no scene, so that kind is never drawn." % kind)
		elif rec.source != LAEventViewRecord.Source.OBSERVED and rec.signal_name == &"":
			out.append("The record for '%s' is fed by a signal it does not name." % kind)
		elif rec.source == LAEventViewRecord.Source.ARRIVAL and rec.arrival_class == &"":
			out.append("The record for '%s' names no class of actor its signal arrives on." % kind)
	return out
