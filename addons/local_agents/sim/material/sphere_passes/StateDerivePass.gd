extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## TEMPERATURE AND PHASE FROM STORED ENTHALPY. Reads `h_j_m3` (J/m^3), the substance amounts and `pressure`,
## and writes the derived `temp` (deg C), the three velocity components, the h2o solid/liquid/vapour shares
## and the silicate melt share. It writes no channel and mutates no state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/state_derive.glsl"

## Channel binding order. The kernel's `channel_at` switch IS this list and props[i] describes CHANNELS[i].
const CHANNELS: PackedStringArray = [
	"h2o",
	"silicate", "carbonate", "silica",
	"o2", "co2", "n2",
	"biomass", "fungus", "detritus", "fuel", "org_h", "org_o",
	"fert"]

## Cases in the kernel's `channel_at` switch. A mismatch drops a substance's heat capacity silently.
const KERNEL_CHANNEL_SLOTS: int = 14

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
	if CHANNELS.size() != KERNEL_CHANNEL_SLOTS:
		push_error("StateDerivePass: CHANNELS holds %d channels and state_derive.glsl switches on %d."
			% [CHANNELS.size(), KERNEL_CHANNEL_SLOTS])
		return
	if not _covers_the_matter_channels():
		return
	var props: PackedFloat32Array = _props()
	if props.is_empty():
		return
	var props_ssbo: RID = _storage_buffer(props.to_byte_array())

	var missing: PackedStringArray = PackedStringArray()
	for name: String in CHANNELS:
		if not _half(bufs, name, 0, false).is_valid():
			missing.append(name)
	for name: String in ["h_j_m3", "pressure", "temp", "cell_vol", "conductivity",
			"n_gas_m3", "rho_cond", "mom_x", "mom_y", "mom_z", "vel_x", "vel_y", "vel_z"]:
		if not _half(bufs, name, 0, false).is_valid():
			missing.append(name)
	for name in PHASE_BUFFERS:
		if not _single(bufs, String(name)).is_valid():
			missing.append(String(name))
	if not missing.is_empty():
		push_error("StateDerivePass: no buffer for %s, so no cell would get a temperature."
			% String(", ").join(missing))
		return
	if not _single(bufs, "temp").is_valid():
		push_error("StateDerivePass: `temp` is not a SINGLE buffer. It is derived, so it has no back half.")
		return

	for p in 2:
		var entries: Array = []
		for i in CHANNELS.size():
			entries.append([i, _half(bufs, CHANNELS[i], p, false)])
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


## Every channel LAChannels declares as matter must be in CHANNELS, or the cell's temperature is read off
## an incomplete heat capacity.
func _covers_the_matter_channels() -> bool:
	var rows: Dictionary = LAChannels.rows()
	var uncovered: PackedStringArray = PackedStringArray()
	for name in rows:
		if String(rows[name].get("substance", "")) != "" and not CHANNELS.has(String(name)):
			uncovered.append(String(name))
	var unknown: PackedStringArray = PackedStringArray()
	for name: String in CHANNELS:
		if not rows.has(name) or String(rows[name].get("substance", "")) == "":
			unknown.append(name)
	if uncovered.is_empty() and unknown.is_empty():
		return true
	push_error("StateDerivePass: CHANNELS disagrees with LAChannels. Not bound: [%s]. Not matter: [%s]. "
		% [String(", ").join(uncovered), String(", ").join(unknown)]
		+ "Add the binding to state_derive.glsl's channel_at switch and the name here, in the same order.")
	return false


## One row per channel, from the substance table. No value is declared here.
func _props() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(CHANNELS.size() * PROP_STRIDE)
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	for i in CHANNELS.size():
		var name: String = CHANNELS[i]
		var row: Dictionary = rows[name]
		var id: String = String(row.get("substance", ""))
		var s: Dictionary = table.get(id, {})
		var rho: float = float(s.get("density", 0.0))
		if rho <= 0.0:
			push_error("StateDerivePass: LASubstances has no density for \"%s\" (channel %s), so its mass "
				% [id, name] + "cannot be weighed and its heat capacity would vanish.")
			return PackedFloat32Array()
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
