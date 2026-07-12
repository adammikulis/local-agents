class_name LAVolcano
extends Node3D

## A volcano is NOT a scripted eruption — it is a VENT (a seed/marker) that does ONE authored thing: drive a
## SUSTAINED lava supply at a fixed spot on the terrain. EVERYTHING downstream EMERGES from the shared substrate
## with zero volcano code:
##   • erupt_source() extrudes deep-mantle lava into the OPEN seawater cell at the growing surface front;
##   • it spreads into a mound as more piles up (lava_flow);
##   • underwater it QUENCHES on contact with seawater (the marine-lava heat sink) and, cooled below the solidus,
##     the M5 reaction record freezes it to rock_fill;
##   • rock_fill crossing 0.5 STAMPS the SDF terrain upward (MineralStamp3D) — the cone accretes;
##   • repeated supply piles the cone until it BREACHES the sea surface = a NEW ISLAND (the capstone), all from
##     eruption + water-quench solidification + rock accumulation + SDF growth composing. Nothing here says "island".
##
## THE SPIN/FRAME RELIC (how the cone piles at ONE spot): the MaterialField grid is WORLD-FIXED while the planet
## body SPINS, so over a long accretion the field's rock_fill and the terrain SDF drift apart and the growing cone
## SMEARS into an arc. VoxelWorld FREEZES the planet spin for the --auto-seavolcano demo (a contract-sanctioned
## option, costing only the day/night sweep) so the field and terrain stay aligned and the island builds at exactly
## ONE spot. Each supply tick deposits at the CURRENT surface top along the vent radial (tracking the growing cone),
## so lava always emerges into the open water at the front where the cell above is sea — the pile climbs, never plugs.
##
## Deleted vs the old scripted volcano: `_is_erupting`, `_bomb_cd`, `BOMBS_PER_BURST`/`BOMB_*`, `_launch_bombs`,
## the bomb GPUParticles/RigidBody emitter, `_bomb_impact`, the burst timer and pressure state machine. A thrown
## rock ("bomb"), a geyser, an island — all just words for what the one substrate does. (Explicit types only.)

const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 55.0

# Sustained supply: molten mantle mineral erupted at the vent each SECOND while active. Generous — the supply must
# out-pace the underwater quench + lateral flow so the cone keeps accreting upward and breaches within a demo run.
const SUPPLY_PER_SEC: float = 16.0
const SUPPLY_INTERVAL: float = 0.05        # deposit cadence (s); many small deposits pile in one cell past MAX_MASS
# A vent is a DISC, not a 1-cell needle: scatter each deposit across a small angular disc around the vent radial so
# the erupted rock piles into a BROAD island cone instead of a single-column spire racing to the grid ceiling. And
# once a column has built a bit ABOVE sea level, stop feeding it (supply flows to the still-submerged columns) so the
# island tops out as a low landmass rather than a runaway tower.
const VENT_DISC: float = 0.10              # angular radius of the vent disc (rad); ~ a handful of columns wide
const ISLAND_FREEBOARD: float = 14.0       # stop feeding a column once its surface sits this far above sea level

# Seismic tremor emitted while supplying (camera shake / felt seismic EMERGES from the shared field, not here).
const ERUPT_SEISMIC: float = 3.0

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null
var _inject: Object = null                  # the field's injection module (owns erupt_source; keeps the field small)
var _center: Vector3 = Vector3.ZERO         # planet centre (radial reference)
var _submerged_seed: bool = false           # true when seeded on the seabed (drives the "island" telemetry)

var _supply_cd: float = 0.0
var _scare_cd: float = 0.0
var _tremor_cd: float = 0.0
var _active: bool = true
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()   # seeded → a REPRODUCIBLE island (deterministic demo)

var _glow: OmniLight3D = null
var _picker: StaticBody3D = null

# Telemetry (read by --auto-seavolcano proof + the inspector): the vent's fixed radial + running deposit ledger.
var vent_dir_world: Vector3 = Vector3.UP    # snapshot of the vent radial at seed (world space, pre-spin)
var seed_surface_radius: float = 0.0        # surface radius at the vent when seeded (the "before" sea floor)
var total_supplied: float = 0.0             # Σ lava mass actually injected (conservation cross-check)


func _ready() -> void:
	add_to_group("selectable")
	_rng.seed = LASimRng.shared().randi()   # seeded from the sim stream so the island reproduces from LA_SIM_SEED


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()
	if _field != null:
		_inject = _field.get("_inject")     # reach the injection module (erupt_source lives there, not in the field)
	if _terrain != null and _terrain.has_method("planet_center"):
		_center = _terrain.planet_center()


## Seed the vent at a world `point` on the terrain surface (land or seabed). Stores the vent's radial and the
## initial surface radius; a seabed seed (below the sea shell) is what builds an island. The node is parented under
## the spinning body, so its global_position rides the terrain — supply tracks this one spot.
func erupt_at(point: Vector3) -> void:
	global_position = point
	vent_dir_world = (point - _center).normalized()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var sr: float = _terrain.surface_radius(vent_dir_world)
		if not is_nan(sr):
			seed_surface_radius = sr
	if _terrain != null and _terrain.has_method("sea_radius"):
		_submerged_seed = seed_surface_radius > 0.0 and seed_surface_radius < _terrain.sea_radius()
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", point)


## Legacy demo hook: a quick pulse of lava at the vent right now (kept so --auto-volcano still shows molten output
## immediately). The sustained supply below does the real work.
func force_erupt() -> void:
	_deposit(2.0)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	lines.append("Kind: %s vent" % ("SEABED" if _submerged_seed else "subaerial"))
	lines.append("Vent radius: %.1f (sea %.1f)" % [_current_surface_radius(), _sea_radius()])
	lines.append("Lava supplied: %.0f" % total_supplied)
	if _submerged_seed:
		var breached: bool = _current_surface_radius() > _sea_radius()
		lines.append("Island: %s" % ("BREACHED SURFACE" if breached else "building underwater"))
	return {"title": "Volcano", "lines": lines}


func _sea_radius() -> float:
	if _terrain != null and _terrain.has_method("sea_radius"):
		return _terrain.sea_radius()
	return 0.0


# Current surface radius along the vent's SPINNING radial (tracks the terrain as it rotates + the cone as it grows).
func _current_surface_radius() -> float:
	var d: Vector3 = _vent_dir_now()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var sr: float = _terrain.surface_radius(d)
		if not is_nan(sr):
			return sr
	return seed_surface_radius


# The vent's radial RIGHT NOW: the node rides the body's spin, so its live position gives the current world radial.
func _vent_dir_now() -> Vector3:
	var d: Vector3 = global_position - _center
	if d.length() > 0.001:
		return d.normalized()
	return vent_dir_world


# Erupt `amount` of molten mantle mineral at the vent's current top. erupt_source injects it into the first OPEN cell
# above the surface (the seawater cell at the growing front), where it quenches + solidifies + stamps the terrain up.
# Depositing at the CURRENT surface radius (not the fixed seed) keeps the supply at the growing front so, as the cone
# climbs, the lava always emerges into open water instead of burying itself in the pile.
func _deposit(amount: float) -> void:
	if _inject == null or not _inject.has_method("erupt_source"):
		return
	# Scatter the deposit across the vent disc: a random direction within VENT_DISC of the vent radial (uniform on the
	# tangent disc) so the pile broadens into an island cone. Build a tangent frame around the vent radial.
	var d: Vector3 = _vent_dir_now()
	var t1: Vector3 = d.cross(Vector3.UP)
	if t1.length() < 0.01:
		t1 = d.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2: Vector3 = d.cross(t1).normalized()
	var ang: float = _rng.randf() * TAU
	# CENTRE-WEIGHTED radius (no sqrt → density peaks at the vent): the centre column leads and reliably breaches,
	# then the freeboard cap redirects supply outward so the pile fills into a cohesive flat-topped island around it.
	var rad: float = _rng.randf() * _rng.randf() * VENT_DISC
	var dir: Vector3 = (d + (t1 * cos(ang) + t2 * sin(ang)) * rad).normalized()
	# This column's current surface; skip if it already stands above the freeboard cap (let submerged columns catch up).
	var sr: float = _current_surface_radius()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var s: float = _terrain.surface_radius(dir)
		if not is_nan(s):
			sr = s
	if sr > _sea_radius() + ISLAND_FREEBOARD:
		return
	var top: Vector3 = _center + dir * sr
	total_supplied += _inject.erupt_source(top, amount)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	# SUSTAINED SUPPLY — the one authored action. Many small deposits per second pile lava in the vent column past
	# MAX_MASS so magma buoyancy lifts it; the rest (quench, solidify, stamp, island) is pure emergent substrate.
	_supply_cd -= delta
	while _supply_cd <= 0.0:
		_supply_cd += SUPPLY_INTERVAL
		_deposit(SUPPLY_PER_SEC * SUPPLY_INTERVAL)

	# Emergent felt seismic (camera shake reads the field), throttled so a continuous tremor reads as overlapping pulses.
	_tremor_cd -= delta
	if _tremor_cd <= 0.0:
		_tremor_cd = 0.15
		if _ecology != null and _ecology.has_method("broadcast_seismic"):
			_ecology.broadcast_seismic(global_position, ERUPT_SEISMIC)

	# Scare wildlife on a cadence — the SAME broadcast stimulus every disaster reuses (emergent flee, no per-case code).
	_scare_cd -= delta
	if _scare_cd <= 0.0:
		_scare_cd = SCARE_INTERVAL
		if _ecology != null and _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(global_position, SCARE_RADIUS, 0.7)

	if _glow != null:
		_glow.light_energy = lerpf(_glow.light_energy, 22.0, 0.1)


func _build_fx() -> void:
	if _glow == null:
		_glow = OmniLight3D.new()
		_glow.light_color = Color(1.0, 0.5, 0.15)
		_glow.omni_range = 26.0
		_glow.position = Vector3(0.0, 2.0, 0.0)
		add_child(_glow)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = 5.0
		col.shape = cs
		_picker.add_child(col)
		add_child(_picker)
