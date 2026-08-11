extends RefCounted

## nbr is the int32 cc*6 neighbour table on binding 15 (slot 0 = inward/down .. slot 5 = outward/up).

const KDIR: String = "res://addons/local_agents/sim/material/kernels3d/"
const FERT_PATH: String = KDIR + "fert_sphere3d.glsl"
const FUNGUS_PATH: String = KDIR + "fungus_sphere3d.glsl"
const FUNGUS_FERT_PATH: String = KDIR + "fungus_fert_sphere3d.glsl"
const SHOCK_PATH: String = KDIR + "shock_sphere3d.glsl"

var _rd: RenderingDevice = null

# Compiled shaders (kept so their RIDs stay owned for the pipelines' lifetime).
var _fert_shader: RID = RID()
var _fungus_shader: RID = RID()
var _fungus_fert_shader: RID = RID()
var _shock_shader: RID = RID()

# Compute pipelines.
var _fert_pipe: RID = RID()
var _fungus_pipe: RID = RID()
var _fungus_fert_pipe: RID = RID()
var _shock_pipe: RID = RID()

# Uniform sets, one per ping-pong parity.
var _fert_set: Array = [RID(), RID()]
var _fungus_set: Array = [RID(), RID()]
var _fungus_fert_set: Array = [RID(), RID()]
var _shock_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("EcoSurfacePass: null RenderingDevice")
		return

	# --- Compile the kernels -------------------------------------------------------
	_fert_shader = _compile(FERT_PATH)
	_fert_pipe = _rd.compute_pipeline_create(_fert_shader)
	_fungus_shader = _compile(FUNGUS_PATH)
	_fungus_pipe = _rd.compute_pipeline_create(_fungus_shader)
	_fungus_fert_shader = _compile(FUNGUS_FERT_PATH)
	_fungus_fert_pipe = _rd.compute_pipeline_create(_fungus_fert_shader)
	_shock_shader = _compile(SHOCK_PATH)
	_shock_pipe = _rd.compute_pipeline_create(_shock_shader)

	# --- Resolve the shared SINGLE buffers once ------------------------------------
	var solid_rid: RID = _single(bufs, "solid")
	var nbr_rid: RID = _single(bufs, "nbr")
	var vel_x_rid: RID = _single(bufs, "vel_x")
	var vel_z_rid: RID = _single(bufs, "vel_z")
	var vel_y_rid: RID = _single(bufs, "vel_y")
	var ltan_rid: RID = _single(bufs, "link_tan")
	var detritus_rid: RID = _single(bufs, "detritus")
	var fungus_fert_rid: RID = _single(bufs, "fungus_fert")  # per-cell fertility scratch (written by ReactionsPass' decompose record, reduced by fungus_fert)

	# --- PAIR channels: [live, back] indexed by parity -----------------------------
	var fert_pair: Array = _pair(bufs, "fert")
	var fungus_pair: Array = _pair(bufs, "fungus")
	var temp_pair: Array = _pair(bufs, "temp")
	# The ONE unified atmospheric-water channel (Phase 2a). Fungus reads it as local moisture (the suspended
	# total is the behavioural proxy, perf-over-parity); snow deposition freezes its condensed part out to snow.
	var moisture_pair: Array = _pair(bufs, "moisture")
	# now and only the gauges read it. See the fungus kernel's FIRE note for why the gate came out.
	var shock_pair: Array = _pair(bufs, "shock")


	# --- One uniform set per parity for every PAIR-touching kernel -----------------
	for p in 2:
		var back: int = 1 - p

		_fert_set[p] = _build_set(_fert_shader, [
			[0, fert_pair[p]],       # FertIn  = live fertility
			[1, fert_pair[back]],    # FertOut = back fertility (fungus_fert then adds into THIS)
			[15, nbr_rid],
		])

		# Decompose chemistry moved to ReactionsPass → this kernel no longer binds CO2/O2 or writes fert scratch.
		_fungus_set[p] = _build_set(_fungus_shader, [
			[0, fungus_pair[p]],     # FungIn  = live fungus
			[1, fungus_pair[back]],  # FungOut = back fungus
			[2, detritus_rid],       # Detritus (SINGLE, read-only — decompose record owns the debit)
			[5, temp_pair[p]],       # Temp  (live, read)
			[6, moisture_pair[p]],   # Moisture = the unified airborne-H₂O channel (live, read)
			[8, solid_rid],          # Solid   (7 = Fire is gone; the gap is deliberate)
			[15, nbr_rid],
		])

		_fungus_fert_set[p] = _build_set(_fungus_fert_shader, [
			[0, fungus_fert_rid],    # FertCell = the per-cell scratch fungus just wrote
			[1, fert_pair[back]],    # Fert = fert's output (fert[back]), added into in place
			[2, solid_rid],          # Solid
			[15, nbr_rid],
		])

		# Snow DEPOSITION (snowfall): freeze the CONDENSED moisture on cold ground → snow, mass-conserving. Reads
		
		_shock_set[p] = _build_set(_shock_shader, [
			[0, shock_pair[p]],      # ShockIn  = live shock
			[1, shock_pair[back]],   # ShockOut = back shock
			[2, solid_rid],          # Solid
			[15, nbr_rid],
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	var precip: float = float(ctx.get("precip", 0.0))
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	var cell_m: float = float(ctx.get("cell_size", 1.0)) * LAPhysical.METRES_PER_MODEL_UNIT
	var k_courant: float = LAMaterialFieldSphereStep3D.real_seconds_per_step() / cell_m if cell_m != 0.0 else 0.0

	# Order: fert -> fungus -> fungus_fert -> shock.
	_run(rd, cl, _fert_pipe, _fert_set[parity], _pc_precip16(cc, precip), groups)
	_run(rd, cl, _fungus_pipe, _fungus_set[parity], _pc_precip32(cc, precip), groups)
	_run(rd, cl, _fungus_fert_pipe, _fungus_fert_set[parity], _pc_u4(cc), groups)
	_run(rd, cl, _shock_pipe, _shock_set[parity], _pc_u4(cc), groups)


## Free every RID this pass owns (uniform sets, then pipelines, then shaders), dependent-first, before the
## driver drops the local RenderingDevice. All buffer bindings are borrowed from the driver's bufs (none owned here).
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in [_fert_set, _fungus_set,
			_fungus_fert_set, _shock_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_fert_set = [RID(), RID()]
	_fungus_set = [RID(), RID()]
	_fungus_fert_set = [RID(), RID()]
	_shock_set = [RID(), RID()]
	for r: RID in [_fert_pipe, _fungus_pipe,
			_fungus_fert_pipe, _shock_pipe,
_fert_shader, _fungus_shader,
			_fungus_fert_shader, _shock_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_fert_pipe = RID()
	_fungus_pipe = RID()
	_fungus_fert_pipe = RID()
	_shock_pipe = RID()
	_fert_shader = RID()
	_fungus_shader = RID()
	_fungus_fert_shader = RID()
	_shock_shader = RID()


# tracer_transport push: { cell_count, depth, k, settle_v, diffuse, deposit, offset, decay }.
func _pc_tracer(cc: int, depth: int, k: float, settle_v: float, diffuse: float,
		offset: int, decay: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k)
	pc.encode_float(12, settle_v)
	pc.encode_float(16, diffuse)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, offset)
	pc.encode_float(28, decay)
	return pc


# --- helpers ------------------------------------------------------------------

## Records one single-pass CA into the open compute list, then a barrier so its writes are ordered ahead
## of the next kernel that reads them.
func _run(rd: RenderingDevice, cl: int, pipe: RID, uset: RID, pc: PackedByteArray, groups: int) -> void:
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _compile(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	return _rd.shader_create_from_spirv(sf.get_spirv())


## Builds a uniform set from a list of [binding, rid] pairs bound to the shader's set 0.
func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var binding: int = e[0]
		var buf: RID = e[1]
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = binding
		u.add_id(buf)
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


## SINGLE channel -> bare RID (RID() if absent).
func _single(bufs: Dictionary, key: String) -> RID:
	var v = bufs.get(key, RID())
	if v is RID:
		return v
	return RID()


## PAIR channel -> [live, back] array; a benign 2-RID array if absent.
func _pair(bufs: Dictionary, key: String) -> Array:
	var v = bufs.get(key, null)
	if v is Array and v.size() >= 2:
		return v
	return [RID(), RID()]


## Snow-depth field (no documented contract key). Prefer bufs["snow"] (a bare RID, or the parity half if the
## driver ever stores it as a PAIR); otherwise fall back to the live half of the "susp" PAIR. See header note.
func _snow_rid(bufs: Dictionary, p: int) -> RID:
	if bufs.has("snow"):
		var s = bufs["snow"]
		if s is Array and s.size() >= 2:
			return s[p]
		if s is RID:
			return s
	var susp: Array = _pair(bufs, "susp")
	return susp[p]


## Push: {uint cell_count, pad, pad, pad} — 16 bytes (fungus_fert, shock).
func _pc_u4(cc: int) -> PackedByteArray:
	return PackedInt32Array([cc, 0, 0, 0]).to_byte_array()


## Push: {uint cell_count, pad, pad, float precip} — 16 bytes (fert).
func _pc_precip16(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip]).to_byte_array())
	return b


## Push: {uint cell_count, pad,pad,pad, float precip, pad,pad,pad} — 32 bytes (fungus).
func _pc_precip32(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip, 0.0, 0.0, 0.0]).to_byte_array())
	return b
