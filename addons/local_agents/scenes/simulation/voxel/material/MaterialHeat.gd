class_name LAMaterialHeat
extends RefCounted

## The thermal step of the MaterialField, split out as its own concern. Each CA tick it: (1) CONDUCTS
## heat between neighbouring cells, then (2) relaxes every cell toward its AMBIENT temperature, where
## ambient = a night floor + incoming SOLAR (the real scene sun's energy × elevation, dimmed by any
## cloud/fog overhead) − an altitude lapse. WET cells are pulled toward ambient faster (big water heat
## capacity → rivers are firebreaks). Reads the shared grid via a back reference (_f). Temperatures
## are real degrees Celsius. (Explicit types only — project rule: no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

## Fraction of a cell's temperature gradient conducted to its 4 neighbours per step.
const CONDUCT_FRACTION: float = 0.16
## How fast a cell relaxes toward its ambient temperature per step (radiative equilibrium).
const AMBIENT_RELAX: float = 0.06
## Radiative night floor (°C the ground relaxes toward with zero sun) — a cool but non-freezing night.
const AMBIENT_NIGHT: float = 6.0
## Ambient warming (°C) per unit of incoming solar (light_energy * elevation) — clouds dim it.
const SOLAR_WARMTH: float = 16.0
## Altitude cooling: temperature drops by LAPSE_RATE °C per world-unit above LAPSE_REF (cold peaks).
const LAPSE_RATE: float = 0.42
const LAPSE_REF: float = 15.0
## Pull (°C toward ambient per second) on WET cells — big water heat capacity keeps rivers near ambient.
const WATER_COOL: float = 300.0
## Cloud/fog overhead shades a cell's sunlight so cloudy ground warms less (clouds-cool-the-ground).
const CLOUD_SHADE_GAIN: float = 3.0      # cloud density -> fraction of solar blocked below it
const CLOUD_SHADE_MAX: float = 0.75      # a cell's cloud can block at most this much of its solar

var _f = null                              # LAMaterialField (shared grid back-reference)
var _tdelta: PackedFloat32Array = PackedFloat32Array()   # scratch for conduction
var _solar: float = 0.0                    # cached incoming solar (energy * elevation)


func setup(field) -> void:
	_f = field
	_tdelta = PackedFloat32Array()
	_tdelta.resize(_f._cell_count)


## Incoming solar at flat ground = the sun's real energy times its downward elevation (angle of
## incidence). Zero at night (sun below horizon), weak at dawn/dusk, peak at noon; dimmed by clouds.
func _solar_input() -> float:
	var light = _f._sun_light
	if light == null:
		return 0.0
	var travel: Vector3 = -light.global_transform.basis.z   # direction photons move
	var elevation: float = maxf(0.0, -travel.y)             # how straight-down the light is
	return elevation * maxf(0.0, light.light_energy)


func step() -> void:
	var dim: int = _f._dim
	var water: PackedFloat32Array = _f._mat_array(Mat.WATER)

	# 1) CONDUCTION — share a fraction of each cell/neighbour difference into _tdelta (symmetric,
	# order-independent). Only sampled cells participate.
	for idx in range(_f._cell_count):
		_tdelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _f._sampled[idx] == 0:
				continue
			var t: float = _f._temp[idx]
			# Right + up neighbours only, applying the flux to BOTH cells → every pair counted once.
			if i < dim - 1:
				var ri: int = idx + 1
				if _f._sampled[ri] != 0:
					var f: float = (t - _f._temp[ri]) * CONDUCT_FRACTION * 0.25
					_tdelta[idx] -= f
					_tdelta[ri] += f
			if j < dim - 1:
				var ui: int = idx + dim
				if _f._sampled[ui] != 0:
					var f2: float = (t - _f._temp[ui]) * CONDUCT_FRACTION * 0.25
					_tdelta[idx] -= f2
					_tdelta[ui] += f2

	# 2) Apply conduction, then relax toward ambient (with altitude lapse), then extra cooling on
	# wet cells so rivers keep fires in check emergently. Ambient is driven by the REAL sun energy.
	_solar = _solar_input()
	var solar_warmth: float = SOLAR_WARMTH * _solar
	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0:
			continue
		var t: float = _f._temp[idx] + _tdelta[idx]
		var altitude: float = _f._terrain_h[idx]
		# Cloud overhead shades this cell's sunlight, so cloudy/foggy ground warms less — the
		# emergent "clouds cool the ground below them" feedback.
		var shade: float = minf(CLOUD_SHADE_MAX, (_f._cloud[idx] + _f._fog[idx]) * CLOUD_SHADE_GAIN)
		var day_base: float = AMBIENT_NIGHT + solar_warmth * (1.0 - shade)
		var ambient: float = day_base - LAPSE_RATE * maxf(0.0, altitude - LAPSE_REF)
		t = t + (ambient - t) * AMBIENT_RELAX
		# Cooling where wet: WATER cells pull toward ambient faster than open ground, so rivers/lakes/
		# flood become firebreaks and rain suppresses fire emergently.
		if water[idx] > _f.WATER_THRESHOLD:
			t = move_toward(t, ambient, WATER_COOL * _f.STEP_DT)
		_f._temp[idx] = t
