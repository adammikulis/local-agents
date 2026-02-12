extends RefCounted
class_name LocalAgentsLivingEntityTaxonomy

const ROOT_LIVING_CREATURE := "living_creature"
const KINGDOM_ANIMAL := "animal"
const KINGDOM_PLANT := "plant"

static func normalized_path(path: Array) -> Array[String]:
	var out: Array[String] = []
	for item in path:
		var token = String(item).strip_edges().to_lower()
		if token == "":
			continue
		out.append(token)
	if out.is_empty() or String(out[0]) != ROOT_LIVING_CREATURE:
		out.insert(0, ROOT_LIVING_CREATURE)
	return out

static func animal_path(category: String, subtype: String = "") -> Array[String]:
	var out: Array[String] = [ROOT_LIVING_CREATURE, KINGDOM_ANIMAL, category]
	if subtype.strip_edges() != "":
		out.append(subtype)
	return normalized_path(out)

static func plant_path(category: String, subtype: String = "") -> Array[String]:
	var out: Array[String] = [ROOT_LIVING_CREATURE, KINGDOM_PLANT, category]
	if subtype.strip_edges() != "":
		out.append(subtype)
	return normalized_path(out)

static func path_key(path: Array) -> String:
	var tokens = normalized_path(path)
	return "/".join(PackedStringArray(tokens))
