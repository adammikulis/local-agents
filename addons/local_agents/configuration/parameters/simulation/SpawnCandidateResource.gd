extends Resource
class_name LocalAgentsSpawnCandidateResource

@export var schema_version: int = 1
@export var candidate_id: String = ""
@export var tile_id: String = ""
@export var x: int = 0
@export var y: int = 0
@export var score_total: float = 0.0
@export var score_breakdown: Dictionary = {}

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "candidate_id": candidate_id,
        "tile_id": tile_id,
        "x": x,
        "y": y,
        "score_total": score_total,
        "score_breakdown": score_breakdown.duplicate(true),
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    candidate_id = String(values.get("candidate_id", candidate_id))
    tile_id = String(values.get("tile_id", tile_id))
    x = int(values.get("x", x))
    y = int(values.get("y", y))
    score_total = float(values.get("score_total", score_total))
    var breakdown_variant = values.get("score_breakdown", {})
    if breakdown_variant is Dictionary:
        score_breakdown = breakdown_variant.duplicate(true)
    else:
        score_breakdown = {}
