extends SceneTree

## Every transport row, reduce row, reaction module and pass belongs to exactly one rung, and no rung
## reduces or moves a buffer its own passes do not allocate.

const DriverScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSphereGPU3D.gd")
const PASS_DIR: String = "res://addons/local_agents/sim/material/sphere_passes/"
const CC: int = 64

var _fail: int = 0
var _unassigned: int = 0
var _duplicate: int = 0
var _absent: int = 0


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


## Rungs whose declaration under `field` admits `key`. Two is an ambiguity, none is an orphan.
func _owners(field: String, key: String) -> Array:
	var out: Array = []
	for r: Dictionary in LAProcessSet.rungs():
		if _admits(r[field] as Array, key):
			out.append(int(r["rung"]))
		elif field == "reduce" and _books(int(r["rung"]), key):
			out.append(int(r["rung"]))
	return out


## A boundary book follows its channel: it enters at the rung of the row that first moves that channel.
func _books(rung: int, key: String) -> bool:
	var all_booked: PackedStringArray = LAReduceBoundaryRows.BOOKED.duplicate()
	all_booked.append_array(LAReduceBoundaryRows.BOOKED_SIGNED)
	for ch in all_booked:
		if key == LAReduceBoundaryRows.BOOKED_PREFIX + String(ch) \
				or key == LAReduceBoundaryRows.HEAT_PREFIX + String(ch):
			return LAProcessSet.channel_rung(String(ch)) == rung
	return false


func _admits(patterns: Array, key: String) -> bool:
	if key == "":
		return false
	for p in patterns:
		var pat: String = String(p)
		if pat == LAProcessSet.AMOUNTS_TOKEN:
			for n in LAReduceRecords.AMOUNTS:
				if key == "all_" + String(n) or key == "open_" + String(n):
					return true
		elif pat.ends_with("*"):
			if key.begins_with(pat.substr(0, pat.length() - 1)):
				return true
		elif pat == key:
			return true
	return false


func _one(field: String, key: String, what: String) -> void:
	var owners: Array = _owners(field, key)
	if owners.is_empty():
		_unassigned += 1
		_say("%s \"%s\" is in no rung. Name it in LAProcessSet.rungs()." % [what, key])
	elif owners.size() > 1:
		_duplicate += 1
		_say("%s \"%s\" is claimed by rungs %s." % [what, key, str(owners)])


## Buffer names the driver and the rung's own passes allocate.
func _buffers_at(rung: int) -> PackedStringArray:
	LAProcessSet.declare(rung)
	var out: PackedStringArray = PackedStringArray(["nbr", "ghost", "pos", "gravity", "cell_vol"])
	out.append_array(LAChannels.channels())
	out.append_array(LAChannels.derived_buffers())
	for path in LAProcessSet.pass_paths(DriverScript.PASS_SCRIPTS, rung):
		var scr: GDScript = load(String(path))
		if scr == null:
			continue
		var p: RefCounted = scr.new()
		for name in (p._buffers(CC) as Dictionary):
			out.append(String(name))
	return out


func _init() -> void:
	var labels: Dictionary = {}
	for row: Dictionary in LATransportRecords.rows():
		var label: String = String(row.get("label", ""))
		if label == "":
			_say("A transport row on channel \"%s\" carries no label, so no rung can name it."
				% String(row["channel"]))
			continue
		if labels.has(label):
			_duplicate += 1
			_say("Two transport rows are labelled \"%s\"." % label)
		labels[label] = true
		_one("transport", label, "transport row")

	for row: Dictionary in LAReduceRecords.rows():
		_one("reduce", String(row["key"]), "reduce row")

	for path in LAMaterialReactions3D.RECORD_MODULES:
		_one("reactions", String(path).get_file(), "reaction module")

	for path in DriverScript.PASS_SCRIPTS:
		_one("passes", String(path).get_file(), "pass")

	for r: Dictionary in LAProcessSet.rungs():
		for f in (r["passes"] as Array):
			if not FileAccess.file_exists(PASS_DIR + String(f)):
				_say("Rung \"%s\" names pass \"%s\", which is not in %s." % [r["name"], f, PASS_DIR])

	# A row that reads what its own rung does not allocate is assigned too low.
	for r2: Dictionary in LAProcessSet.rungs():
		var at: int = int(r2["rung"])
		var have: PackedStringArray = _buffers_at(at)
		for row2: Dictionary in LAProcessSet.reduce_rows(at):
			for k in ["source", "aux", "aux2", "ref", "gate", "gate_aux"]:
				var name2: String = String(row2.get(k, ""))
				if name2 != "" and not have.has(name2):
					_absent += 1
					_say("Rung \"%s\" reduces \"%s\", which names \"%s\" that no pass there allocates."
						% [r2["name"], row2["key"], name2])
		for row3: Dictionary in LAProcessSet.transport_rows(at):
			for k2 in ["channel", "drive", "resist", "aux", "frac"]:
				var name3: String = String(row3.get(k2, ""))
				if name3 != "" and not have.has(name3):
					_absent += 1
					_say("Rung \"%s\" moves \"%s\", which names \"%s\" that no pass there allocates."
						% [r2["name"], row3["label"], name3])

	# The controls draw one entry per record, so every record has to be enumerable and unique.
	var seen: Dictionary = {}
	for rec: Dictionary in LAProcessSet.records():
		var id: String = LAProcessSet.record_id(rec)
		if seen.has(id):
			_duplicate += 1
			_say("Two process records share the id \"%s\"." % id)
		seen[id] = true
	var top: PackedStringArray = LAProcessSet.records_upto(LAProcessSet.TOP)
	if top.size() != LAProcessSet.records().size():
		_say("The top rung does not enumerate every process record.")

	LAProcessSet.declare(LAProcessSet.TOP)
	print('PROCESS_SET={"rungs":%d,"records":%d,"transport":%d,"reduce":%d,"unassigned":%d,"duplicate":%d,"absent_buffer":%d,"failures":%d}'
		% [LAProcessSet.rungs().size(), LAProcessSet.records().size(),
			LATransportRecords.rows().size(), LAReduceRecords.rows().size(),
			_unassigned, _duplicate, _absent, _fail])
	quit(1 if _fail > 0 else 0)
