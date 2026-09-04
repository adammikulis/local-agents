class_name LAChannels
extends RefCounted

## The one declaration of what a channel is. `phase` is "solid" / "liquid" / "gas", or "" when derived
## from enthalpy. `unit` is "mol_m3", moles of substance per m^3 of cell, or "" for not an amount of matter.
static func rows() -> Dictionary:
	var D: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")
	return {
		"e_j_m3":      {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"e_lith_j_m3": {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"h2o":         {"residency": "hot",         "slot": D.H2O,       "substance": "h2o",        "phase": "",       "unit": "mol_m3", "kind": "state"},
		"h2o_pore":    {"residency": "slow",        "slot": -1,          "substance": "h2o",        "phase": "",       "unit": "mol_m3", "kind": "state", "lattice": true},
		"silicate":    {"residency": "slow",        "slot": D.SILICATE,  "substance": "silicate",   "phase": "",       "unit": "mol_m3", "kind": "state", "lithic": true},
		"metal":       {"residency": "static",      "slot": D.METAL,       "substance": "metal",       "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"olivine":     {"residency": "static",      "slot": D.OLIVINE,     "substance": "olivine",     "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"pyroxene":    {"residency": "static",      "slot": D.PYROXENE,    "substance": "pyroxene",    "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"plagioclase": {"residency": "static",      "slot": D.PLAGIOCLASE, "substance": "plagioclase", "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"halite":      {"residency": "static",      "slot": D.HALITE,      "substance": "halite",      "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"apatite":     {"residency": "static",      "slot": D.APATITE,     "substance": "apatite",     "phase": "solid", "unit": "mol_m3", "kind": "state", "lithic": true},
		"cement":      {"residency": "slow",        "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"carbonate":   {"residency": "hot",         "slot": D.CARBONATE, "substance": "carbonate",  "phase": "solid",  "unit": "mol_m3", "kind": "state", "lithic": true},
		"silica":      {"residency": "hot",         "slot": D.SILICA,    "substance": "silica",     "phase": "solid",  "unit": "mol_m3", "kind": "state", "lithic": true},
		"o2":          {"residency": "hot",         "slot": D.O2,        "substance": "o2",         "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"co2":         {"residency": "situational", "slot": D.CO2,       "substance": "co2",        "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"n2":          {"residency": "hot",         "slot": D.N2,        "substance": "n2",         "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"h2":          {"residency": "situational", "slot": D.H2,        "substance": "h2",         "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"co":          {"residency": "situational", "slot": D.CO,        "substance": "co",         "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"so2":         {"residency": "situational", "slot": D.SO2,       "substance": "so2",        "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"h2s":         {"residency": "situational", "slot": D.H2S,       "substance": "h2s",        "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"ch4":         {"residency": "situational", "slot": D.CH4,       "substance": "ch4",        "phase": "gas",    "unit": "mol_m3", "kind": "state"},
		"biomass":     {"residency": "slow",        "slot": D.BIOMASS,   "substance": "cellulose",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"fungus":      {"residency": "situational", "slot": D.FUNGUS,    "substance": "cellulose",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"detritus":    {"residency": "situational", "slot": D.DETRITUS,  "substance": "organic_c",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"fuel":        {"residency": "situational", "slot": D.FUEL,      "substance": "organic_c",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"org_h":       {"residency": "situational", "slot": D.ORG_H,     "substance": "organic_h",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"org_o":       {"residency": "situational", "slot": D.ORG_O,     "substance": "organic_o",  "phase": "solid",  "unit": "mol_m3", "kind": "state"},
		"fert":        {"residency": "slow",        "slot": D.FERT,      "substance": "fixed_n",    "phase": "dissolved", "unit": "mol_m3", "kind": "state"},
		"charge":      {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_x":       {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_y":       {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"mom_z":       {"residency": "hot",         "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"porosity":    {"residency": "slow",        "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"regolith":    {"residency": "static",      "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
		"grain":       {"residency": "static",      "slot": -1,          "substance": "",           "phase": "",       "unit": "", "kind": "state"},
	}


## Buffers a pass recomputes from the channels every step, and the driver copies back on every drain.
static func derived_buffers() -> PackedStringArray:
	return PackedStringArray(["temp", "temp_lith", "conductivity_lith", "h2o_solid", "h2o_liquid", "h2o_vapour", "liquid", "silicate_melt",
		"silicate_susp_water", "silicate_susp_air", "silicate_bed", "vel_x", "vel_y", "vel_z",
		"pressure", "p_fluid", "rho_bulk", "conductivity", "solid", "fire", "discharge",
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


## Every channel, one buffer each. A pass edits its channel in place, so no channel has a second copy.
static func channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in rows():
		out.append(String(name))
	return out


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


## Channels that sit in the lattice by its cement share: the lithic phases and the water in their pores.
static func lattice_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var tbl: Dictionary = rows()
	for name in tbl:
		if bool(tbl[name].get("lithic", false)) or bool(tbl[name].get("lattice", false)):
			out.append(String(name))
	return out


## Channels holding a mineral or metal phase: every row declared lithic.
static func lithosphere_channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var tbl: Dictionary = rows()
	for name in tbl:
		if bool(tbl[name].get("lithic", false)):
			out.append(String(name))
	return out
