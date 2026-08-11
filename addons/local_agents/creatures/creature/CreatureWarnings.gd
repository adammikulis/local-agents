@tool
class_name LocalAgentCreatureWarnings
extends RefCounted

## Inspector validation for a LocalAgentCreature placed in a scene by hand: the checks behind
## Creature._get_configuration_warnings(). It lives here rather than on the creature so Creature.gd stays
## exports-only, and it is static + duck-typed on the passed node so there is no cyclic class reference.
##
## The one thing a non-coder gets wrong when dropping a Creature into a scene is the species id: it is a
## free-text String (@export_enum cannot offer the empty "generic walker" option), so a typo silently
## degrades to the generic walker instead of erroring. These warnings name the typo and list what is
## actually available.
##
## LocalAgentCreatureSpawner reuses check_species() for the same validation over its `counts` keys.
##
## (Explicit types only, no ':=' inferred typing.)

## How many known species ids to name before the list is truncated in a warning message.
const MAX_LISTED_KINDS: int = 24


## Every warning for `creature` (a LocalAgentCreature), in the order a user should deal with them.
## Empty when the node is configured sensibly.
static func check(creature) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if creature == null:
		return out
	var species_id: String = String(creature.get("standalone_species"))
	out.append_array(check_species(species_id, "Standalone Species"))
	if species_id != "" and not bool(creature.get("standalone_on_ready")):
		out.append(
			"Standalone Species is set to \"%s\" but Standalone On Ready is off, so it will be ignored." % species_id
			+ "\nTurn Standalone On Ready on, or call setup_standalone(\"%s\") on this node yourself." % species_id
		)
	return out


## Validate one species id the way LACreatureStandalone.resolve_config() will read it: a known species id,
## a res:// path ending in ".json", or "" for the built-in generic walker. `label` names the property in
## the message so the spawner can say "Counts" where the creature says "Standalone Species".
static func check_species(species_id: String, label: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var id: String = species_id.strip_edges()
	if id == "":
		return out                       # blank is legal — it means the built-in generic walker
	if id.ends_with(".json"):
		# A data file is addressed by path. FileAccess because we only care whether the bytes are on
		# disk — this never goes through the resource system.
		if not FileAccess.file_exists(id):
			out.append("%s points at \"%s\", which does not exist." % [label, id])
		return out
	if not known_kinds().has(id):
		out.append(
			"%s is \"%s\", which has no species file, so the creature falls back to the generic walker." % [label, id]
			+ "\nKnown ids: %s" % known_kinds_text()
			+ "\nOr add creatures/species/<class>/%s.json." % id
		)
	return out


## Sorted species ids that have a data file under creatures/species/. Sorted (rather than in folder-scan
## order) so a warning message reads the same every time.
static func known_kinds() -> PackedStringArray:
	var kinds: Array = LASpeciesLibrary.known_kinds().duplicate()
	kinds.sort()
	var out: PackedStringArray = PackedStringArray()
	for k in kinds:
		out.append(String(k))
	return out


## The known ids as one comma-separated line, truncated so a warning box stays readable.
static func known_kinds_text() -> String:
	var kinds: PackedStringArray = known_kinds()
	if kinds.is_empty():
		return "(none found under creatures/species/)"
	if kinds.size() <= MAX_LISTED_KINDS:
		return ", ".join(kinds)
	var head: PackedStringArray = kinds.slice(0, MAX_LISTED_KINDS)
	return "%s, … (%d more)" % [", ".join(head), kinds.size() - MAX_LISTED_KINDS]
