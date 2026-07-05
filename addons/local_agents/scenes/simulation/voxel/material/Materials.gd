class_name LAMaterials
extends RefCounted

## Data-driven material registry for the unified MaterialField.
##
## EMERGENT-EVERYTHING: every substance in the sim — solids, granular soil, liquids, gases — is one
## entry here, and the differences between water/lava/steam/rock/sand are DATA, not code. Flow,
## phase changes, combustion, buoyancy and settling all fall out of these properties, so the field's
## step loop never branches on "if water" / "if lava". Add a material by adding a row.
##
## Temperature is an abstract relative scalar (not real °C): ambient hovers near 0, disasters inject
## large positive spikes (lightning/lava) or negative ones (blizzard). Thresholds below are tuned in
## that same relative scale. (Explicit types only — project rule: no ':=' inferred typing.)

## Material ids. Kept as plain ints (array index) so per-material state can live in flat arrays.
const AIR: int = 0
const WATER: int = 1
const ICE: int = 2
const STEAM: int = 3
const ROCK: int = 4
const DIRT: int = 5
const SAND: int = 6
const LAVA: int = 7
const ASH: int = 8
const SMOKE: int = 9
const WOOD: int = 10
const SNOW: int = 11
const COUNT: int = 12

## Coarse phase class. Drives which movement rule a material obeys in the field step.
const PHASE_SOLID: int = 0        # static; lives in the voxel SDF, not the mobile grid
const PHASE_GRANULAR: int = 1     # piles; collapses toward repose angle when disturbed
const PHASE_LIQUID: int = 2       # flows to lower surface head
const PHASE_GAS: int = 3          # diffuses + rises by buoyancy; carries heat (convection)

## Sentinel: no thermal transition on this end.
const NONE: int = -1

## One definition dictionary per material id (index == id). Fields:
##   name          display name
##   phase         PHASE_* movement class
##   density       relative; heavier settles below lighter (gas ordering, water-vs-lava)
##   flow          liquid redistribution factor (0 for non-liquids); lava << water = slow creep
##   heat_capacity thermal mass — energy a unit carries per degree (convection weighting)
##   buoyancy      gas rise rate (0 for non-gas)
##   repose        granular slope tangent it settles toward (0 = irrelevant)
##   cold_to/cold_temp   becomes cold_to when temp <= cold_temp (freeze/condense/solidify)
##   hot_to/hot_temp     becomes hot_to  when temp >= hot_temp  (melt/boil)
##   flammable/ignite_temp/burns_to  combustion: at/above ignite_temp, converts to burns_to + heat
##   color         base render tint
const DEFS: Array = [
	{   # AIR
		"name": "air", "phase": PHASE_GAS, "density": 0.0012, "flow": 0.0,
		"heat_capacity": 1.0, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.7, 0.8, 0.9, 0.0),
	},
	{   # WATER
		"name": "water", "phase": PHASE_LIQUID, "density": 1.0, "flow": 0.25,
		"heat_capacity": 4.2, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": ICE, "cold_temp": -1.0, "hot_to": STEAM, "hot_temp": 10.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.16, 0.46, 0.68, 0.55),
	},
	{   # ICE
		"name": "ice", "phase": PHASE_SOLID, "density": 0.92, "flow": 0.0,
		"heat_capacity": 2.1, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": WATER, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.75, 0.88, 0.95, 0.85),
	},
	{   # STEAM
		"name": "steam", "phase": PHASE_GAS, "density": 0.0006, "flow": 0.0,
		"heat_capacity": 2.0, "buoyancy": 1.4, "repose": 0.0,
		"cold_to": WATER, "cold_temp": 8.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.85, 0.88, 0.92, 0.35),
	},
	{   # ROCK  (solid phase == voxel SDF; listed so lava can solidify back to it)
		"name": "rock", "phase": PHASE_SOLID, "density": 2.6, "flow": 0.0,
		"heat_capacity": 0.8, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": LAVA, "hot_temp": 60.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.42, 0.4, 0.4, 1.0),
	},
	{   # DIRT (granular soil; slides in landslides)
		"name": "dirt", "phase": PHASE_GRANULAR, "density": 1.5, "flow": 0.0,
		"heat_capacity": 0.9, "buoyancy": 0.0, "repose": 0.8,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.40, 0.28, 0.18, 1.0),
	},
	{   # SAND (looser granular; lower repose)
		"name": "sand", "phase": PHASE_GRANULAR, "density": 1.6, "flow": 0.0,
		"heat_capacity": 0.8, "buoyancy": 0.0, "repose": 0.6,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.80, 0.74, 0.55, 1.0),
	},
	{   # LAVA (hot, slow-creeping liquid; solidifies to rock when it cools)
		"name": "lava", "phase": PHASE_LIQUID, "density": 2.4, "flow": 0.04,
		"heat_capacity": 1.0, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": ROCK, "cold_temp": 45.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(1.0, 0.42, 0.08, 1.0),
	},
	{   # ASH (light granular residue of fire)
		"name": "ash", "phase": PHASE_GRANULAR, "density": 0.6, "flow": 0.0,
		"heat_capacity": 0.7, "buoyancy": 0.0, "repose": 0.4,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.28, 0.26, 0.25, 1.0),
	},
	{   # SMOKE (hot combustion gas; rises and carries heat — convection)
		"name": "smoke", "phase": PHASE_GAS, "density": 0.0007, "flow": 0.0,
		"heat_capacity": 1.6, "buoyancy": 1.1, "repose": 0.0,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.2, 0.2, 0.22, 0.5),
	},
	{   # WOOD (vegetation fuel; combusts to ash)
		"name": "wood", "phase": PHASE_SOLID, "density": 0.7, "flow": 0.0,
		"heat_capacity": 1.8, "buoyancy": 0.0, "repose": 0.0,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": NONE, "hot_temp": 0.0,
		"flammable": true, "ignite_temp": 5.0, "burns_to": ASH,
		"color": Color(0.36, 0.25, 0.14, 1.0),
	},
	{   # SNOW (frozen precipitation; melts to water)
		"name": "snow", "phase": PHASE_GRANULAR, "density": 0.3, "flow": 0.0,
		"heat_capacity": 2.0, "buoyancy": 0.0, "repose": 0.5,
		"cold_to": NONE, "cold_temp": 0.0, "hot_to": WATER, "hot_temp": 0.0,
		"flammable": false, "ignite_temp": 0.0, "burns_to": NONE,
		"color": Color(0.92, 0.95, 0.98, 1.0),
	},
]


## Definition dictionary for a material id (falls back to AIR on a bad id).
static func def(id: int) -> Dictionary:
	if id < 0 or id >= DEFS.size():
		return DEFS[AIR]
	return DEFS[id]


static func mat_name(id: int) -> String:
	return String(def(id).get("name", "air"))


static func phase(id: int) -> int:
	return int(def(id).get("phase", PHASE_GAS))


static func flow(id: int) -> float:
	return float(def(id).get("flow", 0.0))


static func heat_capacity(id: int) -> float:
	return float(def(id).get("heat_capacity", 1.0))


static func buoyancy(id: int) -> float:
	return float(def(id).get("buoyancy", 0.0))


static func repose(id: int) -> float:
	return float(def(id).get("repose", 0.0))


static func color(id: int) -> Color:
	return def(id).get("color", Color.WHITE)


static func is_flammable(id: int) -> bool:
	return bool(def(id).get("flammable", false))


static func ignite_temp(id: int) -> float:
	return float(def(id).get("ignite_temp", 0.0))


static func burns_to(id: int) -> int:
	return int(def(id).get("burns_to", NONE))


## The material `id` becomes when its cell temperature crosses a threshold, or NONE.
## Returns {to: int, temp: float, hot: bool} describing the nearest transition, or {to: NONE}.
static func cold_transition(id: int) -> Dictionary:
	var d: Dictionary = def(id)
	return {"to": int(d.get("cold_to", NONE)), "temp": float(d.get("cold_temp", 0.0))}


static func hot_transition(id: int) -> Dictionary:
	var d: Dictionary = def(id)
	return {"to": int(d.get("hot_to", NONE)), "temp": float(d.get("hot_temp", 0.0))}


## Ids of the materials that are MOBILE (stored per-cell in the field's flat arrays).
## Solids (rock/ice/wood) live in the voxel SDF / on actors, not the mobile grid.
static func mobile_ids() -> Array:
	var out: Array = []
	for id in range(COUNT):
		var p: int = phase(id)
		if p == PHASE_LIQUID or p == PHASE_GAS or p == PHASE_GRANULAR:
			out.append(id)
	return out
