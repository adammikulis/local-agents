class_name LAThunderstorm
extends Node3D


const LIFETIME: float = 46.0              # seconds from first charge to spent
const BUILD_TIME: float = 6.0             # ramps the SEEDING up over this at the start
const FADE_TIME: float = 10.0             # eases the SEEDING out over this at the end (the cell rains itself out)
const RADIUS: float = 62.0                # footprint half-width (vapor pumping + lightning + drift box)

const VAPOR_PER_SEC: float = 5.0          # total vapor injected per second at full seeding (split over points)
const VAPOR_INJECT_R: float = 14.0        # radius of each vapor blob at the ground

# A storm has no energy source and no energy sink of its own: it seeds moisture only, and whether a cell
# is there at all is read from the convective updraft (+Y lift) that seeding grows.
const LIFT_FOLLOW: float = 5.0            # drift toward stronger local convective lift (track its own updraft)
const LIFT_PROBE: float = 40.0            # radius at which updraft is sampled to find the lift-core direction

const WIND_DRIFT: float = 0.7             # fraction of the atmosphere wind the cell drifts with

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null

var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0

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
	LAAudioDirector.emit(get_tree(), "thunder", _center)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	var lift: float = _core_updraft()
	var ambient: float = _ambient_updraft()
	lines.append("Seeding: %s" % _phase_name())
	lines.append("Cell: %s" % ("centre lifts faster than its surroundings" if lift > ambient else "no cell"))
	lines.append("Updraft here: %.3f u/s" % lift)
	lines.append("Surrounding updraft: %.3f u/s" % ambient)
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


# Outward radial wind (upward is positive) at the cell centre — the convective lift the field actually has.
func _core_updraft() -> float:
	if _field == null or not _field.has_method("updraft_at"):
		return 0.0
	return _field.updraft_at(_center)


# Mean outward radial wind around the cell, on the same probe ring the drift follows. The environment the
# centre is compared against; no constant separates them, only the two readings.
func _ambient_updraft() -> float:
	if _field == null or not _field.has_method("updraft_at"):
		return 0.0
	var total: float = 0.0
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		total += _field.updraft_at(_center + Vector3(cos(a) * LIFT_PROBE, 0.0, sin(a) * LIFT_PROBE))
	return total / 6.0


# Direction (world XZ) toward the strongest nearby RISING air — the cell's own updraft core — so it drifts
# to stay over the convection it grew instead of only sliding with the wind. Signed: a downdraft is not lift.
func _lift_gradient() -> Vector2:
	if _field == null or not _field.has_method("updraft_at"):
		return Vector2.ZERO
	var best_dir: Vector2 = Vector2.ZERO
	var best_val: float = _field.updraft_at(_center)
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		var ox: float = cos(a) * LIFT_PROBE
		var oz: float = sin(a) * LIFT_PROBE
		var v: float = _field.updraft_at(_center + Vector3(ox, 0.0, oz))
		if v > best_val:
			best_val = v
			best_dir = Vector2(ox, oz)
	if best_dir.length() > 0.001:
		return best_dir.normalized()
	return Vector2.ZERO


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	if _field == null:
		push_error("Thunderstorm has no material field: there is no atmosphere to read an updraft from.")
		queue_free()
		return

	# The cell exists while its centre rises faster than the air around it. Two field reads, no threshold
	# between them: when the lift flattens out, there is no convective cell there.
	var lift: float = _core_updraft()
	var ambient: float = _ambient_updraft()
	if lift != 0.0 or ambient != 0.0:      # both exactly zero = no velocity readback yet, which decides nothing
		if lift <= ambient:
			queue_free()
			return

	var seed: float = _seed_scale()

	# DRIFT — a storm cell rides the LOCAL wind at its own position AND biases toward its strongest nearby
	# convective lift, so it tracks the updraft the field grew rather than only sliding downwind.
	if _field.has_method("wind_at") or _field.has_method("wind"):
		var wind: Vector2 = _field.wind_at(_center) if _field.has_method("wind_at") else _field.wind()
		_center.x += wind.x * WIND_DRIFT * delta
		_center.z += wind.y * WIND_DRIFT * delta
	var lift_dir: Vector2 = _lift_gradient()
	_center.x += lift_dir.x * LIFT_FOLLOW * delta
	_center.z += lift_dir.y * LIFT_FOLLOW * delta
	if _terrain != null and _terrain.has_method("ground_point"):
		var sp: Vector3 = _terrain.ground_point(_center)
		if not is_nan(sp.x):
			_center = sp
	global_position = _center

	_pump_moisture(seed, delta)


# Pump humid air up from the ground across the footprint, so the field's condensation rules build
# cloud → rain here. Several injection points spread the cell so a broad sheet forms, not a dot.
func _pump_moisture(intensity: float, delta: float) -> void:
	if intensity <= 0.0:
		return
	var per_point: float = VAPOR_PER_SEC * intensity * delta / 5.0
	var offsets: Array = [
		Vector2(0.0, 0.0), Vector2(RADIUS * 0.55, 0.0), Vector2(-RADIUS * 0.55, 0.0),
		Vector2(0.0, RADIUS * 0.55), Vector2(0.0, -RADIUS * 0.55),
	]
	for off in offsets:
		var px: float = _center.x + off.x
		var pz: float = _center.z + off.y
		var gy: float = _center.y
		if _terrain != null and _terrain.has_method("ground_point"):
			var g: Vector3 = _terrain.ground_point(Vector3(px, _center.y, pz))
			if not is_nan(g.x):
				gy = g.y
		if _field.has_method("add_vapor"):
			_field.add_vapor(Vector3(px, gy + 3.0, pz), per_point, VAPOR_INJECT_R)


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
