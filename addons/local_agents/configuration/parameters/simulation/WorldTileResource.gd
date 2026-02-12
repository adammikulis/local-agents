extends Resource
class_name LocalAgentsWorldTileResource

@export var schema_version: int = 1
@export var tile_id: String = ""
@export var x: int = 0
@export var y: int = 0
@export var elevation: float = 0.0
@export var moisture: float = 0.0
@export var temperature: float = 0.0
@export var slope: float = 0.0
@export var biome: String = "plains"
@export var food_density: float = 0.0
@export var wood_density: float = 0.0
@export var stone_density: float = 0.0

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "tile_id": tile_id,
        "x": x,
        "y": y,
        "elevation": elevation,
        "moisture": moisture,
        "temperature": temperature,
        "slope": slope,
        "biome": biome,
        "food_density": food_density,
        "wood_density": wood_density,
        "stone_density": stone_density,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    tile_id = String(values.get("tile_id", tile_id))
    x = int(values.get("x", x))
    y = int(values.get("y", y))
    elevation = clampf(float(values.get("elevation", elevation)), 0.0, 1.0)
    moisture = clampf(float(values.get("moisture", moisture)), 0.0, 1.0)
    temperature = clampf(float(values.get("temperature", temperature)), 0.0, 1.0)
    slope = clampf(float(values.get("slope", slope)), 0.0, 1.0)
    biome = String(values.get("biome", biome))
    food_density = clampf(float(values.get("food_density", food_density)), 0.0, 1.0)
    wood_density = clampf(float(values.get("wood_density", wood_density)), 0.0, 1.0)
    stone_density = clampf(float(values.get("stone_density", stone_density)), 0.0, 1.0)
