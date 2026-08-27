extends SceneTree

const ROOT: String = "res://addons/local_agents"

# Every stage a .glsl in this tree could declare. A kernel is compute; the others are here so a future
# raster shader cannot slip through unchecked.
const STAGES: Array = [
	RenderingDevice.SHADER_STAGE_COMPUTE,
	RenderingDevice.SHADER_STAGE_VERTEX,
	RenderingDevice.SHADER_STAGE_FRAGMENT,
]

func _find(dir_path: String, out: Array) -> void:
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if d.current_is_dir():
			# Vendored GLSL is not ours and is not a Godot kernel: whisper.cpp ships ggml-vulkan
			# sources Godot never imports, so get_spirv() is null for all of them by construction.
			if name != "thirdparty":
				_find(full, out)
		elif name.ends_with(".glsl"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()

func _init() -> void:
	var files: Array = []
	_find(ROOT, files)
	files.sort()
	var failed: int = 0
	for path in files:
		var sf = load(path)
		if sf == null:
			# Almost always an UNIMPORTED kernel — the fresh-worktree trap. load() returns null, the pass
			# silently never runs, and the report still looks normal.
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"load() returned null (unimported?)\"}" % path)
			failed += 1
			continue
		if not sf.has_method("get_spirv"):
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"not an RDShaderFile\"}" % path)
			failed += 1
			continue
		var spirv = sf.get_spirv()
		if spirv == null:
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"get_spirv() returned null\"}" % path)
			failed += 1
			continue
		var bad: bool = false
		for stage in STAGES:
			var err: String = spirv.get_stage_compile_error(stage)
			if err != "":
				var first: String = err.split("\n")[0]
				print("SHADER_FAIL={\"file\":\"%s\",\"stage\":%d,\"why\":%s}" % [path, stage, JSON.stringify(first)])
				bad = true
		if bad:
			failed += 1
	print("SHADER_GATE={\"checked\":%d,\"failed\":%d}" % [files.size(), failed])
	quit(1 if failed > 0 else 0)
