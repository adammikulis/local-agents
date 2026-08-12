extends RefCounted

## Base for every field pass module. It owns the RenderingDevice handle, compiles kernels, builds uniform
## sets, resolves channel buffers out of the driver's `bufs`, and frees every RID it handed out.

var _rd: RenderingDevice = null

var _owned_sets: Array[RID] = []
var _owned_pipes: Array[RID] = []
var _owned_shaders: Array[RID] = []      # parallel to _owned_pipes: the shader each pipeline was built from
var _owned_buffers: Array[RID] = []

var _ctx_missing: Dictionary = {}        # ctx key -> its absence has already been reported


## Driver entry point: bind the device, then run the subclass's setup.
func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	if rd == null:
		push_error("%s: null RenderingDevice" % _label())
		return
	_rd = rd
	_setup(bufs, cc)


## Subclass hook. Compile kernels and build uniform sets here.
func _setup(_bufs: Dictionary, _cc: int) -> void:
	pass


## Free every RID this pass created, dependent-first: uniform sets, pipelines, shaders, then scratch buffers.
## Buffers taken from the driver's `bufs` are borrowed and are freed by the driver.
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


## True when the device is bound and every pipeline this pass compiled is valid. A pass whose kernel failed
## to compile must not record anything: an invalid pipeline binds nothing and the kernels after it in the
## list read whatever was already there.
func _dispatchable() -> bool:
	if _rd == null or _owned_pipes.is_empty():
		return false
	for p: RID in _owned_pipes:
		if not p.is_valid():
			return false
	return true


# --- kernels ---------------------------------------------------------------------------------------------

## Load, compile and pipeline a compute kernel. RID() on failure, naming the file and the reason: a kernel
## that does not compile loads as null and its pass then silently does nothing.
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


## The shader a kernel's uniform sets are built against.
func _shader_of(kernel: RID) -> RID:
	for i in _owned_pipes.size():
		if _owned_pipes[i] == kernel:
			return _owned_shaders[i]
	return RID()


## Storage-buffer uniform set at set 0 for a kernel from `_kernel`, from [binding, rid] entries.
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


# --- buffers ---------------------------------------------------------------------------------------------

## Storage buffer holding `bytes`, owned by this pass.
func _storage_buffer(bytes: PackedByteArray) -> RID:
	if _rd == null:
		return RID()
	var r: RID = _rd.storage_buffer_create(bytes.size(), bytes)
	if r.is_valid():
		_owned_buffers.append(r)
	return r


## Zero-filled float32 scratch of `n` cells, owned by this pass.
func _scratch(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return _storage_buffer(a.to_byte_array())


# --- channels --------------------------------------------------------------------------------------------

## SINGLE channel -> its RID. RID() when the driver did not allocate it.
func _single(bufs: Dictionary, key: String) -> RID:
	var v: Variant = bufs.get(key, RID())
	return v if v is RID else RID()


## PAIR channel -> [half 0, half 1]. Two invalid RIDs when the driver did not allocate it.
func _pair(bufs: Dictionary, key: String) -> Array:
	var v: Variant = bufs.get(key, null)
	if v is Array and (v as Array).size() >= 2:
		return v
	return [RID(), RID()]


## Many channels at once: each SINGLE name -> its RID, each PAIR name -> [half 0, half 1].
## Keyed by channel name, so a binding list reads `b["solid"]` / `b["water"][back]`.
func _rids(bufs: Dictionary, singles: PackedStringArray, pairs: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for key in singles:
		out[key] = _single(bufs, key)
	for key in pairs:
		out[key] = _pair(bufs, key)
	return out


## PAIR channel -> the live half at parity `p` when `back` is false, the other half when true.
## SINGLE channel -> its bare RID either way.
func _half(bufs: Dictionary, key: String, p: int, back: bool) -> RID:
	var v: Variant = bufs.get(key, null)
	if v is Array and (v as Array).size() >= 2:
		return (v as Array)[1 - p] if back else (v as Array)[p]
	return v if v is RID else RID()


# --- grid geometry ---------------------------------------------------------------------------------------

## A scalar the driver publishes into ctx before any pass dispatches. Absent means 0 and a named error, once
## per key: inventing a size silently changes the physics of every gather that reads it.
func _ctx_num(ctx: Dictionary, key: String) -> float:
	if not ctx.has(key):
		if not _ctx_missing.has(key):
			_ctx_missing[key] = true
			push_error("%s: ctx carries no \"%s\"." % [_label(), key])
		return 0.0
	return float(ctx[key])


## Radial shells per column, at least 1.
func _ctx_depth(ctx: Dictionary) -> int:
	return maxi(int(_ctx_num(ctx, "depth")), 1)


## Radial thickness of one shell, model units.
func _ctx_cell_size(ctx: Dictionary) -> float:
	return _ctx_num(ctx, "cell_size")


## Shell floor, model units.
func _ctx_core_radius(ctx: Dictionary) -> float:
	return _ctx_num(ctx, "core_radius")


# --- push constants --------------------------------------------------------------------------------------

## { uint cell_count; uint pad0; uint pad1; uint pad2; } — 16 bytes.
func _pc_cells(cc: int) -> PackedByteArray:
	return PackedInt32Array([cc, 0, 0, 0]).to_byte_array()


# --- identity --------------------------------------------------------------------------------------------

## This pass's file name, for error messages.
func _label() -> String:
	var scr: Script = get_script() as Script
	if scr == null:
		return "SpherePass"
	return scr.resource_path.get_file().get_basename()
