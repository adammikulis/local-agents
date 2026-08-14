extends RefCounted

## Base for every field pass: device handle, kernel compilation, uniform sets, and RID ownership.

var _rd: RenderingDevice = null

var _owned_sets: Array[RID] = []
var _owned_pipes: Array[RID] = []
var _owned_shaders: Array[RID] = []      # parallel to _owned_pipes: the shader each pipeline was built from
var _owned_buffers: Array[RID] = []

var _ctx_missing: Dictionary = {}        # ctx key -> its absence has already been reported


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	if rd == null:
		push_error("%s: null RenderingDevice" % _label())
		return
	_rd = rd
	_setup(bufs, cc)


func _setup(_bufs: Dictionary, _cc: int) -> void:
	pass


## Buffers the DRIVER allocates into `bufs` before `_setup`, so they are driver-owned and readable back.
## Name -> element count, or -> {"n": count, "indirect": true} for a dispatch-indirect argument buffer.
func _buffers(_cc: int) -> Dictionary:
	return {}


## Readings taken at the drain, once the driver has synced. Key -> value; a float becomes a gauge.
func _drain(_rd: RenderingDevice) -> Dictionary:
	return {}


## Frees this pass's own RIDs, dependent-first. Buffers borrowed from `bufs` belong to the driver.
func dispose(rd: RenderingDevice) -> void:
	var dev: RenderingDevice = rd if rd != null else _rd
	if dev == null:
		return
	for group: Array in [_owned_sets, _owned_pipes, _owned_shaders, _owned_buffers]:
		for r: RID in group:
			if r.is_valid():
				dev.free_rid(r)
	_owned_sets.clear()
	_owned_pipes.clear()
	_owned_shaders.clear()
	_owned_buffers.clear()
	_rd = null


## Device bound and every pipeline compiled. An invalid one binds nothing and the next kernel then
## reads whatever was there.
func _dispatchable() -> bool:
	if _rd == null or _owned_pipes.is_empty():
		return false
	for p: RID in _owned_pipes:
		if not p.is_valid():
			return false
	return true


## Compute pipeline for a kernel; RID() on failure, naming the file and the reason.
func _kernel(path: String) -> RID:
	if _rd == null:
		return RID()
	var sf: RDShaderFile = load(path)
	if sf == null:
		push_error("%s: %s did not load. Run `godot --headless --path . --import`." % [_label(), path.get_file()])
		return RID()
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null:
		push_error("%s: %s has no SPIR-V." % [_label(), path.get_file()])
		return RID()
	var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err.is_empty():
		push_error("%s: %s failed to compile; this pass will not run.\n%s" % [_label(), path.get_file(), err])
		return RID()
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("%s: %s produced no shader." % [_label(), path.get_file()])
		return RID()
	var pipe: RID = _rd.compute_pipeline_create(shader)
	if not pipe.is_valid():
		push_error("%s: %s produced no compute pipeline." % [_label(), path.get_file()])
		_rd.free_rid(shader)
		return RID()
	_owned_shaders.append(shader)
	_owned_pipes.append(pipe)
	return pipe


func _shader_of(kernel: RID) -> RID:
	for i in _owned_pipes.size():
		if _owned_pipes[i] == kernel:
			return _owned_shaders[i]
	return RID()


## Uniform set 0 from [binding, rid] entries.
func _uset(kernel: RID, entries: Array) -> RID:
	var shader: RID = _shader_of(kernel)
	if _rd == null or not shader.is_valid():
		return RID()
	var uniforms: Array[RDUniform] = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	var s: RID = _rd.uniform_set_create(uniforms, shader, 0)
	if s.is_valid():
		_owned_sets.append(s)
	return s


func _storage_buffer(bytes: PackedByteArray) -> RID:
	if _rd == null:
		return RID()
	var r: RID = _rd.storage_buffer_create(bytes.size(), bytes)
	if r.is_valid():
		_owned_buffers.append(r)
	return r


func _scratch(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return _storage_buffer(a.to_byte_array())


## A channel or driver buffer -> its RID; RID() when unallocated.
func _single(bufs: Dictionary, key: String) -> RID:
	var v: Variant = bufs.get(key, RID())
	return v if v is RID else RID()


## A scalar the driver publishes into ctx. Absent is 0 and a named error, once per key.
func _ctx_num(ctx: Dictionary, key: String) -> float:
	if not ctx.has(key):
		if not _ctx_missing.has(key):
			_ctx_missing[key] = true
			push_error("%s: ctx carries no \"%s\"." % [_label(), key])
		return 0.0
	return float(ctx[key])


## Cells along the longest span of the grid, at least 1.
func _ctx_depth(ctx: Dictionary) -> int:
	return maxi(int(_ctx_num(ctx, "depth")), 1)


## Cell edge, model units.
func _ctx_cell_size(ctx: Dictionary) -> float:
	return _ctx_num(ctx, "cell_size")


func _label() -> String:
	var scr: Script = get_script() as Script
	if scr == null:
		return "SpherePass"
	return scr.resource_path.get_file().get_basename()
