extends RefCounted

## Cubed-sphere GENERIC REACTION pass (Phase B3 §3). Wires the ONE data-driven reaction kernel
## (reactions_sphere3d.glsl) into the sphere GPU driver as a single recordable pass. It replaces a pile of
## bespoke "clean same-cell" reaction kernels (gas sky-exchange/vent, fungus decompose, …) with one kernel
## that loops an array of Reaction RECORDS (authored in MaterialReactions3D.gd, uploaded once as a read-only
## SSBO). Adding a reaction is adding a record there, not a kernel here.
##
## Slotted AFTER AtmospherePass and SoilPass so temp/water/o2/co2/moisture/soil are all settled (one-step
## coupling lag is the accepted norm, see MaterialSphereGPU3D.gd:19-20). Buffer HALVES per channel (why each
## differs): o2/co2 were produced by GasWind's transport into BACK (1-p); temp by Thermal into BACK;
## water/moisture by Atmosphere into BACK; SOIL by SoilPass's own ping-pong into BACK (it runs immediately
## before this pass, so BACK is this step's settled water table) — so all of those read/edit BACK. FUNGUS's
## and FERT's producers (EcoSurface's kernels) run LATER, so those are still LIVE (p) at this slot.
##
## Kernel binding -> bufs-key map (authoritative layout is reactions_sphere3d.glsl):
##   0 Temp=temp[back] · 1 Water=water[back] · 2 Moisture=moisture[back] · 3 O2=o2[back] · 4 CO2=co2[back] ·
##   7 Detritus=detritus(single) · 8 Fungus=fungus[live] · 9 Fert=fert[live] (R19 nutrient-uptake reactant now
##   debits it in place, and its own diffuse/leach/decompose-deposit producer, EcoSurfacePass's scent_fert/
##   fungus_fert kernels, runs LATER this step, so LIVE is the freshest read, same convention as Fungus) ·
##   10 Solid=solid · 11 Biomass=biomass(single) ·
##   12 Snow=snow(single, freeze/melt phase transfer) · 15 Neigh=nbr · 20 Scratch=fungus_fert(single, SCRATCH
##   product) · 21 Defs=<record SSBO> · 22 Lava=lava[back] · 23 RockFill=rock_fill(single). M5 solidify /
##   M6 melt transfer mineral mass between LAVA and ROCK_FILL (own-cell, conserving) ·
##   24 Soil=soil[back] (SoilPass ran this step and wrote BACK; the SOIL_ROOT slot reads + debits the regolith
##   column beneath an open cell — transpiration's source) · 25 Radial=radial (per-cell outward unit vector,
##   the LIGHT slot's geometry; the same SSBO ThermalPass binds at 14 for the solar kernel) ·
##   26 Static=static (the GATE_NOT_STATIC test — the sea/lake reservoir is not real per-cell chemistry) ·
##   27 Regolith=regolith (SINGLE, seeded once — the aquifer mask root_soil() walks INSTEAD of `solid`, since
##   `solid` is re-derived from rock_fill every step and an eroded/carved regolith cell is open but still an
##   aquifer; same buffer ActivityPass binds at its own binding 9).
## Push { uint cell_count; uint n_records; float dt; uint raining; float sun_x, sun_y, sun_z, pad; }, 32 bytes.
## sun_dir is sourced from `ctx` exactly as ThermalPass.gd does, so the light the chemistry sees and the light
## the solar kernel heats with are ONE quantity — including its magnitude, which carries insolation.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
const REACTIONS_SCRIPT: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"

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
	#
	# AN EMPTY TABLE IS FATAL, NOT A NO-OP. Measured 2026-08-03, and it cost a whole round of measurements:
	# the record modules were merged to the dev branch without an editor scan, so `LAMaterialReactions3D` was
	# briefly unresolvable, `load()` returned null, and the sim ran with ZERO reaction records. Every same-cell
	# chemistry stopped at once — no M3 settle, no M5 solidify, no freeze/melt, no photosynthesis — and the run
	# still printed a completely normal-looking SIM_REPORT. The only tell was in the aggregates, if you happened
	# to be comparing: susp piled up to 2300 against a baseline of 72 because nothing settled it, sediment read
	# exactly 0.00 against 980, lava reached 1313 against 37 because nothing froze it, and temp_mean hit 152 C.
	# A silent zero here is indistinguishable from "the chemistry is just quiet", which is why it must be loud.
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
	var static_rid: RID = _single(bufs, "static")
	var regolith: RID = _single(bufs, "regolith")   # aquifer mask — the column SOIL_ROOT walks (see below)

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_shader, [
			[0, temp[back]],        # settled temp (Thermal output)
			[1, water[back]],       # settled water (Atmosphere/WaterSlump output)
			[2, moisture[back]],    # settled moisture (Atmosphere output)
			[3, o2[back]],          # o2 transport output — edited in place (sky refill / decompose draw)
			[4, co2[back]],         # co2 transport output — edited in place (sky vent / decompose emit)
			[7, detritus],          # SINGLE — decompose debits in place / respiration credits in place
			[8, fungus[p]],         # LIVE — decompose driver (read-only; producer runs later)
			[9, fert[p]],           # LIVE — R19 nutrient-uptake reactant, debited in place (producer runs later)
			[11, biomass],          # SINGLE — photosynthesis grows it, respiration/decay oxidizes it (persistent, GPU-owned)
			[12, snow],             # SINGLE — freeze (R21) credits it, melt (R22) debits it; SAME H₂O as water/moisture (persistent, GPU-owned)
			[13, sediment[back]],   # loose regolith — loft (M4) debits it; SAME buffer FireDust transport deposits into + reads back
			[14, dust[p]],          # airborne dust (LIVE) — loft (M4) credits it here so FireDust transport advects it THIS step
			[16, susp[back]],       # waterborne suspended sediment — settle (M3) debits it (dead phase today → inert)
			[17, vel_x],            # SINGLE — WINDSPEED driver leg (sqrt(vel_x²+vel_z²))
			[18, vel_z],            # SINGLE — WINDSPEED driver leg
			[22, lava[back]],       # molten rock (settled by Thermal into BACK) — M5 debits it, M6 credits it
			[23, rock_fill],        # SINGLE fractional bedrock — M5 credits it (lava→rock), M6 debits it (rock→lava)
			[10, solid],
			[15, nbr],
			[20, scratch],          # fungus-fert SCRATCH product target
			[21, _defs_ssbo],
			[24, soil[back]],       # settled water table (SoilPass output) — R19's transpiration draws from the
			                        # regolith column BENEATH an open cell (SOIL_ROOT), the only place soil exists
			[25, radial],           # per-cell outward unit vector — the derived LIGHT slot's geometry
			[26, static_rid],       # infinite sea/lake reservoir mask — GATE_NOT_STATIC
			[27, regolith],         # aquifer permeability mask — root_soil() walks THIS, not `solid`
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid() or _n_records <= 0:
		return
	var dt: float = float(ctx.get("dt", 0.1))
	var raining: int = int(ctx.get("raining", 0))   # GATE_NOT_RAINING (dust loft M4) reads this
	# Same source + same default as ThermalPass.gd:150 — the solar kernel and the reaction engine must see the
	# IDENTICAL sun, magnitude included (it carries orbit-distance² × atmospheric transmission, so dust dimming
	# and impact winter suppress photosynthesis directly rather than second-hand through cooling).
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, _n_records)
	pc.encode_float(8, dt)
	pc.encode_u32(12, raining)
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_float(28, 0.0)
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
