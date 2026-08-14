extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## EVERYTHING A CELL DERIVES FROM ITS OWN INDEX. Writes `temp`, `vel_*`, `rho_bulk`,
## `conductivity` and the h2o/silicate phase shares off `h_j_m3` and `pressure`; cements and sets `solid`,
## `regolith`, `grain` off that melt share; adds Coriolis and centrifugal to `mom_*`.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/state_derive.glsl"

## Every buffer outside LAMatterChannels this kernel touches, name -> state_derive.glsl binding. ONE
## declaration: the absence check and the uniform set ask the same list, so neither can name what the
## other does not.
const BOUND: Dictionary = {
	"solid": 14, "cement": 15, "regolith": 16, "grain": 17, "pos": 18, "h_j_m3": 21, "pressure": 22,
	"temp": 23, "mom_x": 25, "mom_y": 26, "mom_z": 27, "vel_x": 28, "vel_y": 29, "vel_z": 30,
	"rho_bulk": 32, "conductivity": 33, "h2o_solid": 34, "h2o_liquid": 35,
	"h2o_vapour": 36, "silicate_melt": 37, "cell_vol": 40, "speed": 41, "lat": 42, "alt": 43,
	"nonfinite": 44, "h_h2o": 45, "h_silicate": 46, "h_sensible": 47, "cap_sensible": 48}

## props row layout — state_derive.glsl PROP_*.
const PROP_STRIDE: int = 5
const PROP_RHO: int = 0
const PROP_C: int = 1
const PROP_MOL_PER_KG: int = 2
const PROP_ENTRY: int = 3
const PROP_LAMBDA: int = 4

var _pipe: RID = RID()
var _set: RID = RID()


## Read by reduce rows on the device and by no CPU consumer, so they are this pass's own rather than
## LAChannels.derived_buffers() entries the driver would copy back on every drain.
func _buffers(cc: int) -> Dictionary:
	return {"speed": cc, "lat": cc, "alt": cc, "nonfinite": cc,
		"h_h2o": cc, "h_silicate": cc, "h_sensible": cc, "cap_sensible": cc}


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	if not LAMatterChannels.covers_the_matter_channels("StateDerivePass"):
		return
	var props: PackedFloat32Array = _props()
	if props.is_empty():
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
		entries.append([i, _single(bufs, channels[i])])
	entries.append([24, props_ssbo])
	for name in BOUND:
		entries.append([int(BOUND[name]), _single(bufs, String(name))])
	_set = _uset(_pipe, entries)


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	var w: Vector3 = ctx.get("spin", Vector3.ZERO) * LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S
	var centre: Vector3 = ctx.get("centre", Vector3.ZERO)
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(44)
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
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


## One row per channel, from the substance table. No value is declared here; the mass column is the one
## LAMatterChannels publishes, so gravity and heat capacity weigh the same cell.
func _props() -> PackedFloat32Array:
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	var rho_units: PackedFloat32Array = LAMatterChannels.rho_units()
	if rho_units.size() != channels.size():
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
		var rho: float = rho_units[i]
		var unit: String = String(row.get("unit", ""))
		if unit != "vf":
			push_error("StateDerivePass: LAChannels row \"%s\" declares unit \"%s\", not \"vf\". " % [name, unit]
				+ "Matter is a volume fraction of the cell; without it the channel's mass is a guess.")
			return PackedFloat32Array()
		var entry: int = LAMatterChannels.entry_of(id)
		var c: float = LAMatterChannels.specific_heat(id)
		if entry == LAMatterChannels.Entry.SENSIBLE and c <= 0.0:
			return PackedFloat32Array()
		var mol_per_kg: float = 0.0
		if LAMatterChannels.GASES.has(id):
			var m: float = float(s.get("molar_mass", 0.0))
			if m <= 0.0:
				push_error("StateDerivePass: LASubstances has no molar mass for the gas \"%s\"." % id)
				return PackedFloat32Array()
			mol_per_kg = 1.0 / m
		var lambda_w_mk: float = float(s.get("conductivity", 0.0))
		if lambda_w_mk <= 0.0:
			push_error("StateDerivePass: LASubstances gives \"%s\" no conductivity, so channel %s "
				% [id, name] + "would carry mass that conducts no heat.")
			return PackedFloat32Array()
		var base: int = i * PROP_STRIDE
		out[base + PROP_LAMBDA] = lambda_w_mk
		out[base + PROP_RHO] = rho
		out[base + PROP_C] = c
		out[base + PROP_MOL_PER_KG] = mol_per_kg
		out[base + PROP_ENTRY] = float(entry)
	return out
