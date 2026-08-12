class_name LAChannels
extends RefCounted

## THE ONE DECLARATION OF WHAT A CHANNEL IS.
##
## `phase` is the state of matter the channel holds — "solid", "liquid", "gas", or "" when the channel's
## phase is DERIVED from its enthalpy rather than stored. `unit` is what the stored number means: "vf" a
## volume fraction of the whole cell, "sat" a saturation of the pore space (multiply by 1 - porosity for a
## volume fraction), "" not an amount of matter at all.
static func rows() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		"h_j_m3":      {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"h2o":         {"buffer": "pair",   "residency": "hot",         "slot": D.H2O,       "substance": "h2o",        "phase": "",       "unit": "vf", "kind": "state"},
		"lava":        {"buffer": "pair",   "residency": "situational", "slot": D.LAVA,      "substance": "silicate",   "phase": "liquid", "unit": "vf", "kind": "state"},
		"rock_fill":   {"buffer": "single", "residency": "situational", "slot": D.ROCK_FILL, "substance": "silicate",   "phase": "solid",  "unit": "sat", "kind": "state"},
		"sediment":    {"buffer": "pair",   "residency": "slow",        "slot": D.SEDIMENT,  "substance": "silicate",   "phase": "solid",  "unit": "vf", "kind": "state"},
		"susp":        {"buffer": "pair",   "residency": "slow",        "slot": D.SUSP,      "substance": "silicate",   "phase": "solid",  "unit": "vf", "kind": "state"},
		"dust":        {"buffer": "pair",   "residency": "situational", "slot": D.DUST,      "substance": "silicate",   "phase": "solid",  "unit": "vf", "kind": "state"},
		"carbonate":   {"buffer": "single", "residency": "hot",         "slot": D.CARBONATE, "substance": "carbonate",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"silica":      {"buffer": "single", "residency": "hot",         "slot": D.SILICA,    "substance": "silica",     "phase": "solid",  "unit": "vf", "kind": "state"},
		"o2":          {"buffer": "pair",   "residency": "hot",         "slot": D.O2,        "substance": "o2",         "phase": "gas",    "unit": "vf", "kind": "state"},
		"co2":         {"buffer": "pair",   "residency": "situational", "slot": D.CO2,       "substance": "co2",        "phase": "gas",    "unit": "vf", "kind": "state"},
		"n2":          {"buffer": "pair",   "residency": "hot",         "slot": D.N2,        "substance": "n2",         "phase": "gas",    "unit": "vf", "kind": "state"},
		"biomass":     {"buffer": "single", "residency": "slow",        "slot": D.BIOMASS,   "substance": "cellulose",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"fungus":      {"buffer": "single", "residency": "situational", "slot": D.FUNGUS,    "substance": "cellulose",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"detritus":    {"buffer": "single", "residency": "situational", "slot": D.DETRITUS,  "substance": "organic_c",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"fuel":        {"buffer": "single", "residency": "situational", "slot": D.FUEL,      "substance": "organic_c",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"org_h":       {"buffer": "single", "residency": "situational", "slot": D.ORG_H,     "substance": "organic_h",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"org_o":       {"buffer": "single", "residency": "situational", "slot": D.ORG_O,     "substance": "organic_o",  "phase": "solid",  "unit": "vf", "kind": "state"},
		"fert":        {"buffer": "pair",   "residency": "slow",        "slot": D.FERT,      "substance": "fixed_n",    "phase": "solid",  "unit": "vf", "kind": "state"},
		"charge":      {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"shock":       {"buffer": "pair",   "residency": "situational", "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_x":       {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_y":       {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_z":       {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"porosity":    {"buffer": "single", "residency": "slow",        "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"regolith":    {"buffer": "single", "residency": "static",      "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"grain":       {"buffer": "single", "residency": "static",      "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
	}


## Buffers that hold no state: a pass recomputes each from the channels every step, so they are never
## seeded, never read back as truth and never conserved. Name -> the law that produces it.
static func derived_buffers() -> Dictionary:
	return {
		"temp": "the mixture's enthalpy ladder inverted at this cell's pressure",
		"h2o_solid": "share of this cell's h2o the ladder leaves below the melting point at this pressure",
		"h2o_liquid": "share of this cell's h2o that is condensed and above the melting point",
		"h2o_vapour": "share of this cell's h2o the saturation curve puts in the gas at this cell's pressure",
		"vel_x": "mom_x divided by the cell's mass",
		"vel_y": "mom_y divided by the cell's mass",
		"vel_z": "mom_z divided by the cell's mass",
		"pressure": "the weight of the column above, integrated along -g",
		"solid": "rock_fill past the lock-up threshold",
		"fire": "the share of a cell's usable oxygen that combustion consumed this step",
		"discharge": "stamped where the field exceeded the local breakdown strength",
	}


## Reaction slots that no channel backs: the kernel derives them from other state each step. A driver here
## may never be a reactant or a product, which is what LAReactionBalance.driver_only() enforces.
static func derived_slots() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		D.TEMP:            {"from": "the enthalpy ladder inverted over the cell mixture", "substance": ""},
		D.WINDSPEED:       {"from": "the flow tangential to -g, and velocity is momentum over mass", "substance": ""},
		D.LIGHT:           {"from": "insolation at this cell", "substance": ""},
		D.SOIL_ROOT:       {"from": "pore water over the whole rooting column", "substance": "h2o"},
		D.VAPOUR_DEFICIT:  {"from": "sat(T) - the cell's own h2o vapour", "substance": ""},
		D.SOIL_TOP:        {"from": "pore water of the first regolith cell below an open one", "substance": "h2o"},
		D.OVERBURDEN:      {"from": "lithostatic pressure of the solid column above", "substance": ""},
		D.BEDROCK_BELOW:   {"from": "rock_fill of the inward neighbour", "substance": "silicate"},
		D.ORG_C:           {"from": "detritus + fuel", "substance": ""},
	}


static func _by(field: String, want: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var tbl: Dictionary = rows()
	for name in tbl:
		if String(tbl[name].get(field, "")) == want:
			out.append(String(name))
	return out


static func pair_channels() -> PackedStringArray:
	return _by("buffer", "pair")


static func single_channels() -> PackedStringArray:
	return _by("buffer", "single")


static func situational_channels() -> PackedStringArray:
	return _by("residency", "situational")


static func slow_channels() -> PackedStringArray:
	return _by("residency", "slow")


## Channel name -> reaction slot, for every channel a reaction can read or write.
static func inventory_channels() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = rows()
	for name in tbl:
		var slot: int = int(tbl[name].get("slot", -1))
		if slot >= 0 and String(tbl[name].get("substance", "")) != "":
			out[String(name)] = slot
	return out


## Reaction slot -> LASubstances id, for every slot whose contents are matter. A DERIVED slot can still be
## matter — SOIL_TOP is water and BEDROCK_BELOW is silicate — and the balance gate has to count it.
static func slot_substance() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = rows()
	for name in tbl:
		var slot: int = int(tbl[name].get("slot", -1))
		var sub: String = String(tbl[name].get("substance", ""))
		if slot >= 0 and sub != "":
			out[slot] = sub
	var der: Dictionary = derived_slots()
	for slot in der:
		var ds: String = String(der[slot].get("substance", ""))
		if ds != "":
			out[int(slot)] = ds
	return out


## Channels holding the one mineral substance, in any phase.
static func lithosphere_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var tbl: Dictionary = rows()
	for name in tbl:
		var sub: String = String(tbl[name].get("substance", ""))
		if sub == "silicate" or sub == "carbonate" or sub == "silica":
			out.append(String(name))
	return out


## Channels whose matter enters the cell mixture BY MASS, paired with what their number means. Keyed by
## channel: {"substance": id, "unit": "vf" | "sat"}. A "sat" channel is a share of the pore space, so a
## volume fraction of the cell is its value times 1 - porosity. A channel declared "gas" is excluded: it is
## the non-condensable denominator of the saturation split, counted in moles instead.
static func mixture_channels() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = rows()
	for name in tbl:
		var sub: String = String(tbl[name].get("substance", ""))
		if sub == "" or String(tbl[name].get("phase", "")) == "gas":
			continue
		out[String(name)] = {"substance": sub, "unit": String(tbl[name].get("unit", "vf"))}
	return out
