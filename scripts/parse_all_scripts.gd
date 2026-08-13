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

# Directories holding code that is not ours to parse: vendored third party and build trees.
#
# tests/ WAS skipped here, on the ground that it carries a .gdignore and so is absent from a consumer
# project. That is true of the shipped surface and irrelevant to whether a test parses. Two tests sat on
# the dev branch with hard parse errors -- a constant declared twice, and a reference to a constant the
# enthalpy collapse deleted -- while this gate reported green, because the one command that would have
# caught them is the test lane, and that is not in lint.
# A plain Array, not PackedStringArray(...): a constructor call is not a constant expression.
const SKIP_DIRS: Array = [
	"/gdextensions/localagents/thirdparty", "/gdextensions/localagents/build",
	"/gdextensions/localagents/build_native", "/.cache",
]


func _initialize() -> void:
	var root: String = DEFAULT_ROOT
	# --skip-tests is for the LIBRARY-ONLY staging, where game/ is deleted and the GDExtension is not
	# loaded, so a test that drives either cannot parse there and its failing to is not a finding. In the
	# real project tests ARE swept: a test that does not parse cannot run.
	var skip_tests: bool = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.substr(7)
		elif arg == "--skip-tests":
			skip_tests = true

	var scripts: PackedStringArray = PackedStringArray()
	_collect(root, scripts)
	if skip_tests:
		var kept: PackedStringArray = PackedStringArray()
		for path in scripts:
			if not (path.contains("/tests/")):
				kept.append(path)
		scripts = kept

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

	# Zero scripts is never a pass. _collect() returns quietly when the root does not exist, so a typo in
	# --root, a staging step that failed to copy, or a directory rename all yield checked:0 / failed:0 —
	# which reads exactly like a clean sweep to every caller. Exit 2 (the repo's "gate could not run"
	# code, distinct from a real failure's 1) so the callers' own guards are a second line and not the
	# only one.
	if scripts.size() == 0:
		printerr("parse_all_scripts: found no .gd files under %s — nothing was parsed." % root)
		quit(2)
		return
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
