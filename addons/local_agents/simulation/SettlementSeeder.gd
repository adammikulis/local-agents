extends RefCounted
class_name LocalAgentsSettlementSeeder

const SpawnCandidateResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SpawnCandidateResource.gd")

func select_site(world_data: Dictionary, hydrology: Dictionary, config) -> Dictionary:
    var tiles: Array = world_data.get("tiles", [])
    var water_tiles: Dictionary = hydrology.get("water_tiles", {})
    var by_id: Dictionary = world_data.get("tile_index", {})

    var candidates: Array = []
    for row_variant in tiles:
        if not (row_variant is Dictionary):
            continue
        var row: Dictionary = row_variant
        var tile_id = String(row.get("tile_id", ""))
        var hydro: Dictionary = water_tiles.get(tile_id, {})
        var reliability = float(hydro.get("water_reliability", 0.0))
        var flood_risk = float(hydro.get("flood_risk", 0.0))
        var food = _nearby_average(tile_id, by_id, "food_density")
        var wood = _nearby_average(tile_id, by_id, "wood_density")
        var stone = _nearby_average(tile_id, by_id, "stone_density")
        var walkability = 1.0 - clampf(float(row.get("slope", 0.5)), 0.0, 1.0)

        var score_breakdown = {
            "water_reliability": reliability * float(config.spawn_weight_water_reliability),
            "flood_safety": (1.0 - flood_risk) * float(config.spawn_weight_flood_penalty),
            "food_density": food * float(config.spawn_weight_food_density),
            "wood_density": wood * float(config.spawn_weight_wood_density),
            "stone_access": stone * float(config.spawn_weight_stone_density),
            "walkability": walkability * float(config.spawn_weight_walkability),
        }
        var score_total = 0.0
        for key in score_breakdown.keys():
            score_total += float(score_breakdown[key])

        var candidate = SpawnCandidateResourceScript.new()
        candidate.candidate_id = "candidate_%s" % tile_id.replace(":", "_")
        candidate.tile_id = tile_id
        candidate.x = int(row.get("x", 0))
        candidate.y = int(row.get("y", 0))
        candidate.score_total = score_total
        candidate.score_breakdown = score_breakdown
        candidates.append(candidate.to_dict())

    candidates.sort_custom(func(a, b):
        var ascore = float(a.get("score_total", 0.0))
        var bscore = float(b.get("score_total", 0.0))
        if is_equal_approx(ascore, bscore):
            return String(a.get("tile_id", "")) < String(b.get("tile_id", ""))
        return ascore > bscore
    )

    var limit = mini(maxi(1, int(config.spawn_top_candidate_count)), candidates.size())
    var top_candidates: Array = []
    for idx in range(limit):
        top_candidates.append(candidates[idx])

    var chosen: Dictionary = {}
    if not top_candidates.is_empty():
        chosen = top_candidates[0].duplicate(true)
    var chosen_tile_id = String(chosen.get("tile_id", ""))
    var chosen_tile: Dictionary = {}
    if chosen_tile_id != "":
        chosen_tile = by_id.get(chosen_tile_id, {}).duplicate(true)

    return {
        "schema_version": 1,
        "chosen": chosen,
        "chosen_tile": chosen_tile,
        "top_candidates": top_candidates,
    }

func _nearby_average(tile_id: String, by_id: Dictionary, key: String) -> float:
    var tile: Dictionary = by_id.get(tile_id, {})
    if tile.is_empty():
        return 0.0
    var x = int(tile.get("x", 0))
    var y = int(tile.get("y", 0))
    var total = 0.0
    var count = 0
    for ny in range(y - 1, y + 2):
        for nx in range(x - 1, x + 2):
            var neighbor_id = "%d:%d" % [nx, ny]
            if not by_id.has(neighbor_id):
                continue
            total += float(by_id[neighbor_id].get(key, 0.0))
            count += 1
    if count == 0:
        return 0.0
    return total / float(count)
