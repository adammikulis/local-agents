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
const AREA: float = 90.0                  # half-extent (world) of the rain box centred on the camera
const FALL_SPEED: float = 34.0            # streak fall speed (fast = long motion-blur streaks)
const MAX_PARTICLES: int = 5200

var _field = null                         # LAMaterialField (cloud_at / avg_cloud_cover / cloud_base_y)
var _camera: Node3D = null
var _pm: ParticleProcessMaterial = null
var _force: bool = false                   # --rain test override: rain regardless of cloud cover


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
	streak.size = Vector2(0.045, 0.9)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.72, 0.86, 0.5)
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


func _process(_delta: float) -> void:
	if _field == null or _camera == null or not is_instance_valid(_camera):
		return
	var cp: Vector3 = _camera.global_position
	# How hard is it raining right here? Take the cloud density around the camera (max of a small cross so
	# the rain leads/lags a moving cloud a touch), and the world Y the clouds sit at.
	var cover: float = 0.0
	if _field.has_method("cloud_at"):
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x + 40.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x - 40.0, cp.z)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z + 40.0)))
		cover = maxf(cover, float(_field.cloud_at(cp.x, cp.z - 40.0)))
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
	amount_ratio = 0.25 + 0.75 * intensity     # heavier downpour under denser cloud
	if not emitting:
		emitting = true
