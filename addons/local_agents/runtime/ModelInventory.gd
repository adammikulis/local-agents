@tool
extends RefCounted
class_name LocalAgentsModelInventory

# On-disk GGUF model discovery.
#
# Scans the places a player already keeps GGUF models so the game reuses them instead of forcing a
# redundant download:
#   - the local user models dir (LocalAgentsRuntimePaths.MODELS_USER_ROOT),
#   - the Hugging Face hub cache ($HF_HUB_CACHE, else $HF_HOME/hub, else ~/.cache/huggingface/hub),
#   - any extra folders the player points us at (persisted by LocalAgentsModelSettingsStore).
#
# Every hit is returned as a plain Dictionary row {path, filename, size_bytes, source, source_label}
# so the UI never has to know how the file was found. Matching a shipped-catalog model to a file on
# disk is by filename (the catalog filenames are unique, e.g. Qwen3-4B-Instruct-2507-Q4_K_M.gguf), so
# a model already sitting in the HF cache shows as "Installed (found in HF cache)" rather than a
# redundant download button.

const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

const SOURCE_USER: String = "user_models"
const SOURCE_HF: String = "hf_cache"
const SOURCE_FOLDER: String = "custom_folder"

# Human-facing labels for the source tags above.
const SOURCE_LABELS: Dictionary = {
	SOURCE_USER: "Local models folder",
	SOURCE_HF: "HF cache",
	SOURCE_FOLDER: "Custom folder",
}

# Guard rail so a mis-pointed folder cannot send us walking an entire home directory.
const MAX_SCAN_DEPTH: int = 8

# -- Cache-root resolution ----------------------------------------------------

# Returns the Hugging Face hub cache directory the CLI/hub library would use, honoring the standard
# env vars, or "" when none of the candidates exist on disk. Never creates anything.
static func hf_hub_cache_dir() -> String:
	var hub_cache: String = OS.get_environment("HF_HUB_CACHE").strip_edges()
	if hub_cache != "" and DirAccess.dir_exists_absolute(hub_cache):
		return hub_cache
	var hf_home: String = OS.get_environment("HF_HOME").strip_edges()
	if hf_home != "":
		var candidate: String = "%s/hub" % hf_home
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	var default_home: String = OS.get_environment("HOME").strip_edges()
	if default_home != "":
		var default_hub: String = "%s/.cache/huggingface/hub" % default_home
		if DirAccess.dir_exists_absolute(default_hub):
			return default_hub
	return ""

# -- Scanning -----------------------------------------------------------------

# Scans every known location and returns a de-duplicated list of GGUF rows. Extra_folders and
# hf_override are the player-configured paths (may be empty); absent paths are skipped silently so an
# unconfigured / cache-less machine simply yields fewer rows (never an error).
func scan(extra_folders: PackedStringArray = PackedStringArray(), hf_override: String = "") -> Array:
	var rows: Array = []
	var seen: Dictionary = {}

	var user_root: String = ProjectSettings.globalize_path(RuntimePaths.MODELS_USER_ROOT)
	_scan_tree(user_root, SOURCE_USER, rows, seen, 0)

	var hf_root: String = hf_override.strip_edges()
	if hf_root == "" or not DirAccess.dir_exists_absolute(hf_root):
		hf_root = hf_hub_cache_dir()
	if hf_root != "":
		_scan_tree(hf_root, SOURCE_HF, rows, seen, 0)

	for folder: String in extra_folders:
		var trimmed: String = folder.strip_edges()
		if trimmed != "" and DirAccess.dir_exists_absolute(trimmed):
			_scan_tree(trimmed, SOURCE_FOLDER, rows, seen, 0)

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("filename", "")).nocasecmp_to(String(b.get("filename", ""))) < 0
	)
	return rows

# Returns the first on-disk path whose filename matches (case-insensitive), or "" when the file is
# not present anywhere. Used to answer "is this catalog model already usable in place?".
func find_file(filename: String, extra_folders: PackedStringArray = PackedStringArray(), hf_override: String = "") -> Dictionary:
	var target: String = filename.strip_edges().to_lower()
	if target == "":
		return {}
	for row: Dictionary in scan(extra_folders, hf_override):
		if String(row.get("filename", "")).to_lower() == target:
			return row
	return {}

func _scan_tree(root_abs: String, source: String, rows: Array, seen: Dictionary, depth: int) -> void:
	if depth > MAX_SCAN_DEPTH:
		return
	var dir: DirAccess = DirAccess.open(root_abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full: String = "%s/%s" % [root_abs, entry]
		if dir.current_is_dir():
			_scan_tree(full, source, rows, seen, depth + 1)
		elif entry.to_lower().ends_with(".gguf"):
			_append_file(full, entry, source, rows, seen)
		entry = dir.get_next()
	dir.list_dir_end()

func _append_file(full_path: String, filename: String, source: String, rows: Array, seen: Dictionary) -> void:
	# Resolve symlinks (the HF cache stores real bytes under blobs/ and links them into snapshots/).
	var canonical: String = full_path
	if seen.has(canonical):
		return
	seen[canonical] = true
	var size_bytes: int = 0
	var file: FileAccess = FileAccess.open(full_path, FileAccess.READ)
	if file != null:
		size_bytes = int(file.get_length())
		file.close()
	rows.append({
		"path": full_path,
		"filename": filename,
		"size_bytes": size_bytes,
		"source": source,
		"source_label": String(SOURCE_LABELS.get(source, source)),
	})

# -- Self-test ----------------------------------------------------------------

# Headless proof of HF-cache detection: builds a throwaway fake cache with the canonical
# models--org--name/snapshots/<rev>/<file>.gguf layout plus a stray non-gguf, scans it, and asserts
# exactly the gguf is found and tagged as an HF-cache hit.
static func run_selftest() -> Dictionary:
	var base: String = "%s/la_inventory_selftest_%d" % [OS.get_environment("TMPDIR").rstrip("/"), Time.get_ticks_usec()]
	if base.begins_with("/la_inventory") or base == "":
		base = "%s/la_inventory_selftest_%d" % ["/tmp", Time.get_ticks_usec()]
	var snap_dir: String = "%s/models--acme--demo-GGUF/snapshots/abc123" % base
	DirAccess.make_dir_recursive_absolute(snap_dir)
	var gguf_path: String = "%s/Demo-Model-Q4_K_M.gguf" % snap_dir
	var writer: FileAccess = FileAccess.open(gguf_path, FileAccess.WRITE)
	var gguf_written: bool = false
	if writer != null:
		var blob: PackedByteArray = PackedByteArray()
		blob.resize(2048)
		writer.store_buffer(blob)
		writer.close()
		gguf_written = true
	var stray: FileAccess = FileAccess.open("%s/config.json" % snap_dir, FileAccess.WRITE)
	if stray != null:
		stray.store_string("{}")
		stray.close()

	var inventory: LocalAgentsModelInventory = LocalAgentsModelInventory.new()
	var rows: Array = inventory.scan(PackedStringArray(), base)
	# The scan also covers the real user-models folder on this machine; restrict correctness checks to
	# the throwaway fake cache we just built so pre-existing local models don't skew the assertions.
	var from_fake: Array = []
	for row: Dictionary in rows:
		if String(row.get("path", "")).begins_with(base):
			from_fake.append(row)
	var found: Dictionary = {}
	for row: Dictionary in from_fake:
		if String(row.get("filename", "")) == "Demo-Model-Q4_K_M.gguf":
			found = row
			break
	var found_hit: bool = not found.is_empty()
	var tagged_hf: bool = found_hit and String(found.get("source", "")) == SOURCE_HF
	var right_size: bool = found_hit and int(found.get("size_bytes", 0)) == 2048
	# Exactly one gguf under the fake cache -> the stray config.json was ignored.
	var only_gguf: bool = from_fake.size() == 1

	var lookup: Dictionary = inventory.find_file("demo-model-q4_k_m.gguf", PackedStringArray(), base)
	var lookup_ok: bool = not lookup.is_empty()
	var lookup_miss: bool = inventory.find_file("nope.gguf", PackedStringArray(), base).is_empty()

	_remove_tree(base)

	var checks: Dictionary = {
		"gguf_written": gguf_written,
		"found_cached_gguf": found_hit,
		"tagged_as_hf_cache": tagged_hf,
		"reported_real_size": right_size,
		"ignored_non_gguf": only_gguf,
		"find_file_hit": lookup_ok,
		"find_file_miss": lookup_miss,
	}
	var ok: bool = true
	for key: String in checks:
		if not bool(checks[key]):
			ok = false
	return {"ok": ok, "checks": checks, "rows": from_fake}

static func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = "%s/%s" % [path, entry]
			if dir.current_is_dir():
				_remove_tree(full)
			else:
				DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
