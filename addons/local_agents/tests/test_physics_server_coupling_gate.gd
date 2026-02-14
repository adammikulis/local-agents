@tool
extends RefCounted

const BRIDGE_SCRIPT_PATH := "res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd"
const SIM_SOURCE_DIR := "res://addons/local_agents/simulation"
const EXT_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/src"
const INCLUDE_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/include"
const ARCHITECTURE_PLAN_PATH := "res://ARCHITECTURE_PLAN.md"
const SOURCE_DIRS := [
	SIM_SOURCE_DIR,
	EXT_SOURCE_DIR,
	INCLUDE_SOURCE_DIR,
]
const BLOCKER_ID := "PHYSICS_SERVER3D_CONTACT_DIVERGENCE"
const FORBIDDEN_PATTERNS := [
	"body_get_direct_state",
	"get_contact_count",
	"get_contact_impulse",
	"get_contact_local_position",
	"get_contact_local_normal",
	"get_contact_collider_position",
	"get_contact_collider_normal",
	"get_contact_collider_id",
	"get_contact_collider",
	"get_contact_local_velocity_at_position",
	"PhysicsDirectBodyState3D",
	"get_contact_collider_object",
]
const TARGET_EXTS := [".gd", ".gdshader", ".cpp", ".cc", ".h", ".hpp"]
const BLOCKER_HEADER_PREFIX := "- [x] Approved blocker:"
const BLOCKER_EXPIRES_PREFIX := "  - Expires:"
const BLOCKER_REASON_MISSING := "missing"
const BLOCKER_REASON_EXPIRED := "expired"
const BLOCKER_REASON_INVALID_EXPIRY := "invalid_expiry"
const BLOCKER_REASON_NO_PLAN := "plan_unreadable"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _assert(FileAccess.file_exists(BRIDGE_SCRIPT_PATH), "Required bridge script must remain present at %s." % BRIDGE_SCRIPT_PATH) and ok

	var violations: Array[String] = []
	for source_dir in SOURCE_DIRS:
		var source_files := _collect_source_files(source_dir)
		for source_file in source_files:
			if source_file == BRIDGE_SCRIPT_PATH:
				continue
			var source_lines := _read_source_lines(source_file)
			if source_lines.is_empty():
				ok = false
				continue
			for pattern in FORBIDDEN_PATTERNS:
				var hits := _scan_pattern_hits(source_file, source_lines, pattern)
				violations.append_array(hits)

	if not violations.is_empty():
		var blocker_state := _get_blocker_state()
		if not blocker_state["ok"]:
			ok = _assert(
				false,
				"PHYSICS_SERVER_COUPLING_GATE code=PSC-001 status=blocked test=addons/local_agents/tests/test_physics_server_coupling_gate.gd plan=ARCHITECTURE_PLAN.md blocker=%s reason=%s expires=%s\n%s"
				% [BLOCKER_ID, blocker_state["reason"], blocker_state["expires"], "\n".join(violations)]
			)
		else:
			print(
				"PHYSICS_SERVER_COUPLING_GATE code=PSC-001 status=bypassed test=addons/local_agents/tests/test_physics_server_coupling_gate.gd blocker=%s expires=%s"
				% [BLOCKER_ID, blocker_state["expires"]]
			)

	if ok:
		print("Physics server coupling gate passed (bridge-only contact-coupling patterns).")
	return ok

func _scan_pattern_hits(path: String, lines: PackedStringArray, pattern: String) -> Array[String]:
	var hits: Array[String] = []
	var line_number := 1
	for line in lines:
		if line.find(pattern) != -1:
			hits.append("%s:%d => %s" % [path, line_number, pattern])
		line_number += 1
	return hits

func _collect_source_files(base_path: String) -> PackedStringArray:
	var files := PackedStringArray()
	var dir := DirAccess.open(base_path)
	if dir == null:
		_assert(false, "Failed to open source directory: %s" % base_path)
		return files

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var path := base_path.path_join(entry)
		if dir.current_is_dir():
			files.append_array(_collect_source_files(path))
		else:
			if _is_target_ext(path):
				files.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	files.sort()
	return files

func _read_source_lines(path: String) -> PackedStringArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source file: %s" % path)
		return PackedStringArray()
	return file.get_as_text().split("\n")

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _is_target_ext(path: String) -> bool:
	for ext in TARGET_EXTS:
		if path.ends_with(ext):
			return true
	return false

func _get_blocker_state() -> Dictionary:
	var state := {
		"ok": false,
		"reason": BLOCKER_REASON_MISSING,
		"expires": "",
	}
	var plan := _read_source_lines(ARCHITECTURE_PLAN_PATH)
	if plan.is_empty():
		state["reason"] = BLOCKER_REASON_NO_PLAN
		return state

	var blocker_line := _find_blocker_line(plan)
	if blocker_line == -1:
		state["reason"] = BLOCKER_REASON_MISSING
		return state

	var parsed := _read_blocker_expiry(plan, blocker_line)
	if not parsed["ok"]:
		state["reason"] = parsed["reason"]
		state["expires"] = parsed.get("expires", "")
		return state

	var expiry := String(parsed["expires"])
	state["expires"] = expiry
	var today := _today_iso_date()
	if today == "":
		state["reason"] = "system_time_unavailable"
		return state

	if _compare_iso_dates(today, expiry) <= 0:
		state["ok"] = true
		state["reason"] = "active"
	else:
		state["reason"] = BLOCKER_REASON_EXPIRED
	return state

func _find_blocker_line(lines: PackedStringArray) -> int:
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.begins_with(BLOCKER_HEADER_PREFIX):
			if line.find(BLOCKER_ID) != -1:
				var trailer := line.substr(BLOCKER_HEADER_PREFIX.length()).strip_edges()
				if trailer == BLOCKER_ID or trailer.begins_with(BLOCKER_ID + " "):
					return i
	return -1

func _read_blocker_expiry(lines: PackedStringArray, start_index: int) -> Dictionary:
	var state := {
		"ok": false,
		"reason": BLOCKER_REASON_MISSING,
		"expires": "",
	}
	var i := start_index + 1
	while i < lines.size():
		var line := lines[i]
		var trimmed := line.strip_edges()
		if trimmed.begins_with("- ") and not line.begins_with("  -"):
			break
		if trimmed.begins_with(BLOCKER_EXPIRES_PREFIX.strip_edges()):
			var payload := trimmed.substr(BLOCKER_EXPIRES_PREFIX.strip_edges().length())
			payload = payload.strip_edges()
			if payload.begins_with(":"):
				payload = payload.substr(1).strip_edges()
			var normalized := _normalize_iso_date(payload)
			if normalized == "":
				state["reason"] = BLOCKER_REASON_INVALID_EXPIRY
				state["expires"] = payload
				return state
			state["ok"] = true
			state["reason"] = "ok"
			state["expires"] = normalized
			return state
		i += 1
	state["reason"] = BLOCKER_REASON_MISSING
	return state

func _normalize_iso_date(value: String) -> String:
	var parts := value.strip_edges().split("-")
	if parts.size() != 3:
		return ""
	if parts[0].length() != 4 or parts[1].length() != 2 or parts[2].length() != 2:
		return ""
	if int(parts[0]) <= 0 or int(parts[1]) <= 0 or int(parts[2]) <= 0:
		return ""
	if int(parts[1]) > 12 or int(parts[2]) > 31:
		return ""
	return "%s-%s-%s" % [parts[0], parts[1], parts[2]]

func _today_iso_date() -> String:
	return Time.get_date_string_from_system(false)

func _compare_iso_dates(left: String, right: String) -> int:
	var l := left.split("-")
	var r := right.split("-")
	if l.size() != 3 or r.size() != 3:
		return 1
	var l_year := int(l[0]); var r_year := int(r[0])
	var l_month := int(l[1]); var r_month := int(r[1])
	var l_day := int(l[2]); var r_day := int(r[2])
	if l_year < r_year:
		return -1
	if l_year > r_year:
		return 1
	if l_month < r_month:
		return -1
	if l_month > r_month:
		return 1
	if l_day < r_day:
		return -1
	if l_day > r_day:
		return 1
	return 0
