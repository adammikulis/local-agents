extends Resource
class_name LocalAgentsStructureResource

@export var schema_version: int = 1
@export var structure_id: String = ""
@export var structure_type: String = "hut"
@export var household_id: String = ""
@export var state: String = "active"
@export var position: Vector3 = Vector3.ZERO
@export var durability: float = 1.0
@export var created_tick: int = 0
@export var last_updated_tick: int = 0

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "structure_id": structure_id,
        "structure_type": structure_type,
        "household_id": household_id,
        "state": state,
        "position": {
            "x": position.x,
            "y": position.y,
            "z": position.z,
        },
        "durability": durability,
        "created_tick": created_tick,
        "last_updated_tick": last_updated_tick,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    structure_id = String(values.get("structure_id", structure_id))
    structure_type = String(values.get("structure_type", structure_type))
    household_id = String(values.get("household_id", household_id))
    state = String(values.get("state", state))
    var pos: Dictionary = values.get("position", {})
    position = Vector3(float(pos.get("x", position.x)), float(pos.get("y", position.y)), float(pos.get("z", position.z)))
    durability = clampf(float(values.get("durability", durability)), 0.0, 1.0)
    created_tick = int(values.get("created_tick", created_tick))
    last_updated_tick = int(values.get("last_updated_tick", last_updated_tick))
