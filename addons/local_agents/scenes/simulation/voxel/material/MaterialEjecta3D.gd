class_name LAMaterialEjecta3D
extends Node3D

## LAMaterialEjecta3D — THE KEYSTONE momentum/ejecta primitive of the substrate. When a pressure release throws
## matter (a volcano bomb, a meteor's debris, a geyser/steam blast), that matter is just a PARCEL of mass+heat
## given momentum: it arcs under the planet's RADIAL gravity and, on landing, re-deposits its mass + heat into
## the field at the impact cell. There is no "bomb code" — every named thrown-debris phenomenon is this ONE
## primitive with different seed parameters. Disaster actors DISSOLVE into a single eject() call.
##
## PHYSICS (CPU, serial — parcels are few, like actors; the per-cell field CAs stay on the GPU):
##   • eject(world_pos, mass, energy, dir_bias) launches a small spray of parcels outward (radial + bias +
##     cone), speed scaled from `energy`.
##   • each step every parcel integrates ballistically under radial gravity a = −g·r̂(pos).
##   • a parcel LANDS when it has risen and fallen back to (or below) its launch radius while descending; it
##     then deposits: add_lava at the impact (a conserving bedrock→lava phase move, so mineral_total stays
##     BOUNDED — the parcel melts an impact blob rather than fabricating mass) + add_heat (the glowing scar).
##
## RENDER: a MultiMeshInstance3D of small emissive embers (GPU-instanced, ONE draw call) whose per-instance
## transforms track the live parcels — the field-driven glowing-ejecta visual. (A discrete-parcel MultiMesh is
## the right tool here; WaterParticles' 12k field-texture dome is for the ambient atmosphere, not tracked debris.)
## (Explicit types only — no ':=' inferred typing.)

# Radial gravity pulling parcels back to the surface (units/s²). Sized so a mid-energy bomb arcs for a few
# seconds, not a geological age (iterate-fast: a visible arc within a short verification run).
const GRAVITY: float = 22.0
# Parcels launched per eject() call (a spray, not a single dot). Kept small — ejecta are sparse events.
const PARCELS_PER_EJECT: int = 6
# Speed = clamp(sqrt(2·energy/mass)·GAIN) — a ballistic launch speed from the release energy. The max is kept
# modest so a parcel's arc completes in a couple of seconds (visible + it re-deposits within a short run).
const SPEED_GAIN: float = 1.0
const SPEED_MIN: float = 6.0
const SPEED_MAX: float = 30.0
# Sideways spread of the spray around the launch direction (radians of cone half-angle).
const CONE: float = 0.5
# Hard cap on simultaneous in-flight parcels (safety + perf; a runaway can't accumulate unbounded work/draws).
const MAX_PARCELS: int = 240
# Safety lifetime — a parcel that never lands (numerical edge) is culled after this many seconds.
const MAX_LIFETIME: float = 12.0
# Heat deposited at the landing per unit parcel mass (°C), over this radius — the glowing impact scar.
const LAND_HEAT_PER_MASS: float = 400.0
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
var _deposited: float = 0.0                              # cumulative mass deposited (diagnostic)
var _ejected: float = 0.0                                # cumulative mass launched (diagnostic)

var _mm: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null


func setup(field) -> void:
	_f = field
	_center = field._origin
	# The module owns its telemetry (like LASimReport's other sources) — keeps the field hub thin.
	LASimReport.register(Callable(self, "report"))


## Ejecta aggregates for SIM_REPORT — in-flight count + cumulative launched/deposited mass (the conservation
## spot check: deposited tracks launched, nothing runs away).
func report() -> Dictionary:
	return {"ejecta_inflight": _p_mass.size(), "ejecta_launched": _ejected, "ejecta_deposited": _deposited}


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
	_multimesh.instance_count = MAX_PARCELS
	_multimesh.visible_instance_count = 0
	_mm = MultiMeshInstance3D.new()
	_mm.name = "EjectaEmbers"
	_mm.multimesh = _multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


## THE INJECT SEAM. Launch a spray of ejecta parcels carrying `mass` (mineral) + heat from `world_pos`, thrown
## with `energy` outward along the radial blended with `dir_bias`. Shared by volcano bombs, meteor debris, and
## geyser/steam blasts — the ONE momentum primitive. No-op if the field is not ready.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _f == null or mass <= 0.0 or energy <= 0.0 or is_nan(world_pos.x):
		return
	var radial: Vector3 = world_pos - _center
	if radial.length_squared() < 1.0e-6:
		radial = Vector3.UP
	radial = radial.normalized()
	var base_speed: float = clampf(sqrt(2.0 * energy / mass) * SPEED_GAIN, SPEED_MIN, SPEED_MAX)
	var launch_dir: Vector3 = (radial + dir_bias).normalized() if (radial + dir_bias).length_squared() > 1.0e-6 else radial
	var per_mass: float = mass / float(PARCELS_PER_EJECT)
	var launch_r: float = (world_pos - _center).length()
	# Build a tangent basis for the spray cone.
	var tan_a: Vector3 = launch_dir.cross(Vector3.UP)
	if tan_a.length_squared() < 1.0e-6:
		tan_a = launch_dir.cross(Vector3.RIGHT)
	tan_a = tan_a.normalized()
	var tan_b: Vector3 = launch_dir.cross(tan_a).normalized()
	for i in range(PARCELS_PER_EJECT):
		if _p_mass.size() >= MAX_PARCELS:
			break
		var ang: float = randf() * TAU
		var spread: float = randf() * CONE
		var dir: Vector3 = (launch_dir * cos(spread) + (tan_a * cos(ang) + tan_b * sin(ang)) * sin(spread)).normalized()
		var speed: float = base_speed * randf_range(0.7, 1.15)
		_p_pos.append(world_pos)
		_p_vel.append(dir * speed)
		_p_mass.append(per_mass)
		_p_launch_r.append(launch_r)
		_p_age.append(0.0)
		_p_risen.append(0)
		_ejected += per_mass


func _process(delta: float) -> void:
	if _p_mass.size() == 0:
		if _multimesh != null and _multimesh.visible_instance_count != 0:
			_multimesh.visible_instance_count = 0
		return
	var dt: float = minf(delta, 0.05)                     # clamp to keep the arc stable under a frame spike
	var i: int = _p_mass.size() - 1
	while i >= 0:
		var pos: Vector3 = _p_pos[i]
		var vel: Vector3 = _p_vel[i]
		var radial: Vector3 = pos - _center
		var r: float = radial.length()
		var r_hat: Vector3 = radial / r if r > 1.0e-6 else Vector3.UP
		vel += -r_hat * GRAVITY * dt
		pos += vel * dt
		var age: float = _p_age[i] + dt
		var r_now: float = (pos - _center).length()
		if r_now > _p_launch_r[i] + 1.0:
			_p_risen[i] = 1
		var descending: bool = vel.dot(r_hat) < 0.0
		var landed: bool = (_p_risen[i] == 1 and descending and r_now <= _p_launch_r[i]) or age > MAX_LIFETIME
		if landed:
			_deposit(pos, _p_mass[i])
			_remove_parcel(i)
		else:
			_p_pos[i] = pos
			_p_vel[i] = vel
			_p_age[i] = age
		i -= 1
	_refresh_visual()


# Deposit a landed parcel's mass + heat into the field. add_lava is a CONSERVING bedrock→lava phase move (it
# melts a blob of the impact column's bedrock), so mineral_total stays BOUNDED — the parcel relocates/melts
# mass rather than fabricating it. add_heat paints the glowing scar (and can ignite fuel — emergent wildfire).
func _deposit(pos: Vector3, mass: float) -> void:
	_deposited += mass
	if _f.has_method("add_lava"):
		_f.add_lava(pos, mass)
	if _f._inject != null:
		_f._inject.add_heat(pos, LAND_HEAT_PER_MASS * mass, LAND_HEAT_R)


func _remove_parcel(i: int) -> void:
	var last: int = _p_mass.size() - 1
	_p_pos[i] = _p_pos[last]
	_p_vel[i] = _p_vel[last]
	_p_mass[i] = _p_mass[last]
	_p_launch_r[i] = _p_launch_r[last]
	_p_age[i] = _p_age[last]
	_p_risen[i] = _p_risen[last]
	_p_pos.remove_at(last)
	_p_vel.remove_at(last)
	_p_mass.remove_at(last)
	_p_launch_r.remove_at(last)
	_p_age.remove_at(last)
	_p_risen.remove_at(last)


func _refresh_visual() -> void:
	if _multimesh == null:
		return
	var n: int = mini(_p_mass.size(), MAX_PARCELS)
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
