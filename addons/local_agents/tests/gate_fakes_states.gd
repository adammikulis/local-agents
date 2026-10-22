extends SceneTree

## The life demo once per arm: the defaults, then each LAFakes record `off`, dealt over `--part=i/n`
## processes that share one bake. The last also reads each record in all three states at the seam.
## Markers: FAKE_STATES_PLAN, _BAKE, _ARM, _END, _SEAMS.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
## Named by path: they use autoloads, which exist only once this script is running.
const WORLD: String = "res://addons/local_agents/examples/LifeDemo.tscn"
const WORLD_END: String = "res://addons/local_agents/game/WorldEnd.gd"
const HARNESS: String = "res://addons/local_agents/runtime/DemoHarness.gd"
const SPEC: String = "LA_ABLATE"
const SEAL: String = "LA_SEAL_KEY"
const PART: String = "--part="
## LAFieldStateCache's own directory: the bake the first world writes and every later world reads.
const STATE_DIR: String = "la_field_cache"

var _arms: Array[Dictionary] = []
var _part: int = 0
var _parts: int = 1
var _at: int = -1
var _world: Node = null
var _end: GDScript = null
var _worst: int = 0
var _baked: bool = false


func _initialize() -> void:
	QuietWindow.apply_if_automated()
	_end = load(WORLD_END)
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(PART):
			var ij: PackedStringArray = String(a).substr(PART.length()).split("/")
			_part = int(ij[0])
			_parts = maxi(1, int(ij[1]))
	if OS.get_environment(SEAL) == "":
		print("FAKE_STATES_NO_SEAL_KEY=%s names no bake the parts share" % SEAL)
		_finish(2)
		return
	OS.unset_environment("LA_SEAL_RESEED")
	var all: Array[Dictionary] = [{"arm": "defaults", "spec": ""}]
	for r in LAFakes.RECORDS:
		var record: String = String(r["name"])
		all.append({"arm": "%s.off" % record, "spec": "%s:%s" % [record, LAAblate.state_off()]})
	for j in all.size():
		if floori(float(j * _parts) / float(all.size())) == _part:
			_arms.append(all[j])
	print("FAKE_STATES_PLAN=" + JSON.stringify(_arms.map(func(a: Dictionary) -> String: return String(a["arm"]))))
	_next()


func _next() -> void:
	_at += 1
	if _at >= _arms.size():
		_finish(_worst)
		return
	_end.call("release")
	if String(_arms[_at]["spec"]) == "":
		OS.unset_environment(SPEC)
	else:
		OS.set_environment(SPEC, String(_arms[_at]["spec"]))
	print("FAKE_STATES_ARM=" + JSON.stringify(_arms[_at]))
	_world = (load(WORLD) as PackedScene).instantiate()
	var harness: Node = _world.get_node("DemoHarness")
	harness.set("host_owned", true)
	harness.connect("finished", _ended)
	root.add_child(_world)


func _ended(code: int) -> void:
	print("FAKE_STATES_END=" + JSON.stringify({"arm": _arms[_at]["arm"], "code": code}))
	_worst = maxi(_worst, code)
	if not _baked:
		_baked = true
		var g: LAVoxelGrid = _world.get("_material")._grid
		var key: String = LAFieldStateCache.state_key(OS.get_environment(SEAL), g.nx, g.ny, g.nz, g.cell_size, g.origin)
		print("FAKE_STATES_BAKE=" + OS.get_user_data_dir().path_join(STATE_DIR).path_join(key + ".bin"))
	_world.tree_exited.connect(_freed, CONNECT_ONE_SHOT)
	_world.queue_free()


func _freed() -> void:
	_world = null
	await process_frame
	_next()


## Per record and state: what the registry reads back from the launch spec, whether the stand-in stands
## in, and whether it hands anything out. Empty means as the state says.
func _seams() -> Dictionary:
	var out: Dictionary = {}
	for r in LAFakes.RECORDS:
		var record: String = String(r["name"])
		var row: Dictionary = {}
		for state in [LAAblate.state_off(), LAAblate.state_real(), LAAblate.state_fake()]:
			_end.call("release")
			OS.set_environment(SPEC, "%s:%s" % [record, state])
			var fake: bool = state == LAAblate.state_fake()
			var wrong: Array[String] = []
			if String(LAFakes.states().get(record, "")) != state:
				wrong.append("reads %s" % LAFakes.states().get(record, ""))
			if LAFakes.stands_in(record) != fake:
				wrong.append("stands_in is %s" % LAFakes.stands_in(record))
			if (LAFakes.draw(record, 1.0) == 1.0) != fake:
				wrong.append("draw hands out the wrong amount")
			row[state] = wrong
		out[record] = row
	_end.call("release")
	OS.unset_environment(SPEC)
	return out


func _finish(code: int) -> void:
	if not _arms.is_empty() and _part == _parts - 1:
		print("FAKE_STATES_SEAMS=" + JSON.stringify(_seams()))
	(load(HARNESS) as GDScript).call("print_complete", code)
	LAAppQuit.request(root, code)
