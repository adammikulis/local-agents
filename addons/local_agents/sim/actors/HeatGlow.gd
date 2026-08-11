class_name LAHeatGlow
extends RefCounted

## Blackbody incandescence for MINERAL matter: temperature in °C to an emissive colour, using the same
## ramp as the terrain shader so a molten rock reads as the same temperature as the molten ground.
## Below GLOW_MIN nothing glows.
##
## Mineral only. Flesh and wood do not incandesce, they burn — a creature that gets hot enough crosses the
## combust bound in the one temperature rule and dies charred. Glow belongs to what is still solid at 400 °C
## and up: molten rock, volcanic ejecta, a meteor on entry, embers.
##
## Consumer: `sim/actors/Meteor.gd`, whose body material and light colour are both computed from
## its MOLTEN_TEMP_C, the same number it injects into the field on impact.
##
## (Explicit types only, no ':=' inferred typing.)

const GLOW_MIN: float = 400.0             # °C — dull red starts here


static func emission(temp: float) -> Color:
	if temp < GLOW_MIN:
		return Color.BLACK
	var brightness: float = clampf((temp - GLOW_MIN) / 900.0, 0.0, 1.0)
	var c: Color = Color(0.75, 0.06, 0.0).lerp(Color(1.0, 0.5, 0.08), clampf((temp - GLOW_MIN) / 400.0, 0.0, 1.0))
	c = c.lerp(Color(1.0, 0.96, 0.82), clampf((temp - 850.0) / 450.0, 0.0, 1.0))
	return c * brightness


static func energy(temp: float) -> float:
	return clampf((temp - GLOW_MIN) / 500.0, 0.0, 4.0)


## Drive a material's emission from a temperature. Only touches emission we set (tagged via meta), so
## materials that already glow for other reasons are left alone below the threshold.
static func apply(mat: StandardMaterial3D, temp: float) -> void:
	if mat == null:
		return
	if temp < GLOW_MIN:
		if bool(mat.get_meta("heatglow", false)) and mat.emission_enabled:
			mat.emission_enabled = false
			mat.set_meta("heatglow", false)
		return
	mat.emission_enabled = true
	mat.emission = emission(temp)
	mat.emission_energy_multiplier = energy(temp)
	mat.set_meta("heatglow", true)
