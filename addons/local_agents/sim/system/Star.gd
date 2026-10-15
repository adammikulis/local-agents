class_name LAStar
extends Node3D

## A star is a BODY. Its mass pulls like any other mass and its luminosity is what it radiates; the flux
## reaching anything else is that luminosity over the sphere it has spread across by the time it arrives.

var _seed_key: String = "star"


func setup(opts: Dictionary = {}) -> void:
	_seed_key = String(opts.get("seed_key", "star"))
	position = seed_row().get("position_m", Vector3.ZERO)
	# Join the N-body group only once the position above is real. Registering in _ready() would put a mass
	# this large at the world origin — on top of the planet — for the window between add_child and setup.
	add_to_group(LAGravity.GROUP)


func seed_row() -> Dictionary:
	return LABodySeeds.of(_seed_key)


func mass() -> float:
	return float(seed_row().get("mass_kg", 0.0))


## Radiant power, watts.
func luminosity_w() -> float:
	return float(seed_row().get("luminosity_w", 0.0))


## Radiant power in the XUV, watts. What an exosphere goes hydrodynamic on.
func xuv_luminosity_w() -> float:
	return float(seed_row().get("xuv_luminosity_w", 0.0))


## Irradiance at a world point, W/m^2. No nominal orbit and no normalisation, so an eccentric or knocked
## orbit changes it on its own.
func irradiance_at(world_pos: Vector3) -> float:
	return LABodySeeds.irradiance_w_m2(luminosity_w(), (world_pos - global_position).length())


func xuv_irradiance_at(world_pos: Vector3) -> float:
	return LABodySeeds.irradiance_w_m2(xuv_luminosity_w(), (world_pos - global_position).length())


## World-space centre — the N-body contract shared with LAPlanetBody and LAMoon.
func center() -> Vector3:
	return global_position
