class_name LAMaterialCombustion3D
extends RefCounted

## LAMaterialCombustion3D — the 3D FIRE / COMBUSTION step of the dense LAMaterialField3D (the process the
## 2.5D MaterialCombustion used to run). Mirrors the shape of LAMaterialHeat3D / LAMaterialLava3D /
## LAMaterialWind3D: it holds NO authoritative grid state of its own — fuel + fire live in the owning
## field (`_f._fuel`, `_f._fire`) so ignite()/is_burning()/active_fire_count() read them directly — and it
## reaches into `_f` for the shared arrays (`_temp`, `_water`, `_solid`, `_vel_x/_y/_z`), the geometry
## (`_dim_*`, `_cell_size`, `_origin`, `sea_level`, `_cell_count`) and the ecology back-reference.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted wildfire. Fire falls out of three local
## rules over a FUEL channel:
##   IGNITION — a flammable cell (fuel > 0, not wet) whose temperature reaches IGNITE_TEMP (~300°C, wood's
##     autoignition from Materials.gd) starts burning. So lava, a lightning bolt's heat, a meteor's heat,
##     or the front of a spreading fire all light it identically — no special-casing the source.
##   BURN — a burning cell CONSUMES its fuel and pins its own temperature to BURN_TEMP (self-sustaining;
##     the heat module then conducts that into neighbours and buoyancy lifts it into a plume). When the
##     fuel runs out the cell stops burning and is ASH (fuel 0), a candidate for later plant regrowth.
##   SPREAD — a burning cell throws EMBER heat at its neighbours, biased DOWNWIND (and upward, so it climbs
##     slopes / into a canopy) by the emergent wind field. Fire therefore RUNS DOWNWIND — the payoff of the
##     wind field. WET cells (water > 0, i.e. rivers / rain / the sea) can't ignite and are extinguished, so
##     water is an emergent firebreak. Creatures avoid fire for free: the injected heat drives the existing
##     heat-comfort flee/seek-water drive, and past LAActor COMBUST_TEMP they catch fire (Creature.gd).
##
## The math here is the CPU-oracle REFERENCE; kernels3d/fire3d.glsl mirrors it EXACTLY (parity mandate —
## constants duplicated there with "must match"). Like the wind field it currently steps on the CPU oracle
## on BOTH the GPU-resident and headless paths (post-readback, on the fresh temperature); the fire3d.glsl
## GPU port is the remaining GPU-first work, wired into the resident step() seam exactly like lava.
## (Explicit types only — no ':=' inferred typing.)

# --- Combustion thresholds. The GPU kernel kernels3d/fire3d.glsl duplicates these EXACTLY ("must match").
const IGNITE_TEMP: float = 300.0          # °C a fuel cell ignites at (== Materials.gd WOOD ignite_temp)
const BURN_TEMP: float = 640.0            # °C a burning cell is pinned to (self-sustaining; > actor COMBUST 200, < lava)
const FUEL_MIN: float = 0.02              # below this a cell holds no meaningful fuel
const FIRE_MIN: float = 0.02              # below this _fire counts as NOT burning
const FIRE_START: float = 0.4            # intensity a freshly-ignited cell starts at
const FIRE_GROW: float = 0.3             # per-step intensity ramp while fuel remains (0..1)
const BURN_RATE: float = 0.045           # fuel mass consumed per step by a fully-lit cell (× fire)
const WET_MAX: float = 0.05              # water mass above which a cell can't ignite / is extinguished (firebreak)
# --- Oxygen coupling (LAMaterialGas3D owns the O₂ field; fire is the consumer). A burning cell draws down its
# own cell's O₂; ignition + burn-sustain require O₂ >= O2_MIN, so a fire in a SEALED cave depletes its trapped
# O₂ and suffocates while an open/windy fire gets O₂ diffused/advected back in + roars. Duplicated in fire3d.glsl.
const O2_MIN: float = 0.35               # O₂ below which a cell can't ignite / a burning cell is extinguished (suffocation)
const BURN_O2_RATE: float = 0.06         # O₂ consumed per step by a fully-lit cell (× fire), floored at 0
# --- CO₂ emission (the carbon-loop source). A burning cell EMITS CO₂ as it draws down O₂ (fuel + O₂ → CO₂ +
# ash + heat). Deterministic ∝ fire intensity, so it stays bit-exact CPU vs GPU. LAMaterialGas3D transports +
# settles it; plants fix it back to O₂. Duplicated EXACTLY in fire3d.glsl ("must match").
const CO2_PER_BURN: float = 0.06         # CO₂ emitted per step by a fully-lit cell (× fire)
# Ember spread: a burning neighbour preheats this cell each step. GATHER form (each cell sums embers from its
# burning neighbours) so the CPU oracle + the single-dispatch GPU kernel are race-free AND bit-for-bit alike.
const EMBER_HEAT: float = 22.0           # base °C a burning lateral neighbour throws at this cell per step
const EMBER_WIND_GAIN: float = 5.0       # extra °C toward a DOWNWIND-aligned neighbour (× that neighbour's wind toward us)
const EMBER_MAX: float = 70.0            # cap on a single neighbour's ember contribution (stability)
const EMBER_UP: float = 16.0             # °C a burning cell BELOW throws upward (plume climbs → upslope/canopy spread)

# --- Fuel seeding (vegetation is the fuel). Matches the terrain shader's grass band: above the beach,
# below the snow cap, on gentle (non-steep) ground, above sea level. Plants/trees add stronger local fuel.
const GRASS_FUEL: float = 0.5            # base fuel on a grassy surface cell (burns to ash in ~11 steps)
const PLANT_FUEL: float = 1.2            # fuel a bush/plant actor adds at its cell
const TREE_FUEL: float = 2.4            # fuel a tree actor adds at its cell (bigger, burns longer)
const BEACH_TOP: float = 3.5            # world units above sea level where sand gives way to grass (shader beach)
const SNOW_LINE: float = 66.0           # world units above sea level the snow cap starts (shader snow_height = sea+66)
const REGROW_TEMP: float = 40.0         # °C an ash cell must have cooled below before a plant can regrow there
# Burnt organic matter is DETRITUS too: a cell that burns out drops a little charred matter into the field's
# decomposer channel (LAMaterialFungus3D), so ash also feeds fungus → CO₂/fertility. A small general coupling.
const ASH_DETRITUS: float = 0.4         # detritus deposited at a cell the moment its fuel burns out (→ ash)

const SCAN_EVERY: int = 4               # cadence (steps) for the actor fuel/consume + ash-regrowth scan
const REGROW_PER_SCAN: int = 3          # ash cells asked to regrow per scan (budgeted; regrowth is slow)
# Both scene-tail sweeps are ROTATING-CURSOR budgeted so the tail cost stays FLAT regardless of fire size.
# Without a cap, _mark_ash swept the whole 127K grid every cadence, and _regrow_ash churned the whole grid
# whenever it couldn't find REGROW_PER_SCAN cool ash cells (i.e. all through a wildfire, when every ash cell
# is still hot) — that full-grid churn was the wildfire tail SPIKE. A bounded slice per call visits the grid
# gradually instead; ash marking + regrowth are glacial, so a slower sweep is imperceptible and behaviour is
# unchanged (every burned-out cell is still eventually marked, every cooled ash cell still eventually regrows).
const MARK_SCAN_BUDGET: int = 8192      # cells the ash-detector visits per _mark_ash call (rotating cursor)
const REGROW_SCAN_BUDGET: int = 8192    # cells the regrowth cursor visits per _regrow_ash call (bounded sweep)

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _fire_scratch: PackedFloat32Array = PackedFloat32Array()  # fire double buffer (reads neighbours, writes out)
var _ash: PackedByteArray = PackedByteArray()            # 1 = a cell that burned out (fuel spent) — regrowth site
var _had_fuel: PackedByteArray = PackedByteArray()       # 1 = a cell that was ever given fuel — GPU-path burned-out detector
var _seeded: bool = false
var _scan_tick: int = 0
var _active_last: int = 0                                # diagnostic: burning cells after the last step
var _ash_cursor: int = 0                                 # rotating cursor for budgeted ash regrowth
var _mark_cursor: int = 0                                # rotating cursor for budgeted GPU-path ash marking


func setup(field) -> void:
	_f = field
	_fire_scratch = PackedFloat32Array()
	_fire_scratch.resize(_f._cell_count)
	_ash = PackedByteArray()
	_ash.resize(_f._cell_count)
	_had_fuel = PackedByteArray()
	_had_fuel.resize(_f._cell_count)
	_seeded = false


## One combustion step (gather form; deterministic + order-independent, so it mirrors the GPU kernel
## bit-for-bit). Seeds the fuel channel from vegetation on first call. Per non-solid cell:
##   1) sum EMBER heat from any burning neighbours (downwind/upward biased) into this cell's temperature,
##   2) if WET → extinguish; else BURN (consume fuel, pin to BURN_TEMP, → ash when spent) or IGNITE
##      (fuel present and temp ≥ IGNITE_TEMP). Fire writes to a scratch buffer, then swaps in.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if not _seeded:
		seed_fuel()
	if _fire_scratch.size() != _f._cell_count:
		_fire_scratch.resize(_f._cell_count)
	if _ash.size() != _f._cell_count:
		_ash.resize(_f._cell_count)

	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var fire: PackedFloat32Array = _f._fire
	var fuel: PackedFloat32Array = _f._fuel
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var o2: PackedFloat32Array = _f._o2
	var co2: PackedFloat32Array = _f._co2
	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vz: PackedFloat32Array = _f._vel_z
	var burning: int = 0

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_fire_scratch[i] = 0.0
					continue

				# 1) EMBER GATHER — sum preheat from each burning neighbour, biased by that neighbour's wind
				# blowing TOWARD this cell (downwind spread) plus a fixed upward throw from a burning cell below.
				var ember: float = 0.0
				if ix > 0:
					var n: int = i - 1                       # neighbour to -X emits toward +X (this cell)
					if solid[n] == 0 and fire[n] > FIRE_MIN:
						ember += _ember(fire[n], vx[n])
				if ix < dx - 1:
					var n2: int = i + 1                      # neighbour to +X emits toward -X
					if solid[n2] == 0 and fire[n2] > FIRE_MIN:
						ember += _ember(fire[n2], -vx[n2])
				if iz > 0:
					var n3: int = i - dx                     # neighbour to -Z emits toward +Z
					if solid[n3] == 0 and fire[n3] > FIRE_MIN:
						ember += _ember(fire[n3], vz[n3])
				if iz < dz - 1:
					var n4: int = i + dx                     # neighbour to +Z emits toward -Z
					if solid[n4] == 0 and fire[n4] > FIRE_MIN:
						ember += _ember(fire[n4], -vz[n4])
				if iy > 0:
					var nd: int = i - layer                  # burning cell below throws a plume upward
					if solid[nd] == 0 and fire[nd] > FIRE_MIN:
						ember += EMBER_UP * clampf(fire[nd], 0.0, 1.0)
				if ember > 0.0:
					temp[i] += ember

				# 2) PHASE — extinguish / burn / ignite.
				var f: float = fire[i]
				var fuel_i: float = fuel[i]
				var fnew: float = 0.0
				if water[i] > WET_MAX or o2[i] < O2_MIN:  # wet firebreak OR suffocated (O2 < O2_MIN)
					fnew = 0.0                               # wet → firebreak (rain, river, sea)
				elif f > FIRE_MIN:
					if fuel_i > 0.0:
						fuel[i] = maxf(0.0, fuel_i - BURN_RATE * clampf(f, 0.0, 1.0))
						o2[i] = maxf(0.0, o2[i] - BURN_O2_RATE * clampf(f, 0.0, 1.0))
						co2[i] += CO2_PER_BURN * clampf(f, 0.0, 1.0)  # emit CO₂ as it burns (fuel + O₂ → CO₂)
						if temp[i] < BURN_TEMP:
							temp[i] = BURN_TEMP              # self-sustain (conducts to neighbours via the heat module)
						if fuel[i] <= 0.0:
							fnew = 0.0                       # fuel spent → burned out
							_ash[i] = 1
							_drop_ash_detritus(i)            # charred matter → detritus (feeds fungus)
						else:
							fnew = minf(1.0, f + FIRE_GROW)
					else:
						fnew = 0.0                           # nothing left to burn
						_ash[i] = 1
						_drop_ash_detritus(i)
				elif fuel_i > FUEL_MIN and temp[i] >= IGNITE_TEMP:
					fnew = FIRE_START                        # IGNITION from any heat source
				_fire_scratch[i] = fnew
				if fnew > FIRE_MIN:
					burning += 1

	# Commit the fire buffer (swap so queries read the fresh state; scratch becomes next step's out buffer).
	var tmp: PackedFloat32Array = _f._fire
	_f._fire = _fire_scratch
	_fire_scratch = tmp
	_active_last = burning

	# Actor coupling + ash regrowth on a cadence (cheap; touches only the plant/tree groups + a few ash cells).
	_scan_tick += 1
	if _scan_tick >= SCAN_EVERY:
		_scan_tick = 0
		_scan_actors()
		_regrow_ash()


## GPU-path TAIL — runs ONLY the scene/ecology concerns (fuel seeding, plant/tree fuel-feed + consume, ash
## marking, ash->plant regrowth) WITHOUT the ember/phase grid loop, because on the GPU-resident path
## kernels3d/fire3d.glsl already ran that per-cell core (ember gather + ignite/burn/ash) on the device and
## _f._fire/_f._fuel came back from the readback. Called ONCE per frame on the fresh GPU readback (the CPU
## path keeps calling the full step()). Mirrors how lava's SDF stamps stay a CPU tail off the GPU flow.
func step_scene_only() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if not _seeded:
		seed_fuel()
	if _ash.size() != _f._cell_count:
		_ash.resize(_f._cell_count)
	if _had_fuel.size() != _f._cell_count:
		_had_fuel.resize(_f._cell_count)
	# NB: we deliberately DON'T run active_fire_count() (a full-grid burning-cell scan) here every frame — it
	# dominated the calm-frame tail cost while nothing in this tail reads _active_last. The SMOKE_SUMMARY/HUD
	# 'fires' diagnostic calls active_fire_count() directly (SimReportSources / StreamerDirector) when it needs it.
	_scan_tick += 1
	if _scan_tick >= SCAN_EVERY:
		_scan_tick = 0
		_scan_actors()
		_mark_ash()
		_regrow_ash()


## GPU-path ash detection: the fire kernel doesn't write the CPU _ash array (a scene concern), so on the GPU
## path we derive ash from the fuel channel — a cell that WAS given fuel (_had_fuel) but has burned down to
## nothing (fuel spent) and is no longer alight is ash, a regrowth site. Fuel only ever decreases by burning,
## so fuel<=FUEL_MIN on a once-fuelled cell means it burned out. Cheap on the SCAN_EVERY cadence.
func _mark_ash() -> void:
	var fuel: PackedFloat32Array = _f._fuel
	var fire: PackedFloat32Array = _f._fire
	var solid: PackedByteArray = _f._solid
	var n: int = _f._cell_count
	var budget: int = mini(MARK_SCAN_BUDGET, n)     # bounded slice per call (rotating cursor) → flat tail cost
	var visited: int = 0
	while visited < budget:
		var i: int = _mark_cursor
		_mark_cursor += 1
		if _mark_cursor >= n:
			_mark_cursor = 0
		visited += 1
		if _had_fuel[i] == 0 or solid[i] != 0:
			continue
		if fuel[i] <= FUEL_MIN and fire[i] <= FIRE_MIN:
			_ash[i] = 1
			_had_fuel[i] = 0
			_drop_ash_detritus(i)                        # charred matter -> detritus (feeds fungus)


## Drop a little charred organic matter into the field's DETRITUS channel when a cell burns out, so wildfire
## ash also feeds the emergent decomposer (LAMaterialFungus3D) → CO₂ + soil fertility. A small general coupling
## (not a per-case branch): every burned-out cell contributes, on both the CPU and GPU-tail ash paths.
func _drop_ash_detritus(i: int) -> void:
	if _f._detritus.size() == _f._cell_count:
		_f._detritus[i] += ASH_DETRITUS


## Ember heat one burning neighbour contributes to this cell: a base creep plus a downwind boost scaled by
## the wind component the neighbour blows TOWARD us (`toward` = +vel along the neighbour→cell axis), all ×
## the emitter's fire intensity. Capped for stability. Duplicated EXACTLY in kernels3d/fire3d.glsl.
func _ember(neighbour_fire: float, toward: float) -> float:
	var w: float = EMBER_HEAT + EMBER_WIND_GAIN * maxf(0.0, toward)
	return minf(EMBER_MAX, w) * clampf(neighbour_fire, 0.0, 1.0)


# --- Fuel seeding from vegetation -------------------------------------------

## Seed the fuel channel once the terrain is sampled: the grassy SURFACE band (above the beach, below the
## snow cap, on gentle ground, above sea level — the same signal the terrain shader paints grass with) gets
## a base fuel; plant/tree actors add stronger local fuel via _scan_actors(). Rock/sand/snow/water = no fuel.
func seed_fuel() -> void:
	if _f == null:
		return
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var cs: float = _f._cell_size
	var oy: float = _f._origin.y
	var sea: float = _f.sea_level
	var fuel: PackedFloat32Array = _f._fuel
	var water: PackedFloat32Array = _f._water
	for iz in range(dz):
		for ix in range(dx):
			var giy: int = _ground_iy(ix, iz)
			if giy < 0 or giy >= dy - 1:
				continue                                     # no ground, or ground at the very top (no surface air cell)
			var siy: int = giy + 1
			var si: int = (siy * dz + iz) * dx + ix
			if _f._solid[si] != 0:
				continue
			var gy: float = oy + float(giy) * cs
			if gy < sea + BEACH_TOP or gy > sea + SNOW_LINE:
				continue                                     # beach/underwater or snow cap → no grass
			if water[si] > WET_MAX:
				continue                                     # standing water on the surface → no grass fuel
			# Slope: a cell whose neighbouring ground rises/falls more than a cell height is a steep rock face.
			var steep: bool = false
			if ix > 0 and absi(_ground_iy(ix - 1, iz) - giy) > 1:
				steep = true
			elif ix < dx - 1 and absi(_ground_iy(ix + 1, iz) - giy) > 1:
				steep = true
			elif iz > 0 and absi(_ground_iy(ix, iz - 1) - giy) > 1:
				steep = true
			elif iz < dz - 1 and absi(_ground_iy(ix, iz + 1) - giy) > 1:
				steep = true
			if steep:
				continue
			if fuel[si] < GRASS_FUEL:
				fuel[si] = GRASS_FUEL
			if _had_fuel.size() == _f._cell_count:
				_had_fuel[si] = 1
	_seeded = true


# Topmost SOLID (ground) cell index-y of a column scanning down from the top, or -1 if the column is all void.
func _ground_iy(ix: int, iz: int) -> int:
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * dz + iz) * dx + ix] != 0:
			return iy
	return -1


# The surface AIR cell of a column (just above the ground) — where vegetation fuel sits + fire burns; -1 if none.
func _surface_air_i(ix: int, iz: int) -> int:
	var giy: int = _ground_iy(ix, iz)
	if giy < 0 or giy >= _f._dim_y - 1:
		return -1
	return ((giy + 1) * _f._dim_z + iz) * _f._dim_x + ix


# The surface air cell index for a world position (a plant/tree/creature at world_pos), or -1 if off-grid.
func _node_cell(world_pos: Vector3) -> int:
	if _f._cell_count <= 0:
		return -1
	var ix: int = _f._col_i(world_pos.x, _f._origin.x)
	var iz: int = _f._col_i(world_pos.z, _f._origin.z)
	return _surface_air_i(ix, iz)


# --- Actor coupling: vegetation feeds fuel + is consumed by fire; ash regrows later ------------------

## Top up fuel under live plant/tree actors, and consume any that sit on a burning cell (plants are burned
## away, trees topple). Emergent: a stronger local fuel load where vegetation stands, and vegetation dies to
## the same fire everything else reads. Cheap — the plant/tree groups are a few hundred nodes.
func _scan_actors() -> void:
	if _f == null or not _f.is_inside_tree():
		return
	var tree: SceneTree = _f.get_tree()
	if tree == null:
		return
	var fuel: PackedFloat32Array = _f._fuel
	var fire: PackedFloat32Array = _f._fire
	for p in tree.get_nodes_in_group("plant"):
		if not is_instance_valid(p):
			continue
		var i: int = _node_cell(p.global_position)
		if i < 0:
			continue
		if fire[i] > FIRE_MIN:
			p.queue_free()                                   # a plant on a burning cell is consumed by the fire
		elif fuel[i] < PLANT_FUEL:
			fuel[i] = PLANT_FUEL
			if _had_fuel.size() == _f._cell_count:
				_had_fuel[i] = 1
	for t in tree.get_nodes_in_group("tree"):
		if not is_instance_valid(t):
			continue
		var ti: int = _node_cell(t.global_position)
		if ti < 0:
			continue
		if fire[ti] > FIRE_MIN:
			if t.has_method("take_damage"):
				t.take_damage(1000.0, "burned", _f.wind3_at(t.global_position.x, t.global_position.y, t.global_position.z))
		elif fuel[ti] < TREE_FUEL:
			fuel[ti] = TREE_FUEL
			if _had_fuel.size() == _f._cell_count:
				_had_fuel[ti] = 1


## Wildfire ash regrows: once an ash cell has COOLED (fire passed, temp back near ambient) and is dry, ask
## the ecology to seed a plant there (respecting its population cap). Budgeted + cursor-rotated so a step
## never scans the whole map; regrowth is slow and only after the burn front has moved on. Emergent renewal.
func _regrow_ash() -> void:
	var eco = _f._ecology if _f != null else null
	if eco == null or not eco.has_method("seed_plant_at"):
		return
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var fire: PackedFloat32Array = _f._fire
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var regrown: int = 0
	var scanned: int = 0
	# Bound the visit count: during a wildfire almost every ash cell is still hot/wet and rejected, so the old
	# scan-until-REGROW_PER_SCAN-found loop swept the WHOLE grid each cadence (the wildfire tail spike). Cap it —
	# the cursor just sweeps more gradually across calls; regrowth is glacial so the pacing is imperceptible.
	var budget: int = mini(REGROW_SCAN_BUDGET, _f._cell_count)
	while scanned < budget and regrown < REGROW_PER_SCAN:
		var i: int = _ash_cursor
		_ash_cursor += 1
		if _ash_cursor >= _f._cell_count:
			_ash_cursor = 0
		scanned += 1
		if _ash[i] == 0:
			continue
		if fire[i] > FIRE_MIN or temp[i] > REGROW_TEMP or water[i] > WET_MAX:
			continue                                         # still hot / burning / wet — not yet
		_ash[i] = 0
		_f._fuel[i] = 0.0
		var iy: int = i / layer
		var rem: int = i % layer
		var iz: int = rem / dx
		var ix: int = rem % dx
		eco.seed_plant_at(_f.cell_world_pos(ix, iy, iz))
		regrown += 1


# --- Consumer API (the field's ignite()/is_burning()/active_fire_count() forward here) ---------------

## Light the cell under a node on fire (a disaster or scripted ignition). Gives the cell a little fuel if it
## has none so the flame sustains, sets it burning, and pins it hot so the heat immediately spreads.
func ignite_node(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var i: int = _node_cell(node.global_position)
	if i < 0 or _f._solid[i] != 0:
		return
	if _f._fuel[i] < FUEL_MIN:
		_f._fuel[i] = GRASS_FUEL
	_f._fire[i] = maxf(_f._fire[i], FIRE_START)
	if _f._temp[i] < BURN_TEMP:
		_f._temp[i] = BURN_TEMP
	_ash[i] = 0


## Is the cell under this node currently burning?
func is_burning_node(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var i: int = _node_cell(node.global_position)
	if i < 0:
		return false
	return _f._fire[i] > FIRE_MIN


## Number of cells currently on fire (diagnostic / HUD / SMOKE_SUMMARY `fires`).
func active_fire_count() -> int:
	if _f == null:
		return 0
	var fire: PackedFloat32Array = _f._fire
	var n: int = 0
	for i in range(_f._cell_count):
		if fire[i] > FIRE_MIN:
			n += 1
	return n


## Total fuel mass across the field (diagnostic).
func total_fuel() -> float:
	if _f == null:
		return 0.0
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _f._fuel[i]
	return s
