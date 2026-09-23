class_name LAMoon
extends Node3D

## A moon is a BODY: its mass pulls, and its size and its reflectance are those of the rock it is made of.

const ROCK: String = "silicate"

var _seed_key: String = "moon"


func _ready() -> void:
	add_to_group(LAGravity.GROUP)
	add_to_group("selectable")


func seed_row() -> Dictionary:
	return LABodySeeds.of(_seed_key)


func center() -> Vector3:
	return global_position


func mass() -> float:
	return float(seed_row().get("mass_kg", 0.0))


## The moon is not on a grid of its own, so its size comes from its seeded mass and the density of the rock
## it is made of rather than from a measurement it has no way to take.
func radius() -> float:
	var row: Dictionary = LASubstances.table().get(ROCK, {})
	# A row that names its melt is its solid; a row that names its solid is its liquid.
	var rho: float = float(row.get("density" if row.has("density_melt") else "density_solid", 0.0))
	if rho <= 0.0:
		return -1.0
	return pow(3.0 * mass() / (4.0 * PI * rho), 1.0 / 3.0)


## Fraction of the sunlight falling on it that its surface sends back: its rock's albedo. -1 when unknown.
func albedo() -> float:
	return float(LASubstances.table().get(ROCK, {}).get("albedo", -1.0))
