extends Resource
class_name LocalAgentsVillagerStateResource

@export var npc_id: String = ""
@export var display_name: String = ""
@export var mood: String = "neutral"
@export var morale: float = 0.5
@export var fear: float = 0.0
@export var energy: float = 1.0
@export var hunger: float = 0.0
@export var profession: String = "general"
@export var household_id: String = ""
@export var last_dream_effect: Dictionary = {}

func from_dict(payload: Dictionary) -> void:
    npc_id = String(payload.get("npc_id", npc_id))
    display_name = String(payload.get("display_name", display_name))
    mood = String(payload.get("mood", mood))
    morale = clampf(float(payload.get("morale", morale)), 0.0, 1.0)
    fear = clampf(float(payload.get("fear", fear)), 0.0, 1.0)
    energy = clampf(float(payload.get("energy", energy)), 0.0, 1.0)
    hunger = clampf(float(payload.get("hunger", hunger)), 0.0, 1.0)
    profession = String(payload.get("profession", profession))
    household_id = String(payload.get("household_id", household_id))
    var effect_variant = payload.get("last_dream_effect", {})
    if effect_variant is Dictionary:
        last_dream_effect = effect_variant.duplicate(true)
    else:
        last_dream_effect = {}

func to_dict() -> Dictionary:
    return {
        "npc_id": npc_id,
        "display_name": display_name,
        "mood": mood,
        "morale": morale,
        "fear": fear,
        "energy": energy,
        "hunger": hunger,
        "profession": profession,
        "household_id": household_id,
        "last_dream_effect": last_dream_effect.duplicate(true),
    }
