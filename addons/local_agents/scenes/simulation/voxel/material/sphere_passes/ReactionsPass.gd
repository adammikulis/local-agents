extends RefCounted

## Cubed-sphere GENERIC REACTION pass (Phase B3 §3). Wires the ONE data-driven reaction kernel
## (reactions_sphere3d.glsl) into the sphere GPU driver as a single recordable pass. It replaces a pile of
## bespoke "clean same-cell" reaction kernels (gas sky-exchange/vent, fungus decompose, …) with one kernel
## that loops an array of Reaction RECORDS (authored in MaterialReactions3D.gd, uploaded once as a read-only
## SSBO). Adding a reaction is adding a record there — not a kernel here.
##
## Slotted AFTER AtmospherePass so temp/water/o2/co2/airwater are all settled (one-step coupling lag is the
## accepted norm — MaterialSphereGPU3D.gd:19-20). Buffer HALVES per channel (why each differs): o2/co2 were
## produced by GasWind's transport into BACK (1-p); temp by Thermal into BACK; water/airwater by Atmosphere
## into BACK — so those read/edit BACK. FUNGUS's producer (EcoSurface's fungus kernel) runs LATER, so the
## current fungus is still LIVE (p) at this slot → bound to LIVE, read-only.
##
## Kernel binding -> bufs-key map (authoritative layout is reactions_sphere3d.glsl):
##   0 Temp=temp[back] · 1 Water=water[back] · 2 AirWater=airwater[back] · 3 O2=o2[back] · 4 CO2=co2[back] ·
##   7 Detritus=detritus(single) · 8 Fungus=fungus[live] · 10 Solid=solid · 11 Biomass=biomass(single) ·
##   12 Snow=snow(single, freeze/melt phase transfer) · 15 Neigh=nbr · 20 Scratch=fungus_fert(single, SCRATCH
##   product) · 21 Defs=<record SSBO>.
## Push { uint cell_count; uint n_records; float dt; float pad; } — 16 bytes.

const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/reactions_sphere3d.glsl"
const REACTIONS_SCRIPT: String = "res://addons/local_agents/scenes/simulation/voxel/material/MaterialReactions3D.gd"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _defs_ssbo: RID = RID()
var _n_records: int = 0
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("ReactionsPass: null RenderingDevice")
		return

	_shader = _compile(KERNEL_PATH)
	if not _shader.is_valid():
		push_error("ReactionsPass: reactions_sphere3d.glsl failed to compile (editor import scan needed?)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	# Upload the immutable record table once as a read-only SSBO.
	var defs_script: GDScript = load(REACTIONS_SCRIPT)
	var recs: Array = defs_script.records()
	_n_records = recs.size()
	var bytes: PackedByteArray = defs_script.serialize(recs)
	if bytes.size() == 0:
		bytes = PackedByteArray([0, 0, 0, 0])   # never create a 0-byte SSBO
	_defs_ssbo = _rd.storage_buffer_create(bytes.size(), bytes)

	var temp: Array = _pair(bufs, "temp")
	var water: Array = _pair(bufs, "water")
	var airwater: Array = _pair(bufs, "airwater")
	var o2: Array = _pair(bufs, "o2")
	var co2: Array = _pair(bufs, "co2")
	var fungus: Array = _pair(bufs, "fungus")
	var detritus: RID = _single(bufs, "detritus")
	var biomass: RID = _single(bufs, "biomass")
	var snow: RID = _single(bufs, "snow")
	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var scratch: RID = _single(bufs, "fungus_fert")
	var sediment: Array = _pair(bufs, "sediment")
	var dust: Array = _pair(bufs, "dust")
	var susp: Array = _pair(bufs, "susp")
	var vel_x: RID = _single(bufs, "vel_x")
	var vel_z: RID = _single(bufs, "vel_z")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_shader, [
			[0, temp[back]],        # settled temp (Thermal output)
			[1, water[back]],       # settled water (Atmosphere/WaterSlump output)
			[2, airwater[back]],    # settled airwater (Atmosphere output)
			[3, o2[back]],          # o2 transport output — edited in place (sky refill / decompose draw)
			[4, co2[back]],         # co2 transport output — edited in place (sky vent / decompose emit)
			[7, detritus],          # SINGLE — decompose debits in place / respiration credits in place
			[8, fungus[p]],         # LIVE — decompose driver (read-only; producer runs later)
			[11, biomass],          # SINGLE — photosynthesis grows it, respiration/decay oxidizes it (persistent, GPU-owned)
			[12, snow],             # SINGLE — freeze (R21) credits it, melt (R22) debits it; SAME H₂O as water/airwater (persistent, GPU-owned)
			[13, sediment[back]],   # loose regolith — loft (M4) debits it; SAME buffer FireDust transport deposits into + reads back
			[14, dust[p]],          # airborne dust (LIVE) — loft (M4) credits it here so FireDust transport advects it THIS step
			[16, susp[back]],       # waterborne suspended sediment — settle (M3) debits it (dead phase today → inert)
			[17, vel_x],            # SINGLE — WINDSPEED driver leg (sqrt(vel_x²+vel_z²))
			[18, vel_z],            # SINGLE — WINDSPEED driver leg
			[10, solid],
			[15, nbr],
			[20, scratch],          # fungus-fert SCRATCH product target
			[21, _defs_ssbo],
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid() or _n_records <= 0:
		return
	var dt: float = float(ctx.get("dt", 0.1))
	var raining: int = int(ctx.get("raining", 0))   # GATE_NOT_RAINING (dust loft M4) reads this
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, _n_records)
	pc.encode_float(8, dt)
	pc.encode_u32(12, raining)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set = [RID(), RID()]
	if _defs_ssbo.is_valid():
		rd.free_rid(_defs_ssbo)
		_defs_ssbo = RID()
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


# --- helpers ------------------------------------------------------------------

func _compile(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	if sf == null:
		return RID()
	return _rd.shader_create_from_spirv(sf.get_spirv())


func _uset(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _single(bufs: Dictionary, key: String) -> RID:
	var v = bufs.get(key, RID())
	return v if v is RID else RID()


func _pair(bufs: Dictionary, key: String) -> Array:
	var v = bufs.get(key, null)
	if v is Array and v.size() >= 2:
		return v
	return [RID(), RID()]
