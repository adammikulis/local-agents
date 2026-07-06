class_name LAVolcano
extends Node3D

## An ACTIVE volcano — a vent over a DEEP MAGMA SOURCE whose eruptions EMERGE FROM THE FIELD, not a
## scripted pressure timer. On placement it registers ONE hot magma source deep below the surface via
## `MaterialField3D.add_magma_source`; the field's emergent MAGMA process does the rest: the source's
## overpressure BORES ITS OWN CONDUIT up to the surface and erupts episodically. Lava, heat and the
## bored conduit all fall out of the field simulation — the volcano only READS the field
## (`magma_erupting()`, `temp_at`) to drive its FX/scare/seismic/audio. Everything downstream emerges:
## lava flows downhill glowing, solidifies into new rock, ignites forests, boils water, scares wildlife;
## the cone accretes over time as eruptions overflow and cool into new rock around the vent.
## Built in code, no assets. (Explicit types only — no ':=' inferred typing.)

const VENT_RADIUS: float = 3.5
const VENT_HEAT_PER_SEC: float = 1500.0   # extra heat injected at the vent while erupting (ignites/scorches)
const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 60.0

# --- Deep magma source (the ONLY field input — the field's magma process bores + erupts on its own) ---
const CHAMBER_TEMP: float = 1300.0        # source temp; MUST exceed the field's MELT_TEMP=1200 to bootstrap the first bore
const RATE: float = 1.5                   # lava mass/sec the deep source injects (drives overpressure → eruption)
const CONDUIT_DEPTH: float = 8.0          # how far below the surface the source is seeded (the field bores up from here)
const CRATER_RADIUS: float = 4.5          # radius used for vent heat/scorch injection

# --- Seismic emissions (camera shake EMERGES from these, felt via the ecology's seismic field) ---
# The volcano never touches the camera. While the field reports an eruption it emits seismic pulses that
# the camera queries via seismic_energy_at() and shakes to — proximity/decay handled there, not here.
const ERUPT_SEISMIC: float = 3.0          # ongoing eruption seismic energy/sec, scaled by vent-temp intensity

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

var _scare_cd: float = 0.0
var _rumble_cd: float = 0.0                 # cadence for the seismic rumble / eruption-roar SFX
var _tremor_cd: float = 0.0                 # throttle for continuous eruption seismic pulses

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


## Place the vent at `point` and seed ONE deep magma source below it. The field's emergent magma process
## takes over from there: the source's overpressure bores its own conduit up to the surface and erupts
## episodically — no scripted breach, no pre-carved chute. The cone accretes from the lava it erupts.
func erupt_at(point: Vector3) -> void:
	_vent = point
	global_position = point
	_build_fx()
	if _field != null and _field.has_method("add_magma_source"):
		var deep_pos: Vector3 = _vent - Vector3(0.0, CONDUIT_DEPTH, 0.0)
		_field.add_magma_source(deep_pos, CHAMBER_TEMP, RATE)
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", _vent)


## Kick a visible lava burst RIGHT NOW (for demos/tests that need molten output on demand). The deep
## source is already boring its conduit; this just floods a little lava at the vent so --auto-volcano
## shows a flow immediately instead of waiting for the field to bore all the way up.
func force_erupt() -> void:
	if _field != null and _field.has_method("add_lava"):
		_field.add_lava(_vent, 3.0)


func get_inspector_payload() -> Dictionary:
	var erupting: bool = _is_erupting()
	var lines: Array = []
	var status: String = "ERUPTING" if erupting else "building"
	lines.append("Status: %s" % status)
	lines.append("Vent temp: %.0f°C" % _vent_temp())
	if _field != null and _field.has_method("magma_cell_count"):
		lines.append("Over-pressured lava cells: %d" % _field.magma_cell_count())
	lines.append("Vent: (%.0f, %.0f, %.0f)" % [_vent.x, _vent.y, _vent.z])
	return {"title": "Volcano", "lines": lines}


# Is the field's magma process currently venting up its conduit? Drives all FX/scare/seismic/audio.
func _is_erupting() -> bool:
	if _field != null and _field.has_method("magma_erupting"):
		return _field.magma_erupting()
	return false


# The live temperature at the vent (magma proxy). Read from the field; falls back to reference temp.
func _vent_temp() -> float:
	if _field != null and _field.has_method("temp_at"):
		return _field.temp_at(_vent.x, _vent.z, _vent.y)
	return CHAMBER_TEMP


# Emit a seismic pulse at the vent (throttled) so a CONTINUOUS tremor reads as several overlapping
# short pulses in the ecology's seismic field rather than one per frame. `magnitude` is the pulse
# energy; the camera queries the field and shakes — proximity/decay are handled there, not here.
func _emit_tremor(magnitude: float, delta: float) -> void:
	_tremor_cd -= delta
	if _tremor_cd > 0.0:
		return
	_tremor_cd = 0.15
	if magnitude > 0.0 and _ecology != null and _ecology.has_method("broadcast_seismic"):
		_ecology.broadcast_seismic(_vent, magnitude)


func _physics_process(delta: float) -> void:
	# Eruptions are OWNED by the field's magma process — the volcano just reads whether it's venting and
	# how hot the vent runs, and drives FX/scare/seismic/audio off that. No pressure state machine here.
	var erupting: bool = _is_erupting()
	var intensity: float = clampf(_vent_temp() / CHAMBER_TEMP, 0.0, 1.3)

	if erupting:
		# Ongoing rumble emerges from felt seismic energy, scaled by how hot/violent the vent is running.
		_emit_tremor(ERUPT_SEISMIC * intensity, delta)
		# Sustained eruption roar in overlapping bursts.
		_rumble_cd -= delta
		if _rumble_cd <= 0.0:
			_rumble_cd = randf_range(1.1, 2.0)
			LocalAgentsAudioDirector.emit(get_tree(), "volcano_roar", _vent)
		# Keep the vent scorching so it ignites forests / boils water around the mouth — driven toward a
		# bounded target so continuous injection at one cell never runs away.
		if _field != null and _field.has_method("add_heat"):
			var vt: float = _vent_temp()
			if vt < 1300.0:
				_field.add_heat(_vent, minf(VENT_HEAT_PER_SEC * delta, (1300.0 - vt) * 0.5), VENT_RADIUS)
		# Scare wildlife on a cadence, intensity scaling with how hot the eruption is.
		_scare_cd -= delta
		if _scare_cd <= 0.0:
			_scare_cd = SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(_vent, SCARE_RADIUS, clampf(0.4 + intensity * 0.6, 0.0, 1.0))
		# Explosive bomb volleys while venting; the volley size scales with the eruption's intensity.
		_bomb_cd -= delta
		if _bomb_cd <= 0.0:
			_bomb_cd = randf_range(BOMB_BURST_MIN, BOMB_BURST_MAX)
			_launch_bombs(intensity)

	_update_fx(erupting, intensity)


# Fling a burst of glowing lava bombs (RigidBody projectiles) up and out from the vent. The volley
# size and launch speed scale with the eruption's intensity (`force`, ~0..1.3) — a hotter eruption
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
		if _field.has_method("add_lava"):
			_field.add_lava(pos, 0.18)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(pos, 12.0, 0.5)
	# A landing bomb thumps the ground — a small seismic pulse (felt as a light shake if the camera is near).
	if _ecology != null and _ecology.has_method("broadcast_seismic"):
		_ecology.broadcast_seismic(pos, 0.5)
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


func _update_fx(erupting: bool, intensity: float) -> void:
	if _glow != null:
		var target: float
		if erupting:
			target = 18.0 + 8.0 * clampf(intensity, 0.0, 1.3)   # bright while venting, brighter when hotter
		else:
			target = 4.0                                        # a dull ember when quiet between eruptions
		_glow.light_energy = lerpf(_glow.light_energy, target, 0.1)
	if _smoke != null:
		_smoke.amount_ratio = 1.0 if erupting else 0.25
