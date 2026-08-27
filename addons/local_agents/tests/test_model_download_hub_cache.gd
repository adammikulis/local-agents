@tool
extends RefCounted

const ModelDownloadManagerScript := preload("res://addons/local_agents/ui/ModelDownloadManager.gd")

func run_test(tree: SceneTree) -> bool:
	var ok := true
	ok = ok and _test_find_and_link_roundtrip(tree)
	ok = ok and _test_real_hub_cache_hit_if_present(tree)
	if ok:
		print("Model download hub-cache test passed")
	else:
		push_error("Model download hub-cache assertions failed")
	return ok

# Builds a throwaway hub cache under a temp HF_HOME, then checks that the manager's private
# lookup finds a snapshot file and that its link helper produces a real link (not a stale copy).
func _test_find_and_link_roundtrip(tree: SceneTree) -> bool:
	var manager: Node = ModelDownloadManagerScript.new()
	tree.root.add_child(manager)

	var tmp_root: String = ProjectSettings.globalize_path("user://hub_cache_test_tmp")
	DirAccess.remove_absolute(tmp_root)
	var repo_dir: String = tmp_root.path_join("hub/models--test--repo")
	var blob_path: String = repo_dir.path_join("blobs/deadbeef")
	var snap_dir: String = repo_dir.path_join("snapshots/abc123")
	DirAccess.make_dir_recursive_absolute(snap_dir)
	DirAccess.make_dir_recursive_absolute(blob_path.get_base_dir())
	var blob_file: FileAccess = FileAccess.open(blob_path, FileAccess.WRITE)
	blob_file.store_string("fake model bytes")
	blob_file.close()
	var link_ok: bool = manager.call("_link_or_copy", blob_path, snap_dir.path_join("model.gguf"))

	var prev_hf_home: String = OS.get_environment("HF_HOME")
	OS.set_environment("HF_HOME", tmp_root)
	var found: String = manager.call("_find_in_hub_cache", "test/repo", "model.gguf")
	var missing: String = manager.call("_find_in_hub_cache", "test/repo", "does-not-exist.gguf")

	var ok := true
	ok = ok and link_ok
	ok = ok and found == snap_dir.path_join("model.gguf")
	ok = ok and missing == ""

	# Prove the snapshot entry is a real link to the blob, not an independent copy: change the
	# blob's content and confirm the snapshot file reads the new bytes.
	var rewrite: FileAccess = FileAccess.open(blob_path, FileAccess.WRITE)
	rewrite.store_string("changed bytes")
	rewrite.close()
	var snap_read: FileAccess = FileAccess.open(snap_dir.path_join("model.gguf"), FileAccess.READ)
	var snap_text: String = snap_read.get_as_text() if snap_read != null else ""
	if snap_read != null:
		snap_read.close()
	ok = ok and snap_text == "changed bytes"

	if not ok:
		push_error("roundtrip failed: link_ok=%s found=%s missing=%s snap_text=%s" % [link_ok, found, missing, snap_text])

	OS.set_environment("HF_HOME", prev_hf_home)
	DirAccess.remove_absolute(tmp_root)
	manager.queue_free()
	return ok

# Checks filesystem state right after start_download() returns rather than awaiting the
# (deferred) completion signal. Skips, rather than fails, if this model isn't already cached.
func _test_real_hub_cache_hit_if_present(tree: SceneTree) -> bool:
	var manager: Node = ModelDownloadManagerScript.new()
	tree.root.add_child(manager)

	var probe: String = manager.call("_find_in_hub_cache", "unsloth/functiongemma-270m-it-GGUF", "functiongemma-270m-it-Q8_0.gguf")
	if probe == "":
		print("skip: unsloth/functiongemma-270m-it-GGUF not present in this machine's hub cache")
		manager.queue_free()
		return true

	var started: bool = manager.start_download("functiongemma-270m-it-q8_0")
	var still_downloading: bool = manager.is_downloading()
	var installed_path: String = manager.installed_path("functiongemma-270m-it-q8_0")

	var ok := true
	ok = ok and started
	ok = ok and not still_downloading
	ok = ok and installed_path != ""
	ok = ok and FileAccess.file_exists(installed_path)
	if not ok:
		push_error("real hub-cache hit failed: started=%s still_downloading=%s installed_path=%s" % [started, still_downloading, installed_path])

	manager.queue_free()
	return ok
