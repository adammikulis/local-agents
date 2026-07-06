class_name LAThunderstorm
extends Node3D

## A thunderstorm CELL. It doesn't paint rain or schedule thunder on a timeline — it seeds the physical
## ingredients of a storm into the MaterialField and lets the emergent water cycle do the rest: each step
## it PUMPS humid air (add_vapor) up from the ground across its footprint and COOLS the air aloft
## (add_cooling), so rising moist air passes its dewpoint and the field's own condense→rain rules build a
## DENSE cloud → HEAVY rain right here. While the cell is charged it fires LIGHTNING bolts within its
## footprint (reusing the real LightningStrike actor, so fires/scorch/panic all emerge from the bolt's
## heat as usual) — and the more cloud has built overhead, the more it crackles. The cell DRIFTS downwind
## and rains itself out over its lifetime. Built in code, no assets. (Explicit types only — no ':=' .)

const LIFETIME: float = 46.0              # seconds from first charge to spent
const BUILD_TIME: float = 6.0             # ramps up over this at the start
const FADE_TIME: float = 10.0             # eases out over this at the end
const RADIUS: float = 62.0                # footprint half-width (vapor pumping + lightning + drift box)

# Moisture pump + aloft cooling — the two ingredients; the cloud/rain EMERGE from them via the field.
const VAPOR_PER_SEC: float = 5.0          # total vapor injected per second at full strength (split over points)
const VAPOR_INJECT_R: float = 14.0        # radius of each vapor blob at the ground
const COOL_PER_SEC: float = 14.0          # °C/s pulled out of the air aloft to force condensation
const COOL_INJECT_R: float = 30.0

const WIND_DRIFT: float = 0.7             # fraction of the atmosphere wind the cell drifts with
const BOLT_MIN_CD: float = 1.4            # fastest lightning cadence (at peak cloud), seconds
const BOLT_MAX_CD: float = 6.0            # slowest cadence (barely charged)
const BOLT_CLOUD_REF: float = 0.6         # cloud density that counts as "fully charged" for bolt cadence

var _terrain: Object = null
var _ecology: Object = null
var _disasters: Object = null             # LAVoxelDisasters — reused to spawn the real lightning bolts
var _field: Object = null

var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _bolt_cd: float = 1.0

var _cloud_fx: GPUParticles3D = null
var _picker: StaticBody3D = null


func _ready() -> void:
	add_to_group("selectable")


func setup(terrain: Object, ecology: Object, disasters: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	_disasters = disasters
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
	lines.append("Intensity: %.0f%%" % (_intensity() * 100.0))
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


# A build-up → sustain → fade envelope over the lifetime, so the cell charges, storms, then rains out.
func _intensity() -> float:
	if _age >= LIFETIME:
		return 0.0
	var up: float = clampf(_age / BUILD_TIME, 0.0, 1.0)
	var down: float = clampf((LIFETIME - _age) / FADE_TIME, 0.0, 1.0)
	return minf(up, down)


func _physics_process(delta: float) -> void:
	_age += delta
	var intensity: float = _intensity()
	if _age >= LIFETIME or _field == null:
		if _age >= LIFETIME:
			queue_free()
		return

	# DRIFT downwind — a storm cell rides the LOCAL wind at its own position (not one global vector).
	if _field.has_method("wind_at") or _field.has_method("wind"):
		var wind: Vector2 = _field.wind_at(_center.x, _center.z) if _field.has_method("wind_at") else _field.wind()
		_center.x += wind.x * WIND_DRIFT * delta
		_center.z += wind.y * WIND_DRIFT * delta
	if _terrain != null and _terrain.has_method("surface_height"):
		var gy: float = _terrain.surface_height(_center.x, _center.z)
		if not is_nan(gy):
			_center.y = gy
	global_position = _center

	_pump_moisture(intensity, delta)
	_maybe_strike(intensity, delta)
	_update_fx(intensity)


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
	# Cold aloft: pull heat out of the mid-air over the cell so the rising humid air condenses hard.
	if _field.has_method("add_cooling"):
		_field.add_cooling(Vector3(_center.x, cloud_base, _center.z), COOL_PER_SEC * intensity * delta, COOL_INJECT_R)


# Fire lightning within the footprint; cadence scales with how much cloud has actually built overhead
# (emergent — a barely-charged cell rarely crackles, a mature one hammers). Reuses the real bolt actor.
func _maybe_strike(intensity: float, delta: float) -> void:
	if intensity < 0.2 or _disasters == null or not _disasters.has_method("spawn_lightning"):
		return
	_bolt_cd -= delta
	if _bolt_cd > 0.0:
		return
	var cover: float = 0.0
	if _field.has_method("cloud_at"):
		cover = float(_field.cloud_at(_center.x, _center.z))
	var charge: float = clampf(cover / BOLT_CLOUD_REF, 0.0, 1.0) * intensity
	_bolt_cd = lerpf(BOLT_MAX_CD, BOLT_MIN_CD, charge)
	# Strike a random point inside the footprint, on the ground.
	var ang: float = randf() * TAU
	var rad: float = sqrt(randf()) * RADIUS
	var sx: float = _center.x + cos(ang) * rad
	var sz: float = _center.z + sin(ang) * rad
	var sy: float = _center.y
	if _terrain != null and _terrain.has_method("surface_height"):
		var h: float = _terrain.surface_height(sx, sz)
		if is_nan(h):
			return
		sy = h
	_disasters.spawn_lightning(Vector3(sx, sy, sz))


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
