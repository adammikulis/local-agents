extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## EVERYTHING A CELL DERIVES FROM ITS OWN INDEX. Writes `temp`, `vel_*`, `rho_bulk`,
## `conductivity` and the h2o/silicate phase shares off `e_j_m3` and `pressure`; cements and sets `solid`,
## `regolith`, `grain` off that melt share; adds weight, Coriolis and centrifugal to `mom_*`.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/state_derive.glsl"

const FluxPassScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd")

## props row layout — state_derive.glsl PROP_*.
const PROP_STRIDE: int = 79
const PROP_M: int = 0
const PROP_MOL_PER_KG: int = 1
const PROP_ENTRY: int = 2
const PROP_LAMBDA: int = 3
const PROP_FULL: int = 4
## 1 where the channel is a rock or metal phase, so the solid flag reads the whole lithic volume.
const PROP_LITHIC: int = 5
## 1-based index into the push constant's radiogenic W/kg slots; 0 for a substance with no U/Th/K.
const PROP_RAD_GROUP: int = 6
## 1 where the channel is a CONDENSED phase: it fills volume of its own and resists being squeezed. A
## dissolved solute rides in its solvent and does neither.
const PROP_CONDENSED: int = 7
## The solid's and the melt's equations of state, LASubstances.eos_of(id), a PH_* block each.
const PROP_SOLID: int = 8
const PROP_LIQUID: int = 17
const PH_FULL: int = 0
const PH_ALPHA: int = 1
const PH_BULK: int = 2
const PH_KP: int = 3
const PH_B4: int = 4
const PH_TREF: int = 5
const PH_LINEAR: int = 6
const PH_F_LO: int = 7
const PH_F_HI: int = 8
## The channel substance's own phase ladder, laid out by LAMixtureEnthalpy::thermal_row — every condensed
## channel melts and boils where its table row says. state_derive.glsl PROP_LADDER, TH_*.
const PROP_LADDER: int = 26

## Push-constant slots for distinct radiogenic trace mixes, re-evaluated at the run's epoch per step.
const RAD_GROUPS: int = 4

## state_derive.glsl's Params, less the chunk words the driver appends. LAFieldDriver::run_transport
## writes the restate's three words at PC_BYTES-12, -8 and -4, so they stay the last three here.
const PC_BYTES: int = 96
const PC_LITHIFY: int = 76
const PC_DETECT: int = 80

## Detector thresholds appended after the channel rows of `props` — state_derive.glsl DET_*.
const DET_SLOTS: int = 5

var _pipe: RID = RID()
var _set: RID = RID()
var _fresh_h_per_c: float = 0.0
var _fresh_o_per_c: float = 0.0
var _rad_mixes: Array = []


## Device-read only, so this pass's own rather than drained LAChannels.derived_buffers() entries.
func _buffers(cc: int) -> Dictionary:
	# The four entry-heat buffers carry ghost tails: transport's pass 0 reads them for ghost donors.
	# The temporal levels come with the derive rather than with transport: the restate walks the same
	# sorted list, and this pass runs at rungs below the one that moves anything.
	return LATemporalLevels.buffers(cc + ghost_count, FluxPassScript.group_count()).merged({"speed": cc,
		"lat": cc, "alt": cc, "nonfinite": cc, "mom_orphan": cc, "unconverged": cc,
		"h_h2o": {"n": cc, "ghosts": true}, "h_h2o_vap": {"n": cc, "ghosts": true}, "h_silicate": {"n": cc, "ghosts": true},
		"h_sensible": {"n": cc, "ghosts": true}, "cap_sensible": {"n": cc, "ghosts": true},
		"org_hc": cc, "org_oc": cc, "org_fresh": cc,
		"bodyf_x": cc, "bodyf_y": cc, "bodyf_z": cc,
		"water_rho": {"n": cc, "ghosts": true}, "k_cond": {"n": cc, "ghosts": true}, "gas_r": {"n": cc, "ghosts": true},
		"gas_gamma": {"n": cc, "ghosts": true}, "mach": cc, "g_rest": {"n": cc, "stride": 3, "ghosts": true}, "cap_lith": {"n": cc, "ghosts": true}, "lattice_frac": {"n": cc, "ghosts": true},
		"rad_w_m3": {"n": cc, "ghosts": true}, "ke_j_m3": cc, "pe_j_m3": cc, "grav_phi": {"n": cc, "ghosts": true}, "grav_ref": {"n": cc, "ghosts": true}, "lithic_frac": {"n": cc, "ghosts": true}, "lithic_kg": {"n": cc, "ghosts": true},
		"r_frac": cc, "surface_class": cc, "melt_body": cc, "erupt": cc, "cyclone": cc,
		"vert_up": cc, "vert_down": cc})


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	if not LAMatterChannels.covers_the_matter_channels("StateDerivePass"):
		return
	var props: PackedFloat32Array = _props()
	if props.is_empty():
		return
	_fresh_h_per_c = LASubstances.fresh_litter_per_carbon("H")
	_fresh_o_per_c = LASubstances.fresh_litter_per_carbon("O")
	if _fresh_h_per_c <= 0.0 or _fresh_o_per_c <= 0.0:
		push_error("StateDerivePass: LASubstances gives fresh litter no H or O per carbon, so the organic "
			+ "ratio buffers would divide by nothing.")
		return
	var props_ssbo: RID = _storage_buffer(props.to_byte_array())

	_set = _uset(_pipe, LABindings.set_for("state_derive.glsl", bufs, {"derive_props": props_ssbo}))


func dispatch(_rd: RenderingDevice, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	# The body's spin vector, rad/s: direction from its seeded angular momentum, rate from its measured
	# inertia. Zero while unmeasured, which is no rotating frame rather than a guessed one.
	var w: Vector3 = ctx.get("spin", Vector3.ZERO) * float(ctx.get("spin_rate_rad_s", 0.0))
	var centre: Vector3 = ctx.get("centre", Vector3.ZERO)
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(PC_LITHIFY, 1 if LAProcessSet.has_record("derive", "lithify") else 0)
	pc.encode_u32(0, cc)
	pc.encode_float(4, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	pc.encode_float(8, w.x)
	pc.encode_float(12, w.y)
	pc.encode_float(16, w.z)
	pc.encode_float(20, centre.x)
	pc.encode_float(24, centre.y)
	pc.encode_float(28, centre.z)
	pc.encode_float(32, LAPhysical.GRAIN_D_LOWLAND_M)
	pc.encode_float(36, LAPhysical.LITHIFICATION_RATE_PER_PA)
	pc.encode_float(40, LAPhysical.LITHIFICATION_PRESSURE_PA)
	pc.encode_float(44, _fresh_h_per_c)
	pc.encode_float(48, _fresh_o_per_c)
	# W/kg of each distinct radiogenic trace mix at the run's epoch: the store is finite, so the rate falls.
	var epoch: float = LARadiogenicDecay.epoch_years()
	for i in RAD_GROUPS:
		var w_kg: float = 0.0
		if i < _rad_mixes.size():
			var mix: Array = _rad_mixes[i]
			w_kg = LARadiogenicDecay.heat_w_kg_of({"U": mix[0], "Th": mix[1], "K": mix[2]}, epoch)
		pc.encode_float(52 + i * 4, w_kg)
	pc.encode_float(68, float(ctx.get("sea_radius", 0.0)))
	# NO SOLVER, NO POTENTIAL: a world with no gravity pass has a zero potential field, and the weight it
	# would be read at is never guessed. GravityPass publishes which of its two sources wrote it.
	pc.encode_float(72, float(ctx.get("gravity_self", 0.0)))
	# THE DETECT PHASE runs second, behind a barrier: what a cell's NEIGHBOURS make of it, off the state
	# the phase above settled. Reading a neighbour inside the derive would read a value being written.
	var pc_detect: PackedByteArray = pc.duplicate()
	pc_detect.encode_u32(PC_DETECT, 1)
	_driver.run(_pipe, [_set], [pc, pc_detect], PackedInt32Array([groups, groups]),
		[RID(), RID()], PackedInt32Array([0, 0]), true,
		PackedStringArray([_label() + "/derive", _label() + "/detect"]))
	# THE SAME SOLVE, HANDED TO THE SUBSTEP LOOP. One owner of the equation of state: transport dispatches
	# this pipeline again over its active list, and the driver writes the list slot into the block.
	ctx["restate"] = {"pipe": _pipe, "set": _set, "pc": pc, "total": cc + ghost_count}


## One row per channel, from the substance table. No value is declared here; the mass column is the one
## LAMatterChannels publishes, so gravity and heat capacity weigh the same cell.
func _props() -> PackedFloat32Array:
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	var molar: PackedFloat32Array = LAMatterChannels.molar_masses()
	var full: PackedFloat32Array = LAMatterChannels.full_amounts()
	if molar.size() != channels.size() or full.size() != channels.size():
		return PackedFloat32Array()
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(channels.size() * PROP_STRIDE + DET_SLOTS)
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var carriers: Dictionary = {}
	for i in channels.size():
		var name: String = channels[i]
		var row: Dictionary = rows[name]
		var id: String = String(row.get("substance", ""))
		var s: Dictionary = table.get(id, {})
		var unit: String = String(row.get("unit", ""))
		if unit != "mol_m3":
			push_error("StateDerivePass: LAChannels row \"%s\" declares unit \"%s\", not \"mol_m3\". "
				% [name, unit] + "A channel amount is moles per m^3; without it the channel's mass is a guess.")
			return PackedFloat32Array()
		var entry: int = LAMatterChannels.entry_of(id)
		carriers[entry] = true
		var ladder: PackedFloat32Array = LAMixtureEnthalpy.thermal_row(id)
		if ladder.size() != PROP_STRIDE - PROP_LADDER:
			return PackedFloat32Array()
		var mol_per_kg: float = 1.0 / molar[i] if LAMatterChannels.GASES.has(id) else 0.0
		var lambda_w_mk: float = float(s.get("conductivity", 0.0))
		if lambda_w_mk <= 0.0:
			push_error("StateDerivePass: LASubstances gives \"%s\" no conductivity, so channel %s "
				% [id, name] + "would carry mass that conducts no heat.")
			return PackedFloat32Array()
		var base: int = i * PROP_STRIDE
		out[base + PROP_LAMBDA] = lambda_w_mk
		out[base + PROP_M] = molar[i]
		out[base + PROP_MOL_PER_KG] = mol_per_kg
		out[base + PROP_ENTRY] = float(entry)
		out[base + PROP_FULL] = full[i]
		for k in ladder.size():
			out[base + PROP_LADDER + k] = ladder[k]
		# CONDENSED fills volume of its own and resists being squeezed, which is what the EOS sums; a gas
		# is the A term and a dissolved solute rides in its solvent.
		var condensed: bool = not (mol_per_kg > 0.0 or String(row.get("phase", "")) == "dissolved")
		out[base + PROP_CONDENSED] = 1.0 if condensed else 0.0
		var eos: Dictionary = LASubstances.eos_of(id)
		var fluid: Dictionary = eos["fluid"]
		if mol_per_kg > 0.0 and fluid.is_empty():
			push_error("StateDerivePass: LASubstances gives gas \"%s\" no fluid equation of state." % id)
			return PackedFloat32Array()
		var solid: Dictionary = eos["solid"]
		var melt: Dictionary = eos["liquid"]
		var melts: bool = is_finite(LASubstances.melt_c_at(id, LAPhysical.STANDARD_PRESSURE_PA))
		if condensed and melts and (solid.is_empty() or melt.is_empty()):
			push_error("StateDerivePass: LASubstances gives \"%s\" a melting point and not both phases' " % id
				+ "equations of state, so channel %s would melt into a volume nobody measured." % name)
			return PackedFloat32Array()
		_pack_phase(out, base + PROP_SOLID, solid, molar[i])
		_pack_phase(out, base + PROP_LIQUID, melt, molar[i])
		out[base + PROP_LITHIC] = 1.0 if bool(row.get("lithic", false)) or bool(row.get("lattice", false)) else 0.0
		out[base + PROP_RAD_GROUP] = float(_rad_group(s.get("traces", {})))
	# The kernel reads the water and rock carriers by index; a table without either has no water or rock row.
	if not (carriers.has(LAMatterChannels.Entry.H2O) and carriers.has(LAMatterChannels.Entry.SILICATE)):
		push_error("StateDerivePass: the channel table carries no water or no silicate channel.")
		return PackedFloat32Array()
	# The amounts the detect phase compares against, each read back from its ONE declaration, so the
	# kernel and the row that counts its cells ask the same question.
	var body: float = float(LAReduceRecords.row("lava_hot").get("threshold", NAN))
	if is_nan(body):
		push_error("StateDerivePass: LAReduceRecords declares no \"lava_hot\" threshold, so the melt "
			+ "body has no depth and its interior/rind split would be taken against a guess.")
		return PackedFloat32Array()
	var det: int = channels.size() * PROP_STRIDE
	out[det] = LAMaterialField3D.MIN_MASS
	out[det + 1] = LAMaterialField3D.SNOW_PRESENT
	out[det + 2] = body
	out[det + 3] = LAMaterialFieldQueries3D.TUBE_MELT_NEAR_ZERO
	out[det + 4] = LAMaterialFieldQueries3D.MOLTEN_MIN
	return out


## One phase of LASubstances.eos_of() as a PH_* block; zeros where the table names none.
func _pack_phase(out: PackedFloat32Array, at: int, ph: Dictionary, molar_kg: float) -> void:
	if ph.is_empty():
		return
	out[at + PH_FULL] = float(ph["rho"]) / molar_kg
	out[at + PH_ALPHA] = float(ph["alpha"])
	out[at + PH_BULK] = float(ph["k"])
	out[at + PH_KP] = float(ph["kp"])
	out[at + PH_B4] = float(ph["b4"])
	out[at + PH_TREF] = float(ph["t_ref_c"])
	out[at + PH_LINEAR] = 1.0 if bool(ph["linear_density"]) else 0.0
	out[at + PH_F_LO] = float(ph["f_lo"])
	out[at + PH_F_HI] = float(ph["f_hi"])


## 1-based index of this trace mix among the distinct radiogenic mixes; 0 for one with no U/Th/K.
func _rad_group(traces: Dictionary) -> int:
	if float(traces.get("U", 0.0)) <= 0.0 and float(traces.get("Th", 0.0)) <= 0.0 \
			and float(traces.get("K", 0.0)) <= 0.0:
		return 0
	var key: Array = [float(traces.get("U", 0.0)), float(traces.get("Th", 0.0)),
		float(traces.get("K", 0.0))]
	for i in _rad_mixes.size():
		if _rad_mixes[i] == key:
			return i + 1
	if _rad_mixes.size() >= RAD_GROUPS:
		push_error("StateDerivePass: more than %d distinct radiogenic trace mixes; the push constant "
			% RAD_GROUPS + "cannot carry another epoch rate.")
		return 0
	_rad_mixes.append(key)
	return _rad_mixes.size()
