class_name LAFieldLedgerRecords
extends RefCounted

## Which channels each conserved substance is made of. Data for LAMaterialFieldLedger3D; no state, no walk.

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")

## The planet's water. ONE channel: every phase of H2O is the same stock, and which phase a cell's share
## is in is derived from its enthalpy, not stored. Every cell, no residency mask.
const H2O: PackedStringArray = ["h2o"]

## The lithosphere. `MINERAL_SUM` is the conserved total; carbonate and silica are memo lines outside it.
const MINERAL: PackedStringArray = ["silicate", "carbonate", "silica"]
const MINERAL_SUM: PackedStringArray = ["silicate"]
## Not matter: the derived state of the silicate. The crust gauge needs `cement` to tell rock from grains,
## the presence counts need the airborne share.
const FABRIC: PackedStringArray = ["cement", "silicate_susp_air"]

## The atmosphere/biosphere element book.
const ELEMENT: PackedStringArray = ["co2", "o2", "detritus", "biomass", "fert", "fungus", "fuel"]
## The reaction table's closed carbon triangle.
const CARBON: PackedStringArray = ["co2", "biomass", "detritus"]
## Carbon over every pool that carries it, not only the three the reaction table moves between.
const CARBON_CLOSED: PackedStringArray = ["co2", "biomass", "detritus", "fungus", "fuel"]
## O2-equivalent sum the reaction table holds.
const OXIDANT: PackedStringArray = ["o2", "co2"]
## Nitrogen-bearing organic pools, divided by LAPhysical.LITTER_C_TO_N in the ledger.
const NITROGEN_ORGANIC: PackedStringArray = ["biomass", "detritus", "fungus", "fuel"]


## The energy stock is one channel. It used to be the fifteen channels a mixture capacity read, plus the
## pore fraction that converted the matrix one.
static func energy() -> PackedStringArray:
	return PackedStringArray(["h_j_m3"])


## Union of every substance's legs — the one `request_probe` list.
static func all_legs() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for group in [energy(), H2O, MINERAL, ELEMENT, FABRIC]:
		for name in group:
			if not out.has(name):
				out.append(name)
	return out


## Moles of each element held by a set of channel amounts, from the same declaration the load-time reaction
## balance gate checks every record against. A channel amount IS moles, so nothing is converted here.
static func elements_of(by_channel: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for ch in by_channel:
		var parts: Dictionary = BalanceScript.channel_elements(ch)
		var moles: float = float(by_channel[ch])
		for el in parts:
			out[el] = float(out.get(el, 0.0)) + moles * float(parts[el])
	return out


## The same book restricted to the lithosphere channels.
static func lith_elements(by_channel: Dictionary) -> Dictionary:
	var only: Dictionary = {}
	for ch in BalanceScript.lithosphere_channels():
		only[ch] = float(by_channel.get(ch, 0.0))
	return elements_of(only)


## Sum a named subset out of a per-channel amount map.
static func sum_of(by_channel: Dictionary, group: PackedStringArray) -> float:
	var acc: float = 0.0
	for name in group:
		acc += float(by_channel.get(name, 0.0))
	return acc
