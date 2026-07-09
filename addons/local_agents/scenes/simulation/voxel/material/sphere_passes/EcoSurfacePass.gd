extends RefCounted

## Cubed-sphere GPU pass plugin: the ECOSYSTEM / SURFACE field CAs — scent (surface-wind precompute,
## lateral transport, soil-fertility creep), the fungus decomposer + its radial fertility reduce, the
## snow phase, and the shock/sound pressure-wave — wired to the SphereGPU driver via the PLUGIN CONTRACT
## (setup() once, dispatch() each step).
##
## The driver owns the RenderingDevice, all channel buffers, and the open compute list. This plugin only:
##   1. setup(): compiles the sphere kernels, then builds the uniform sets (one per parity for any kernel
##      that touches a ping-pong PAIR channel; a single shared set for the parity-free scent_wind
##      precompute), mapping each kernel's .glsl binding indices onto the driver's shared `bufs`.
##   2. dispatch(): records each kernel into the driver's open compute list `cl`, with a barrier after
##      every kernel so a producer's writes are visible to the next kernel that reads them.
##
## PAIR channels arrive as [live, back] = bufs[key][parity], bufs[key][1-parity]; SINGLE channels are a
## bare RID. scent is a PAIR sized 5*cc packed by channel (base = ch*cc); every other field is len cc.
## nbr is the int32 cc*6 neighbour table on binding 15 (slot 0 = inward/down .. slot 5 = outward/up).
##
## Per-kernel binding -> bufs-key map (authoritative layout is each kernel's .glsl header):
##   scent_wind_sphere3d      0 VelX=vel_x  · 1 VelZ=vel_z · 2 Solid=solid ·
##                            3 SurfVx=surf_vx · 4 SurfVz=surf_vz · 15 Neigh=nbr           (SINGLE-only, 1 set)
##   scent_transport_sphere3d 0 ScentIn=scent[live] · 1 ScentOut=scent[back] · 15 Neigh=nbr
##   scent_fert_sphere3d      0 FertIn=fert[live] · 1 FertOut=fert[back] · 15 Neigh=nbr
##   fungus_sphere3d          0 FungIn=fungus[live] · 1 FungOut=fungus[back] · 2 Detritus=detritus(readonly) ·
##                            5 Temp=temp[live] · 6 Vapor=vapor[live] · 7 Fire=fire[live] · 8 Solid=solid ·
##                            15 Neigh=nbr   (the same-cell decompose chemistry + its CO2/O2/fert-scratch writes
##                            moved to ReactionsPass; this kernel is now the cross-cell growth/spread/death half)
##   fungus_fert_sphere3d     0 FertCell=fungus_fert · 1 Fert=fert[back] (add in place on scent_fert output) ·
##                            2 Solid=solid · 15 Neigh=nbr
##   snowice_sphere3d         0 Snow=<snow> · 1 Temp=temp[back] · 2 Moisture=moisture[back] (-=frozen condensate) ·
##                            3 Solid=solid · 15 Neigh=nbr   (deposition-only: freezes CONDENSED moisture → snow on
##                            cold ground, mass-conserving; freeze-liquid + melt are now records R21/R22)
##   shock_sphere3d           0 ShockIn=shock[live] · 1 ShockOut=shock[back] · 2 Solid=solid · 15 Neigh=nbr
##
## Push-constant layouts (see each .glsl Params):
##   scent_wind, fungus_fert, shock, snowice : {uint cell_count, pad, pad, pad}                -> 16 bytes
##   scent_transport, scent_fert    : {uint cell_count, pad, pad, float precip}                -> 16 bytes
##   fungus                         : {uint cell_count, pad,pad,pad, float precip, pad,pad,pad} -> 32 bytes
## precip comes from ctx.get("precip", 0.0). (dt is unused: every rate here is a per-step constant.)
##
## SKIPPED: erosion_advect_sphere3d.glsl / erosion_deposit_sphere3d.glsl do NOT exist in kernels3d/ (only the
## box versions erosion_advect3d.glsl / erosion_deposit3d.glsl are present), so the erosion advect+deposit
## dispatches are omitted. Wire them here once the sphere ports land.
##
## IMPROVISED buffer key: the snow-depth field has no documented PAIR/SINGLE key in the contract. It is a
## per-cell depth mutated in place, so this pass resolves it as bufs["snow"] when present (a bare RID, or the
## live half if the driver ever stores it as a PAIR), else falls back to the live half of the "susp" PAIR.

const KDIR: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/"
const SCENT_WIND_PATH: String = KDIR + "scent_wind_sphere3d.glsl"
const SCENT_TRANSPORT_PATH: String = KDIR + "scent_transport_sphere3d.glsl"
const SCENT_FERT_PATH: String = KDIR + "scent_fert_sphere3d.glsl"
const FUNGUS_PATH: String = KDIR + "fungus_sphere3d.glsl"
const FUNGUS_FERT_PATH: String = KDIR + "fungus_fert_sphere3d.glsl"
const SNOWICE_PATH: String = KDIR + "snowice_sphere3d.glsl"
const SHOCK_PATH: String = KDIR + "shock_sphere3d.glsl"

var _rd: RenderingDevice = null

# Compiled shaders (kept so their RIDs stay owned for the pipelines' lifetime).
var _scent_wind_shader: RID = RID()
var _scent_transport_shader: RID = RID()
var _scent_fert_shader: RID = RID()
var _fungus_shader: RID = RID()
var _fungus_fert_shader: RID = RID()
var _snowice_shader: RID = RID()
var _shock_shader: RID = RID()

# Compute pipelines.
var _scent_wind_pipe: RID = RID()
var _scent_transport_pipe: RID = RID()
var _scent_fert_pipe: RID = RID()
var _fungus_pipe: RID = RID()
var _fungus_fert_pipe: RID = RID()
var _snowice_pipe: RID = RID()
var _shock_pipe: RID = RID()

# Uniform sets. scent_wind is SINGLE-only (one set); the rest touch a PAIR so they hold one set per parity.
var _scent_wind_set: RID = RID()
var _scent_transport_set: Array = [RID(), RID()]
var _scent_fert_set: Array = [RID(), RID()]
var _fungus_set: Array = [RID(), RID()]
var _fungus_fert_set: Array = [RID(), RID()]
var _snowice_set: Array = [RID(), RID()]
var _shock_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("EcoSurfacePass: null RenderingDevice")
		return

	# --- Compile the kernels -------------------------------------------------------
	_scent_wind_shader = _compile(SCENT_WIND_PATH)
	_scent_wind_pipe = _rd.compute_pipeline_create(_scent_wind_shader)
	_scent_transport_shader = _compile(SCENT_TRANSPORT_PATH)
	_scent_transport_pipe = _rd.compute_pipeline_create(_scent_transport_shader)
	_scent_fert_shader = _compile(SCENT_FERT_PATH)
	_scent_fert_pipe = _rd.compute_pipeline_create(_scent_fert_shader)
	_fungus_shader = _compile(FUNGUS_PATH)
	_fungus_pipe = _rd.compute_pipeline_create(_fungus_shader)
	_fungus_fert_shader = _compile(FUNGUS_FERT_PATH)
	_fungus_fert_pipe = _rd.compute_pipeline_create(_fungus_fert_shader)
	_snowice_shader = _compile(SNOWICE_PATH)
	_snowice_pipe = _rd.compute_pipeline_create(_snowice_shader)
	_shock_shader = _compile(SHOCK_PATH)
	_shock_pipe = _rd.compute_pipeline_create(_shock_shader)

	# --- Resolve the shared SINGLE buffers once ------------------------------------
	var solid_rid: RID = _single(bufs, "solid")
	var nbr_rid: RID = _single(bufs, "nbr")
	var vel_x_rid: RID = _single(bufs, "vel_x")
	var vel_z_rid: RID = _single(bufs, "vel_z")
	var surf_vx_rid: RID = _single(bufs, "surf_vx")
	var surf_vz_rid: RID = _single(bufs, "surf_vz")
	var detritus_rid: RID = _single(bufs, "detritus")
	var fungus_fert_rid: RID = _single(bufs, "fungus_fert")  # per-cell fertility scratch (written by ReactionsPass' decompose record, reduced by fungus_fert)

	# --- PAIR channels: [live, back] indexed by parity -----------------------------
	var scent_pair: Array = _pair(bufs, "scent")      # 5*cc packed
	var fert_pair: Array = _pair(bufs, "fert")
	var fungus_pair: Array = _pair(bufs, "fungus")
	var temp_pair: Array = _pair(bufs, "temp")
	# The ONE unified atmospheric-water channel (Phase 2a). Fungus reads it as local moisture (the suspended
	# total is the behavioural proxy, perf-over-parity); snow deposition freezes its condensed part out to snow.
	var moisture_pair: Array = _pair(bufs, "moisture")
	var fire_pair: Array = _pair(bufs, "fire")
	var shock_pair: Array = _pair(bufs, "shock")

	# --- scent_wind: parity-free (SINGLE buffers only) -> one set ------------------
	_scent_wind_set = _build_set(_scent_wind_shader, [
		[0, vel_x_rid],      # VelX
		[1, vel_z_rid],      # VelZ
		[2, solid_rid],      # Solid
		[3, surf_vx_rid],    # SurfVx (writeonly, per-cell)
		[4, surf_vz_rid],    # SurfVz (writeonly, per-cell)
		[15, nbr_rid],       # Neigh
	])

	# --- One uniform set per parity for every PAIR-touching kernel -----------------
	for p in 2:
		var back: int = 1 - p

		_scent_transport_set[p] = _build_set(_scent_transport_shader, [
			[0, scent_pair[p]],      # ScentIn  = live scent (5-packed)
			[1, scent_pair[back]],   # ScentOut = back scent
			[15, nbr_rid],
		])

		_scent_fert_set[p] = _build_set(_scent_fert_shader, [
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
			[7, fire_pair[p]],       # Fire  (live, read)
			[8, solid_rid],          # Solid
			[15, nbr_rid],
		])

		_fungus_fert_set[p] = _build_set(_fungus_fert_shader, [
			[0, fungus_fert_rid],    # FertCell = the per-cell scratch fungus just wrote
			[1, fert_pair[back]],    # Fert = scent_fert's output (fert[back]), added into in place
			[2, solid_rid],          # Solid
			[15, nbr_rid],
		])

		# Snow DEPOSITION (snowfall): freeze the CONDENSED moisture on cold ground → snow, mass-conserving. Reads
		# the SETTLED temp + moisture (BACK halves — Thermal/Atmosphere wrote them this step) and debits moisture
		# in that same BACK half so the loss carries forward as next frame's live (no later pass writes moisture).
		_snowice_set[p] = _build_set(_snowice_shader, [
			[0, _snow_rid(bufs, p)], # Snow depth (SINGLE, in place)
			[1, temp_pair[back]],    # Temp (settled, read)
			[2, moisture_pair[back]],# Moisture (settled, debited in place — the frozen-out condensate)
			[3, solid_rid],          # Solid
			[15, nbr_rid],
		])

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

	# Order: scent_wind -> scent_transport -> scent_fert -> fungus -> fungus_fert -> snowice -> shock.
	# (erosion_advect / erosion_deposit skipped: sphere kernels absent — see header.)
	# A barrier after every kernel makes each producer's writes visible to its consumer:
	#   fungus writes the per-cell fertility scratch that fungus_fert reduces (hard dependency);
	#   scent_fert writes fert[back] that fungus_fert adds into in place (hard dependency).
	_run(rd, cl, _scent_wind_pipe, _scent_wind_set, _pc_u4(cc), groups)
	_run(rd, cl, _scent_transport_pipe, _scent_transport_set[parity], _pc_precip16(cc, precip), groups)
	_run(rd, cl, _scent_fert_pipe, _scent_fert_set[parity], _pc_precip16(cc, precip), groups)
	_run(rd, cl, _fungus_pipe, _fungus_set[parity], _pc_precip32(cc, precip), groups)
	_run(rd, cl, _fungus_fert_pipe, _fungus_fert_set[parity], _pc_u4(cc), groups)
	_run(rd, cl, _snowice_pipe, _snowice_set[parity], _pc_u4(cc), groups)
	_run(rd, cl, _shock_pipe, _shock_set[parity], _pc_u4(cc), groups)


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


## Push: {uint cell_count, pad, pad, pad} — 16 bytes (scent_wind, fungus_fert, shock).
func _pc_u4(cc: int) -> PackedByteArray:
	return PackedInt32Array([cc, 0, 0, 0]).to_byte_array()


## Push: {uint cell_count, pad, pad, float precip} — 16 bytes (scent_transport, scent_fert).
func _pc_precip16(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip]).to_byte_array())
	return b


## Push: {uint cell_count, pad,pad,pad, float precip, pad,pad,pad} — 32 bytes (fungus, snowice).
func _pc_precip32(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip, 0.0, 0.0, 0.0]).to_byte_array())
	return b
