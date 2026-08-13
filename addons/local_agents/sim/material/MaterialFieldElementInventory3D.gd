class_name LAMaterialFieldElementInventory3D
extends RefCounted

## Channel amounts -> moles of element, through the reaction-balance composition table.

## The one declaration of what each channel is MADE OF, shared with the load-time reaction balance gate.
const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


## Channel amount (units x cell volume) -> MOLES of each element it contains, through the same
## LAReactionBalance declaration the load-time balance gate checks every record against. The one conversion:
## LAMaterialFieldElementProbe3D attributes per-pass element movement with this exact function.
static func elements_of(by_channel: Dictionary) -> Dictionary:
	var elements: Dictionary = {}
	for ch in by_channel:
		var parts: Dictionary = BalanceScript.channel_elements(ch)
		var moles: float = float(by_channel[ch])
		for el in parts:
			elements[el] = float(elements.get(el, 0.0)) + moles * float(parts[el])
	return elements


## Every stored channel whose composition carries `element`. The probe reads only these, so asking where the
## carbon went costs six channel reads rather than nineteen.
static func channels_with(element: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in BalanceScript.inventory_channels():
		if BalanceScript.channel_elements(ch).has(element):
			out.append(String(ch))
	return out


## Every element any stored channel carries.
static func all_elements() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in BalanceScript.inventory_channels():
		for el in BalanceScript.channel_elements(ch):
			if not out.has(String(el)):
				out.append(String(el))
	return out
