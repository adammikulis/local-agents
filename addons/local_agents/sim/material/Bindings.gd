class_name LABindings
extends RefCounted

## THE ONE DECLARATION OF EVERY SSBO BINDING NUMBER. A kernel writes `LA_BIND_<NAME>` off
## `kernels3d/bindings.glsli`, which `scripts/gen_bindings.py` emits from `SLOT`; a pass asks
## `set_for()`. `scripts/check_binding_collisions.sh` holds both tables to the kernels, both ways.
const SLOT: Dictionary = {
	# the grid
	"nbr": 0, "pos": 1, "ghost": 2, "rim_ghost": 3, "rim_w": 4, "vert_up": 5, "vert_down": 6, "slot_off": 7,
	"face_partner": 8, "cell_edge": 9, "ground_d": 10,
	# the matter channels, in LAMatterChannels.CHANNELS order
	"h2o": 11, "silicate": 12, "carbonate": 13, "silica": 14, "o2": 15, "co2": 16, "n2": 17, "biomass": 18,
	"fungus": 19, "detritus": 20, "fuel": 21, "org_h": 22, "org_o": 23, "fert": 24, "metal": 25,
	"olivine": 26, "pyroxene": 27, "plagioclase": 28, "halite": 29, "apatite": 30, "h2": 31, "co": 32,
	"so2": 33, "h2s": 34, "ch4": 35, "h2o_pore": 36,
	# the rest of the state
	"e_j_m3": 37, "e_lith_j_m3": 38, "charge": 39, "mom_x": 40, "mom_y": 41, "mom_z": 42, "cement": 43,
	"porosity": 44, "regolith": 45, "grain": 46,
	# derived from the state every step
	"temp": 47, "temp_lith": 48, "conductivity": 49, "conductivity_lith": 50, "solid": 51, "liquid": 52,
	"pressure": 53, "p_fluid": 54, "rho_bulk": 55, "h2o_solid": 56, "h2o_liquid": 57, "h2o_vapour": 58,
	"silicate_melt": 59, "silicate_susp_water": 60, "silicate_susp_air": 61, "silicate_bed": 62, "vel_x": 63,
	"vel_y": 64, "vel_z": 65, "speed": 66, "lat": 67, "alt": 68, "mach": 69, "gas_r": 70, "gas_gamma": 71,
	"k_cond": 72, "cap_sensible": 73, "cap_lith": 74, "h_h2o": 75, "h_h2o_vap": 76, "h_silicate": 77,
	"h_sensible": 78, "lattice_frac": 79, "lithic_frac": 80, "lithic_kg": 81, "org_hc": 82, "org_oc": 83,
	"org_fresh": 84, "bodyf_x": 85, "bodyf_y": 86, "bodyf_z": 87, "g_rest": 88, "ke_j_m3": 89, "pe_j_m3": 90,
	"mom_orphan": 91, "nonfinite": 92, "unconverged": 93, "fire": 94, "discharge": 95, "rad_absorbed": 96,
	"rad_emitted": 97, "rad_w_m3": 98, "radiogenic": 99, "col_e": 100, "strike": 101, "sw_space": 102,
	"rad_residual": 103,
	# what a cell's NEIGHBOURS make of it: the derive's detect phase, off state its own phase settled
	"r_frac": 163, "surface_class": 164, "melt_body": 165, "erupt": 166, "cyclone": 167,
	# the gravity solve
	"gravity": 104, "grav_phi": 105, "grav_ref": 106, "grav_density": 107, "grav_cellflag": 108,
	"grav_moments": 109, "grav_partials": 110, "grav_props": 111,
	# the derive's per-channel substance table
	"derive_props": 112,
	# the temporal levels and the active-cell lists
	"tlevel": 113, "level_idx": 114, "level_args": 115, "level_peak": 116, "act_quiet": 117, "act_claim": 118,
	"act_queue": 119, "act_wake": 120, "act_wake_args": 121, "active_idx": 122, "active_args": 123,
	# transport's per-record slots: what the row names, not one fixed buffer
	"flux_amount": 124, "flux_energy": 125, "flux_resist": 126, "flux_drive": 127, "flux_aux": 128,
	"flux_frac": 129, "flux_h_carried": 130, "flux_bnd_amt": 131, "flux_bnd_h": 132, "flux_bnd_mom_x": 133,
	"flux_bnd_mom_y": 134, "flux_bnd_mom_z": 135, "flux_bnd_q": 136, "flux_o3": 137, "flux_rad_table": 138,
	# transport's own scratch
	"flux_face_u": 139, "flux_fp_star": 140, "flux_face_uw": 141, "flux_fpw_star": 142, "flux_send": 143,
	"flux_x_amt": 144, "flux_x_h": 145, "flux_x_q": 146, "flux_lw_emis": 147, "flux_sw_absorbed": 148,
	"flux_sw_keep": 149, "flux_sw_src": 150, "flux_nu_t": 151, "flux_w_top": 152, "flux_dm_x": 174,
	"flux_dm_y": 175, "flux_dm_z": 176,
	# the reduce row's slots
	"reduce_src": 153, "reduce_aux": 154, "reduce_aux2": 155, "reduce_ref": 156, "reduce_gate": 157,
	"reduce_gate_aux": 158, "reduce_partials": 159,
	# the sparse edit: the batch, and the two channels one dispatch names
	"inject_idx": 168, "inject_val": 169, "inject_applied": 170, "inject_src": 171, "inject_dst": 172,
	# the reaction table
	"reaction_defs": 160,
	# the selftest probes
	# water_rho is kg/m^3 the cell's own liquid water stands at
	"stack_probe": 161, "enthalpy_probe": 162, "water_rho": 173, "tide_bodies": 177, "tidal_accel": 178, "tidal_work": 179
}

## The slots each kernel's translation unit declares, its includes with it. A pass binds this
## list and nothing else, so a kernel and its uniform set cannot drift apart.
const IN_KERNEL: Dictionary = {
	"enthalpy_selftest.glsl": ["enthalpy_probe"],
	"flux.glsl": ["nbr", "ghost", "rim_ghost", "rim_w", "slot_off", "face_partner", "cell_edge", "ground_d",
		"h2o", "silicate", "o2", "co2", "n2", "biomass", "h2", "co", "so2", "h2s", "ch4", "charge", "mom_x",
		"mom_y", "mom_z", "cement", "porosity", "grain", "temp", "temp_lith", "solid", "pressure", "rho_bulk",
		"h2o_pore", "h2o_solid", "h2o_liquid", "h2o_vapour", "water_rho", "silicate_melt",
		"silicate_susp_water", "silicate_susp_air", "silicate_bed", "vel_x", "vel_y", "vel_z", "speed", "gas_r",
		"gas_gamma", "k_cond", "cap_sensible", "cap_lith", "lattice_frac", "lithic_frac", "lithic_kg",
		"bodyf_x", "bodyf_y", "bodyf_z", "g_rest", "tidal_accel", "tidal_work", "pe_j_m3", "rad_absorbed", "rad_emitted", "rad_w_m3",
		"radiogenic", "col_e", "strike", "sw_space", "rad_residual", "grav_phi", "grav_ref", "tlevel",
		"level_idx", "level_args", "level_peak", "act_quiet", "act_claim", "act_queue", "act_wake",
		"act_wake_args", "active_idx", "active_args", "flux_amount", "flux_energy", "flux_resist", "flux_drive",
		"flux_aux", "flux_frac", "flux_h_carried", "flux_bnd_amt", "flux_bnd_h", "flux_bnd_mom_x",
		"flux_bnd_mom_y", "flux_bnd_mom_z", "flux_bnd_q", "flux_o3", "flux_rad_table", "flux_face_u",
		"flux_fp_star", "flux_face_uw", "flux_fpw_star", "flux_send", "flux_x_amt", "flux_x_h", "flux_x_q",
		"flux_lw_emis", "flux_sw_absorbed", "flux_sw_keep", "flux_sw_src", "flux_nu_t", "flux_w_top",
		"flux_dm_x", "flux_dm_y", "flux_dm_z"],
	"gravity_poisson.glsl": ["nbr", "pos", "vert_up", "vert_down", "slot_off", "face_partner", "cell_edge",
		"h2o", "silicate", "carbonate", "silica", "o2", "co2", "n2", "biomass", "fungus", "detritus", "fuel",
		"org_h", "org_o", "fert", "metal", "olivine", "pyroxene", "plagioclase", "halite", "apatite", "h2",
		"co", "so2", "h2s", "ch4", "h2o_pore", "gravity", "grav_phi", "grav_ref", "grav_density",
		"grav_cellflag", "grav_moments", "grav_partials", "grav_props"],
	"pressure.glsl": ["vert_up", "cell_edge", "solid", "pressure", "rho_bulk", "lithic_kg", "g_rest"],
	"reactions_sphere3d.glsl": ["vert_up", "vert_down", "cell_edge", "h2o", "silicate", "carbonate",
		"silica", "o2", "co2", "n2", "biomass", "fungus", "detritus", "fuel", "org_h", "org_o", "fert",
		"e_j_m3", "regolith", "grain", "temp", "solid", "pressure", "h2o_solid", "h2o_liquid", "h2o_vapour",
		"vel_x", "vel_y", "vel_z", "fire", "discharge", "col_e", "strike", "gravity", "act_wake",
		"act_wake_args", "reaction_defs"],
	"sparse_edit.glsl": ["cell_edge", "inject_idx", "inject_val", "inject_applied", "inject_src",
		"inject_dst"],
	"reduce.glsl": ["nbr", "vert_up", "vert_down", "slot_off", "face_partner", "cell_edge", "solid", "rho_bulk",
		"reduce_src", "reduce_aux", "reduce_aux2", "reduce_ref", "reduce_gate", "reduce_gate_aux",
		"reduce_partials"],
	"stack_selftest.glsl": ["stack_probe"],
	"state_derive.glsl": ["nbr", "slot_off", "face_partner", "vert_up", "vert_down", "r_frac",
		"surface_class", "melt_body", "erupt", "cyclone", "pos", "cell_edge", "h2o", "silicate", "carbonate",
		"silica", "o2", "co2", "n2", "biomass", "fungus", "detritus", "fuel", "org_h", "org_o", "fert", "metal",
		"olivine", "pyroxene", "plagioclase", "halite", "apatite", "h2", "co", "so2", "h2s", "ch4", "h2o_pore",
		"e_j_m3", "e_lith_j_m3", "mom_x", "mom_y", "mom_z", "cement", "regolith", "grain", "temp", "temp_lith",
		"conductivity", "conductivity_lith", "solid", "liquid", "pressure", "p_fluid", "rho_bulk", "h2o_solid",
		"h2o_liquid", "h2o_vapour", "water_rho", "silicate_melt", "vel_x", "vel_y", "vel_z", "speed", "lat",
		"alt", "mach", "gas_r", "gas_gamma", "k_cond", "cap_sensible", "cap_lith", "h_h2o", "h_h2o_vap",
		"h_silicate", "h_sensible", "lattice_frac", "lithic_frac", "lithic_kg", "org_hc", "org_oc", "org_fresh",
		"bodyf_x", "bodyf_y", "bodyf_z", "g_rest", "tidal_accel", "tidal_work", "ke_j_m3", "pe_j_m3", "mom_orphan", "nonfinite", "unconverged",
		"rad_w_m3", "gravity", "grav_phi", "grav_ref", "tide_bodies", "derive_props", "level_idx", "level_args"],
}


## The binding a named slot occupies. An unknown name is a named error and -1: a uniform set
## built on a guessed slot binds a buffer into a kernel that never declared it.
static func of(name: String) -> int:
	if not SLOT.has(name):
		push_error("LABindings: no slot named \"%s\". Declare it in SLOT and IN_KERNEL, then "
			% name + "regenerate kernels3d/bindings.glsli with scripts/gen_bindings.py.")
		return -1
	return int(SLOT[name])


## The whole uniform set for `kernel`: every slot it declares, the driver's buffers by their
## own name out of `bufs` and the pass's own out of `own`. A slot in neither is a named error
## and an empty set, because a partial set binds a kernel to memory nobody wrote.
static func set_for(kernel: String, bufs: Dictionary, own: Dictionary) -> Array:
	var out: Array = []
	for name: String in IN_KERNEL.get(kernel, []):
		var v: Variant = own.get(name, bufs.get(name, null))
		if not (v is RID and (v as RID).is_valid()):
			push_error("LABindings: %s declares \"%s\" and neither the driver nor the pass has a "
				% [kernel, name] + "buffer for it, so the kernel would read memory nobody wrote.")
			return []
		out.append([of(name), v])
	return out
