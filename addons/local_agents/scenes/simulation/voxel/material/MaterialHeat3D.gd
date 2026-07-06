class_name LAMaterialHeat3D
extends RefCounted

## LAMaterialHeat3D — the 3D thermal step of the dense MaterialField3D (generalises the 2.5D
## MaterialHeat to a real volume). Temperature lives in EVERY cell — rock and void alike — so heat
## conducts through cave walls, sunlight warms the exposed surface, hot air/lava rises by buoyancy
## (thermals/plumes), and wet cells cool by evaporation. Nothing scripts fire/weather/incandescence;
## they emerge from where this heat goes. Holds no state beyond tuning — it reaches into the owning
## field (`_f`) for `_temp`, `_solid`, `_water`, `_lava`, `_dim_*`, and the scene sun.
## (Explicit types only — no ':=' inferred typing.)

const CONDUCT_FRACTION: float = 0.14      # per-step relaxation of a cell toward its 6-neighbour mean
const AMBIENT_NIGHT: float = 6.0          # °C the sunless surface relaxes toward
const SOLAR_WARMTH: float = 18.0          # extra °C at the surface under full midday sun
const AMBIENT_RELAX: float = 0.05         # how fast an exposed surface cell tracks its solar/ambient target
const LAPSE: float = 0.06                 # °C drop per world unit of altitude (cooler up high)
const BUOYANCY: float = 0.18              # share of an upward temperature inversion convected each step
const WATER_COOL_RATE: float = 0.12       # evaporative cooling pull on a wet cell (toward WATER_TEMP)
const WATER_TEMP: float = 12.0            # temperature wet cells are pulled toward

var _f = null
var _scratch: PackedFloat32Array = PackedFloat32Array()


func setup(field) -> void:
	_f = field
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## Current solar factor 0..1 from the real sun (energy × how high it is). 0 at night.
func _solar() -> float:
	if _f._sun_light == null:
		return 0.6
	var down: Vector3 = -_f._sun_light.global_transform.basis.z   # direction the light travels
	var above: float = clampf(-down.y, 0.0, 1.0)                  # 1 = straight down (noon), 0 = at/below horizon
	return clampf(above * _f._sun_light.light_energy, 0.0, 1.0)


## One thermal step: 6-neighbour conduction, solar/ambient forcing at the sky-exposed surface, buoyant
## upward convection of hot void, and evaporative cooling of wet cells. `skip_conduction` = the GPU
## already ran the conduction pass into _temp (see MaterialGPU3D.step_heat_conduction) — run only the
## remaining CPU forcing passes.
func step(skip_conduction: bool = false) -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid

	# 1) CONDUCTION — relax each cell toward the mean of its in-bounds 6 neighbours (into scratch). When
	# the GPU already ran this pass into _temp, skip it and go straight to the CPU-only forcing passes.
	if not skip_conduction:
		for iy in range(dy):
			for iz in range(dz):
				for ix in range(dx):
					var i: int = (iy * dz + iz) * dx + ix
					var sum: float = 0.0
					var n: int = 0
					if ix > 0:
						sum += temp[i - 1]; n += 1
					if ix < dx - 1:
						sum += temp[i + 1]; n += 1
					if iz > 0:
						sum += temp[i - dx]; n += 1
					if iz < dz - 1:
						sum += temp[i + dx]; n += 1
					if iy > 0:
						sum += temp[i - layer]; n += 1
					if iy < dy - 1:
						sum += temp[i + layer]; n += 1
					if n == 0:
						_scratch[i] = temp[i]
					else:
						_scratch[i] = temp[i] + CONDUCT_FRACTION * (sum / float(n) - temp[i])
		for ai in range(_f._cell_count):
			temp[ai] = _scratch[ai]

	# 2) SOLAR / AMBIENT at the sky-exposed surface (topmost non-solid cell of each column). Interior and
	# underground cells only conduct — sunlight never reaches them, so caves stay cool.
	var solar: float = _solar()
	for iz in range(dz):
		for ix in range(dx):
			for iy in range(dy - 1, -1, -1):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					break                                   # hit rock from the top with no void above → no sky cell
				# First non-solid cell scanning down from the top of a column IS the exposed surface.
				var wy: float = _f._origin.y + float(iy) * _f._cell_size
				var target: float = AMBIENT_NIGHT + SOLAR_WARMTH * solar - LAPSE * maxf(0.0, wy - _f.sea_level)
				temp[i] += AMBIENT_RELAX * (target - temp[i])
				break

	# 3) BUOYANCY — hot void rises: if a void cell is hotter than the void cell above it, convect a share
	# of the difference upward (thermals, lava/fire plumes). Uses scratch as before/after is fine in place
	# because we only move heat strictly upward once per cell.
	for iy in range(dy - 1):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var iu: int = i + layer
				if solid[iu] != 0:
					continue
				var d: float = temp[i] - temp[iu]
				if d > 0.0:
					var move: float = BUOYANCY * d * 0.5
					temp[i] -= move
					temp[iu] += move

	# 4) EVAPORATIVE COOLING — wet cells (water or the sea) shed heat toward WATER_TEMP (rivers/sea are a
	# heat sink and a firebreak). Lava is NOT cooled here — it sustains its own heat in the lava module.
	var water: PackedFloat32Array = _f._water
	for i in range(_f._cell_count):
		if solid[i] == 0 and water[i] > 0.05:
			temp[i] += WATER_COOL_RATE * (WATER_TEMP - temp[i]) * clampf(water[i], 0.0, 1.0)


## Inject a temperature change at a world point (lightning/lava/meteor = +, blizzard = −), spread over a
## sphere of `radius` with linear falloff. The emergent driver disasters call.
func add_heat(world_pos: Vector3, amount: float, radius: float) -> void:
	if amount == 0.0:
		return
	var cs: float = _f._cell_size
	var ci: int = int(round((world_pos.x - _f._origin.x) / cs))
	var cj: int = int(round((world_pos.y - _f._origin.y) / cs))
	var ck: int = int(round((world_pos.z - _f._origin.z) / cs))
	var cells: int = maxi(0, int(ceil(radius / cs)))
	var r2: float = radius * radius
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _f._dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _f._dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _f._dim_x:
					continue
				var wp: Vector3 = _f.cell_world_pos(ix, iy, iz)
				var dd: float = wp.distance_squared_to(world_pos)
				if dd > r2:
					continue
				var falloff: float = 1.0 - sqrt(dd) / maxf(0.001, radius)
				_f._temp[(iy * _f._dim_z + iz) * _f._dim_x + ix] += amount * falloff
