class_name LAMaterialEjecta3D
extends Node3D

## LAMaterialEjecta3D: the momentum/ejecta primitive of the substrate — a pressure release throws mass, the
## mass arcs under the N-body field, and it lands as sediment plus its own kinetic energy as heat.

const PARCELS_PER_EJECT: int = 6
# Ballistic launch speed from the release energy: clamp(sqrt(2*energy/mass)*GAIN).
const SPEED_GAIN: float = 1.0
const SPEED_MIN: float = 6.0
const SPEED_MAX: float = 30.0
# Sideways spread of the spray around the launch direction (radians of cone half-angle).
const CONE: float = 0.5
# Ceiling on simultaneous in-flight parcels, and the MultiMesh allocation. Fixed: it bounds the work, so it
# may not vary with a setting or a viewpoint.
const DRAW_CEIL: int = 256          # multimesh instances. Presentation: it may not reach the physics.
const DRAW_FLOOR: int = 48
const MAX_LIFETIME: float = 12.0           # s; a parcel that never lands is culled
const LAND_HEAT_R: float = 8.0

var _f = null                                            # owning LAMaterialField3D
var _center: Vector3 = Vector3.ZERO                      # planet centre (radial-gravity origin)
# Parcel state as parallel arrays (avoids per-parcel object churn). Index i is one in-flight parcel.
var _p_pos: Array = []                                   # Vector3 world position
var _p_vel: Array = []                                   # Vector3 world velocity
var _p_mass: PackedFloat32Array = PackedFloat32Array()   # carried mineral mass
var _p_launch_r: PackedFloat32Array = PackedFloat32Array()  # launch radius (landing test)
var _p_age: PackedFloat32Array = PackedFloat32Array()
var _p_risen: PackedByteArray = PackedByteArray()        # 1 once the parcel has climbed above launch radius
var _p_src: PackedInt32Array = PackedInt32Array()        # cell the parcel was thrown out of (the debit site)
var _deposited: float = 0.0                              # cumulative mass deposited (diagnostic)
var _ejected: float = 0.0                                # cumulative mass handed to eject() (diagnostic)
var _impact_energy_j: float = 0.0                        # cumulative landing kinetic energy given to the field
var _peak_inflight: int = 0                              # high-water mark of live parcels (plateau check)

var _mm: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null


func setup(field) -> void:
	_f = field
	_center = field._origin
	# The module owns its telemetry (like LASimReport's other sources) — keeps the field hub thin.
	LASimReport.register(Callable(self, "report"))


## How many parcels are DRAWN: DRAW_CEIL scaled by the published effects scale, floored. Presentation only —
## every live parcel is integrated regardless, and how many are drawn may not reach the arc.
func _draw_cap() -> int:
	var scale: float = float(Engine.get_meta("la_effects_scale", 0.65)) if Engine.has_meta("la_effects_scale") else 0.65
	return clampi(int(round(float(DRAW_CEIL) * clampf(scale, 0.0, 1.0))), DRAW_FLOOR, DRAW_CEIL)


## Ejecta aggregates for SIM_REPORT: launched must track deposited.
func report() -> Dictionary:
	return {
		"ejecta_inflight": _p_mass.size(),
		"ejecta_peak": _peak_inflight,
		"ejecta_launched": _ejected,
		"ejecta_deposited": _deposited,
		"ejecta_impact_j": snappedf(_impact_energy_j, 0.01),
	}


func _ready() -> void:
	_build_visual()


# A small emissive ember mesh, GPU-instanced via MultiMesh (one draw call for all live parcels).
func _build_visual() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 1.2
	mesh.height = 2.4
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.12)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.15)
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	_multimesh.mesh = mesh
	_multimesh.instance_count = DRAW_CEIL
	_multimesh.visible_instance_count = 0
	_mm = MultiMeshInstance3D.new()
	_mm.name = "EjectaEmbers"
	_mm.multimesh = _multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _f == null or mass <= 0.0 or energy <= 0.0 or is_nan(world_pos.x):
		return
	var per_mass: float = mass / float(PARCELS_PER_EJECT)
	# A parcel deposited without flying still carries the energy it was thrown with.
	var base_speed: float = clampf(sqrt(2.0 * energy / mass) * SPEED_GAIN, SPEED_MIN, SPEED_MAX)
	var src: int = _f.world_to_cell(world_pos)
	var radial: Vector3 = world_pos - _center
	if radial.length_squared() < 1.0e-6:
		radial = Vector3.UP
	radial = radial.normalized()
	var launch_dir: Vector3 = (radial + dir_bias).normalized() if (radial + dir_bias).length_squared() > 1.0e-6 else radial
	var launch_r: float = (world_pos - _center).length()
	# Build a tangent basis for the spray cone.
	var tan_a: Vector3 = launch_dir.cross(Vector3.UP)
	if tan_a.length_squared() < 1.0e-6:
		tan_a = launch_dir.cross(Vector3.RIGHT)
	tan_a = tan_a.normalized()
	var tan_b: Vector3 = launch_dir.cross(tan_a).normalized()
	for i in range(PARCELS_PER_EJECT):
		var rng: LASimRng = LASimRng.shared()
		var ang: float = rng.randf() * TAU
		var spread: float = rng.randf() * CONE
		var dir: Vector3 = (launch_dir * cos(spread) + (tan_a * cos(ang) + tan_b * sin(ang)) * sin(spread)).normalized()
		var speed: float = base_speed * rng.randf_range(0.7, 1.15)
		_p_pos.append(world_pos)
		_p_vel.append(dir * speed)
		_p_mass.append(per_mass)
		_p_launch_r.append(launch_r)
		_p_age.append(0.0)
		_p_risen.append(0)
		_p_src.append(src)
		_ejected += per_mass
	if _p_mass.size() > _peak_inflight:
		_peak_inflight = _p_mass.size()


func _physics_process(delta: float) -> void:
	if _p_mass.size() == 0:
		if _multimesh != null and _multimesh.visible_instance_count != 0:
			_multimesh.visible_instance_count = 0
		return
	var dt: float = delta
	var i: int = _p_mass.size() - 1
	while i >= 0:
		var pos: Vector3 = _p_pos[i]
		var vel: Vector3 = _p_vel[i]
		var radial: Vector3 = pos - _center
		var r: float = radial.length()
		var r_hat: Vector3 = radial / r if r > 1.0e-6 else Vector3.UP
		# The N-body field, not a local constant: the same call the meteor's coast uses, so a parcel arcs
		# under the planet, gets bent by the moon on a close pass, and feels the star's tide out at range.
		vel += LAGravity.acceleration_at(get_tree(), pos) * dt
		pos += vel * dt
		var age: float = _p_age[i] + dt
		var r_now: float = (pos - _center).length()
		if r_now > _p_launch_r[i] + 1.0:
			_p_risen[i] = 1
		var descending: bool = vel.dot(r_hat) < 0.0
		var landed: bool = (_p_risen[i] == 1 and descending and r_now <= _p_launch_r[i]) or age > MAX_LIFETIME
		if landed:
			_deposit(_p_src[i], pos, _p_mass[i], vel.length())
			_remove_parcel(i)
		else:
			_p_pos[i] = pos
			_p_vel[i] = vel
			_p_age[i] = age
		i -= 1
	_refresh_visual()


## Kilograms in one mass unit at `cell`. The grid is metres, so the cell volume is already m^3.
func _mass_unit_kg(cell: int) -> float:
	if _f == null:
		return 0.0
	var vol: PackedFloat32Array = LAMaterialFieldCellVolume3D.of(_f)
	if cell < 0 or cell >= vol.size():
		return 0.0
	var max_mass: float = maxf(float(_f.MAX_MASS), 0.0001)
	return LAPhysical.ROCK_DENSITY_KG_M3 * vol[cell] / max_mass


## A parcel lands: the debris it carried out of `src` arrives here, and its kinetic energy arrives as heat.
## Impact ejecta is pulverised rock, so it lands as `sediment` — nothing here asserts that it is molten.
func _deposit(src: int, pos: Vector3, mass: float, speed: float) -> void:
	_deposited += mass
	if _f._inject != null:
		_f._inject.land_ejecta(src, pos, mass)
	if _f._inject != null and speed > 0.0:
		var joules: float = 0.5 * mass * _mass_unit_kg(_f.world_to_cell(pos)) * speed * speed
		_impact_energy_j += joules
		_f._inject.add_heat_energy(pos, joules, LAND_HEAT_R)


func _remove_parcel(i: int) -> void:
	var last: int = _p_mass.size() - 1
	_p_pos[i] = _p_pos[last]
	_p_vel[i] = _p_vel[last]
	_p_mass[i] = _p_mass[last]
	_p_launch_r[i] = _p_launch_r[last]
	_p_age[i] = _p_age[last]
	_p_risen[i] = _p_risen[last]
	_p_src[i] = _p_src[last]
	_p_pos.remove_at(last)
	_p_vel.remove_at(last)
	_p_mass.remove_at(last)
	_p_launch_r.remove_at(last)
	_p_age.remove_at(last)
	_p_risen.remove_at(last)
	_p_src.remove_at(last)


func _refresh_visual() -> void:
	if _multimesh == null:
		return
	var n: int = mini(_p_mass.size(), _draw_cap())
	for i in range(n):
		var t: Transform3D = Transform3D(Basis(), _p_pos[i])
		_multimesh.set_instance_transform(i, t)
	_multimesh.visible_instance_count = n


# --- Diagnostics -------------------------------------------------------------

func in_flight() -> int:
	return _p_mass.size()

func ejected_total() -> float:
	return _ejected

func deposited_total() -> float:
	return _deposited
