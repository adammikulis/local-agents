extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## EVERYTHING A CELL DERIVES FROM ITS OWN INDEX. Writes `temp`, `vel_*`, `rho_bulk`,
## `conductivity` and the h2o/silicate phase shares off `e_j_m3` and `pressure`; cements and sets `solid`,
## `regolith`, `grain` off that melt share; adds weight, Coriolis and centrifugal to `mom_*`.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/state_derive.glsl"

const FluxPassScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd")

## Every buffer outside LAMatterChannels this kernel touches, name -> state_derive.glsl binding. ONE
## declaration: the absence check and the uniform set ask the same list.
const BOUND: Dictionary = {
	"solid": 14, "cement": 15, "regolith": 16, "grain": 17, "pos": 18, "liquid": 19, "org_hc": 20,
	"e_j_m3": 21, "pressure": 22, "ke_j_m3": 90, "pe_j_m3": 91, "grav_phi": 78, "grav_ref": 95, "level_args": 82,
	"temp": 23, "mom_x": 25, "mom_y": 26, "mom_z": 27, "vel_x": 28, "vel_y": 29, "vel_z": 30,
	"org_oc": 31, "rho_bulk": 32, "conductivity": 33, "h2o_solid": 34, "h2o_liquid": 35,
	"h2o_vapour": 36, "silicate_melt": 37, "org_fresh": 38, "cell_edge": 94, "speed": 41, "lat": 42,
	"alt": 43, "nonfinite": 44, "h_h2o": 45, "h_silicate": 46, "h_sensible": 47, "cap_sensible": 48,
	"gravity": 49, "bodyf_x": 50, "bodyf_y": 51, "bodyf_z": 52, "k_cond": 53, "rad_w_m3": 65,
	"g_rest": 39, "level_idx": 81, "mom_orphan": 92, "lithic_frac": 96, "lithic_kg": 97, "unconverged": 99}

## props row layout — state_derive.glsl PROP_*.
const PROP_STRIDE: int = 12
const PROP_M: int = 0
const PROP_C: int = 1
const PROP_MOL_PER_KG: int = 2
const PROP_ENTRY: int = 3
const PROP_LAMBDA: int = 4
const PROP_FULL: int = 5
## The EOS half: rho(T, p) inverted per substance, so pressure is a state function of the cell.
const PROP_ALPHA: int = 6
const PROP_BULK: int = 7
const PROP_TREF: int = 8
## 1 where the channel is a rock or metal phase, so the solid flag reads the whole lithic volume.
const PROP_LITHIC: int = 9
## 1-based index into the push constant's radiogenic W/kg slots; 0 for a substance with no U/Th/K.
const PROP_RAD_GROUP: int = 10
## 1 where the channel is a CONDENSED phase: it fills volume of its own and resists being squeezed. A
## dissolved solute rides in its solvent and does neither.
const PROP_CONDENSED: int = 11

## Push-constant slots for distinct radiogenic trace mixes, re-evaluated at the run's epoch per step.
const RAD_GROUPS: int = 4

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
		"h_h2o": {"n": cc, "ghosts": true}, "h_silicate": {"n": cc, "ghosts": true},
		"h_sensible": {"n": cc, "ghosts": true}, "cap_sensible": {"n": cc, "ghosts": true},
		"org_hc": cc, "org_oc": cc, "org_fresh": cc,
		"bodyf_x": cc, "bodyf_y": cc, "bodyf_z": cc,
		"k_cond": {"n": cc, "ghosts": true}, "g_rest": {"n": cc * 3, "ghosts": true},
		"rad_w_m3": {"n": cc, "ghosts": true}, "ke_j_m3": cc, "pe_j_m3": cc, "grav_phi": cc, "grav_ref": cc, "lithic_frac": {"n": cc, "ghosts": true}, "lithic_kg": {"n": cc, "ghosts": true}})


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

	var want: PackedStringArray = LAMatterChannels.CHANNELS.duplicate()
	want.append_array(PackedStringArray(BOUND.keys()))
	var missing: PackedStringArray = LAMatterChannels.absent(bufs, want)
	if not missing.is_empty():
		push_error("StateDerivePass: no buffer for %s, so no cell would get a temperature."
			% String(", ").join(missing))
		return
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	var entries: Array = []
	for i in channels.size():
		entries.append([LAMatterChannels.binding_of(i), _single(bufs, channels[i])])
	entries.append([24, props_ssbo])
	for name in BOUND:
		entries.append([int(BOUND[name]), _single(bufs, String(name))])
	_set = _uset(_pipe, entries)


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	# The body's spin vector, rad/s: direction from its seeded angular momentum, rate from its measured
	# inertia. Zero while unmeasured, which is no rotating frame rather than a guessed one.
	var w: Vector3 = ctx.get("spin", Vector3.ZERO) * float(ctx.get("spin_rate_rad_s", 0.0))
	var centre: Vector3 = ctx.get("centre", Vector3.ZERO)
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(88)
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
	_driver.run(cl, _pipe, [_set], [pc], PackedInt32Array([groups]), [RID()],
		PackedInt32Array([0]), false)
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
	out.resize(channels.size() * PROP_STRIDE)
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
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
		var c: float = LAMatterChannels.specific_heat(id)
		if entry == LAMatterChannels.Entry.SENSIBLE and c <= 0.0:
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
		out[base + PROP_C] = c
		out[base + PROP_MOL_PER_KG] = mol_per_kg
		out[base + PROP_ENTRY] = float(entry)
		out[base + PROP_FULL] = full[i]
		out[base + PROP_ALPHA] = float(s.get("expansion_per_k", 0.0))
		# CONDENSED fills volume of its own and resists being squeezed, which is what the EOS sums; a gas
		# is the A term and a dissolved solute rides in its solvent. No modulus is a substance nobody has
		# measured, and reading one as incompressible lets its cell signal at any speed at all.
		out[base + PROP_CONDENSED] = 0.0 if mol_per_kg > 0.0 \
			or String(row.get("phase", "")) == "dissolved" else 1.0
		out[base + PROP_BULK] = float(s.get("bulk_modulus_pa", s.get("bulk_modulus_solid_pa", 0.0)))
		out[base + PROP_TREF] = float(s.get("density_ref_t_c", 0.0))
		out[base + PROP_LITHIC] = 1.0 if bool(row.get("lithic", false)) else 0.0
		out[base + PROP_RAD_GROUP] = float(_rad_group(s.get("traces", {})))
	return out


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
