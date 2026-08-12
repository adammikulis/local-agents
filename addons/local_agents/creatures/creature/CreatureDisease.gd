class_name LACreatureDisease
extends RefCounted


var loads: Dictionary = {}
# Acquired immunity: strain_id -> level 0..1 (survivors resist re-infection + fight faster). Wanes very slowly.
var immunity: Dictionary = {}
# Innate immune strength (from genes/config) — higher clears infection faster + blunts symptoms.
var constitution: float = 1.0
# Taxonomic class ("mammals"/"birds"/"insects"/"people"/…) from the species data folder — host-restriction reads it.
var host_class: String = "mammals"

const IMMUNITY_WANE: float = 0.002        # immunity lost per second (slow — survivors stay resistant for a long time)
const SHED_PERIOD: float = 0.5            # seconds between shedding passes (transmission is throttled, not per-frame)
const INFECTIOUS_LOAD: float = 0.12       # min symptomatic load to shed to others
const MAX_LOAD: float = 1.2
const FEVER_DRAIN_PER_DEGREE: float = 0.12

var _shed_cd: float = 0.0


## Initialise from the creature's expressed config/genome. Constitution scales with body size (a bigger, more
## robust animal fights infection a little better) and any explicit `constitution` gene; host_class comes from
## the species data folder (injected by LASpeciesLibrary).
func setup(_creature, config: Dictionary) -> void:
	var size: float = float(config.get("size", 0.5))
	constitution = clampf(float(config.get("constitution", 0.7 + size)), 0.2, 3.0)
	host_class = String(config.get("host_class", "mammals"))


func infect(strain_id: String, dose: float) -> void:
	if dose <= 0.0:
		return
	var rec: Dictionary = LADiseaseLibrary.strain(strain_id)
	if rec.is_empty() or not LADiseaseLibrary.infects_host(rec, host_class):
		return
	var eff: float = dose * (1.0 - clampf(float(immunity.get(strain_id, 0.0)), 0.0, 1.0))
	if eff <= 0.0:
		return
	if loads.has(strain_id):
		var e: Dictionary = loads[strain_id]
		e["load"] = minf(MAX_LOAD, float(e["load"]) + eff)
	else:
		loads[strain_id] = {"load": eff, "age": 0.0, "sympt": false}


func tick(creature, delta: float) -> bool:
	# Immunity wanes slowly whether or not sick.
	if not immunity.is_empty():
		for sid in immunity.keys():
			immunity[sid] = maxf(0.0, float(immunity[sid]) - IMMUNITY_WANE * delta)
	if loads.is_empty():
		return false
	var recovered: Array = []
	var pos: Vector3 = creature.global_position
	for sid in loads.keys():
		var e: Dictionary = loads[sid]
		var rec: Dictionary = LADiseaseLibrary.strain(sid)
		if rec.is_empty():
			recovered.append(sid)
			continue
		e["age"] = float(e["age"]) + delta
		var load: float = float(e["load"])
		# Immune fight: innate constitution + a big boost from acquired immunity to THIS strain.
		var immune_power: float = float(rec["resolve"]) * (constitution + 2.0 * float(immunity.get(sid, 0.0)))
		var symptomatic: bool = float(e["age"]) >= float(rec["incubation"])
		if symptomatic:
			e["sympt"] = true
			load += float(rec["virulence"]) * delta        # worsens once active…
		load -= immune_power * delta                        # …while the immune system fights it down
		load = clampf(load, 0.0, MAX_LOAD)
		e["load"] = load
		if load <= 0.0:
			recovered.append(sid)
			immunity[sid] = maxf(float(immunity.get(sid, 0.0)), float(rec["immunity_gain"]))
			continue
		if symptomatic:
			# Symptoms scale with load: wasting (energy), tissue damage (HP → death), and fever (body heat into
			# the field — emergent overheat + a warm-body cue). Movement lethargy emerges from the energy drain.
			creature.energy = maxf(0.0, creature.energy - float(rec["drain"]) * load * delta)
			creature.health -= float(rec["lethality"]) * load * delta
			var fever: float = float(rec["fever"])
			var fever_burn: float = fever * FEVER_DRAIN_PER_DEGREE * load * delta
			if fever_burn > 0.0:
				creature.energy = maxf(0.0, creature.energy - fever_burn)
				if creature._material != null and creature._material.has_method("respire_at"):
					creature._material.respire_at(pos, fever_burn)
			var slow: float = float(rec["slow"])
			if slow > 0.0:
				creature.lactate = minf(1.0, float(creature.lactate) + slow * load * delta)
			if creature.health <= 0.0:
				creature.die("disease")
				return true
	for sid in recovered:
		loads.erase(sid)
	# Shed to nearby hosts on a throttle (contact/airborne/pest reach; waterborne needs shared water).
	_shed_cd -= delta
	if _shed_cd <= 0.0:
		_shed_cd = SHED_PERIOD
		_shed(creature)
	return false


## Spread each infectious strain to susceptible creatures in range (proximity dose blunted by their immunity;
## host-restriction + water gating handled in infect()/here). One spatial-index query per infectious strain,
## only when this creature is actually shedding — cheap and local.
func _shed(creature) -> void:
	var pos: Vector3 = creature.global_position
	for sid in loads.keys():
		var e: Dictionary = loads[sid]
		if not bool(e.get("sympt", false)) or float(e["load"]) < INFECTIOUS_LOAD:
			continue
		var rec: Dictionary = LADiseaseLibrary.strain(sid)
		if rec.is_empty():
			continue
		var reach: float = float(rec["range"])
		var waterborne: bool = String(rec["vector"]) == "waterborne"
		# Waterborne strains only pass at shared water (both drinking/wet) — else they don't reach through air.
		if waterborne and not _at_water(creature):
			continue
		var others: Array = LACreatureSenses.creatures_within(creature, reach)
		var base_dose: float = float(rec["transmissibility"]) * float(e["load"]) * SHED_PERIOD
		for other in others:
			if other == creature or not is_instance_valid(other) or other.disease == null:
				continue
			if waterborne and not _at_water(other):
				continue
			var d: float = pos.distance_to(other.global_position)
			var prox: float = clampf(1.0 - d / maxf(reach, 0.1), 0.0, 1.0)
			if prox <= 0.0:
				continue
			other.disease.infect(sid, base_dose * prox)


## True where the creature is standing in/at water (waterborne exposure gate) — reads the shared field.
func _at_water(creature) -> bool:
	if creature._material != null and creature._material.has_method("is_water_at"):
		return creature._material.is_water_at(creature.global_position)
	return false


## Is this creature carrying any active infection? Read by telemetry / the streamer.
func is_infected() -> bool:
	return not loads.is_empty()


## How infectious right now (0 = not shedding, up to ~1) — the peak symptomatic load across active strains.
func infectiousness() -> float:
	var m: float = 0.0
	for sid in loads.keys():
		var e: Dictionary = loads[sid]
		if bool(e.get("sympt", false)):
			m = maxf(m, float(e["load"]))
	return m


## Symptom severity 0..1 — aggregate "how sick" for emergent behaviour + the HUD. Peak symptomatic load.
func severity() -> float:
	return clampf(infectiousness(), 0.0, 1.0)
