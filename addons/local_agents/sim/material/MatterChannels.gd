class_name LAMatterChannels
extends RefCounted

## THE MATTER CHANNELS THE KERNELS BIND, AND THE ONE WEIGHING OF THEM.
## `kernels3d/matter_channels.glsli` is the GPU half: same order, same switch. LABindings owns the slots.

## Which of the three heat buffers carries a channel's enthalpy — state_derive.glsl E_*.
enum Entry { H2O, SILICATE, SENSIBLE }

const CARRIERS: Dictionary = {"h2o": Entry.H2O, "silicate": Entry.SILICATE}

## Gaseous through this planet's whole surface range; their moles are the Dalton split's denominator.
const GASES: PackedStringArray = ["o2", "co2", "n2", "h2", "co", "so2", "h2s", "ch4"]


## Which heat buffer a substance's enthalpy is carried in.
static func entry_of(id: String) -> int:
	return int(CARRIERS.get(id, Entry.SENSIBLE))


## J/kg/K of the phase a CHANNEL's row declares its matter stands in; the liquid column where the row
## leaves the phase to be derived from enthalpy. 0 for a channel whose entry is a heat buffer of its own,
## which needs no capacity share to be told apart from what rides beside it.
static func channel_specific_heat(channel: String) -> float:
	var row: Dictionary = LAChannels.rows().get(channel, {})
	var id: String = String(row.get("substance", ""))
	if id == "" or entry_of(id) != Entry.SENSIBLE:
		return 0.0
	var s: Dictionary = LASubstances.table().get(id, {})
	var c_liq: float = float(s.get("specific_heat", 0.0))
	var phase: String = String(row.get("phase", ""))
	var c: float = float(s.get("specific_heat_solid", c_liq)) if phase == "solid" \
		else (float(s.get("specific_heat_gas", c_liq)) if phase == "gas" else c_liq)
	if c <= 0.0:
		push_error("LAMatterChannels: LASubstances gives \"%s\" no specific heat, so matter of it would "
			% id + "carry mass with no heat capacity.")
	return c


## Binding order. The include's `channel_at` switch IS this list.
const CHANNELS: PackedStringArray = [
	"h2o",
	"silicate", "carbonate", "silica",
	"o2", "co2", "n2",
	"biomass", "fungus", "detritus", "fuel", "org_h", "org_o",
	"fert",
	"metal", "olivine", "pyroxene", "plagioclase", "halite", "apatite",
	"h2", "co", "so2", "h2s", "ch4",
	"h2o_pore"]

## Cases in the include's `channel_at` switch. A mismatch drops a substance out of every kernel that
## weighs a cell.
const KERNEL_SLOTS: int = 26


## kg one mole of a channel's substance carries, in CHANNELS order: a channel amount is mol/m^3, so mass
## per m^3 is amount times this. Empty when the table lacks a datum — a missing measurement is missing.
static func molar_masses() -> PackedFloat32Array:
	return _per_channel("molar_mass")


## mol/m^3 at which a cell is FULL of a channel's substance; amount/full is its volume fraction.
static func full_amounts() -> PackedFloat32Array:
	var out: PackedFloat32Array = _per_channel("density")
	var mm: PackedFloat32Array = molar_masses()
	if out.is_empty() or mm.is_empty():
		return PackedFloat32Array()
	for i in out.size():
		out[i] = out[i] / mm[i]
	return out


static func _per_channel(prop: String) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(CHANNELS.size())
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	for i in CHANNELS.size():
		var id: String = String(rows.get(CHANNELS[i], {}).get("substance", ""))
		var v: float = float(table.get(id, {}).get(prop, 0.0))
		if v <= 0.0:
			push_error("LAMatterChannels: LASubstances has no %s for \"%s\" (channel %s), so its "
				% [prop, id, CHANNELS[i]] + "mass cannot be weighed.")
			return PackedFloat32Array()
		out[i] = v
	return out


## Every channel LAChannels declares as matter must be in CHANNELS, or a cell is weighed incomplete.
## Names the disagreement and returns false.
static func covers_the_matter_channels(label: String) -> bool:
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
	push_error("%s: CHANNELS disagrees with LAChannels. Not bound: [%s]. Not matter: [%s]. "
		% [label, String(", ").join(uncovered), String(", ").join(unknown)]
		+ "Add the buffer to LABindings, kernels3d/matter_channels.glsli and the name here.")
	return false
