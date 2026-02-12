extends Resource
class_name LocalAgentsHouseholdMembershipResource

@export var household_id: String = ""
@export var member_ids: Array[String] = []

func add_member(npc_id: String) -> void:
    var id := npc_id.strip_edges()
    if id == "":
        return
    if member_ids.has(id):
        return
    member_ids.append(id)
    member_ids.sort()

func remove_member(npc_id: String) -> void:
    var id := npc_id.strip_edges()
    if id == "":
        return
    member_ids.erase(id)
    member_ids.sort()

func from_dict(payload: Dictionary) -> void:
    household_id = String(payload.get("household_id", household_id))
    member_ids.clear()
    var rows = payload.get("member_ids", [])
    if rows is Array:
        for row in rows:
            add_member(String(row))

func to_dict() -> Dictionary:
    return {
        "household_id": household_id,
        "member_ids": member_ids.duplicate(),
    }
