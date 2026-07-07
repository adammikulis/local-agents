class_name LAMaterialScent3D
extends RefCounted

## LAMaterialScent3D — the emergent SCENT + WASTE/FERTILITY step of the dense LAMaterialField3D (the
## stigmergy substrate that replaced the marker-based LAScentField + the LAPoop node). Scent is a small
## FIXED set of per-column airborne channels that DIFFUSE, ADVECT ON THE REAL WIND, DECAY, and wash out
## faster in rain; waste deposits a soil FERTILITY channel that plants grow from. Creatures WRITE these
## (a musk trail derived from what they ARE + how hungry/hurt/panicked they are, plus feces/urine/blood)
## and READ the gradients — so herd/predator-prey/foraging behavior EMERGES from the shared field rather
## than per-pair code (see EMERGENCE.md). No per-species scent tables: emission is DERIVED from diet/size/
## state, and "a predator downwind of prey smells it" just falls out of advection on the local wind.
##
## Per-COLUMN (2D) not per-cell: scent is a ground phenomenon that rides the surface wind — exactly how the
## old markers drifted by wind_at(x,z) — so a column grid (dim_x×dim_z) is the right, cheap representation
## (≈8× fewer cells than the full volume). Channel c, column (ix,iz) -> index c*_area + iz*_dim_x + ix.
## It holds its OWN channels (no field-resident array, no GPU kernel reads them yet) — the field only wires
## step() + a few forwarders. CPU-oracle only (like wind/slump): a future scent3d.glsl is the parity port.
## (Explicit types only — no ':=' inferred typing.)

# --- Channels (airborne, per-column) ----------------------------------------
const PREY: int = 0            # grazer/prey musk — carnivores follow it toward prey-dense ground
const PREDATOR: int = 1        # predator musk — prey avoid/flee down it; marking boosts it
const BLOOD: int = 2           # acute fresh-wound signal — fast decay, sharp plume that draws opportunists
const FOOD: int = 3            # persistent carrion/dung cue — scavengers home on it ("watch the vultures")
const ALARM: int = 4           # lingering "danger here" — panicked creatures leave it, others avoid it
const CHANNELS: int = 5

# --- CA tuning. Kept so the total per-column outflow share stays < 1 (stable, mass-aware gather). --------
const DIFFUSE: float = 0.08              # symmetric share sent to each of the 4 lateral column-neighbours
const ADVECT: float = 0.06               # extra downwind share (× clamped wind toward the neighbour)
const WIND_REF: float = 6.0              # wind speed at which the advective share saturates
# Per-channel decay per step (BLOOD fast, FOOD persistent). Rain multiplies decay (washes scent away).
# (A PackedFloat32Array built from a literal is not a GDScript constant expression, so this is a var.)
var DECAY: PackedFloat32Array = PackedFloat32Array([0.030, 0.030, 0.100, 0.015, 0.045])
const RAIN_WASH: float = 0.30            # extra decay × precipitation() (a downpour scrubs the air)
const SCENT_MIN: float = 0.002           # below this a channel reads as empty (diagnostics / gradient noise floor)

# --- Fertility (soil nutrient; no advection, very slow leach; plants grow from it) ---------------------
const FERT_DECAY: float = 0.0015         # nutrients persist for a long time
const FERT_RAIN_LEACH: float = 0.02      # rain leaches nutrient faster
const FERT_BLUR: float = 0.04            # gentle 4-neighbour spread (soil creep)
const SEED_THRESH: float = 2.5           # fertility above which the ecology may seed a plant on the patch
const SEED_SPEND: float = 1.2            # nutrient consumed when a plant is seeded
const SEED_PER_STEP: int = 2             # budgeted seedings per step (cursor-rotated)

# --- Emission tunables (DERIVED from creature state; no per-species branches) --------------------------
const MUSK_RATE: float = 0.55            # base musk laid per step, × size (bigger animals smell stronger)
const HUNGER_MUSK: float = 0.5           # predator musk boost fraction when starving (a hungry hunter is pungent)
const BLOOD_RATE: float = 0.9            # blood scent per step × wound fraction (1 - health/max_health)
const ALARM_RATE: float = 0.8            # alarm scent per step while fleeing/panicking
const CARRION_FOOD: float = 0.08         # FOOD laid per step × a carcass's remaining meat value
# Waste deposits (feces/urine) — diet-flavored: herbivore scat enriches soil, carnivore scat smells of FOOD.
const FECES_FERT: float = 3.0            # soil nutrient a dropping adds
const FECES_FOOD: float = 1.5            # FOOD dab a dropping adds (dung draws scavengers/flies)
const FECES_MUSK: float = 2.0            # the depositor's own musk in the dropping (predators track prey by dung)
const URINE_FERT: float = 1.2           # urine nitrogen
const URINE_MUSK: float = 2.5           # territorial marking is mostly musk

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _area: int = 0                                       # dim_x * dim_z (one column plane)
var _scent: PackedFloat32Array = PackedFloat32Array()    # CHANNELS * _area airborne density
var _scent_next: PackedFloat32Array = PackedFloat32Array()
var _fert: PackedFloat32Array = PackedFloat32Array()     # _area soil nutrient
var _fert_next: PackedFloat32Array = PackedFloat32Array()
var _surf_vx: PackedFloat32Array = PackedFloat32Array()  # cached surface wind X per column (recomputed each step)
var _surf_vz: PackedFloat32Array = PackedFloat32Array()  # cached surface wind Z per column
var _seed_cursor: int = 0


func setup(field) -> void:
	_f = field
	_area = _f._dim_x * _f._dim_z
	_scent = PackedFloat32Array()
	_scent.resize(CHANNELS * _area)
	_scent_next = PackedFloat32Array()
	_scent_next.resize(CHANNELS * _area)
	_fert = PackedFloat32Array()
	_fert.resize(_area)
	_fert_next = PackedFloat32Array()
	_fert_next.resize(_area)
	_surf_vx = PackedFloat32Array()
	_surf_vx.resize(_area)
	_surf_vz = PackedFloat32Array()
	_surf_vz.resize(_area)


## One scent+fertility step: creatures/carcasses emit (derived from their state), then each channel
## diffuses + advects on the surface wind + decays (faster in rain), and the soil nutrient blurs/leaches
## and seeds plants where it is richest. Gather form (each column reads neighbours, writes itself), so it
## is order-independent and a future GPU port is bit-for-bit.
func step() -> void:
	if _f == null or _area <= 0:
		return
	if _scent.size() != CHANNELS * _area:
		setup(_f)
	_emit_from_actors()
	var rain: float = _f.precipitation() if _f.has_method("precipitation") else 0.0
	var wash: float = rain * RAIN_WASH
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	# Precompute the surface wind per column ONCE (one _surface_iy scan each) so the per-channel gather
	# below is pure array reads — a big win over re-scanning the column for every neighbour of every channel.
	for iz in range(dz):
		for ix in range(dx):
			var col0: int = iz * dx + ix
			var siy: int = _f._surface_iy(ix, iz)
			if siy >= 0:
				var si: int = (siy * dz + iz) * dx + ix
				_surf_vx[col0] = _f._vel_x[si]
				_surf_vz[col0] = _f._vel_z[si]
			else:
				_surf_vx[col0] = 0.0
				_surf_vz[col0] = 0.0
	for iz in range(dz):
		for ix in range(dx):
			var col: int = iz * dx + ix
			var wvx: float = _surf_vx[col]
			var wvz: float = _surf_vz[col]
			# Wind-biased outflow shares to each of the 4 lateral neighbours (away from this column).
			var out_e: float = _share(maxf(0.0, wvx))       # to +X
			var out_w: float = _share(maxf(0.0, -wvx))      # to -X
			var out_s: float = _share(maxf(0.0, wvz))       # to +Z
			var out_n: float = _share(maxf(0.0, -wvz))      # to -Z
			# Inflow shares from each neighbour (its wind blowing TOWARD this column) — pairwise-conserving.
			var has_e: bool = ix < dx - 1
			var has_w: bool = ix > 0
			var has_s: bool = iz < dz - 1
			var has_n: bool = iz > 0
			var in_e: float = _in_share(-_surf_vx[col + 1]) if has_e else 0.0
			var in_w: float = _in_share(_surf_vx[col - 1]) if has_w else 0.0
			var in_s: float = _in_share(-_surf_vz[col + dx]) if has_s else 0.0
			var in_n: float = _in_share(_surf_vz[col - dx]) if has_n else 0.0
			var out_share: float = 0.0
			if has_e: out_share += out_e
			if has_w: out_share += out_w
			if has_s: out_share += out_s
			if has_n: out_share += out_n
			var keep: float = 1.0 - out_share
			for ch in range(CHANNELS):
				var base: int = ch * _area
				var acc: float = _scent[base + col] * keep
				if has_e: acc += _scent[base + col + 1] * in_e
				if has_w: acc += _scent[base + col - 1] * in_w
				if has_s: acc += _scent[base + col + dx] * in_s
				if has_n: acc += _scent[base + col - dx] * in_n
				var d: float = DECAY[ch] + wash
				_scent_next[base + col] = maxf(0.0, acc * (1.0 - d))
	var tmp: PackedFloat32Array = _scent
	_scent = _scent_next
	_scent_next = tmp
	_step_fertility(rain)
	_seed_from_fertility()


# Outflow share toward a neighbour the wind blows toward at speed `away` (>=0).
func _share(away: float) -> float:
	return DIFFUSE + ADVECT * clampf(away / WIND_REF, 0.0, 1.0)


# Inflow share from a neighbour whose wind blows toward this column at speed `toward`.
func _in_share(toward: float) -> float:
	return DIFFUSE + ADVECT * clampf(maxf(0.0, toward) / WIND_REF, 0.0, 1.0)


# --- Soil fertility: blur + leach + budgeted plant seeding ------------------

func _step_fertility(rain: float) -> void:
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var leach: float = FERT_DECAY + rain * FERT_RAIN_LEACH
	for iz in range(dz):
		for ix in range(dx):
			var col: int = iz * dx + ix
			var here: float = _fert[col]
			var acc: float = here * (1.0 - 4.0 * FERT_BLUR)
			if ix < dx - 1:
				acc += FERT_BLUR * _fert[col + 1]
			if ix > 0:
				acc += FERT_BLUR * _fert[col - 1]
			if iz < dz - 1:
				acc += FERT_BLUR * _fert[col + dx]
			if iz > 0:
				acc += FERT_BLUR * _fert[col - dx]
			_fert_next[col] = maxf(0.0, acc * (1.0 - leach))
	var tmp: PackedFloat32Array = _fert
	_fert = _fert_next
	_fert_next = tmp


## Where soil nutrient is richest, ask the ecology to grow a plant (respecting its pop cap) and spend the
## nutrient — the emergent replacement for LAPoop's `wants_seed` signal (dung fertilizes → grass sprouts).
## Budgeted + cursor-rotated so a step never scans the whole plane; growth is slow.
func _seed_from_fertility() -> void:
	var eco = _f._ecology if _f != null else null
	if eco == null or not eco.has_method("seed_plant_at"):
		return
	var dx: int = _f._dim_x
	var seeded: int = 0
	var scanned: int = 0
	while scanned < _area and seeded < SEED_PER_STEP:
		var col: int = _seed_cursor
		_seed_cursor += 1
		if _seed_cursor >= _area:
			_seed_cursor = 0
		scanned += 1
		if _fert[col] < SEED_THRESH:
			continue
		var ix: int = col % dx
		var iz: int = col / dx
		var wx: float = _f._origin.x + float(ix) * _f._cell_size
		var wz: float = _f._origin.z + float(iz) * _f._cell_size
		var wy: float = wx  # placeholder replaced below
		wy = _f._terrain.surface_height(wx, wz) if _f._terrain != null and _f._terrain.has_method("surface_height") else _f.sea_level
		if is_nan(wy):
			continue
		_fert[col] = maxf(0.0, _fert[col] - SEED_SPEND)
		eco.seed_plant_at(Vector3(wx, wy, wz))
		seeded += 1


# --- Emission: creatures + carcasses write scent DERIVED from their state ---

## Passive per-step scan of the "creature" + "carrion" groups (like MaterialCombustion3D._scan_actors):
## reads only public props (no LACreature dependency) and lays each creature's musk/blood/alarm at its
## column, and each carcass's FOOD cue. Creatures stay thin — the trail is emergent from being observed.
func _emit_from_actors() -> void:
	if _f == null or not _f.is_inside_tree():
		return
	var tree: SceneTree = _f.get_tree()
	if tree == null:
		return
	for c in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(c) or not (c is Node3D):
			continue
		var col: int = _col_of((c as Node3D).global_position)
		if col < 0:
			continue
		var size: float = float(c.get("size")) if c.get("size") != null else 0.5
		var hunter: bool = c.has_method("is_hunter") and bool(c.call("is_hunter"))
		# Category musk, size-scaled; a starving hunter is pungent (drives the hunt).
		if hunter:
			var energy: float = float(c.get("energy")) if c.get("energy") != null else 1.0
			var maxe: float = maxf(1.0, float(c.get("max_energy")) if c.get("max_energy") != null else 1.0)
			var hunger: float = clampf(1.0 - energy / maxe, 0.0, 1.0)
			_add(PREDATOR, col, MUSK_RATE * size * (1.0 + HUNGER_MUSK * hunger))
		else:
			_add(PREY, col, MUSK_RATE * size)
		# Wounds bleed; panic leaves alarm.
		var health: float = float(c.get("health")) if c.get("health") != null else 1.0
		var maxh: float = maxf(1.0, float(c.get("max_health")) if c.get("max_health") != null else 1.0)
		var wound: float = clampf(1.0 - health / maxh, 0.0, 1.0)
		if wound > 0.02:
			_add(BLOOD, col, BLOOD_RATE * wound)
		var st: String = String(c.get("state"))
		if st == "flee" or st == "panic":
			_add(ALARM, col, ALARM_RATE)
	for body in tree.get_nodes_in_group("carrion"):
		if not is_instance_valid(body) or not (body is Node3D):
			continue
		var bcol: int = _col_of((body as Node3D).global_position)
		if bcol < 0:
			continue
		var meat: float = float(body.get("_carrion")) if body.get("_carrion") != null else 0.0
		if meat > 0.0:
			_add(FOOD, bcol, CARRION_FOOD * meat)


# --- Event deposits (creatures call these at the moment they happen) ---------

## A dropping: diet-flavored soil enrichment + a FOOD dab + the depositor's own musk (dung carries the
## animal's scent, so predators emergently track prey by their droppings). `kind` = "feces" | "urine".
func deposit_waste(world_pos: Vector3, creature, kind: String) -> void:
	var col: int = _col_of(world_pos)
	if col < 0:
		return
	var hunter: bool = creature != null and creature.has_method("is_hunter") and bool(creature.call("is_hunter"))
	var musk_ch: int = PREDATOR if hunter else PREY
	if kind == "urine":
		_fert[col] += URINE_FERT
		_add(musk_ch, col, URINE_MUSK)
	else:
		_fert[col] += FECES_FERT
		_add(FOOD, col, FECES_FOOD)
		_add(musk_ch, col, FECES_MUSK)


## A fresh wound/kill burst of blood scent (take_damage / die).
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	var col: int = _col_of(world_pos)
	if col >= 0 and amount > 0.0:
		_add(BLOOD, col, amount)


## A carcass advertising food (the decaying-corpse cue LACreatureRagdoll lays).
func deposit_food(world_pos: Vector3, amount: float) -> void:
	var col: int = _col_of(world_pos)
	if col >= 0 and amount > 0.0:
		_add(FOOD, col, amount)


## Enrich the soil directly (no diet/musk flavour): the DEATH→SOIL leg — LAMaterialFungus3D calls this as
## it decomposes detritus, so rot feeds the same fertility channel dung does and plants regrow on it.
func deposit_fertility(world_pos: Vector3, amount: float) -> void:
	var col: int = _col_of(world_pos)
	if col >= 0 and amount > 0.0:
		_fert[col] += amount


func _add(channel: int, col: int, amount: float) -> void:
	_scent[channel * _area + col] += amount


# --- Read API (replaces LAScentField.scent_direction/scent_strength) --------

## Scent density of `channel` at a world point (0 off-grid).
func scent_at(world_pos: Vector3, channel: int) -> float:
	var col: int = _col_of(world_pos)
	return 0.0 if col < 0 else _scent[channel * _area + col]


## Normalized XZ direction UP the `channel` gradient (toward stronger scent) — the O(4) central-difference
## replacement for the old marker-centroid `scent_direction`. ZERO if flat / off-grid.
func scent_gradient(world_pos: Vector3, channel: int) -> Vector3:
	var ix: int = _f._col_i(world_pos.x, _f._origin.x)
	var iz: int = _f._col_i(world_pos.z, _f._origin.z)
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var base: int = channel * _area
	var col: int = iz * dx + ix
	var gx: float = 0.0
	var gz: float = 0.0
	if ix < dx - 1:
		gx += _scent[base + col + 1]
	if ix > 0:
		gx -= _scent[base + col - 1]
	if iz < dz - 1:
		gz += _scent[base + col + dx]
	if iz > 0:
		gz -= _scent[base + col - dx]
	var g: Vector3 = Vector3(gx, 0.0, gz)
	return g.normalized() if g.length() > 0.0001 else Vector3.ZERO


## Soil nutrient at a world point (plants read this to grow faster on rich ground).
func fertility_at(world_pos: Vector3) -> float:
	var col: int = _col_of(world_pos)
	return 0.0 if col < 0 else _fert[col]


# --- Diagnostics (SMOKE_SUMMARY) --------------------------------------------

## Columns carrying any meaningful airborne scent (proof the field is live).
func scent_cell_count() -> int:
	var n: int = 0
	for col in range(_area):
		for ch in range(CHANNELS):
			if _scent[ch * _area + col] > SCENT_MIN:
				n += 1
				break
	return n


func fertility_peak() -> float:
	var m: float = 0.0
	for col in range(_area):
		if _fert[col] > m:
			m = _fert[col]
	return m


# Column index (iz*dim_x + ix) for a world position, or -1 if off-grid.
func _col_of(world_pos: Vector3) -> int:
	if _area <= 0:
		return -1
	var ix: int = _f._col_i(world_pos.x, _f._origin.x)
	var iz: int = _f._col_i(world_pos.z, _f._origin.z)
	return iz * _f._dim_x + ix
