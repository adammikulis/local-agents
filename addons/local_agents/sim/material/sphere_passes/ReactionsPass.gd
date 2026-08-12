extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The generic reaction engine: one kernel over the whole record table (reactions_sphere3d.glsl).


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
const REACTIONS_SCRIPT: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"

## Lithostatic pressure added per unit of overlying rock, Pa. Takes the local gravity: a pressure is
## rho*g*h and this planet has no single g.
static func overburden_pa_per_unit(g_m_s2: float) -> float:
	var cells: int = maxi(int(LAMaterialField3D.REGOLITH_CELLS), 1)
	var metres_per_cell: float = LAPhysical.GROUNDWATER_CIRCULATION_M / float(cells)
	return g_m_s2 * metres_per_cell

var _pipe: RID = RID()
var _n_records: int = 0
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
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
			+ "respiration, decompose, freeze/melt, lava solidify, weathering, lithification) is disabled. "
			+ "This is a load failure, not a valid configuration — check the record modules in "
			+ "material/reactions/ and run scripts/editor_scan.sh.")
		return
	_n_records = recs.size()
	var defs_ssbo: RID = _storage_buffer(defs_script.serialize(recs))

	var temp: Array = _pair(bufs, "temp")
	var water: Array = _pair(bufs, "water")
	var moisture: Array = _pair(bufs, "moisture")
	var o2: Array = _pair(bufs, "o2")
	var co2: Array = _pair(bufs, "co2")
	var fungus: RID = _single(bufs, "fungus")
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
	var regolith: RID = _single(bufs, "regolith")   # aquifer mask — the column SOIL_ROOT walks
	# `fire` is a PAIR but is NOT a channel: the kernel assigns it as the fraction of this cell's usable
	# oxygen that combustion consumed, so the gauges have something true to read. No physics reads it.
	var fuel: RID = _single(bufs, "fuel")
	var fire: Array = _pair(bufs, "fire")
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
	var porosity: RID = _single(bufs, "porosity")
	var cell_vol: RID = _single(bufs, "cell_vol")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_pipe, [
			[0, temp[back]],        # settled temp
			[1, water[back]],       # settled water
			[2, moisture[back]],    # settled moisture
			[3, o2[back]],          # o2 transport output — edited in place (sky refill / decompose draw)
			[4, co2[back]],         # co2 transport output — edited in place (sky vent / decompose emit)
			[5, fuel],              # SINGLE — combustion debits it (its only sink in the whole tree)
			[6, fire[back]],        # BACK — the burn INSTRUMENT, assigned every step. Back for the same reason
			                        # o2/co2 are: the authoritative readback reads the back half after the
			                        # phase flip, so a write to LIVE would be discarded.
			[7, detritus],          # SINGLE — decompose debits in place / respiration credits in place
			[8, fungus],            # SINGLE — decompose drives on it and both bio records write it
			[9, fert[p]],           # LIVE — nutrient-uptake reactant, debited in place (producer runs later)
			[10, solid],
			[11, biomass],          # SINGLE — photosynthesis grows it, respiration/decay oxidises it
			[12, snow],             # SINGLE — freeze/deposition credit it, melt debits it; same H₂O as water
			[13, sediment[back]],   # loose regolith — loft debits it
			[14, dust[p]],          # airborne dust — loft credits it
			[15, nbr],
			[16, susp[back]],       # waterborne suspended sediment — settle debits it
			[17, vel_x],            # SINGLE — WINDSPEED driver leg (sqrt(vel_x²+vel_z²))
			[18, vel_z],            # SINGLE — WINDSPEED driver leg
			[20, scratch],          # fungus-fert SCRATCH product target
			[21, defs_ssbo],
			[22, lava[back]],       # molten rock — solidify debits, melt credits
			[23, rock_fill],        # SINGLE fractional bedrock — solidify credits it, melt debits it
			[24, soil[back]],       # settled water table — transpiration draws the regolith column (SOIL_ROOT)
			[25, radial],           # per-cell outward unit vector — the derived LIGHT slot's geometry
			[27, regolith],         # aquifer permeability mask — root_soil() walks THIS, not `solid`
			[28, carbonate],        # SINGLE CaCO3 — the Urey record credits it forward, debits it in reverse
			[29, silica],           # SINGLE SiO2 — the weathering residue, same record
			[30, n2[back]],         # dinitrogen — lightning fixation debits it
			[31, discharge],        # SINGLE — the lightning discharge stamp, driver only
			[32, org_h],            # SINGLE — organic hydrogen; ORG_H/ORG_C is the cell's molar H:C
			[33, org_o],            # SINGLE — organic oxygen; ORG_O/ORG_C is the cell's molar O:C
			[38, porosity],         # phi — rc_of and the overburden walk convert rock_fill with it
			[40, cell_vol],         # per-cell volume (kernels3d/cellvol.glsli)
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or _n_records <= 0:
		return
	# The solar kernel and the reaction engine must see the IDENTICAL sun, magnitude included: it carries
	# orbit-distance² × atmospheric transmission, so dust dimming suppresses photosynthesis directly rather
	# than second-hand through cooling.
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
	pc.encode_float(28, overburden_pa_per_unit(float(ctx.get("g_m_s2", 0.0))))
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
