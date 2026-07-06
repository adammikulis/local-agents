class_name LARainLayer
extends GPUParticles3D

## LARainLayer — the VISUAL for the field's emergent precipitation. It renders nothing on its own logic:
## it samples the MaterialField's CLOUD density around the camera each frame and only rains where the
## simulation is actually raining (cloud density over the precipitation threshold). Intensity tracks the
## cloud density, so a passing storm cell drives a passing downpour — the rain falls out of the water
## cycle (evaporation → cloud → rain), never a scripted timer. GPU particles keep it cheap + pretty.
## (Explicit types only — no ':=' inferred typing.)

# Cloud density at/above which it visibly rains (the atmosphere condenses→rains around here); intensity
# ramps from this up to full over the next band.
const RAIN_THRESHOLD: float = 0.28
const RAIN_FULL: float = 0.6
const AREA: float = 85.0                  # half-extent (world) of the rain box centred on the camera
const FALL_SPEED: float = 44.0            # streak fall speed (fast = long motion-blur streaks)
const MAX_PARTICLES: int = 16000
const SPLASH_INTERVAL: float = 0.12       # min seconds between splash-ripple emissions under heavy rain
const SPLASH_RAIN_MIN: float = 0.45       # only splash the ground once the downpour is at least this hard

var _field = null                         # LAMaterialField (cloud_at / avg_cloud_cover / cloud_base_y)
var _camera: Node3D = null
var _pm: ParticleProcessMaterial = null
var _force: bool = false                   # --rain test override: rain regardless of cloud cover
var _splash_cd: float = 0.0                # throttle for splash-ripple feedback on wet ground/water


## Test override: force a full downpour regardless of the sim's cloud density (verification aid).
func set_force(on: bool) -> void:
	_force = on


func setup(field, camera: Node3D) -> void:
	_field = field
	_camera = camera
	name = "RainLayer"
	amount = MAX_PARTICLES
	lifetime = (AREA * 2.2) / FALL_SPEED   # long enough to fall from cloud base through the ground
	preprocess = lifetime                  # start mid-storm, not with an empty sky filling in
	visibility_aabb = AABB(Vector3(-AREA, -AREA * 2.0, -AREA), Vector3(AREA * 2.0, AREA * 3.0, AREA * 2.0))
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	emitting = false

	# A thin, vertically-stretched translucent streak — a raindrop smeared by speed.
	var streak: QuadMesh = QuadMesh.new()
	streak.size = Vector2(0.07, 1.7)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.80, 0.92, 0.7)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	streak.material = mat
	draw_pass_1 = streak

	_pm = ParticleProcessMaterial.new()
	_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_pm.emission_box_extents = Vector3(AREA, 1.0, AREA)   # a thin slab up at cloud base; it rains straight down
	_pm.direction = Vector3(0.0, -1.0, 0.0)
	_pm.spread = 2.0
	_pm.gravity = Vector3(0.0, -6.0, 0.0)
	_pm.initial_velocity_min = FALL_SPEED
	_pm.initial_velocity_max = FALL_SPEED * 1.15
	_pm.scale_min = 0.7
	_pm.scale_max = 1.5
	_pm.color = Color(0.66, 0.75, 0.88, 0.55)
	process_material = _pm


func _process(delta: float) -> void:
	if _field == null or _camera == null or not is_instance_valid(_camera):
		return
	var cp: Vector3 = _camera.global_position
	# How hard is it raining right HERE? Sample the LOCAL cloud density right around the camera (max of a
	# tight cross so the rain leads/lags a moving storm cell a touch) rather than the global average — so a
	# passing storm drives a passing downpour that visibly intensifies under it and stops when it clears.
	var cover: float = 0.0
	if _field.has_method("cloud_at"):
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x + 30.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x - 30.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z + 30.0)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z - 30.0)))
		cover = maxf(cover, float(_field.cloud_at(cp.x + 60.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x - 60.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z + 60.0)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z - 60.0)))
	elif _field.has_method("avg_cloud_cover"):
		cover = float(_field.avg_cloud_cover())

	var intensity: float = clampf((cover - RAIN_THRESHOLD) / maxf(0.001, RAIN_FULL - RAIN_THRESHOLD), 0.0, 1.0)
	if _force:
		intensity = 1.0
	if intensity <= 0.0:
		if emitting:
			emitting = false
		return

	# Rain falls from the cloud sheet down; centre the emitter slab over the camera at cloud base.
	var base_y: float = float(_field.cloud_base_y()) if _field.has_method("cloud_base_y") else cp.y + 60.0
	global_position = Vector3(cp.x, base_y, cp.z)
	amount_ratio = 0.3 + 0.7 * intensity     # heavier downpour under denser cloud
	if not emitting:
		emitting = true

	# SPLASH FEEDBACK: under a real downpour, spatter the wet ground/water near the camera so puddles and
	# ripples EMERGE where the rain is falling. Throttled; only on water surfaces (dry ground has no pool
	# to ripple yet). The rain feeds the water CA too (the atmosphere rains into the field), so puddles
	# form and then these splashes ripple them — closing the visible loop.
	if intensity >= SPLASH_RAIN_MIN and _field.has_method("splash") and _field.has_method("surface_y_at"):
		_splash_cd -= delta
		if _splash_cd <= 0.0:
			_splash_cd = SPLASH_INTERVAL
			var ang: float = randf() * TAU
			var rad: float = sqrt(randf()) * 40.0
			var sx: float = cp.x + cos(ang) * rad
			var sz: float = cp.z + sin(ang) * rad
			var sy: float = float(_field.surface_y_at(sx, sz))
			if not is_nan(sy):
				_field.splash(Vector3(sx, sy, sz), 0.5 + intensity)
