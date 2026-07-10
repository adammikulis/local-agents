class_name LACreatureInspector
extends RefCounted

## Inspector presentation for LACreature, factored out of the main brain: turns live creature
## state into the {title, lines} payload the HUD shows, plus the activity phrase and energy/water
## bar. Static + dependency-free of the LACreature type. (Explicit types only — no ':=' typing.)

static func payload(c) -> Dictionary:
	var maturity: String = "adult" if c.is_mature() else "juvenile"
	var activity: String = describe_activity(String(c.state))
	var energy_pct: int = int(round(100.0 * c.energy / maxf(1.0, c.max_energy)))
	var hydration_pct: int = int(round(100.0 * c.hydration / maxf(1.0, c.max_hydration)))
	var nearby: int = c.get_tree().get_nodes_in_group("species_" + String(c.species)).size() - 1
	var p: Vector3 = c.global_position
	var lines: Array = [
		"Species: %s (%s)" % [c.species, maturity],
		"Diet: %s" % c.diet,
		"Doing: %s" % activity,
		"Energy: %d%%  %s" % [energy_pct, energy_bar(energy_pct)],
		"Water:  %d%%  %s" % [hydration_pct, energy_bar(hydration_pct)],
		"Age: %.0fs / %.0fs" % [c.age, c.max_age],
		"Speed: %.1f   Size: %.2f" % [c.speed, c.size],
		"Herd nearby: %d" % maxi(0, nearby),
		"Pos: (%.0f, %.0f, %.0f)" % [p.x, p.y, p.z],
	]
	if c.throws:
		lines.append("Rock in hand: %s" % ("yes" if c.has_rock else "no"))
	# Cognition/genetics readout: how much this individual has learned and which generation it is.
	if c.has_method("get_cognition") and c.get_cognition() != null:
		var cog = c.get_cognition()
		var gen: int = 0
		if c.has_method("get_genome") and c.get_genome() != null:
			gen = int(c.get_genome().generation)
		lines.append("Mind: %d habits · %d asked · %d learned · gen %d" % [
			cog.policy_size(), cog.escalations, cog.lessons, gen])
		lines.append("Eyes: %d° FOV   Hearing: %.0fm" % [int(round(c.eye_fov)), c.hearing_range])
	return {"title": String(c.species).capitalize(), "lines": lines}


static func describe_activity(state: String) -> String:
	match state:
		"panic": return "terrified — fleeing!"
		"flee": return "fleeing a predator"
		"chase": return "chasing prey"
		"stalk": return "stalking prey (persistence hunt)"
		"track": return "tracking scent"
		"throw": return "throwing a rock"
		"eat": return "eating"
		"drink": return "drinking"
		"seek": return "searching for water"
		"thirsty": return "searching for water"
		"cruise": return "flying with the flock"
		"flock": return "moving with the flock"
		"soar": return "soaring, scanning for carrion"
		"circle": return "circling a carcass"
		"investigate": return "investigating a carrion cue"
		"rest": return "resting to conserve energy"
		"sleep": return "sleeping at its nest"
		"roost": return "heading home to roost"
		"nesting": return "tending its nest"
		"migrate": return "migrating to new ground"
		"wander": return "wandering with its kind"
		_: return state


static func energy_bar(pct: int) -> String:
	var filled: int = clampi(pct / 10, 0, 10)
	return "[%s%s]" % ["#".repeat(filled), "-".repeat(10 - filled)]
