class_name LAMatterChannels
extends RefCounted

## THE MATTER CHANNELS THE KERNELS BIND, AND THE ONE WEIGHING OF THEM.
## `kernels3d/matter_channels.glsli` is the GPU half: same order, same binding slots, same switch.

## Mixture entries — state_derive.glsl E_*. Two substances carry a phase ladder; the rest are linear in T.
enum Entry { H2O, SILICATE, SENSIBLE }

const LADDER: Dictionary = {"h2o": Entry.H2O, "silicate": Entry.SILICATE}

## No melt and no boil in this planet's range, so their moles are the Dalton vapour split's denominator.
const GASES: PackedStringArray = ["o2", "co2", "n2"]


## Which mixture entry a substance's enthalpy sits in.
static func entry_of(id: String) -> int:
	return int(LADDER.get(id, Entry.SENSIBLE))


## J/kg/K a substance holds sensible heat at, or 0 for one on a phase ladder (whose enthalpy comes off
## the ladder, not off a single capacity). Empty table entry -> 0 and a named error.
static func specific_heat(id: String) -> float:
	# A row naming no substance carries no matter, so it has no capacity to look up.
	if id == "" or entry_of(id) != Entry.SENSIBLE:
		return 0.0
	var s: Dictionary = LASubstances.table().get(id, {})
	var c: float = float(s.get("specific_heat_gas", 0.0)) if GASES.has(id) else 0.0
	if c <= 0.0:
		c = float(s.get("specific_heat", 0.0))
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
	"fert"]

## Cases in the include's `channel_at` switch. A mismatch drops a substance out of every kernel that
## weighs a cell.
const KERNEL_SLOTS: int = 14


## kg/m^3 one unit of a channel's fill carries, in CHANNELS order. Phase does not enter it: the fill is a
## volume fraction at the substance's declared density, so freezing moves no mass. Empty when the table
## gives a channel's substance no density, which is a missing measurement rather than a zero.
static func rho_units() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(CHANNELS.size())
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	for i in CHANNELS.size():
		var name: String = CHANNELS[i]
		var id: String = String(rows.get(name, {}).get("substance", ""))
		var rho: float = float(table.get(id, {}).get("density", 0.0))
		if rho <= 0.0:
			push_error("LAMatterChannels: LASubstances has no density for \"%s\" (channel %s), so its "
				% [id, name] + "mass cannot be weighed.")
			return PackedFloat32Array()
		out[i] = rho
	return out


## The names in `want` that `bufs` has no buffer for.
static func absent(bufs: Dictionary, want: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name: String in want:
		var v: Variant = bufs.get(name, null)
		if not (v is RID and (v as RID).is_valid()):
			out.append(name)
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
		+ "Add the binding to kernels3d/matter_channels.glsli and the name here, in the same order.")
	return false
