class_name LAVolcano
extends Node3D

## An ACTIVE volcano — a persistent vent that erupts on a cycle. It only INJECTS lava + heat into the
## MaterialField at its vent; everything else emerges: the lava piles and SOLIDIFIES into a growing
## cone (it builds its own mountain), overflows and creeps downhill glowing, sets forests alight from
## its heat, boils water it reaches, and scares wildlife. Eruption ⇄ dormancy alternate. Built in
## code, no assets. (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const VENT_RADIUS: float = 3.5
const LAVA_RATE: float = 0.6              # lava depth/sec emitted while erupting
const VENT_HEAT_PER_SEC: float = 1500.0   # keeps the vent molten (ΔT/s injected)
const ERUPT_MIN: float = 8.0
const ERUPT_MAX: float = 16.0
const DORMANT_MIN: float = 10.0
const DORMANT_MAX: float = 22.0
const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 60.0

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

var _erupting: bool = true
var _phase_timer: float = 0.0
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


## Place the vent at `point` and start erupting. The cone grows itself from solidifying lava.
func erupt_at(point: Vector3) -> void:
	_vent = point
	global_position = point
	_erupting = true
	_phase_timer = randf_range(ERUPT_MIN, ERUPT_MAX)
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _vent)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	lines.append("Status: %s" % ("ERUPTING" if _erupting else "dormant"))
	lines.append("Next phase in: %.0fs" % maxf(0.0, _phase_timer))
	lines.append("Vent: (%.0f, %.0f, %.0f)" % [_vent.x, _vent.y, _vent.z])
	return {"title": "Volcano", "lines": lines}


func _physics_process(delta: float) -> void:
	_phase_timer -= delta
	if _phase_timer <= 0.0:
		_erupting = not _erupting
		_phase_timer = randf_range(ERUPT_MIN, ERUPT_MAX) if _erupting else randf_range(DORMANT_MIN, DORMANT_MAX)
		if _erupting:
			LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _vent)

	if _erupting and _field != null:
		# Inject molten rock + heat at the vent. Lava's own physics does the rest (pile → cone,
		# flow downhill, glow, ignite, boil, solidify).
		if _field.has_method("add_material"):
			_field.add_material(_vent, Mat.LAVA, LAVA_RATE * delta, VENT_RADIUS)
		if _field.has_method("add_heat"):
			_field.add_heat(_vent, VENT_HEAT_PER_SEC * delta, VENT_RADIUS)
		# The ground shakes with the eruption — steep flanks slump (emergent).
		if _ecology != null and _ecology.has_method("disturb_ground") and randf() < delta * 0.5:
			_ecology.disturb_ground(_vent, VENT_RADIUS * 4.0, 1.0)
		_scare_cd -= delta
		if _scare_cd <= 0.0:
			_scare_cd = SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(_vent, SCARE_RADIUS, 0.8)
		# Occasional explosive burst that launches lava bombs.
		_bomb_cd -= delta
		if _bomb_cd <= 0.0:
			_bomb_cd = randf_range(BOMB_BURST_MIN, BOMB_BURST_MAX)
			_launch_bombs()

	_update_fx()


# Fling a burst of glowing lava bombs (RigidBody projectiles) up and out from the vent.
func _launch_bombs() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _vent)
	if _glow != null:
		_glow.light_energy = 30.0                        # flash on the burst
	for i in range(BOMBS_PER_BURST):
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
		var out: float = randf_range(BOMB_OUT_MIN, BOMB_OUT_MAX)
		bomb.linear_velocity = Vector3(cos(ang) * out, randf_range(BOMB_UP_MIN, BOMB_UP_MAX), sin(ang) * out)
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
