extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## TEMPERATURE AND PHASE FROM STORED ENTHALPY. Reads `h_j_m3` (J/m^3), the substance amounts and `pressure`,
## and writes the derived `temp` (deg C), the three velocity components, the h2o solid/liquid/vapour shares
## and the silicate melt share. It writes no channel and mutates no state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/state_derive.glsl"

## Derived phase shares the kernel writes, name -> state_derive.glsl binding.
const PHASE_BUFFERS: Dictionary = {
	"h2o_solid": 34, "h2o_liquid": 35, "h2o_vapour": 36, "silicate_melt": 37}

## props row layout — state_derive.glsl PROP_*.
const PROP_STRIDE: int = 5
const PROP_RHO: int = 0
const PROP_C: int = 1
const PROP_MOL_PER_KG: int = 2
const PROP_ENTRY: int = 3
const PROP_LAMBDA: int = 4

## Mixture entries — state_derive.glsl E_*.
const E_H2O: int = 0
const E_SILICATE: int = 1
const E_SENSIBLE: int = 2

## Substances the table gives no melt and no boil, so they stay gas at every temperature this planet
## reaches. Their moles are the non-condensable denominator of the Dalton vapour split.
const GASES: PackedStringArray = ["o2", "co2", "n2"]

## Substance id -> the mixture entry that carries its phase ladder.
const LADDER: Dictionary = {"h2o": E_H2O, "silicate": E_SILICATE}

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]     # one uniform set per ping-pong parity


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
	want.append_array(PackedStringArray(["h_j_m3", "pressure", "temp", "cell_vol", "conductivity",
		"n_gas_m3", "rho_cond", "mom_x", "mom_y", "mom_z", "vel_x", "vel_y", "vel_z"]))
	want.append_array(PackedStringArray(PHASE_BUFFERS.keys()))
	var missing: PackedStringArray = LAMatterChannels.absent(bufs, want)
	if not missing.is_empty():
		push_error("StateDerivePass: no buffer for %s, so no cell would get a temperature."
			% String(", ").join(missing))
		return
	if not _single(bufs, "temp").is_valid():
		push_error("StateDerivePass: `temp` is not a SINGLE buffer. It is derived, so it has no back half.")
		return

	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	for p in 2:
		var entries: Array = []
		for i in channels.size():
			entries.append([i, _half(bufs, channels[i], p, false)])
		entries.append([21, _half(bufs, "h_j_m3", p, false)])   # FRONT: the settled enthalpy
		entries.append([22, _single(bufs, "pressure")])
		entries.append([23, _single(bufs, "temp")])
		entries.append([24, props_ssbo])
		entries.append([25, _half(bufs, "mom_x", p, false)])
		entries.append([26, _half(bufs, "mom_y", p, false)])
		entries.append([27, _half(bufs, "mom_z", p, false)])
		entries.append([28, _single(bufs, "vel_x")])
		entries.append([29, _single(bufs, "vel_y")])
		entries.append([30, _single(bufs, "vel_z")])
		entries.append([31, _single(bufs, "n_gas_m3")])
		entries.append([32, _single(bufs, "rho_cond")])
		entries.append([33, _single(bufs, "conductivity")])
		entries.append([40, _single(bufs, "cell_vol")])
		for name in PHASE_BUFFERS:
			entries.append([int(PHASE_BUFFERS[name]), _single(bufs, String(name))])
		_set[p] = _uset(_pipe, entries)


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set[parity].is_valid():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
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
		var entry: int = int(LADDER.get(id, E_SENSIBLE))
		var c: float = 0.0
		if entry == E_SENSIBLE:
			c = float(s.get("specific_heat_gas", 0.0)) if GASES.has(id) else 0.0
			if c <= 0.0:
				c = float(s.get("specific_heat", 0.0))
			if c <= 0.0:
				push_error("StateDerivePass: LASubstances gives \"%s\" no specific heat, so channel %s "
					% [id, name] + "would carry mass with no heat capacity.")
				return PackedFloat32Array()
		var mol_per_kg: float = 0.0
		if GASES.has(id):
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
