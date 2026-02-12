extends Resource
class_name LocalAgentsFlowNetworkResource

@export var schema_version: int = 1
@export var edges: Array = []
@export var edge_count: int = 0

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "edges": edges.duplicate(true),
        "edge_count": edge_count,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    edges = []
    for row_variant in values.get("edges", []):
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        edges.append({
            "edge": String(row.get("edge", "")),
            "heat": maxf(0.0, float(row.get("heat", 0.0))),
            "strength": maxf(0.0, float(row.get("strength", 0.0))),
        })
    edges.sort_custom(func(a, b):
        var a_key = String((a as Dictionary).get("edge", ""))
        var b_key = String((b as Dictionary).get("edge", ""))
        return a_key < b_key
    )
    edge_count = int(values.get("edge_count", edges.size()))
