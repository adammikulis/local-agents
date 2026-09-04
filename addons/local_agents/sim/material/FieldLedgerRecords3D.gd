class_name LAFieldLedgerRecords
extends RefCounted

## Which channels each conserved substance is made of. Data for LAMaterialFieldLedger3D; no state, no walk.

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")

## The planet's water: the free channel, whose phase is derived from its enthalpy, and the rock's pore
## water. Every cell, no residency mask.
const H2O: PackedStringArray = ["h2o", "h2o_pore"]

## The lithosphere. Reactions move matter between these channels, so the conserved stock is elemental Si.
const MINERAL: PackedStringArray = ["silicate", "carbonate", "silica", "olivine", "pyroxene",
	"plagioclase", "metal", "halite", "apatite"]
## The atmosphere/biosphere element book.
const ELEMENT: PackedStringArray = ["co2", "o2", "detritus", "biomass", "fert", "fungus", "fuel", "n2",
	"org_h", "org_o", "h2", "co", "so2", "h2s", "ch4"]
## The reaction table's closed carbon triangle.
const CARBON: PackedStringArray = ["co2", "biomass", "detritus"]
## Carbon over every pool that carries it, not only the three the reaction table moves between.
const CARBON_CLOSED: PackedStringArray = ["co2", "biomass", "detritus", "fungus", "fuel", "carbonate",
	"co", "ch4"]
## O2-equivalent sum the reaction table holds.
const OXIDANT: PackedStringArray = ["o2", "co2"]


## The energy stock: the fluid's reservoir and the lattice's.
static func energy() -> PackedStringArray:
	return PackedStringArray(["e_j_m3", "e_lith_j_m3"])


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
