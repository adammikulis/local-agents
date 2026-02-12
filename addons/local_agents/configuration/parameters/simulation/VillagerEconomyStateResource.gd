extends Resource
class_name LocalAgentsVillagerEconomyStateResource

const InventoryScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerInventoryResource.gd")

@export var npc_id: String = ""
@export var inventory: Resource
@export var wage_due: float = 0.0
@export var moved_total_weight: float = 0.0
@export var energy: float = 1.0
@export var health: float = 1.0

func _init() -> void:
    if inventory == null:
        inventory = InventoryScript.new()

func to_dict() -> Dictionary:
    if inventory == null:
        inventory = InventoryScript.new()
    return {
        "npc_id": npc_id,
        "wage_due": wage_due,
        "moved_total_weight": moved_total_weight,
        "energy": energy,
        "health": health,
        "inventory": inventory.to_dict(),
    }
