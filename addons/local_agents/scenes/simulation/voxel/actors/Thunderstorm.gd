class_name LAThunderstorm
extends Node3D

## A thunderstorm CELL. It doesn't paint rain or schedule thunder on a timeline — it seeds the physical
## ingredients of a storm into the MaterialField and lets the emergent water cycle do the rest: each step
## it PUMPS humid air (add_vapor) up from the ground across its footprint, WARMS the surface (add_heat) to
## grow the convective updraft, and COOLS the air aloft (add_cooling), so rising moist air passes its
## dewpoint and the field's own condense→rain rules build a DENSE cloud → HEAVY rain right here.
##
## LIGHTNING IS NOT SPAWNED HERE. There is no bolt cadence, no strike timer, no random footprint pick — the
## cell only seeds moisture + heat. Charge ACCUMULATES on the built-up cloud/water in MaterialCharge3D and
## fires bolts NATURALLY when a cell reaches dielectric breakdown (which injects the strike heat, discharges
## the cell, and calls the bolt visual). So fires/scorch/panic still emerge from the bolt's heat as usual —
## but the bolt itself falls out of the field's own charge physics, not out of this actor. The cell DRIFTS
## downwind and rains itself out over its lifetime. Built in code, no assets. (Explicit types only — no ':=' .)
##
## Deleted vs the old scripted storm: `_maybe_strike`, `_bolt_cd`, BOLT_MIN_CD/MAX_CD/CLOUD_REF and the
## random-footprint spawn_lightning call — a bolt is just what charge does at breakdown, not "bolt code".

const LIFETIME: float = 46.0              # seconds from first charge to spent
const BUILD_TIME: float = 6.0             # ramps the SEEDING up over this at the start (grace before starve-death)
const FADE_TIME: float = 10.0             # eases the SEEDING out over this at the end (the cell rains itself out)
const RADIUS: float = 62.0                # footprint half-width (vapor pumping + lightning + drift box)

# Moisture pump + surface heating + aloft cooling — the ingredients the actor SEEDS; the cloud/rain and the
# convective updraft the cell then feeds on EMERGE from them via the field. Charge separation
# (charge_accum_sphere3d) then feeds on updraft × cloud × how supercooled the cloud is, and climbs to
# dielectric breakdown → a bolt, entirely in the field. (The storm seeds; MaterialCharge3D fires.)
const VAPOR_PER_SEC: float = 5.0          # total vapor injected per second at full seeding (split over points)
const VAPOR_INJECT_R: float = 14.0        # radius of each vapor blob at the ground
const SEED_HEAT_PER_SEC: float = 10.0     # surface warming that makes the air rise → the convective updraft
const SEED_HEAT_R: float = 16.0
const COOL_PER_SEC: float = 14.0          # °C/s pulled out of the air aloft to force condensation
const COOL_INJECT_R: float = 30.0

# Intensity now EMERGES from the convective updraft (+Y lift) the seeding grows — not a scripted envelope.
const STRENGTH_MAX: float = 1.0           # intensity is normalized 0..1
const UPDRAFT_TO_STRENGTH: float = 0.3    # K: |updraft| → strength; tuned so a strong convective lift saturates
const STRENGTH_RATE: float = 0.1          # smoothing of strength toward the field-read target
const DISSIPATE_STRENGTH: float = 0.12    # past BUILD_TIME, a collapsed updraft (no lift) kills the cell
const LIFT_FOLLOW: float = 5.0            # drift toward stronger local convective lift (track its own updraft)
const LIFT_PROBE: float = 40.0            # radius at which updraft is sampled to find the lift-core direction

const WIND_DRIFT: float = 0.7             # fraction of the atmosphere wind the cell drifts with

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null

var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _strength: float = 0.0                # EMERGENT storm intensity, read from the convective updraft each step

var _cloud_fx: GPUParticles3D = null
var _picker: StaticBody3D = null


func _ready() -> void:
	add_to_group("selectable")


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


func begin(point: Vector3) -> void:
	_center = point
	global_position = _center
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "thunder", _center)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	lines.append("Status: %s" % _phase_name())
	lines.append("Intensity: %.0f%%" % (_strength / STRENGTH_MAX * 100.0))
	var lift: float = 0.0
	if _field != null and _field.has_method("updraft_at"):
		lift = _field.updraft_at(_center.x, _center.z)
	lines.append("Updraft (lift): %.2f" % lift)
	var cover: float = 0.0
	if _field != null and _field.has_method("cloud_at"):
		cover = float(_field.cloud_at(_center.x, _center.z))
	lines.append("Cloud overhead: %.2f" % cover)
	lines.append("Age: %.0fs / %.0fs" % [_age, LIFETIME])
	return {"title": "Thunderstorm", "lines": lines}


func _phase_name() -> String:
	if _age < BUILD_TIME:
		return "building"
	if _age > LIFETIME - FADE_TIME:
		return "dissipating"
	return "mature"


# The SEEDING envelope — a build-up → sustain → fade over the lifetime that scales how hard the cell PUMPS
# its ingredients (vapor/heat/cooling) into the field, so it charges, storms, then rains itself out. This
# governs SEEDING only; the storm's intensity now emerges separately from the updraft the seeding grows.
func _seed_scale() -> float:
	if _age >= LIFETIME:
		return 0.0
	var up: float = clampf(_age / BUILD_TIME, 0.0, 1.0)
	var down: float = clampf((LIFETIME - _age) / FADE_TIME, 0.0, 1.0)
	return minf(up, down)


# Direction (world XZ) toward the strongest nearby convective lift — the cell's own updraft core — so it
# drifts to stay over the convection it grew instead of only sliding with the wind. Zero if none is stronger.
func _lift_gradient() -> Vector2:
	if _field == null or not _field.has_method("updraft_at"):
		return Vector2.ZERO
	var best_dir: Vector2 = Vector2.ZERO
	var best_val: float = absf(_field.updraft_at(_center.x, _center.z))
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		var ox: float = cos(a) * LIFT_PROBE
		var oz: float = sin(a) * LIFT_PROBE
		var v: float = absf(_field.updraft_at(_center.x + ox, _center.z + oz))
		if v > best_val:
			best_val = v
			best_dir = Vector2(ox, oz)
	if best_dir.length() > 0.001:
		return best_dir.normalized()
	return Vector2.ZERO


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME or _field == null:
		if _age >= LIFETIME:
			queue_free()
		return

	# STRENGTH — EMERGES from the convective updraft (+Y lift) the seeding grows, read fresh each step; no
	# scripted intensity envelope. A cell whose lift collapses (drifted off its convection) withers and dies.
	var lift: float = 0.0
	if _field.has_method("updraft_at"):
		lift = absf(_field.updraft_at(_center.x, _center.z))
	_strength = clampf(lerpf(_strength, UPDRAFT_TO_STRENGTH * lift, STRENGTH_RATE), 0.0, STRENGTH_MAX)
	if _age > BUILD_TIME and _strength <= DISSIPATE_STRENGTH:
		queue_free()
		return

	var seed: float = _seed_scale()

	# DRIFT — a storm cell rides the LOCAL wind at its own position AND biases toward its strongest nearby
	# convective lift, so it tracks the updraft the field grew rather than only sliding downwind.
	if _field.has_method("wind_at") or _field.has_method("wind"):
		var wind: Vector2 = _field.wind_at(_center.x, _center.z) if _field.has_method("wind_at") else _field.wind()
		_center.x += wind.x * WIND_DRIFT * delta
		_center.z += wind.y * WIND_DRIFT * delta
	var lift_dir: Vector2 = _lift_gradient()
	_center.x += lift_dir.x * LIFT_FOLLOW * delta
	_center.z += lift_dir.y * LIFT_FOLLOW * delta
	if _terrain != null and _terrain.has_method("surface_height"):
		var gy: float = _terrain.surface_height(_center.x, _center.z)
		if not is_nan(gy):
			_center.y = gy
	global_position = _center

	_pump_moisture(seed, delta)
	_update_fx(_strength)


# Pump humid air up from the ground across the footprint + cool the air aloft, so the field's condensation
# rules build cloud → rain here. Several injection points spread the cell so a broad sheet forms, not a dot.
func _pump_moisture(intensity: float, delta: float) -> void:
	if intensity <= 0.0:
		return
	var cloud_base: float = _center.y + 60.0
	if _field.has_method("cloud_base_y"):
		cloud_base = float(_field.cloud_base_y())
	var per_point: float = VAPOR_PER_SEC * intensity * delta / 5.0
	var offsets: Array = [
		Vector2(0.0, 0.0), Vector2(RADIUS * 0.55, 0.0), Vector2(-RADIUS * 0.55, 0.0),
		Vector2(0.0, RADIUS * 0.55), Vector2(0.0, -RADIUS * 0.55),
	]
	for off in offsets:
		var px: float = _center.x + off.x
		var pz: float = _center.z + off.y
		var gy: float = _center.y
		if _terrain != null and _terrain.has_method("surface_height"):
			var h: float = _terrain.surface_height(px, pz)
			if not is_nan(h):
				gy = h
		if _field.has_method("add_vapor"):
			_field.add_vapor(Vector3(px, gy + 3.0, pz), per_point, VAPOR_INJECT_R)
		# Warm the surface air so it becomes buoyant and RISES — this is what grows the convective updraft
		# the cell's emergent strength then feeds on (the field's buoyancy rule lifts the warmed humid air).
		if _field.has_method("add_heat"):
			_field.add_heat(Vector3(px, gy + 2.0, pz), SEED_HEAT_PER_SEC * intensity * delta / 5.0, SEED_HEAT_R)
	# Cold aloft: pull heat out of the mid-air over the cell so the rising humid air condenses hard.
	if _field.has_method("add_cooling"):
		_field.add_cooling(Vector3(_center.x, cloud_base, _center.z), COOL_PER_SEC * intensity * delta, COOL_INJECT_R)


# --- Visuals: a dark churning cloud slab drifting over the cell (the rain itself is the RainLayer's) ---

# Soft fade for the storm slab: transparent → dark thundercloud → transparent, so the cell reads as a
# dense DARK anvil overhead with soft edges rather than a flat grey sheet of hard quads.
func _cloud_ramp() -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.22, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color(0.09, 0.10, 0.13, 0.0),
		Color(0.08, 0.09, 0.12, 0.72),
		Color(0.06, 0.07, 0.10, 0.55),
		Color(0.05, 0.06, 0.09, 0.0),
	])
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


func _build_fx() -> void:
	if _cloud_fx == null:
		_cloud_fx = GPUParticles3D.new()
		_cloud_fx.amount = 190                           # denser slab so the storm darkens the sky
		_cloud_fx.lifetime = 6.5
		_cloud_fx.emitting = true
		_cloud_fx.local_coords = false
		_cloud_fx.position = Vector3(0.0, 62.0, 0.0)
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(30.0, 30.0)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)     # tint from the per-particle ramp below
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = mat
		_cloud_fx.draw_pass_1 = quad
		var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(RADIUS, 5.0, RADIUS)
		pm.direction = Vector3(1.0, 0.0, 0.0)
		pm.spread = 40.0
		pm.initial_velocity_min = 1.0
		pm.initial_velocity_max = 4.0
		pm.gravity = Vector3(0.0, 0.0, 0.0)
		pm.scale_min = 0.9
		pm.scale_max = 2.8
		pm.color_ramp = _cloud_ramp()
		_cloud_fx.process_material = pm
		_cloud_fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_cloud_fx)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = 14.0
		col.shape = cs
		_picker.position = Vector3(0.0, 20.0, 0.0)
		_picker.add_child(col)
		add_child(_picker)


func _update_fx(intensity: float) -> void:
	if _cloud_fx != null:
		_cloud_fx.amount_ratio = clampf(0.2 + 0.8 * intensity, 0.05, 1.0)
