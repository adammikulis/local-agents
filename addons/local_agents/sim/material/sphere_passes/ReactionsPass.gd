extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The generic reaction engine: one kernel over the whole record table (reactions_sphere3d.glsl).


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
const REACTIONS_SCRIPT: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"

var _pipe: RID = RID()
var _n_records: int = 0
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return

	var defs_script: GDScript = load(REACTIONS_SCRIPT)
	if defs_script == null:
		push_error("ReactionsPass: could not load %s — the reaction table is GONE and all same-cell chemistry "
			% REACTIONS_SCRIPT + "would silently stop. Run scripts/editor_scan.sh (a new class_name only "
			+ "registers after a scan).")
		return
	var recs: Array = defs_script.records()
	if recs.is_empty():
		push_error("ReactionsPass: the reaction table is EMPTY. Every same-cell reaction (photosynthesis, "
			+ "respiration, decompose, evaporation, weathering) is disabled. "
			+ "This is a load failure, not a valid configuration — check the record modules in "
			+ "material/reactions/ and run scripts/editor_scan.sh.")
		return
	_n_records = recs.size()
	var defs_ssbo: RID = _storage_buffer(defs_script.serialize(recs))

	var temp: RID = _single(bufs, "temp")        # derived C, read-only
	var h: Array = _pair(bufs, "h_j_m3")         # the state, J/m^3
	var h2o: Array = _pair(bufs, "h2o")
	var o2: Array = _pair(bufs, "o2")
	var co2: Array = _pair(bufs, "co2")
	var fungus: RID = _single(bufs, "fungus")
	var fert: Array = _pair(bufs, "fert")
	var detritus: RID = _single(bufs, "detritus")
	var biomass: RID = _single(bufs, "biomass")
	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var scratch: RID = _scratch(cc)         # reaction product target, consumed in the same step
	var vel_x: RID = _single(bufs, "vel_x")
	var vel_y: RID = _single(bufs, "vel_y")
	var vel_z: RID = _single(bufs, "vel_z")
	var silicate: Array = _pair(bufs, "silicate")
	var regolith: RID = _single(bufs, "regolith")   # aquifer mask — the column SOIL_ROOT walks
	# `fire` is a PAIR but is NOT a channel: the kernel assigns it as the fraction of this cell's usable
	# oxygen that combustion consumed, so the gauges have something true to read. No physics reads it.
	var fuel: RID = _single(bufs, "fuel")
	var fire: RID = _single(bufs, "fire")   # derived: the burn instrument, not a stock
	# The two non-silicate mineral species (slots 24/25, bindings 28/29). SINGLE buffers: nothing advects them,
	# and this kernel is their only reader and only writer, so there is no producer to ping-pong against.
	var carbonate: RID = _single(bufs, "carbonate")
	var silica: RID = _single(bufs, "silica")
	# `discharge` is the lightning stamp — read-only, single, driver only.
	var n2: Array = _pair(bufs, "n2")
	var discharge: RID = _single(bufs, "discharge")
	# The dead organic pool's hydrogen and oxygen. Registered channels (LAChannels), so the driver owns them.
	var org_h: RID = _single(bufs, "org_h")
	var org_o: RID = _single(bufs, "org_o")
	var cell_vol: RID = _single(bufs, "cell_vol")
	var pressure: RID = _single(bufs, "pressure")
	var gravity: RID = _single(bufs, "gravity")
	# The h2o phase shares state_derive.glsl publishes. No record moves mass between them.
	var h2o_solid: RID = _single(bufs, "h2o_solid")
	var h2o_liquid: RID = _single(bufs, "h2o_liquid")
	var h2o_vapour: RID = _single(bufs, "h2o_vapour")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_pipe, [
			[0, temp],
			[19, h[back]],          # the settled half, the one this pass adds reaction heat to
			[1, h2o[back]],         # settled h2o — ONE channel, every phase
			[3, o2[back]],          # o2 transport output — edited in place (sky refill / decompose draw)
			[4, co2[back]],         # co2 transport output — edited in place (sky vent / decompose emit)
			[5, fuel],              # SINGLE — combustion debits it (its only sink in the whole tree)
			[6, fire],              # derived: the burn INSTRUMENT, assigned every step
			                        # o2/co2 are: the authoritative readback reads the back half after the
			                        # phase flip, so a write to LIVE would be discarded.
			[7, detritus],          # SINGLE — decompose debits in place / respiration credits in place
			[8, fungus],            # SINGLE — decompose drives on it and both bio records write it
			[9, fert[p]],           # LIVE — nutrient-uptake reactant, debited in place (producer runs later)
			[10, solid],
			[11, biomass],          # SINGLE — photosynthesis grows it, respiration/decay oxidises it
			[15, nbr],
			[17, vel_x],            # SINGLE — WINDSPEED reads the flow tangential to the local vertical
			[18, vel_z],
			[26, vel_y],
			[20, scratch],          # fungus-fert SCRATCH product target
			[21, defs_ssbo],
			[22, silicate[back]],   # ONE mineral amount — weathering debits it, nothing else writes it
			[27, regolith],         # aquifer permeability mask — root_soil() walks THIS, not `solid`
			[28, carbonate],        # SINGLE CaCO3 — the Urey record credits it forward, debits it in reverse
			[29, silica],           # SINGLE SiO2 — the weathering residue, same record
			[30, n2[back]],         # dinitrogen — lightning fixation debits it
			[31, discharge],        # SINGLE — the lightning discharge stamp, driver only
			[32, org_h],            # SINGLE — organic hydrogen; ORG_H/ORG_C is the cell's molar H:C
			[33, org_o],            # SINGLE — organic oxygen; ORG_O/ORG_C is the cell's molar O:C
			[34, h2o_solid],        # DERIVED share — ice
			[35, h2o_liquid],       # DERIVED share — liquid, free or in pores
			[36, h2o_vapour],       # DERIVED share — vapour
			[37, pressure],         # Pa — the saturation curve and the ladder both read it
			[40, cell_vol],         # per-cell volume (kernels3d/cellvol.glsli)
			[48, gravity],          # the SOLVED g: every "above"/"below" and the light angle read it
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or _n_records <= 0:
		return
	# The solar kernel and the reaction engine must see the IDENTICAL sun, magnitude included: it carries
	# orbit-distance squared times atmospheric transmission, so what dims the sky suppresses photosynthesis
	# directly rather than second-hand through cooling.
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, _n_records)
	pc.encode_u32(8, 0)    # pad0 — no kernel-side dt; every rate_k carries its own timebase
	pc.encode_u32(12, 0)   # pad1 — no global rain gate
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_u32(28, 0)   # pad2
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
