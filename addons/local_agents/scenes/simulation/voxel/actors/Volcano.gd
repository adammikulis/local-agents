class_name LAVolcano
extends Node3D

## An ACTIVE volcano — a vent over a magma chamber whose ERUPTIONS EMERGE FROM PRESSURE, not a timer.
## The chamber accumulates pressure from magma recharge, amplified by how HOT it runs (hot gas expands
## → more pressure); when pressure exceeds the vent's strength the vent cracks and ERUPTS. Lava outflow
## and explosive bomb force both scale with the over-pressure, which venting bleeds off until the vent
## reseals and pressure rebuilds — so eruption timing AND intensity fall out of the pressure/temperature
## cycle. It only INJECTS lava + heat into the MaterialField at its vent; everything else emerges: lava
## flows downhill glowing, solidifies into new rock, ignites forests, boils water, scares wildlife.
## On placement it cuts a lava CHUTE down into the ground where it sits — no pre-built mountain; the
## cone accretes over time as eruptions overflow the chute and solidify into new rock around the vent.
## Built in code, no assets. (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const VENT_RADIUS: float = 3.5
const VENT_HEAT_PER_SEC: float = 1500.0   # keeps the vent molten (ΔT/s injected) while venting
const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 60.0

# --- Magma-chamber pressure (drives emergent eruptions) ----------------------
const CHAMBER_TEMP: float = 1200.0        # reference magma temp; the live vent temp vs this sets recharge
const RECHARGE_RATE: float = 0.05         # base pressure/sec the sealed chamber builds from magma influx
const BREACH_BUILD_RATE: float = 0.11     # pressure/sec while forming (magma intruding toward the first breach)
const ERUPT_PRESSURE: float = 1.0         # over-pressure that cracks the vent and begins an eruption
const SEAL_PRESSURE: float = 0.2          # eruption ends (vent reseals) once pressure bleeds below this
const VENT_RELEASE: float = 0.9           # how fast venting bleeds off over-pressure
const OUTFLOW_PER_PRESSURE: float = 1.3   # lava depth/sec per unit over-pressure at the vent
const BOMB_PRESSURE: float = 0.45         # only strongly over-pressured eruptions throw bombs
var _pressure: float = 0.4                # current chamber over-pressure (starts part-charged)

# --- Seismic emissions (camera shake EMERGES from these, felt via the ecology's seismic field) ---
# The volcano never touches the camera. Its tremors/breach/eruption all disturb the ground (which emits
# seismic pulses) and, for the moments the ground barely moves (early build-up, onset), it emits a
# seismic pulse directly. The camera queries seismic_energy_at() and shakes — proximity is automatic.
const TREMOR_SEISMIC: float = 2.6         # build-up seismic energy/sec, scaled by build fraction² (grows toward breach)
const BREACH_SEISMIC: float = 6.0         # one-shot seismic jolt when the crust ruptures
const ERUPT_SEISMIC: float = 3.0          # ongoing eruption seismic energy/sec, scaled by over-pressure

# --- Lava chute cut into the ground (NO pre-built mountain — the cone accretes from eruptions) ---
const CRATER_RADIUS: float = 4.5          # flared mouth / crater lip carved at the surface
const CONDUIT_RADIUS: float = 2.2         # narrow vertical shaft bored down from the mouth
const CONDUIT_DEPTH: float = 8.0          # how deep the chute goes (shallow enough to fill + overflow)
const CONDUIT_STEPS: int = 5

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
var _breached: bool = false                # false = crust still intact; magma is building toward the first breach
var _scare_cd: float = 0.0
var _rumble_cd: float = 0.0                 # cadence for the seismic rumble / eruption-roar SFX
var _tremor_cd: float = 0.0                 # throttle for continuous build-up/eruption seismic pulses

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


## Place the vent at `point` over INTACT ground: no vent is cut yet. A magma chamber begins building
## pressure beneath the crust; rising heat glows and cracks the surface (precursors) until the pressure
## gives way and the magma PIERCES through for the first time (_breach) — the volcano is born on screen.
## From then the vent stays open and the cone accretes from the lava it erupts.
func erupt_at(point: Vector3) -> void:
	_vent = point
	global_position = point
	_breached = false
	_pressure = 0.3                                     # a new volcano starts low and builds until it breaks through
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", _vent)


## Skip the pressure build-up and breach RIGHT NOW (for demos/tests that need an active flow on demand).
func force_erupt() -> void:
	if not _breached:
		_pressure = ERUPT_PRESSURE
		_breach()


# Blow out a CALDERA when the magma pierces through: carve a broad, deep BOWL into the summit (the
# surrounding higher ground IS the rim — no pre-built dome), plus a narrow conduit shaft down the
# centre. These are large, single, smooth SDF carves, so the caldera reads as smooth terrain — the bowl
# is deep enough that the thin cooled-lava crust can't fill it in, so the crater stays a real caldera.
func _carve_conduit() -> void:
	if _terrain == null or not _terrain.has_method("carve_sphere"):
		return
	# Wide bowl, centred a little above the vent so it bites a proper crater into the peak.
	_terrain.carve_sphere(_vent + Vector3(0.0, CRATER_RADIUS * 0.5, 0.0), CRATER_RADIUS * 1.7)
	for k in range(CONDUIT_STEPS):
		var t: float = float(k) / float(maxi(1, CONDUIT_STEPS - 1))
		var y: float = _vent.y - t * CONDUIT_DEPTH
		_terrain.carve_sphere(Vector3(_vent.x, y, _vent.z), CONDUIT_RADIUS)
	# Sync the field's cached ground heights to the carved-down surface so lava pools in the chute.
	if _field != null and _field.has_method("resample_terrain"):
		_field.resample_terrain(_vent, CRATER_RADIUS * 2.2)
	# Snap the vent to the chute floor (the new, lower surface) so lava/heat inject at the bottom.
	var gy = _terrain.surface_height(_vent.x, _vent.z)
	if (typeof(gy) == TYPE_FLOAT or typeof(gy) == TYPE_INT) and not (is_nan(float(gy)) or is_inf(float(gy))):
		_vent.y = float(gy)
		global_position = _vent
	# Seed a little glowing lava at the chute floor so even a dormant vent reads as molten.
	if _field != null and _field.has_method("add_material"):
		_field.add_material(_vent, Mat.LAVA, 0.5, CONDUIT_RADIUS * 1.2)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	var status: String = "forming — crust intact" if not _breached else ("ERUPTING" if _erupting else "pressurizing")
	lines.append("Status: %s" % status)
	lines.append("Chamber pressure: %.0f%%" % (_pressure / ERUPT_PRESSURE * 100.0))
	lines.append("Vent temp: %.0f°C" % _vent_temp())
	lines.append("Vent: (%.0f, %.0f, %.0f)" % [_vent.x, _vent.y, _vent.z])
	return {"title": "Volcano", "lines": lines}


# The live temperature at the vent (magma proxy). Read from the field; falls back to reference temp.
func _vent_temp() -> float:
	if _field != null and _field.has_method("temp_at"):
		return _field.temp_at(_vent.x, _vent.z)
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
	# Pressure/temperature dynamics drive everything. The hotter the vent runs, the faster gas pressure
	# builds; when it crosses ERUPT_PRESSURE the vent cracks; venting then bleeds pressure until it seals.
	var heat_factor: float = clampf(_vent_temp() / CHAMBER_TEMP, 0.4, 1.3)

	if not _breached:
		# Crust still intact: magma builds pressure below and its heat bleeds up until it pierces through.
		_pressurize_toward_breach(delta)
	elif not _erupting:
		# Sealed (already breached): recharge. Cross the vent's strength → an eruption begins.
		_pressure += RECHARGE_RATE * heat_factor * delta
		if _pressure >= ERUPT_PRESSURE:
			_erupting = true
			LocalAgentsAudioDirector.emit(get_tree(), "volcano_erupt", _vent)
			if _glow != null:
				_glow.light_energy = 34.0                # onset flash
	elif _field != null:
		# Erupting: outflow + bomb force scale with OVER-pressure; venting bleeds it toward the seal.
		var over: float = maxf(0.0, _pressure - SEAL_PRESSURE)
		var outflow: float = OUTFLOW_PER_PRESSURE * over
		_emit_tremor(ERUPT_SEISMIC * over, delta)           # ongoing rumble emerges from felt seismic energy
		# Sustained eruption roar in overlapping bursts.
		_rumble_cd -= delta
		if _rumble_cd <= 0.0:
			_rumble_cd = randf_range(1.1, 2.0)
			LocalAgentsAudioDirector.emit(get_tree(), "volcano_roar", _vent)
		if _field.has_method("add_material"):
			_field.add_material(_vent, Mat.LAVA, outflow * delta, VENT_RADIUS)
		# Keep the vent molten but DRIVE it toward a bounded target (~1300°C) instead of adding heat
		# blindly — otherwise continuous injection at one cell runs away (worse on a finer grid).
		if _field.has_method("add_heat"):
			var vt: float = _vent_temp()
			if vt < 1300.0:
				_field.add_heat(_vent, minf(VENT_HEAT_PER_SEC * delta, (1300.0 - vt) * 0.5), VENT_RADIUS)
		# Bleed pressure as it vents (plus a little continued recharge fighting it), then reseal when spent.
		_pressure += (RECHARGE_RATE * heat_factor * 0.4 - VENT_RELEASE * over) * delta
		# NOTE: no per-frame disturb_ground here — repeatedly slumping the vent churned the terrain into
		# smooth fill_sphere "zit" domes. Physical ground disturbance is now a ONE-SHOT at the breach only.
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


# BEFORE the volcano has opened: magma accumulates under intact crust. Pressure builds (heat-amplified),
# and rising heat warms the ground above so a hot spot GLOWS and the surface trembles/cracks — emergent
# precursors — until the pressure gives way and the magma pierces through.
func _pressurize_toward_breach(delta: float) -> void:
	# Magma intrudes from below at a steady rate (not gated by surface heat, which is still low) so a
	# freshly-placed volcano visibly builds up and breaks through in a handful of seconds.
	_pressure += BREACH_BUILD_RATE * delta
	var frac: float = clampf(_pressure / ERUPT_PRESSURE, 0.0, 1.0)
	if _field != null and _field.has_method("add_heat"):
		# Rising magma warms the ground above toward a GLOW that brightens as the breach nears (dull red
		# ~450°C early → orange ~1000°C at breach). Driven toward a target so it never runs away.
		var target_glow: float = 250.0 + 750.0 * frac * frac
		var vt: float = _vent_temp()
		if vt < target_glow:
			_field.add_heat(_vent, (target_glow - vt) * minf(1.0, 3.0 * delta), CRATER_RADIUS * 1.6)
	# No per-frame disturb_ground during build-up — physically fracturing the vent every frame churned
	# it up. The tremors are FELT as camera shake via the seismic field (emergent — no direct camera
	# call), intensifying as the breach nears (frac²) — a warning it's coming.
	_emit_tremor(TREMOR_SEISMIC * frac * frac, delta)
	# Deep ground rumble that comes faster (more menacing) the closer the breach is.
	_rumble_cd -= delta
	if _rumble_cd <= 0.0:
		_rumble_cd = lerpf(3.5, 0.8, frac)
		LocalAgentsAudioDirector.emit(get_tree(), "volcano_rumble", _vent)
	if frac > 0.5:
		_scare_cd -= delta
		if _scare_cd <= 0.0:
			_scare_cd = SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(_vent, SCARE_RADIUS * frac, frac * 0.5)
	if _pressure >= ERUPT_PRESSURE:
		_breach()


# The magma PIERCES the crust for the first time: cut the vent open from below, throw shattered crust,
# shock the world, and flood the first lava out. From here the vent stays open and the cone accretes.
func _breach() -> void:
	_carve_conduit()                                    # the ground finally gives way — the vent opens
	_breached = true
	_erupting = true
	_pressure = 0.7                                     # the breach releases much of the built-up pressure
	if _field != null:
		if _field.has_method("add_material"):
			_field.add_material(_vent, Mat.LAVA, 2.5, CRATER_RADIUS)   # first lava floods out (molten by definition)
		if _field.has_method("add_heat"):
			_field.add_heat(_vent, 700.0, CRATER_RADIUS * 2.2)         # a heat pulse to scorch/ignite around the new vent
	_launch_bombs(1.4)                                  # violent opening blast of crust + lava bombs
	if _ecology != null:
		if _ecology.has_method("disturb_ground"):
			_ecology.disturb_ground(_vent, CRATER_RADIUS * 5.0, 3.0)  # the ground heaves as it ruptures
		if _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(_vent, SCARE_RADIUS * 1.5, 1.0)
	LocalAgentsAudioDirector.emit(get_tree(), "volcano_erupt", _vent)
	# A hard seismic jolt as the crust ruptures — the camera feels it through the seismic field.
	if _ecology != null and _ecology.has_method("broadcast_seismic"):
		_ecology.broadcast_seismic(_vent, BREACH_SEISMIC)
	if _glow != null:
		_glow.light_energy = 42.0


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


func _update_fx() -> void:
	var frac: float = clampf(_pressure / ERUPT_PRESSURE, 0.0, 1.0)
	if _glow != null:
		var target: float
		if not _breached:
			target = 1.0 + 9.0 * frac                    # faint precursor glow that grows as breach nears
		else:
			target = 18.0 if _erupting else 4.0
		_glow.light_energy = lerpf(_glow.light_energy, target, 0.1)
	if _smoke != null:
		if not _breached:
			_smoke.amount_ratio = 0.08 * frac            # only wisps of steam/ash escape intact crust
		else:
			_smoke.amount_ratio = 1.0 if _erupting else 0.25
