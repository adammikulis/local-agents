class_name LAFakes
extends RefCounted

## Every stand-in this world runs on: what it stands in for, the expression standing in on it, the one
## the field answers through (`real_seam`, empty while there is none), and one of `rung` or `release`.
## A record is a three-way switch on LAAblate; docs/FAKES.md is the same list, check_fakes.sh the gate.
const RECORDS: Array[Dictionary] = [
	{"name": "drinking_water", "rung": LAProcessSet.ADVECT,
		"file": "addons/local_agents/creatures/creature/CreatureThirst.gd",
		"expression": "LAFakes.draw(\"drinking_water\"", "real_seam": "c._material.drink_water(pos, want)",
		"stands_in": "Rain, springs and rivers wetting ground away from the sea. Nothing on this world moves water over the surface, so an animal born inland can never reach any."},
	{"name": "breathable_o2", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/creatures/creature/CreatureRespiration.gd",
		"expression": "LAFakes.draw(\"breathable_o2\"", "real_seam": "c._material.respire_at(pos, want)",
		"stands_in": "Free atmospheric oxygen. The seeded 4.4 Ga air has none, so nothing that breathes can oxidise anything."},
	{"name": "plant_carbon", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/actors/Plant.gd",
		"expression": "LAFakes.draw(\"plant_carbon\"", "real_seam": "_material.graze_biomass(pos, want_mass)",
		"stands_in": "Photosynthesis fixing CO2 into standing biomass under a plant, which a plant then draws on."},
	{"name": "founding_stock", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/material/MaterialFieldBiota3D.gd",
		"expression": "LAFakes.draw(\"founding_stock\"", "real_seam": "",
		"stands_in": "The matter a body is built out of. A creature that appears after the world sealed has no field to build itself from and no parent stock to draw on, so its elements are made here and booked."},
	{"name": "population_caps", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/ecology/EcologyPlants.gd",
		"expression": "LAFakes.capped(\"population_caps\"", "real_seam": "p.feed(SEED_RESERVE_COST)",
		"stands_in": "Carrying capacity. What bounds a population is the energy and carbon its ground fixes; with none on the field, an authored ceiling holds each species' numbers instead."},
	{"name": "recruitment_rate", "rung": LAProcessSet.CHEMISTRY,
		"file": "addons/local_agents/sim/ecology/EcologyBreeding.gd",
		"expression": "LAFakes.stands_in(\"recruitment_rate\")", "real_seam": "",
		"stands_in": "How many young a school produces, which is the food its adults convert into eggs. No field feeds a fish, so a fraction of the mature adults spawns each tick instead."},
	{"name": "species_tables", "release": "0.5 (traits from DNA loci)",
		"file": "addons/local_agents/sim/ecology/EcologyService.gd",
		"expression": "LAFakes.stands_in(\"species_tables\")", "real_seam": "",
		"stands_in": "Traits read off a genome's loci, sorted by what survives. Speed, senses, diet, hierarchy and which tree grows where are read from authored per-species rows instead. Body mass in kilograms is the one measured number a row may carry: the body's carbon, water, metabolic rate and mouth rate all derive from it."},
]

## name -> [made, returned, draws]. What a fake hands out is MADE here: there is no source behind it.
static var _books: Dictionary = {}
static var _registered: bool = false


## Every record on the one switch registry, beside the processes and the modules, and its state here.
static func states() -> Dictionary:
	if not _registered:
		_registered = true
		for r in RECORDS:
			LAAblate.adopt_fake(String(r["name"]), int(r["rung"]) if r.has("rung") else -1)
	return LAAblate.fake_states()


## Is this stand-in carrying the world? False in `off` and in `real`, where the field's own query answers
## at the same seam and hands out whatever the rung produces.
static func stands_in(name: String) -> bool:
	if not _registered:
		states()
	return LAAblate.state_of(name) == LAAblate.state_fake()


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


## Every fake in force, what makes it real, and how much it has made.
static func report() -> Dictionary:
	var out: Dictionary = {}
	for r in RECORDS:
		var name: String = String(r["name"])
		if not stands_in(name):
			continue
		var b: Array = _books.get(name, [0.0, 0.0, 0])
		out[name] = {"created": float(b[0]), "returned": float(b[1]), "draws": int(b[2])}
	return out
