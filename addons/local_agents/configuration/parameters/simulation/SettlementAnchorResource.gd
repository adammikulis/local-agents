extends Resource
class_name LocalAgentsSettlementAnchorResource

@export var schema_version: int = 1
@export var anchor_id: String = ""
@export var anchor_type: String = "water_access"
@export var household_id: String = ""
@export var position: Vector3 = Vector3.ZERO

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "anchor_id": anchor_id,
        "anchor_type": anchor_type,
        "household_id": household_id,
        "position": {
            "x": position.x,
            "y": position.y,
            "z": position.z,
        },
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    anchor_id = String(values.get("anchor_id", anchor_id))
    anchor_type = String(values.get("anchor_type", anchor_type))
    household_id = String(values.get("household_id", household_id))
    var pos: Dictionary = values.get("position", {})
    position = Vector3(float(pos.get("x", position.x)), float(pos.get("y", position.y)), float(pos.get("z", position.z)))
