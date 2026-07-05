class_name LAVolcano
extends Node3D

## An ACTIVE volcano — a vent over a magma chamber whose ERUPTIONS EMERGE FROM PRESSURE, not a timer.
## The chamber accumulates pressure from magma recharge, amplified by how HOT it runs (hot gas expands
## → more pressure); when pressure exceeds the vent's strength the vent cracks and ERUPTS. Lava outflow
## and explosive bomb force both scale with the over-pressure, which venting bleeds off until the vent
## reseals and pressure rebuilds — so eruption timing AND intensity fall out of the pressure/temperature
## cycle. It only INJECTS lava + heat into the MaterialField at its vent; everything else emerges: lava
## flows downhill glowing, solidifies into new rock, ignites forests, boils water, scares wildlife.
## On placement it carves a summit crater + conduit so lava pools in a real vent, not flat on the
## ground. Built in code, no assets. (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const VENT_RADIUS: float = 3.5
const VENT_HEAT_PER_SEC: float = 1500.0   # keeps the vent molten (ΔT/s injected) while venting
const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 60.0

# --- Magma-chamber pressure (drives emergent eruptions) ----------------------
const CHAMBER_TEMP: float = 1200.0        # reference magma temp; the live vent temp vs this sets recharge
const RECHARGE_RATE: float = 0.05         # base pressure/sec the sealed chamber builds from magma influx
const ERUPT_PRESSURE: float = 1.0         # over-pressure that cracks the vent and begins an eruption
const SEAL_PRESSURE: float = 0.2          # eruption ends (vent reseals) once pressure bleeds below this
const VENT_RELEASE: float = 0.9           # how fast venting bleeds off over-pressure
const OUTFLOW_PER_PRESSURE: float = 1.3   # lava depth/sec per unit over-pressure at the vent
const BOMB_PRESSURE: float = 0.45         # only strongly over-pressured eruptions throw bombs
var _pressure: float = 0.4                # current chamber over-pressure (starts part-charged)

# --- Conduit / crater the vent is carved into --------------------------------
const CONE_RADIUS: float = 15.0           # broad base raised so the vent sits on a mountain
const CRATER_RADIUS: float = 5.0          # summit bowl lava pools in
const CONDUIT_RADIUS: float = 2.4         # vertical lava-tube shaft bored down from the crater
const CONDUIT_DEPTH: float = 24.0
const CONDUIT_STEPS: int = 6

# Explosive bursts: while erupting, the vent periodically LAUNCHES ballistic lava bombs (glowing hot
# rock) that arc out and, on their fuse, dump heat + a little lava where they land — starting spot
# fires and small flows away from the cone. Emergent: they're just hot projectiles.
const BOMB_BURST_MIN: float = 2.5         # seconds between bursts while erupting
const BOMB_BURST_MAX: float = 6.0
const BOMBS_PER_BURST: int = 6
const BOMB_UP_MIN: float = 14.0
const BOMB_UP_MAX: float = 26.0
const BOMB_OUT_MIN: float = 6.0
const BOMB_OUT_MAX: float = 22.0
const BOMB_FUSE: float = 3.2              # seconds aloft before it impacts
var _bomb_cd: float = 0.0

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null
var _vent: Vector3 = Vector3.ZERO

var _erupting: bool = false
var _scare_cd: float = 0.0

var _glow: OmniLight3D = null
var _smoke: GPUParticles3D = null
var _picker: StaticBody3D = null


func _ready() -> void:
	add_to_group("selectable")


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


## Place the vent at `point`: raise a cone, carve a summit crater + conduit tube, seed a lava pool in
## it, and start the pressure cycle charging (the first eruption emerges when it reaches ERUPT_PRESSURE).
func erupt_at(point: Vector3) -> void:
	_vent = point
	global_position = point
	_carve_conduit()
	_pressure = 0.6                                     # placed volcanoes are already pressurizing
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", _vent)


# Reshape the ground into a real vent: raise a broad cone (so a volcano placed on flat ground still
# becomes a mountain), carve a bowl crater at the summit and bore a vertical conduit tube down into it,
# then re-read the terrain so lava pools in the crater instead of sitting flat, and seed a starter pool.
func _carve_conduit() -> void:
	if _terrain == null or not _terrain.has_method("fill_sphere") or not _terrain.has_method("carve_sphere"):
		return
	# Cone: a few stacked domes of decreasing radius build a peaked mountain around the vent.
	_terrain.fill_sphere(_vent + Vector3(0.0, -3.0, 0.0), CONE_RADIUS)
	_terrain.fill_sphere(_vent + Vector3(0.0, 1.0, 0.0), CONE_RADIUS * 0.7)
	_terrain.fill_sphere(_vent + Vector3(0.0, 4.0, 0.0), CONE_RADIUS * 0.45)
	# Crater bowl at the summit + a vertical lava-tube conduit bored straight down through the cone.
	_terrain.carve_sphere(_vent + Vector3(0.0, 5.0, 0.0), CRATER_RADIUS)
	for k in range(CONDUIT_STEPS):
		var t: float = float(k) / float(maxi(1, CONDUIT_STEPS - 1))
		var y: float = _vent.y + 4.0 - t * CONDUIT_DEPTH
		_terrain.carve_sphere(Vector3(_vent.x, y, _vent.z), CONDUIT_RADIUS)
	# Sync the field's cached ground heights to the reshaped terrain so lava sits in the new crater.
	if _field != null and _field.has_method("resample_terrain"):
		_field.resample_terrain(_vent, CONE_RADIUS + 3.0)
	# Snap the vent to the crater floor (new surface) so lava/heat inject at the right spot.
	var gy = _terrain.surface_height(_vent.x, _vent.z)
	if (typeof(gy) == TYPE_FLOAT or typeof(gy) == TYPE_INT) and not (is_nan(float(gy)) or is_inf(float(gy))):
		_vent.y = float(gy)
		global_position = _vent
	# Seed a glowing lava pool in the fresh crater so the vent reads as molten immediately.
	if _field != null and _field.has_method("add_material"):
		_field.add_material(_vent, Mat.LAVA, 0.9, CRATER_RADIUS * 0.8)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	lines.append("Status: %s" % ("ERUPTING" if _erupting else "pressurizing"))
	lines.append("Chamber pressure: %.0f%%" % (_pressure / ERUPT_PRESSURE * 100.0))
	lines.append("Vent temp: %.0f°C" % _vent_temp())
	lines.append("Vent: (%.0f, %.0f, %.0f)" % [_vent.x, _vent.y, _vent.z])
	return {"title": "Volcano", "lines": lines}


# The live temperature at the vent (magma proxy). Read from the field; falls back to reference temp.
func _vent_temp() -> float:
	if _field != null and _field.has_method("temp_at"):
		return _field.temp_at(_vent.x, _vent.z)
	return CHAMBER_TEMP


func _physics_process(delta: float) -> void:
	# Pressure/temperature dynamics drive everything. The hotter the vent runs, the faster gas pressure
	# builds; when it crosses ERUPT_PRESSURE the vent cracks; venting then bleeds pressure until it seals.
	var heat_factor: float = clampf(_vent_temp() / CHAMBER_TEMP, 0.4, 1.3)

	if not _erupting:
		# Sealed: recharge. Cross the vent's strength → an eruption begins (emergent onset).
		_pressure += RECHARGE_RATE * heat_factor * delta
		if _pressure >= ERUPT_PRESSURE:
			_erupting = true
			LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _vent)
			if _glow != null:
				_glow.light_energy = 34.0                # onset flash
	elif _field != null:
		# Erupting: outflow + bomb force scale with OVER-pressure; venting bleeds it toward the seal.
		var over: float = maxf(0.0, _pressure - SEAL_PRESSURE)
		var outflow: float = OUTFLOW_PER_PRESSURE * over
		if _field.has_method("add_material"):
			_field.add_material(_vent, Mat.LAVA, outflow * delta, VENT_RADIUS)
		if _field.has_method("add_heat"):
			_field.add_heat(_vent, VENT_HEAT_PER_SEC * delta, VENT_RADIUS)
		# Bleed pressure as it vents (plus a little continued recharge fighting it), then reseal when spent.
		_pressure += (RECHARGE_RATE * heat_factor * 0.4 - VENT_RELEASE * over) * delta
		if _ecology != null and _ecology.has_method("disturb_ground") and randf() < delta * 0.5:
			_ecology.disturb_ground(_vent, VENT_RADIUS * 4.0, 1.0)
		_scare_cd -= delta
		if _scare_cd <= 0.0:
			_scare_cd = SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(_vent, SCARE_RADIUS, minf(1.0, 0.4 + over))
		# Explosive bomb volleys only when strongly over-pressured — the volley size scales with pressure.
		if over > BOMB_PRESSURE:
			_bomb_cd -= delta
			if _bomb_cd <= 0.0:
				_bomb_cd = randf_range(BOMB_BURST_MIN, BOMB_BURST_MAX)
				_launch_bombs(over)
		if _pressure <= SEAL_PRESSURE:
			_erupting = false

	_update_fx()


# Fling a burst of glowing lava bombs (RigidBody projectiles) up and out from the vent. The volley
# size and launch speed scale with the eruption's over-pressure (`force`, ~0..1+) — a bigger build-up
# throws more bombs, higher and farther.
func _launch_bombs(force: float = 0.6) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _vent)
	if _glow != null:
		_glow.light_energy = 30.0 + 20.0 * force         # flash scales with the burst
	var count: int = int(round(BOMBS_PER_BURST * clampf(0.5 + force, 0.5, 2.2)))
	var speed_gain: float = clampf(0.7 + force, 0.7, 2.0)
	for i in range(count):
		var bomb: RigidBody3D = RigidBody3D.new()
		bomb.collision_layer = 4
		bomb.collision_mask = 1
		bomb.gravity_scale = 1.0
		bomb.add_to_group("debris")
		var mi: MeshInstance3D = MeshInstance3D.new()
		var sphere: SphereMesh = SphereMesh.new()
		var sz: float = randf_range(0.3, 0.7)
		sphere.radius = sz
		sphere.height = sz * 2.0
		mi.mesh = sphere
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.35, 0.1)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.55, 0.15)
		mat.emission_energy_multiplier = 4.0
		mi.material_override = mat
		bomb.add_child(mi)
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = sz
		col.shape = cs
		bomb.add_child(col)
		parent.add_child(bomb)
		bomb.global_position = _vent + Vector3(randf_range(-1.5, 1.5), 4.0, randf_range(-1.5, 1.5))
		var ang: float = randf() * TAU
		var out: float = randf_range(BOMB_OUT_MIN, BOMB_OUT_MAX) * speed_gain
		bomb.linear_velocity = Vector3(cos(ang) * out, randf_range(BOMB_UP_MIN, BOMB_UP_MAX) * speed_gain, sin(ang) * out)
		bomb.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
		var fuse: SceneTreeTimer = get_tree().create_timer(BOMB_FUSE)
		fuse.timeout.connect(_bomb_impact.bind(bomb))


# A landed lava bomb dumps heat + a little molten rock where it fell — a spot fire / small flow.
func _bomb_impact(bomb: Node) -> void:
	if not is_instance_valid(bomb):
		return
	var pos: Vector3 = (bomb as Node3D).global_position
	if _field != null:
		if _field.has_method("add_heat"):
			_field.add_heat(pos, 900.0, 4.0)
		if _field.has_method("add_material"):
			_field.add_material(pos, Mat.LAVA, 0.18, 2.0)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(pos, 12.0, 0.5)
	bomb.queue_free()


func _build_fx() -> void:
	if _glow == null:
		_glow = OmniLight3D.new()
		_glow.light_color = Color(1.0, 0.5, 0.15)
		_glow.omni_range = 26.0
		_glow.position = Vector3(0.0, 2.0, 0.0)
		add_child(_glow)
	if _smoke == null:
		_smoke = GPUParticles3D.new()
		_smoke.amount = 60
		_smoke.lifetime = 4.0
		_smoke.emitting = true
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(4.0, 4.0)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.14, 0.13, 0.13, 0.5)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = mat
		_smoke.draw_pass_1 = quad
		var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 2.0
		pm.direction = Vector3(0.0, 1.0, 0.0)
		pm.spread = 18.0
		pm.initial_velocity_min = 4.0
		pm.initial_velocity_max = 9.0
		pm.gravity = Vector3(0.0, 3.0, 0.0)          # ash column rises
		pm.scale_min = 0.8
		pm.scale_max = 2.6
		pm.color = Color(0.16, 0.15, 0.15, 0.55)
		_smoke.process_material = pm
		_smoke.position = Vector3(0.0, 3.0, 0.0)
		add_child(_smoke)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = VENT_RADIUS * 1.5
		col.shape = cs
		_picker.add_child(col)
		add_child(_picker)


func _update_fx() -> void:
	if _glow != null:
		var target: float = 18.0 if _erupting else 4.0
		_glow.light_energy = lerpf(_glow.light_energy, target, 0.1)
	if _smoke != null:
		_smoke.amount_ratio = 1.0 if _erupting else 0.25
