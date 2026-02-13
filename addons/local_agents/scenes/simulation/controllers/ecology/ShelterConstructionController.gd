extends RefCounted

var _owner: Variant
var _shelter_step_accumulator: float = 0.0
var _shelter_sites: Dictionary = {}
var _shelter_site_sequence: int = 0
var _sim_time_seconds: float = 0.0

func setup(owner: Variant) -> void:
	_owner = owner

func set_sim_time(sim_time_seconds: float) -> void:
	_sim_time_seconds = sim_time_seconds

func step_shelter_construction(delta: float, living_entity_profiles: Array) -> void:
	_shelter_step_accumulator += maxf(0.0, delta)
	var stepped := false
	while _shelter_step_accumulator >= _owner.shelter_step_seconds:
		_shelter_step_accumulator -= _owner.shelter_step_seconds
		stepped = true
		_apply_shelter_step(float(_owner.shelter_step_seconds), living_entity_profiles)
	if not stepped:
		_apply_shelter_decay(delta)

func clear_sites() -> void:
	_shelter_sites.clear()
	_shelter_site_sequence = 0

func collect_shelter_sites() -> Array:
	var rows: Array = []
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var row: Dictionary = _shelter_sites.get(site_id, {})
		if row.is_empty():
			continue
		rows.append(row.duplicate(true))
	return rows

func _apply_shelter_step(step_delta: float, living_entity_profiles: Array) -> void:
	_apply_shelter_decay(step_delta)
	for profile_variant in living_entity_profiles:
		if not (profile_variant is Dictionary):
			continue
		var profile = profile_variant as Dictionary
		if not bool(profile.has("position")):
			continue
		var position = _position_from_profile(profile)
		var carry_channels = _normalized_carry_channels(profile)
		var build_channels = _normalized_build_channels(profile)
		var build_power = _build_power(carry_channels, build_channels)
		if build_power <= 0.01:
			continue
		var site_id = _find_or_create_shelter_site(profile, position, build_channels)
		if site_id == "":
			continue
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var required_work = maxf(1.0, float(site.get("required_work", 8.0)))
		var progress = clampf(float(site.get("progress", 0.0)), 0.0, required_work)
		var work_gain = build_power * _owner.shelter_work_scalar * step_delta
		progress = minf(required_work, progress + work_gain)
		var stability = clampf(float(site.get("stability", 0.0)) + build_power * 0.03, 0.0, 1.0)
		var carried_mass = _channel_total(carry_channels)
		site["material_mass"] = maxf(0.0, float(site.get("material_mass", 0.0)) + carried_mass * 0.08 * step_delta)
		site["dig_depth"] = maxf(0.0, float(site.get("dig_depth", 0.0)) + float(build_channels.get("dig", 0.0)) * 0.03 * step_delta)
		site["progress"] = progress
		site["stability"] = stability
		site["state"] = "complete" if progress >= required_work else "building"
		site["last_touched_time"] = _sim_time_seconds
		site["last_builder_id"] = String(profile.get("entity_id", ""))
		var builders: Array = site.get("builder_ids", [])
		var builder_id = String(profile.get("entity_id", ""))
		if builder_id != "" and not builders.has(builder_id):
			builders.append(builder_id)
		site["builder_ids"] = builders
		_shelter_sites[site_id] = site

func _apply_shelter_decay(delta: float) -> void:
	if delta <= 0.0 or _shelter_sites.is_empty():
		return
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var untouched_time = _sim_time_seconds - float(site.get("last_touched_time", _sim_time_seconds))
		if untouched_time <= 8.0:
			continue
		var state = String(site.get("state", "building"))
		var decay_scale = 0.35 if state == "complete" else 1.0
		var progress = maxf(0.0, float(site.get("progress", 0.0)) - _owner.shelter_decay_per_second * delta * decay_scale)
		site["progress"] = progress
		site["state"] = "complete" if progress >= float(site.get("required_work", 1.0)) else "building"
		_shelter_sites[site_id] = site

func _find_or_create_shelter_site(profile: Dictionary, position: Vector3, build_channels: Dictionary) -> String:
	var nearby_id = _nearest_shelter_site_id(position, String(profile.get("entity_id", "")))
	if nearby_id != "":
		return nearby_id
	_shelter_site_sequence += 1
	var site_id = "shelter_%d" % _shelter_site_sequence
	var preferences: Dictionary = profile.get("shelter_preferences", {})
	var shape = String(preferences.get("shape", _dominant_shelter_shape(build_channels)))
	var required_work = maxf(1.0, float(preferences.get("required_work", _default_required_work(_normalized_carry_channels(profile), build_channels))))
	var taxonomy_path: Array = profile.get("taxonomy_path", [])
	_shelter_sites[site_id] = {
		"shelter_id": site_id,
		"x": position.x,
		"y": position.y,
		"z": position.z,
		"shape": shape,
		"required_work": required_work,
		"progress": 0.0,
		"stability": 0.0,
		"material_mass": 0.0,
		"dig_depth": 0.0,
		"state": "building",
		"builder_ids": [],
		"last_builder_id": "",
		"taxonomy_path": taxonomy_path.duplicate(true),
		"last_touched_time": _sim_time_seconds,
	}
	return site_id

func _nearest_shelter_site_id(position: Vector3, _builder_id: String) -> String:
	var best_id = ""
	var best_dist = _owner.shelter_builder_search_radius
	var ids = _shelter_sites.keys()
	ids.sort()
	for site_id_variant in ids:
		var site_id = String(site_id_variant)
		var site: Dictionary = _shelter_sites.get(site_id, {})
		if site.is_empty():
			continue
		var site_pos = Vector3(float(site.get("x", 0.0)), float(site.get("y", 0.0)), float(site.get("z", 0.0)))
		var dist = position.distance_to(site_pos)
		if dist <= best_dist:
			best_dist = dist
			best_id = site_id
	return best_id

func _position_from_profile(profile: Dictionary) -> Vector3:
	var pos_variant = profile.get("position", {})
	if pos_variant is Dictionary:
		var row = pos_variant as Dictionary
		return Vector3(float(row.get("x", 0.0)), float(row.get("y", 0.0)), float(row.get("z", 0.0)))
	return Vector3.ZERO

func _normalized_carry_channels(profile: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var carry_variant = profile.get("carry_channels", {})
	if carry_variant is Dictionary:
		for key_variant in (carry_variant as Dictionary).keys():
			var key = String(key_variant).strip_edges().to_lower()
			out[key] = clampf(float((carry_variant as Dictionary).get(key_variant, 0.0)), 0.0, 4.0)
	if _is_animal_profile(profile):
		out["mouth"] = maxf(float(out.get("mouth", 0.0)), 0.18)
	if _is_hominid_profile(profile):
		out["hands"] = maxf(float(out.get("hands", 0.0)), 0.72)
	return out

func _normalized_build_channels(profile: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var build_variant = profile.get("build_channels", {})
	if build_variant is Dictionary:
		for key_variant in (build_variant as Dictionary).keys():
			var key = String(key_variant).strip_edges().to_lower()
			out[key] = clampf(float((build_variant as Dictionary).get(key_variant, 0.0)), 0.0, 4.0)
	var carry = _normalized_carry_channels(profile)
	var carry_power = _channel_total(carry)
	out["carry"] = maxf(float(out.get("carry", 0.0)), carry_power * 0.55)
	if _is_animal_profile(profile):
		out["dig"] = maxf(float(out.get("dig", 0.0)), float(carry.get("mouth", 0.0)) * 0.4)
	return out

func _build_power(carry_channels: Dictionary, build_channels: Dictionary) -> float:
	var carry_power = _channel_total(carry_channels)
	var build_total = _channel_total(build_channels)
	return maxf(0.0, carry_power * 0.5 + build_total * 0.7)

func _channel_total(channels: Dictionary) -> float:
	var total = 0.0
	var keys = channels.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		total += maxf(0.0, float(channels.get(String(key_variant), 0.0)))
	return total

func _dominant_shelter_shape(build_channels: Dictionary) -> String:
	var dig = float(build_channels.get("dig", 0.0))
	var carry = float(build_channels.get("carry", 0.0))
	var stack = float(build_channels.get("stack", 0.0))
	if dig >= carry and dig >= stack:
		return "burrow"
	if stack >= dig and stack >= carry:
		return "stacked"
	return "nest"

func _default_required_work(carry_channels: Dictionary, build_channels: Dictionary) -> float:
	var dexterity = float(carry_channels.get("hands", 0.0))
	var dig = float(build_channels.get("dig", 0.0))
	var base = 7.5 + dexterity * 6.0 + dig * 1.2
	return clampf(base, 4.0, 26.0)

func _is_animal_profile(profile: Dictionary) -> bool:
	var taxonomy: Array = profile.get("taxonomy_path", [])
	for token_variant in taxonomy:
		if String(token_variant).to_lower() == "animal":
			return true
	return false

func _is_hominid_profile(profile: Dictionary) -> bool:
	var tags: Array = profile.get("tags", [])
	for tag_variant in tags:
		var tag = String(tag_variant).to_lower()
		if tag == "hominid" or tag == "human":
			return true
	var meta: Dictionary = profile.get("metadata", {})
	return bool(meta.get("dexterous_grasp", false))
