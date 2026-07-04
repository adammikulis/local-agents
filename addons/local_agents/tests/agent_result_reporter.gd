@tool
extends RefCounted

# Emits a single machine-parseable line that scripts/agent_harness.sh and other
# tooling can grep to learn a harness run's outcome without scraping free text.
# Reporting-only helper: owns no simulation authority and takes no fallback path.
#
# Line format:
#   AGENT_TEST_RESULT={"suite":..,"status":"pass|fail","passed":N,"failed":M,
#                      "duration_s":..,"failures":[{"name":..,"reason":..}]}

const MARKER := "AGENT_TEST_RESULT"

static func format_result(suite: String, passed: int, failed: int, failures: Array, duration_s: float) -> String:
	var payload := {
		"suite": suite,
		"status": "pass" if failed == 0 else "fail",
		"passed": maxi(0, passed),
		"failed": maxi(0, failed),
		"duration_s": snappedf(maxf(0.0, duration_s), 0.001),
		"failures": _normalize_failures(failures),
	}
	return "%s=%s" % [MARKER, JSON.stringify(payload)]

static func emit(suite: String, passed: int, failed: int, failures: Array, duration_s: float) -> void:
	print(format_result(suite, passed, failed, failures, duration_s))

# Accepts either dictionaries ({name, reason}) or "name: reason" strings and
# normalizes to a uniform [{name, reason}] shape.
static func _normalize_failures(failures: Array) -> Array:
	var out: Array = []
	for entry in failures:
		if entry is Dictionary:
			out.append({
				"name": String((entry as Dictionary).get("name", "")),
				"reason": String((entry as Dictionary).get("reason", "")),
			})
			continue
		var text := String(entry)
		var name := text
		var reason := ""
		var sep := text.find(": ")
		if sep >= 0:
			name = text.substr(0, sep)
			reason = text.substr(sep + 2)
		out.append({"name": name, "reason": reason})
	return out
