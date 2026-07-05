class_name LAMaterialCombustion
extends RefCounted

## LAMaterialCombustion — the COMBUSTION concern of the material field (fire + boiling LOGIC).
##
## Split out of LAMaterialField: this module owns the fire mechanism (there is NO separate fire
## system) and the boiling rule. A flammable actor (tree/plant = WOOD) whose cell crosses WOOD's
## ignition temperature catches fire; it pumps heat back into the field so fire SPREADS through the
## temperature grid, glows (flame FX), burns down, then is consumed (topples + ash reseeds a plant).
## Rivers/wet cells stay cool → firebreaks emerge for free. Boiling: where WATER sits on a cell above
## 100°C it flashes to steam (puff FX + sizzle sound) and the water is rapidly cooled/evaporated.
##
## It holds NO grid state of its own beyond its own cooldowns/fire list; it reaches back into the
## owning LAMaterialField (`_f`) for the shared grid state (`_temp`, `_mats`, `_sampled`, `_terrain_h`,
## `_cell_count`, `_dim`, `_cell_x`, `_ecology`, `WATER_THRESHOLD`) and its heat/query API (`add_heat`,
## `temp_at`, `is_water_at`) plus the render module (`_f._render.steam_puff`). Behaviour is identical
## to the old inline code. (Explicit types only — no ':=' inferred typing.)

# Material registry (preloaded so cross-file constants resolve without an editor class-scan).
const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

# --- Combustion (folded in — there is NO separate fire system). A flammable actor (tree/plant =
# WOOD) whose cell crosses WOOD's ignition temperature catches fire; it pumps heat back into the
# field so fire SPREADS through the temperature grid, glows (flame FX), burns down, then is consumed
# (topples + ash reseeds a plant). Rivers/wet cells stay cool → firebreaks emerge for free. ---
const FLAMMABLE_GROUPS: Array = ["tree", "plant"]
const BURN_TIME_MIN: float = 6.0
const BURN_TIME_MAX: float = 11.0
const BURN_HEAT_PER_SEC: float = 1000.0   # °C/s a burning actor injects into its cell (flame heat)
const BURN_HEAT_RADIUS: float = 5.0
const IGNITE_SCAN_INTERVAL: float = 0.4
const FIRE_SCARE_INTERVAL: float = 1.3
const FIRE_SCARE_RADIUS: float = 9.0

# Boiling: where WATER sits on a cell above 100°C it flashes to steam (puff FX + sizzle sound), and
# the water is rapidly cooled/evaporated. Emergent wherever hot meets water (crater rim, lava, fire).
const BOIL_TEMP: float = 100.0
const BOIL_CHECK_INTERVAL: float = 0.4
const BOIL_SAMPLES: int = 220              # random cells probed per check (cheap)
const BOIL_MAX_PUFFS: int = 4              # cap steam puffs spawned per check

var _f = null                              # back-reference to the owning LAMaterialField
var _fires: Array = []                     # [{node, life, scare_cd, fx}]
var _ignite_cd: float = 0.0
var _boil_cd: float = 0.0


func setup(field) -> void:
	_f = field


# --- Frame step (owns ignition/spread/burn AND boiling; runs every frame) -----

## Combustion (ignition sweep + burn/spread of active fires) plus the throttled boil check.
func step(delta: float) -> void:
	# IGNITION sweep (throttled): light any flammable actor whose cell crossed WOOD's ignition temp
	# and isn't wet. Runs even with no active fire, so a meteor/lightning heat spike or a drought
	# ignites vegetation with nothing pre-burning — emergent from the temperature field alone.
	_ignite_cd -= delta
	if _ignite_cd <= 0.0:
		_ignite_cd = IGNITE_SCAN_INTERVAL
		_scan_ignitions()

	if not _fires.is_empty():
		var survivors: Array = []
		for f in _fires:
			var node = f["node"]
			if node == null or not is_instance_valid(node):
				continue
			var pos: Vector3 = (node as Node3D).global_position
			# Pump flame heat back into the field so neighbours cross the ignition temp → SPREAD emerges.
			_f.add_heat(pos, BURN_HEAT_PER_SEC * delta, BURN_HEAT_RADIUS)
			f["life"] = float(f["life"]) - delta
			if float(f["life"]) <= 0.0:
				_consume(node as Node3D)
				continue
			f["scare_cd"] = float(f["scare_cd"]) - delta
			if float(f["scare_cd"]) <= 0.0:
				f["scare_cd"] = FIRE_SCARE_INTERVAL
				if _f._ecology != null and _f._ecology.has_method("broadcast_scare"):
					_f._ecology.broadcast_scare(pos, FIRE_SCARE_RADIUS, 0.6)
			survivors.append(f)
		_fires = survivors

	# Boiling: wherever hot ground/lava/fire meets water, it steams — emergent, throttled.
	_boil_cd -= delta
	if _boil_cd <= 0.0:
		_boil_cd = BOIL_CHECK_INTERVAL
		_boil_step()


# --- Public API (delegated from the field) ----------------------------------

func active_fire_count() -> int:
	return _fires.size()


func is_burning(node) -> bool:
	for f in _fires:
		if f["node"] == node:
			return true
	return false


## Set a flammable actor alight (flame FX + track it). No-op for non-flammable / already-burning.
func ignite(node) -> void:
	if node == null or not is_instance_valid(node) or not (node is Node3D):
		return
	if not _is_flammable(node) or is_burning(node):
		return
	var n3: Node3D = node as Node3D
	var fx: Node3D = _make_fire_fx(n3)
	n3.add_child(fx)
	_fires.append({
		"node": n3,
		"life": randf_range(BURN_TIME_MIN, BURN_TIME_MAX),
		"scare_cd": randf_range(0.2, FIRE_SCARE_INTERVAL),
		"fx": fx,
	})


# --- Private helpers ---------------------------------------------------------

func _is_flammable(node) -> bool:
	for group in FLAMMABLE_GROUPS:
		if node.is_in_group(group):
			return true
	return false


func _scan_ignitions() -> void:
	var ignite_temp: float = Mat.ignite_temp(Mat.WOOD)
	for group in FLAMMABLE_GROUPS:
		for a in _f.get_tree().get_nodes_in_group(group):
			if not is_instance_valid(a) or not (a is Node3D) or is_burning(a):
				continue
			var p: Vector3 = (a as Node3D).global_position
			if _f.temp_at(p.x, p.z) < ignite_temp:
				continue
			if _f.is_water_at(p.x, p.z):
				continue
			ignite(a)


# Fully consumed: topple as it collapses, leave ash that seeds a new plant, then remove.
func _consume(node: Node3D) -> void:
	var pos: Vector3 = node.global_position
	if node.has_method("topple"):
		node.call("topple", Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0))
	if _f._ecology != null and _f._ecology.has_method("seed_plant_at"):
		_f._ecology.seed_plant_at(pos)
	node.queue_free()


# Flame parented to the burning actor (frees with it). Shared with creature combustion (LAFlameFX).
func _make_fire_fx(host: Node3D) -> Node3D:
	return LAFlameFX.make()


# --- Boiling: hot water flashes to steam (emergent wherever hot meets water) -

func _boil_step() -> void:
	if not _f._mats.has(Mat.WATER) or not _f.is_inside_tree():
		return
	var water: PackedFloat32Array = _f._mats[Mat.WATER]
	var puffs: int = 0
	for n in range(BOIL_SAMPLES):
		if puffs >= BOIL_MAX_PUFFS:
			break
		var idx: int = randi() % _f._cell_count
		if _f._sampled[idx] == 0 or water[idx] < _f.WATER_THRESHOLD or _f._temp[idx] < BOIL_TEMP:
			continue
		var i: int = idx % _f._dim
		var j: int = idx / _f._dim
		var pos: Vector3 = Vector3(_f._cell_x(i), _f._terrain_h[idx] + water[idx], _f._cell_z(j))
		_f._render.steam_puff(pos)
		# Boiling carries heat away fast and evaporates a little water (latent heat sink).
		_f._temp[idx] = maxf(BOIL_TEMP - 5.0, _f._temp[idx] - 40.0)
		water[idx] = maxf(0.0, water[idx] - 0.05)
		LocalAgentsAudioDirector.emit(_f.get_tree(), "sizzle", pos)
		puffs += 1
