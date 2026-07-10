class_name LALightningStrike
extends Node3D

## A lightning bolt — VISUAL/AUDIO ONLY. The physics (charge buildup, breakdown, the heat pulse that
## ignites wildfire via combustion, and the scare broadcast) now live in the field's emergent CHARGE
## process (LAMaterialCharge3D); the field injects the heat + broadcasts the scare itself, then fires
## this bolt via a callback. So this node just draws the jagged flash and plays the thunder, then
## self-frees. (Explicit types only — no ':=' inferred typing.)

const STRIKE_HEIGHT: float = 130.0        # bolt drawn from this high down to the point
const FLASH_ENERGY: float = 34.0
const LINGER: float = 0.7                 # seconds of afterglow before free
const SEGMENTS: int = 14

var _flash: OmniLight3D = null
var _age: float = 0.0
var _terrain: Object = null


## Kept for call-shape compatibility — VoxelDisasters still calls setup(terrain, ecology). The physics
## those args fed now lives in the field's CHARGE process; terrain is retained only so the bolt can
## resolve radial ("up") at the strike point on a spherical planet.
func setup(terrain: Object, _ecology: Object) -> void:
	_terrain = terrain


## Strike the ground at `point`: draw the bolt, flash, and thunder. No physics — that emerges in the field.
func strike(point: Vector3) -> void:
	global_position = Vector3.ZERO
	var up: Vector3 = _up_at(point)
	_build_bolt(point, up)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(0.85, 0.9, 1.0)
	_flash.light_energy = FLASH_ENERGY
	_flash.omni_range = 60.0
	_flash.position = point + up * 6.0
	add_child(_flash)
	LocalAgentsAudioDirector.emit(get_tree(), "thunder", point)


func _process(delta: float) -> void:
	_age += delta
	if _flash != null:
		_flash.light_energy = FLASH_ENERGY * maxf(0.0, 1.0 - _age / LINGER)
	if _age >= LINGER:
		queue_free()


# A jagged emissive polyline anchored at the surface strike point and built upward along `up` (radial
# on a spherical planet), laterally jittered in the local tangent plane (less near the ground).
func _build_bolt(point: Vector3, up: Vector3) -> void:
	# Two orthonormal tangents spanning the plane perpendicular to `up`, so lateral jitter hugs the
	# surface rather than world XZ (which would only align at the poles).
	var t1: Vector3 = up.cross(Vector3.RIGHT)
	if t1.length_squared() < 1.0e-6:
		t1 = up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	var mesh: ImmediateMesh = ImmediateMesh.new()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.9, 1.0)
	mat.emission_energy_multiplier = 8.0
	mat.albedo_color = Color(0.9, 0.95, 1.0)
	mat.vertex_color_use_as_albedo = true
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	var top: Vector3 = point + up * STRIKE_HEIGHT + t1 * randf_range(-14.0, 14.0) + t2 * randf_range(-14.0, 14.0)
	for s in range(SEGMENTS + 1):
		var t: float = float(s) / float(SEGMENTS)
		var base: Vector3 = top.lerp(point, t)
		var jitter: float = (1.0 - t) * 5.0                   # straightens toward the ground
		if s > 0 and s < SEGMENTS:
			base += t1 * randf_range(-jitter, jitter) + t2 * randf_range(-jitter, jitter)
		mesh.surface_add_vertex(base)
	mesh.surface_end()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# Radial "up" at `pos` on the spherical planet: the dominant gravity body's outward normal, falling
# back to the terrain's own normal, then world +Y. Mirrors the idiom in Meteor._up_at / Creature.
func _up_at(pos: Vector3) -> Vector3:
	var b: Object = LAGravity.dominant_body(get_tree(), pos) if is_inside_tree() else null
	if b != null and b.has_method("center"):
		var r: Vector3 = pos - (b.center() as Vector3)
		if r.length() > 0.001:
			return r.normalized()
	if _terrain != null and _terrain.has_method("up_at"):
		return _terrain.up_at(pos)
	return Vector3.UP
