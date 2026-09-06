class_name LAFakes
extends RefCounted

## Every stand-in this world runs on, one record each: what it stands in for, the file and greppable
## expression standing in on it, and exactly one of `rung` (the ladder rung whose landing deletes it) or
## `release`. docs/FAKES.md is the same list in prose; scripts/check_fakes.sh holds the three together.
const RECORDS: Array[Dictionary] = [
	{"name": "drinking_water", "rung": LAProcessSet.ADVECT,
		"file": "addons/local_agents/creatures/creature/CreatureThirst.gd",
		"expression": "LAFakes.draw(\"drinking_water\"",
		"stands_in": "Rain, springs and rivers wetting ground away from the sea. Nothing on this world moves water over the surface, so an animal born inland can never reach any."},
	{"name": "breathable_o2", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/creatures/creature/CreatureRespiration.gd",
		"expression": "LAFakes.draw(\"breathable_o2\"",
		"stands_in": "Free atmospheric oxygen. The seeded 4.4 Ga air has none, so nothing that breathes can oxidise anything."},
	{"name": "plant_carbon", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/actors/Plant.gd",
		"expression": "LAFakes.draw(\"plant_carbon\"",
		"stands_in": "Photosynthesis fixing CO2 into standing biomass under a plant, which a plant then draws on."},
	{"name": "founding_stock", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/material/MaterialFieldBiota3D.gd",
		"expression": "LAFakes.draw(\"founding_stock\"",
		"stands_in": "The matter a body is built out of. A creature that appears after the world sealed has no field to build itself from and no parent stock to draw on, so its elements are made here and booked."},
	{"name": "population_caps", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/ecology/EcologyPlants.gd",
		"expression": "LAFakes.capped(\"population_caps\"",
		"stands_in": "Carrying capacity. What bounds a population is the energy and carbon its ground fixes; with none on the field, an authored ceiling holds each species' numbers instead."},
	{"name": "recruitment_rate", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/ecology/EcologyBreeding.gd",
		"expression": "LAFakes.stands_in(\"recruitment_rate\")",
		"stands_in": "How many young a school produces, which is the food its adults convert into eggs. No field feeds a fish, so a fraction of the mature adults spawns each tick instead."},
	{"name": "species_tables", "release": "0.5 (traits from DNA loci)",
		"file": "addons/local_agents/sim/ecology/EcologyService.gd",
		"expression": "LAFakes.stands_in(\"species_tables\")",
		"stands_in": "Traits read off a genome's loci, sorted by what survives. Speed, senses, diet, hierarchy and which tree grows where are read from authored per-species rows instead."},
]

## name -> [made, returned, draws]. What a fake hands out is MADE here: there is no source behind it.
static var _books: Dictionary = {}


static func record(name: String) -> Dictionary:
	for r in RECORDS:
		if String(r["name"]) == name:
			return r
	return {}


## Is this stand-in still carrying the world? False once the rung that replaces it is in the world, so
## the real path takes over at the same seam and deleting the record is the whole swap.
static func stands_in(name: String) -> bool:
	var r: Dictionary = record(name)
	if r.is_empty():
		return false
	return LAProcessSet.active() < int(r["rung"]) if r.has("rung") else true


## An authored ceiling on a population, applied only while the fake that owns it stands in.
static func capped(name: String, count: int, ceiling: int) -> bool:
	return stands_in(name) and count >= ceiling


## Hand out `want`, made here and booked as made. The real path debits a channel at this same seam.
static func draw(name: String, want: float) -> float:
	if want <= 0.0 or not stands_in(name):
		return 0.0
	var b: Array = _books.get(name, [0.0, 0.0, 0])
	_books[name] = [float(b[0]) + want, b[1], int(b[2]) + 1]
	return want


## Give `amount` back to the fake rather than crediting the sealed field with mass it never had.
static func give_back(name: String, amount: float) -> void:
	if amount <= 0.0 or not stands_in(name):
		return
	var b: Array = _books.get(name, [0.0, 0.0, 0])
	_books[name] = [b[0], float(b[1]) + amount, b[2]]


static func reset() -> void:
	_books.clear()


## Every fake in force, what replaces it, and how much it has made.
static func report() -> Dictionary:
	var out: Dictionary = {}
	for r in RECORDS:
		var name: String = String(r["name"])
		if not stands_in(name):
			continue
		var b: Array = _books.get(name, [0.0, 0.0, 0])
		out[name] = {"until": LAProcessSet.name_of(int(r["rung"])) if r.has("rung") else String(r["release"]),
			"created": float(b[0]), "returned": float(b[1]), "draws": int(b[2])}
	return out
