class_name LAChannels
extends RefCounted

## THE ONE DECLARATION OF WHAT A CHANNEL IS.
##
static func rows() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		"temp":        {"buffer": "pair",   "residency": "hot",         "slot": D.TEMP,      "substance": "",           "heat": ""},
		"water":       {"buffer": "pair",   "residency": "hot",         "slot": D.WATER,     "substance": "h2o",        "heat": "WATER_LIQUID"},
		"moisture":    {"buffer": "pair",   "residency": "hot",         "slot": D.MOISTURE,  "substance": "h2o",        "heat": "WATER_VAPOUR"},
		"snow":        {"buffer": "single", "residency": "hot",         "slot": D.SNOW,      "substance": "h2o",        "heat": "WATER_SOLID"},
		"soil":        {"buffer": "pair",   "residency": "slow",        "slot": D.SOIL_ROOT, "substance": "h2o",        "heat": "WATER_LIQUID"},
		"lava":        {"buffer": "pair",   "residency": "situational", "slot": D.LAVA,      "substance": "silicate",   "heat": "SILICATE"},
		"rock_fill":   {"buffer": "single", "residency": "situational", "slot": D.ROCK_FILL, "substance": "silicate",   "heat": "MATRIX"},
		"sediment":    {"buffer": "pair",   "residency": "slow",        "slot": D.SEDIMENT,  "substance": "silicate",   "heat": "SILICATE"},
		"susp":        {"buffer": "pair",   "residency": "slow",        "slot": D.SUSP,      "substance": "silicate",   "heat": "SILICATE"},
		"dust":        {"buffer": "pair",   "residency": "situational", "slot": D.DUST,      "substance": "silicate",   "heat": "SILICATE"},
		"carbonate":   {"buffer": "single", "residency": "hot",         "slot": D.CARBONATE, "substance": "carbonate",  "heat": "CARBONATE"},
		"silica":      {"buffer": "single", "residency": "hot",         "slot": D.SILICA,    "substance": "silica",     "heat": "SILICA"},
		"o2":          {"buffer": "pair",   "residency": "hot",         "slot": D.O2,        "substance": "o2",         "heat": ""},
		"co2":         {"buffer": "pair",   "residency": "situational", "slot": D.CO2,       "substance": "co2",        "heat": ""},
		"n2":          {"buffer": "pair",   "residency": "hot",         "slot": D.N2,        "substance": "n2",         "heat": ""},
		"biomass":     {"buffer": "single", "residency": "slow",        "slot": D.BIOMASS,   "substance": "cellulose",  "heat": "ORGANIC"},
		"fungus":      {"buffer": "pair",   "residency": "situational", "slot": D.FUNGUS,    "substance": "cellulose",  "heat": "ORGANIC"},
		"detritus":    {"buffer": "single", "residency": "situational", "slot": D.DETRITUS,  "substance": "organic_c",  "heat": "ORGANIC"},
		"fuel":        {"buffer": "single", "residency": "situational", "slot": D.FUEL,      "substance": "organic_c",  "heat": "ORGANIC"},
		"org_h":       {"buffer": "single", "residency": "situational", "slot": D.ORG_H,     "substance": "organic_h",  "heat": ""},
		"org_o":       {"buffer": "single", "residency": "situational", "slot": D.ORG_O,     "substance": "organic_o",  "heat": ""},
		"fert":        {"buffer": "pair",   "residency": "slow",        "slot": D.FERT,      "substance": "fixed_n",    "heat": ""},
		"fire":        {"buffer": "pair",   "residency": "situational", "slot": D.FIRE,      "substance": "",           "heat": ""},
		"charge":      {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"discharge":   {"buffer": "single", "residency": "hot",         "slot": D.DISCHARGE, "substance": "",           "heat": ""},
		"shock":       {"buffer": "pair",   "residency": "situational", "slot": -1,          "substance": "",           "heat": ""},
		"air":         {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"pressure":    {"buffer": "single", "residency": "situational", "slot": -1,          "substance": "",           "heat": ""},
		"vel_x":       {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"vel_y":       {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"vel_z":       {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"fungus_fert": {"buffer": "single", "residency": "hot",         "slot": -1,          "substance": "",           "heat": ""},
		"porosity":    {"buffer": "single", "residency": "slow",        "slot": -1,          "substance": "",           "heat": ""},
		"solid":       {"buffer": "single", "residency": "static",      "slot": -1,          "substance": "",           "heat": ""},
		"regolith":    {"buffer": "single", "residency": "static",      "slot": -1,          "substance": "",           "heat": ""},
		"grain":       {"buffer": "single", "residency": "static",      "slot": -1,          "substance": "",           "heat": ""},
	}


## Reaction slots that no channel backs: the kernel derives them from other state each step. A driver here
## may never be a reactant or a product, which is what LAReactionBalance.driver_only() enforces.
static func derived_slots() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		D.WINDSPEED:       {"from": "sqrt(vel_x^2 + vel_z^2)", "substance": ""},
		D.LIGHT:           {"from": "insolation at this cell", "substance": ""},
		D.SOIL_ROOT:       {"from": "soil over the whole rooting column", "substance": "h2o"},
		D.VAPOUR_DEFICIT:  {"from": "sat(T) - moisture", "substance": ""},
		D.SOIL_TOP:        {"from": "soil of the first regolith cell below an open one", "substance": "h2o"},
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


## Channels in one LAHeatCapacity group.
static func heat_group(group: String) -> PackedStringArray:
	return _by("heat", group)
