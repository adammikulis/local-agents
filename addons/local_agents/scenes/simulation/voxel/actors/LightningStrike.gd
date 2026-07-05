class_name LALightningStrike
extends Node3D

## A lightning bolt. It only DEPOSITS a burst of intense heat at the strike point (plus a blinding
## flash and thunder); everything else emerges from the MaterialField — vegetation that crosses the
## ignition temperature catches fire, the ground scorches and glows then cools, water flashes to
## steam, and wildlife panics. No hardcoded "lightning → fire". Built in code, self-frees after the
## flash. (Explicit types only — no ':=' inferred typing.)

const STRIKE_HEIGHT: float = 130.0        # bolt drawn from this high down to the point
const STRIKE_HEAT: float = 1400.0         # °C deposited (well above wood's 300°C ignition)
const HEAT_RADIUS: float = 3.0
const SCORCH_RADIUS: float = 1.4          # small glassy crater at the point
const SCARE_RADIUS: float = 34.0
const FLASH_ENERGY: float = 34.0
const LINGER: float = 0.7                 # seconds of afterglow before free
const SEGMENTS: int = 14

var _terrain: Object = null
var _ecology: Object = null
var _flash: OmniLight3D = null
var _age: float = 0.0


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


## Strike the ground at `point`: draw the bolt, flash, thunder, and inject heat (fire emerges).
func strike(point: Vector3) -> void:
	global_position = Vector3.ZERO
	_build_bolt(point)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(0.85, 0.9, 1.0)
	_flash.light_energy = FLASH_ENERGY
	_flash.omni_range = 60.0
	_flash.position = point + Vector3(0.0, 6.0, 0.0)
	add_child(_flash)

	# INJECTION ONLY — fire/scorch/steam emerge from the heat.
	if _ecology != null and _ecology.has_method("material_field"):
		var field: Object = _ecology.material_field()
		if field != null:
			if field.has_method("add_heat"):
				field.add_heat(point, STRIKE_HEAT, HEAT_RADIUS)
			if field.has_method("is_water_at") and field.is_water_at(point.x, point.z):
				if field.has_method("splash"):
					field.splash(point, 2.5)
				LocalAgentsAudioDirector.emit(get_tree(), "steam", point)
	if _terrain != null and _terrain.has_method("carve_sphere"):
		_terrain.carve_sphere(point, SCORCH_RADIUS)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(point, SCARE_RADIUS, 1.0)
	LocalAgentsAudioDirector.emit(get_tree(), "thunder", point)


func _process(delta: float) -> void:
	_age += delta
	if _flash != null:
		_flash.light_energy = FLASH_ENERGY * maxf(0.0, 1.0 - _age / LINGER)
	if _age >= LINGER:
		queue_free()


# A jagged emissive polyline from the sky to the point, laterally jittered (less near the ground).
func _build_bolt(point: Vector3) -> void:
	var mesh: ImmediateMesh = ImmediateMesh.new()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.9, 1.0)
	mat.emission_energy_multiplier = 8.0
	mat.albedo_color = Color(0.9, 0.95, 1.0)
	mat.vertex_color_use_as_albedo = true
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	var top: Vector3 = point + Vector3(randf_range(-14.0, 14.0), STRIKE_HEIGHT, randf_range(-14.0, 14.0))
	for s in range(SEGMENTS + 1):
		var t: float = float(s) / float(SEGMENTS)
		var base: Vector3 = top.lerp(point, t)
		var jitter: float = (1.0 - t) * 5.0                   # straightens toward the ground
		if s > 0 and s < SEGMENTS:
			base += Vector3(randf_range(-jitter, jitter), 0.0, randf_range(-jitter, jitter))
		mesh.surface_add_vertex(base)
	mesh.surface_end()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
