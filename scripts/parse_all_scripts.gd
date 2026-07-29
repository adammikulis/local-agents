extends SceneTree

## Force every .gd under a root to actually load, and report the ones that fail.
##
## Why this exists. An editor scan only loads what something references, so a script nothing
## instantiates can carry a broken `preload` and never be looked at. scripts/check_library_only.sh
## staged a game-free tree, scanned it, printed OK, and missed exactly that: sim/streamer/
## StreamerHost.gd preloads game/ui/SceneEnergyGraph.gd, which the staging had just deleted. Three
## separate reviews found the hole before the gate did.
##
## load() on a GDScript with an unresolvable preload or a parse error returns null, so calling it on
## every file in one process is a real parse gate and costs one startup instead of several hundred.
##
##   godot --headless --path <project> -s scripts/parse_all_scripts.gd -- --root=res://addons/local_agents
##
## Prints PARSE_ALL={"checked":N,"failed":N,"failures":[...]} and exits non-zero on any failure.
## (Explicit types only, project rule: no ':=' inferred typing.)

const DEFAULT_ROOT: String = "res://addons/local_agents"

# Directories whose scripts are not part of the shipped surface. tests/ carries a .gdignore so it is
# skipped anyway in a consumer project, and the build tree under gdextensions/ holds vendored code.
# A plain Array, not PackedStringArray(...): a constructor call is not a constant expression.
const SKIP_DIRS: Array = [
	"/tests", "/gdextensions/localagents/thirdparty", "/gdextensions/localagents/build",
	"/gdextensions/localagents/build_native", "/.cache",
]


func _initialize() -> void:
	var root: String = DEFAULT_ROOT
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.substr(7)

	var scripts: PackedStringArray = PackedStringArray()
	_collect(root, scripts)

	# Loading is what MAKES the engine parse each file. It is not what detects the failure: measured
	# 2026-07-29, load() on a script whose preload target is missing prints
	# `SCRIPT ERROR: Parse Error: Preload file "..." does not exist.` and still returns a non-null
	# Script. So the caller greps this run's stderr, and the null check below only catches the harder
	# failures where the engine gives back nothing at all.
	var failures: PackedStringArray = PackedStringArray()
	for path in scripts:
		var res: Resource = load(path)
		if res == null:
			failures.append(path)

	var payload: Dictionary = {
		"root": root,
		"checked": scripts.size(),
		"failed": failures.size(),
		"failures": Array(failures),
	}
	print("PARSE_ALL=%s" % JSON.stringify(payload))
	quit(1 if failures.size() > 0 else 0)


func _collect(dir_path: String, out: PackedStringArray) -> void:
	for skip in SKIP_DIRS:
		if dir_path.ends_with(skip) or dir_path.contains(skip + "/"):
			return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
