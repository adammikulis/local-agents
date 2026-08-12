extends RefCounted


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
const REACTIONS_SCRIPT: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"

static func overburden_pa_per_unit() -> float:
	var cells: int = maxi(int(LAMaterialField3D.REGOLITH_CELLS), 1)
	var metres_per_cell: float = LAPhysical.GROUNDWATER_CIRCULATION_M / float(cells)
	return LAPhysical.STANDARD_GRAVITY_M_S2 * metres_per_cell

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

	var defs_script: GDScript = load(REACTIONS_SCRIPT)
	if defs_script == null:
		push_error("ReactionsPass: could not load %s — the reaction table is GONE and all same-cell chemistry "
			% REACTIONS_SCRIPT + "would silently stop. Run scripts/editor_scan.sh (a new class_name only "
			+ "registers after a scan).")
		return
	var recs: Array = defs_script.records()
	if recs.is_empty():
		push_error("ReactionsPass: the reaction table is EMPTY. Every same-cell reaction (photosynthesis, "
			+ "respiration, decompose, freeze/melt, lava solidify, weathering, lithification) is disabled. "
			+ "This is a load failure, not a valid configuration — check the record modules in "
			+ "material/reactions/ and run scripts/editor_scan.sh.")
		return
	_n_records = recs.size()
	var bytes: PackedByteArray = defs_script.serialize(recs)
	_defs_ssbo = _rd.storage_buffer_create(bytes.size(), bytes)

	var temp: Array = _pair(bufs, "temp")
	var water: Array = _pair(bufs, "water")
	var moisture: Array = _pair(bufs, "moisture")
	var o2: Array = _pair(bufs, "o2")
	var co2: Array = _pair(bufs, "co2")
	var fungus: Array = _pair(bufs, "fungus")
	var fert: Array = _pair(bufs, "fert")
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
	var lava: Array = _pair(bufs, "lava")
	var rock_fill: RID = _single(bufs, "rock_fill")
	var soil: Array = _pair(bufs, "soil")
	var radial: RID = _single(bufs, "radial")
	var regolith: RID = _single(bufs, "regolith")   # aquifer mask — the column SOIL_ROOT walks (see below)
	# oxidises it, and it is the only sink fuel has anywhere in the tree. `fire` is a PAIR but is NOT a
	# channel: the kernel assigns it as the fraction of a cell's fuel that burned this step, purely so
	# `fire_cells` / `fire_peak` / `is_burning` have something true to read. Nothing in the physics reads it.
	var fuel: RID = _single(bufs, "fuel")
	var fire: Array = _pair(bufs, "fire")
	# The two non-silicate mineral species (slots 24/25, bindings 28/29). SINGLE buffers: nothing advects them,
	# and this kernel is their only reader and only writer, so there is no producer to ping-pong against.
	var carbonate: RID = _single(bufs, "carbonate")
	var silica: RID = _single(bufs, "silica")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_shader, [
			[0, temp[back]],        # settled temp (Thermal output)
			[1, water[back]],       # settled water (Atmosphere/WaterSlump output)
			[2, moisture[back]],    # settled moisture (Atmosphere output)
			[3, o2[back]],          # o2 transport output — edited in place (sky refill / decompose draw)
			[4, co2[back]],         # co2 transport output — edited in place (sky vent / decompose emit)
			[5, fuel],              # SINGLE — R26 combustion debits it (its only sink in the whole tree)
			[6, fire[back]],        # BACK — the burn INSTRUMENT, assigned every step. Back for the same reason
			                        # o2/co2 are: the authoritative readback reads the back half after the
			                        # phase flip, so a write to LIVE would be discarded. Nothing reads it back
			                        # into the physics, so there is no ordering hazard either way.
			[7, detritus],          # SINGLE — decompose debits in place / respiration credits in place
			[8, fungus[p]],         # LIVE — decompose driver (read-only; producer runs later)
			[9, fert[p]],           # LIVE — R19 nutrient-uptake reactant, debited in place (producer runs later)
			[11, biomass],          # SINGLE — photosynthesis grows it, respiration/decay oxidizes it (persistent, GPU-owned)
			[12, snow],             # SINGLE — freeze (R21) credits it, melt (R22) debits it; SAME H₂O as water/moisture (persistent, GPU-owned)
			[13, sediment[back]],   # loose regolith — loft (M4) debits it; SAME buffer FireDust transport deposits into + reads back
			[14, dust[p]],          # airborne dust (LIVE) — loft (M4) credits it here so FireDust transport advects it THIS step
			[16, susp[back]],       # waterborne suspended sediment — settle (M3) debits it. LIVE: ErosionTransport
			                        # wrote this half (advected load) and ErosionPickup added this step's scour.
			                        # inert since the pickup pass landed.)
			[17, vel_x],            # SINGLE — WINDSPEED driver leg (sqrt(vel_x²+vel_z²))
			[18, vel_z],            # SINGLE — WINDSPEED driver leg
			[22, lava[back]],       # molten rock (settled by Thermal into BACK) — M5 debits it, M6 credits it
			[23, rock_fill],        # SINGLE fractional bedrock — M5 credits it (lava→rock), M6 debits it (rock→lava)
			[10, solid],
			[15, nbr],
			[20, scratch],          # fungus-fert SCRATCH product target
			[21, _defs_ssbo],
			[24, soil[back]],       # settled water table (SoilPass output) — R19's transpiration draws from the
			[38, bufs["porosity"]],  # phi — rc_of and the overburden walk convert rock_fill with it
			                        # regolith column BENEATH an open cell (SOIL_ROOT), the only place soil exists
			[25, radial],           # per-cell outward unit vector — the derived LIGHT slot's geometry
			[27, regolith],         # aquifer permeability mask — root_soil() walks THIS, not `solid`
			[28, carbonate],        # SINGLE CaCO3 — the Urey record credits it forward, debits it in reverse
			[29, silica],           # SINGLE SiO2 — the weathering residue, same record
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid() or _n_records <= 0:
		return
	# Same source + same default as ThermalPass.gd:150 — the solar kernel and the reaction engine must see the
	# IDENTICAL sun, magnitude included (it carries orbit-distance² × atmospheric transmission, so dust dimming
	# and impact winter suppress photosynthesis directly rather than second-hand through cooling).
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, _n_records)
	pc.encode_u32(8, 0)    # was `dt`, uploaded and never read; every rate_k already carries its own timebase
	pc.encode_u32(12, 0)   # was `raining`; the global rain gate is deleted
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_float(28, overburden_pa_per_unit())
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
