extends Resource
class_name LocalAgentsSimulationEconomySnapshotResource

const BundleScript = preload("res://addons/local_agents/configuration/parameters/simulation/ResourceBundleResource.gd")

@export var world_id: String = ""
@export var branch_id: String = ""
@export var tick: int = 0
@export var community: Resource
@export var households: Dictionary = {}
@export var individuals: Dictionary = {}
@export var market_prices: Dictionary = {}

func _init() -> void:
    if community == null:
        community = BundleScript.new()

func to_dict() -> Dictionary:
    if community == null:
        community = BundleScript.new()
    return {
        "world_id": world_id,
        "branch_id": branch_id,
        "tick": tick,
        "community": community.to_dict(),
        "households": households.duplicate(true),
        "individuals": individuals.duplicate(true),
        "market_prices": market_prices.duplicate(true),
    }
