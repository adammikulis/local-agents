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
# STEEPENED environmental lapse — the emergent treeline + snow cap. A cell's ambient target drops this many
# °C per world unit of altitude, so high ground goes below freezing and the snow line + treeline fall out of
# the temperature field (no elevation number in the ecology). Steep enough (was 0.06) that peaks reach below
# 0°C. Steepening this ALONE used to run the dry fire plumes away to 3000-4000°C (no heat sink on the way up);
# the RADIATIVE SINK below now gives every hot cell a floor-referenced sink, so a steep lapse is energy-stable.
# Mirrored EXACTLY in heat3d_solar.glsl.
const LAPSE: float = 0.30                 # °C drop per world unit of altitude (cooler up high)
# --- ENERGY-STABLE heat: a radiative sink + a global clamp, both FOLDED into the conduction output (PART 1)
# so no extra pass/barrier is needed. Applied to EVERY cell's post-conduction temperature. Mirrored EXACTLY
# in heat3d.glsl (same BRANCHLESS arithmetic — maxf/clampf here, max/clamp there). -----------------------
# RADIATIVE SINK: a hot cell above RAD_FLOOR sheds RAD_RATE of its excess each step (Newtonian radiative loss
# toward a floor). This is the sink dry convective plumes were missing — an unsustained hot void cell that
# buoyancy piled heat into bleeds back down instead of running away to 3000-4000°C under a steep lapse. The
# FLOOR sits at 950 = the lava MOLTEN_FLOOR: the magma/lava melt-chain lives at 950-1300°C and is re-pinned
# each step by the lava/magma modules, so a lower floor (e.g. 120) bleeds the pinned chamber/conduit faster
# than they re-pin and STOPS eruptions (verified: magma_cells/lava_cells → 0). Flooring at the sustained-lava
# band leaves that chain untouched while still bounding any plume that climbs above it. A temperature floor
# (not a lava mask) keeps this parity-safe — lava is only ~1e-3 parity CPU-vs-GPU, so a `lava==0` mask would
# flip and break temp parity. CRITICAL: the BRANCHLESS max(0, t-floor) form (NOT a `t > floor` conditional) —
# a threshold flips on float32/64 differences and BREAKS GPU parity.
const RAD_FLOOR: float = 950.0            # °C below which a cell radiates nothing (== lava MOLTEN_FLOOR; magma-safe)
const RAD_RATE: float = 0.30              # fraction of the above-floor excess a hot cell sheds each step
# GLOBAL CLAMP: an idempotent safety net bounding any residual runaway just above magma temperature (nothing
# physical exceeds the ~1300°C chamber). Idempotent → parity-safe; re-applying it changes nothing in range.
const T_MIN: float = -80.0                # coldest temperature any cell may hold (°C)
const T_MAX: float = 1400.0               # hottest temperature any cell may hold (°C; just above magma ~1300)
# Warm maritime air: over an OCEAN column the sky cell relaxes toward this warm anchor (the tropical sea
# heats the air above it) with only a gentle lapse, day and night, so the marine boundary layer the storm
# systems sense stays warm. Mirrored EXACTLY in heat3d_solar.glsl.
const MARINE_AMBIENT: float = 25.0        # warm marine-air anchor at sea level over open ocean (°C)
const MARINE_LAPSE: float = 0.04          # gentle °C drop per world unit of altitude in the marine column
const BUOYANCY: float = 0.18              # share of an upward temperature inversion convected each step
const WATER_COOL_RATE: float = 0.12       # evaporative cooling pull on a wet cell (toward its depth target)
# Sea thermal profile (a THERMOCLINE): a wet cell relaxes toward a warm SURFACE temperature near sea level
# that cools with DEPTH toward WATER_TEMP_DEEP. This gives the ocean a tropical-warm skin (so hurricane
# genesis + lively sea evaporation have fuel) while the abyss stays cold and physical — one depth profile,
# not a per-cell special case. Cells at/above sea level clamp to the surface value. Mirrored EXACTLY in
# heat3d_cool.glsl (target = WATER_TEMP_DEEP + (SST_SURFACE - WATER_TEMP_DEEP) * exp(-depth/THERMOCLINE_SCALE)).
const SST_SURFACE: float = 26.0           # tropical warm sea-surface temperature at/near sea level (°C)
const WATER_TEMP_DEEP: float = 10.0       # cold deep-water floor the profile decays to with depth (°C)
const THERMOCLINE_SCALE: float = 24.0     # world-units of depth over which the warm skin decays to deep

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
					var out_t: float
					if n == 0:
						out_t = temp[i]
					else:
						out_t = temp[i] + CONDUCT_FRACTION * (sum / float(n) - temp[i])
					# ENERGY-STABLE FOLD (branchless — mirror of heat3d.glsl): radiative sink above the floor,
					# then the idempotent global clamp. Gives fire/lava plumes the missing heat sink so a steep
					# lapse can't run them away, while normal climate (< RAD_FLOOR) is left untouched.
					out_t = out_t - RAD_RATE * maxf(0.0, out_t - RAD_FLOOR)
					_scratch[i] = clampf(out_t, T_MIN, T_MAX)
		for ai in range(_f._cell_count):
			temp[ai] = _scratch[ai]

	# 2) SOLAR / AMBIENT at the sky-exposed surface (topmost non-solid cell of each column). Interior and
	# underground cells only conduct — sunlight never reaches them, so caves stay cool. OCEAN columns anchor
	# their sky cell to a WARM MARINE ambient (the tropical sea warms the maritime air above it) instead of
	# the cold land ambient — so the warm-sea skin actually reaches the air the storm systems read. A column
	# is ocean when the cell just below sea level is non-solid (water, not rock): a pure `solid`-mask test.
	var solar: float = _solar()
	var sea2: float = _f.sea_level
	var iy_sea: int = clampi(int(round((sea2 - _f._origin.y) / _f._cell_size)) - 1, 0, dy - 1)
	for iz in range(dz):
		for ix in range(dx):
			for iy in range(dy - 1, -1, -1):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					break                                   # hit rock from the top with no void above → no sky cell
				# First non-solid cell scanning down from the top of a column IS the exposed surface.
				var wy: float = _f._origin.y + float(iy) * _f._cell_size
				var is_ocean: bool = solid[(iy_sea * dz + iz) * dx + ix] == 0
				var target: float
				if is_ocean:
					target = MARINE_AMBIENT - MARINE_LAPSE * maxf(0.0, wy - sea2)
				else:
					target = AMBIENT_NIGHT + SOLAR_WARMTH * solar - LAPSE * maxf(0.0, wy - sea2)
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

	# 4) EVAPORATIVE COOLING — wet cells shed heat toward their DEPTH-PROFILE target: a warm sea skin near
	# sea level cooling to WATER_TEMP_DEEP with depth (thermocline). Warm surface sea => hurricane fuel +
	# lively evaporation; cold abyss => physical. Lava is NOT cooled here (the lava module sustains it).
	var water: PackedFloat32Array = _f._water
	var origin_y: float = _f._origin.y
	var cell_size: float = _f._cell_size
	var sea: float = _f.sea_level
	for i in range(_f._cell_count):
		if solid[i] == 0 and water[i] > 0.05:
			var iy: int = i / layer
			var wy: float = origin_y + float(iy) * cell_size
			var wt: float = sea_water_target(wy, sea)
			temp[i] += WATER_COOL_RATE * (wt - temp[i]) * clampf(water[i], 0.0, 1.0)


## The sea thermal profile: temperature (°C) a wet cell at world height `wy` relaxes toward. A warm skin
## at/above sea level (SST_SURFACE) decaying exponentially with DEPTH toward WATER_TEMP_DEEP (thermocline).
## Static (`static`) so seed_sea can seed the ocean warm without an instance. Mirrored in heat3d_cool.glsl.
static func sea_water_target(wy: float, sea: float) -> float:
	var depth: float = maxf(0.0, sea - wy)
	return WATER_TEMP_DEEP + (SST_SURFACE - WATER_TEMP_DEEP) * exp(-depth / THERMOCLINE_SCALE)


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
