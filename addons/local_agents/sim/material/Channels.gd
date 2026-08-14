class_name LAChannels
extends RefCounted

## The one declaration of what a channel is. `phase` is "solid" / "liquid" / "gas", or "" when derived
## from enthalpy. `unit` is "vf", a volume fraction of the cell, or "" for not an amount of matter.
static func rows() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		"h_j_m3":      {"buffer": "pair",   "residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"h2o":         {"buffer": "pair",   "residency": "hot",         "slot": D.H2O,       "substance": "h2o",        "phase": "",       "unit": "vf", "kind": "state"},
		"silicate":    {"buffer": "pair",   "residency": "slow",        "slot": D.SILICATE,  "substance": "silicate",   "phase": "",       "unit": "vf", "kind": "state"},
		"cement":      {"buffer": "single", "residency": "slow",        "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
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


## Buffers a pass recomputes from the channels every step, and the driver copies back on every drain.
static func derived_buffers() -> PackedStringArray:
	return PackedStringArray(["temp", "h2o_solid", "h2o_liquid", "h2o_vapour", "silicate_melt",
		"silicate_susp_water", "silicate_susp_air", "silicate_bed", "vel_x", "vel_y", "vel_z",
		"pressure", "rho_bulk", "conductivity", "solid", "fire", "discharge",
		"rad_absorbed", "rad_emitted"])


## Reaction slots that no channel backs; the kernel derives them from other state each step. Slot -> the
## LASubstances id it holds, or "" where the slot is not an amount of matter.
static func derived_slots() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {D.TEMP: "", D.WINDSPEED: "", D.LIGHT: "", D.SOIL_ROOT: "h2o", D.VAPOUR_DEFICIT: "",
		D.SOIL_TOP: "h2o", D.BEDROCK_BELOW: "silicate", D.ORG_C: ""}


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


## Reaction slot -> LASubstances id, for every slot whose contents are matter, derived slots included.
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
		if String(der[slot]) != "":
			out[int(slot)] = String(der[slot])
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


## Channels entering the cell mixture by mass: name -> {"substance": id, "unit": "vf"}. Gas is excluded:
## it is the non-condensable denominator of the saturation split, counted in moles.
static func mixture_channels() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = rows()
	for name in tbl:
		var sub: String = String(tbl[name].get("substance", ""))
		if sub == "" or String(tbl[name].get("phase", "")) == "gas":
			continue
		out[String(name)] = {"substance": sub, "unit": String(tbl[name].get("unit", "vf"))}
	return out
