class_name LAMaterialEjecta3D
extends Node3D

## LAMaterialEjecta3D — THE KEYSTONE momentum/ejecta primitive of the substrate. When a pressure release throws
## matter (a volcano bomb, a meteor's debris, a geyser/steam blast), that matter is just a PARCEL of mass+heat
## given momentum: it arcs under the planet's RADIAL gravity and, on landing, re-deposits its mass + heat into
## the field at the impact cell. There is no "bomb code" — every named thrown-debris phenomenon is this ONE
## primitive with different seed parameters. Disaster actors DISSOLVE into a single eject() call.
##
## PERF — BOUNDED + ACTIVITY-LOD (a meteor volley must NOT tank the frame-rate). Two levers, per the repo's
## Big-O / bubbles-of-compute mandate, layered on the emergent physics WITHOUT losing it:
##   1. GLOBAL BUDGET/POOL. There is a hard cap on TOTAL live parcels, quality-scaled (Potato/Low small →
##      Ultra large) from the published `la_effects_scale`. At the cap a new impact spawns FEWER airborne
##      parcels; the leftover mass is DEPOSITED IMMEDIATELY at the impact point (conserved — nothing vanishes),
##      so a sustained volley plateaus at the budget instead of growing debris fields without bound.
##   2. ACTIVITY-LOD FAST-SETTLE. Only parcels that are near AND in the camera's view stay airborne and tick
##      (the compute bubble). A parcel that is off-screen or far from the camera SETTLES IMMEDIATELY — it still
##      deposits its mass/heat (conserved), it just skips the invisible arc animation. An impact whose launch
##      point is off-screen spawns ZERO parcels and deposits in one shot. Airborne work therefore scales with
##      what the player can actually see, not with how many meteors fell.
## Neither lever changes the physics: airborne parcels still carry real momentum and every gram of mass/heat
## still redeposits into the field (mass conserved). Only the COUNT is bounded and invisible arcs are skipped.
##
## PHYSICS (CPU, serial — airborne parcels are FEW by construction now, like actors; the per-cell field CAs stay
## on the GPU). The per-parcel step is data-parallel, but the hard budget + view-LOD keep the live count to a
## few dozen, so CPU ballistic integration costs a fraction of a millisecond — a GPU port would only add a
## landing-event readback hop (against the minimize-CPU↔GPU-hops rule) for no measurable win. The CPU form is
## the right tool at this bounded scale.
##   • eject(world_pos, mass, energy, dir_bias) launches a small spray of parcels outward (radial + bias +
##     cone), speed scaled from `energy` — subject to the budget + view-LOD gates above.
##   • each step every AIRBORNE parcel integrates ballistically under radial gravity a = −g·r̂(pos).
##   • a parcel LANDS when it has risen and fallen back to (or below) its launch radius while descending (or is
##     culled by the LOD/lifetime gate); it then deposits: add_lava at the impact (a conserving bedrock→lava
##     phase move, so mineral_total stays BOUNDED — the parcel melts an impact blob rather than fabricating
##     mass) + add_heat (the glowing scar).
##
## RENDER: a MultiMeshInstance3D of small emissive embers (GPU-instanced, ONE draw call) whose per-instance
## transforms track the live parcels — the field-driven glowing-ejecta visual. The MultiMesh is allocated to the
## absolute ceiling once; visible_instance_count follows the live (budgeted) count.
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
# ABSOLUTE ceiling on simultaneous in-flight parcels — the MultiMesh allocation and the hard cap any quality
# preset can reach (Ultra). The LIVE budget (_budget) is quality-scaled down from this; a runaway can never
# accumulate unbounded work/draws regardless of how many impacts fire.
const BUDGET_CEIL: int = 256
# Floor so even the lowest preset still shows a little ejecta rather than none.
const BUDGET_FLOOR: int = 48
# Distance (world units) beyond which a parcel is FAR and settles immediately (skips the arc). ~1.8× a default
# planet radius: embers this far from the camera are sub-pixel, so arcing them is wasted work + draws.
const EJECTA_LOD_RADIUS: float = 450.0
# Safety lifetime — a parcel that never lands (numerical edge) is culled after this many seconds.
const MAX_LIFETIME: float = 12.0
# Heat deposited at the landing per unit parcel mass (°C), over this radius — the glowing impact scar.
const LAND_HEAT_PER_MASS: float = 400.0
const LAND_HEAT_R: float = 8.0

var _f = null                                            # owning LAMaterialField3D
var _center: Vector3 = Vector3.ZERO                      # planet centre (radial-gravity origin)
var _budget: int = BUDGET_CEIL                           # live quality-scaled cap on airborne parcels
# Parcel state as parallel arrays (avoids per-parcel object churn). Index i is one in-flight parcel.
var _p_pos: Array = []                                   # Vector3 world position
var _p_vel: Array = []                                   # Vector3 world velocity
var _p_mass: PackedFloat32Array = PackedFloat32Array()   # carried mineral mass
var _p_launch_r: PackedFloat32Array = PackedFloat32Array()  # launch radius (landing test)
var _p_age: PackedFloat32Array = PackedFloat32Array()
var _p_risen: PackedByteArray = PackedByteArray()        # 1 once the parcel has climbed above launch radius
var _deposited: float = 0.0                              # cumulative mass deposited (diagnostic)
var _ejected: float = 0.0                                # cumulative mass handed to eject() (diagnostic)
var _peak_inflight: int = 0                              # high-water mark of live parcels (plateau check)

# Active camera, cached once per render frame (a single get_camera_3d() lookup shared by every parcel, not one
# per parcel — mirrors LACreature._camera_pos).
var _cam_frame: int = -1
var _cam: Camera3D = null

var _mm: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null


func setup(field) -> void:
	_f = field
	_center = field._origin
	_budget = _resolve_budget()
	# The module owns its telemetry (like LASimReport's other sources) — keeps the field hub thin.
	LASimReport.register(Callable(self, "report"))


## Quality-scaled live budget: BUDGET_CEIL × the published effects scale (0.35 Low → 0.65 Medium → 1.0
## High/Ultra), clamped to [floor, ceil]. Re-read from the Engine meta so a mid-game settings re-apply
## (LAVoxelSettingsApplier.publish_globals) takes effect on the next impact without re-wiring.
func _resolve_budget() -> int:
	var scale: float = float(Engine.get_meta("la_effects_scale", 0.65)) if Engine.has_meta("la_effects_scale") else 0.65
	return clampi(int(round(float(BUDGET_CEIL) * clampf(scale, 0.0, 1.0))), BUDGET_FLOOR, BUDGET_CEIL)


## Ejecta aggregates for SIM_REPORT — in-flight count + budget + peak + cumulative launched/deposited mass (the
## conservation + plateau spot check: deposited tracks launched, in-flight never exceeds budget, nothing runs
## away).
func report() -> Dictionary:
	return {
		"ejecta_inflight": _p_mass.size(),
		"ejecta_budget": _budget,
		"ejecta_peak": _peak_inflight,
		"ejecta_launched": _ejected,
		"ejecta_deposited": _deposited,
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
	_multimesh.instance_count = BUDGET_CEIL
	_multimesh.visible_instance_count = 0
	_mm = MultiMeshInstance3D.new()
	_mm.name = "EjectaEmbers"
	_mm.multimesh = _multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


# Active camera cached once per render frame (headless → null; then all parcels keep the default arc, still
# bounded by the budget). Mirrors the Fish/Creature shared-lookup pattern.
func _camera() -> Camera3D:
	var f: int = int(Engine.get_frames_drawn())
	if f != _cam_frame:
		_cam_frame = f
		var vp: Viewport = get_viewport()
		_cam = vp.get_camera_3d() if vp != null else null
	return _cam


# Should a parcel at `pos` stay AIRBORNE (arc) rather than settle immediately? Only if it is near the camera
# AND inside its view frustum — the compute bubble tracks what the player can see. No camera (headless) → yes
# (keep the arc; still budget-bounded). This is the activity-LOD gate shared by eject() and the per-frame step.
func _airborne_visible(cam: Camera3D, pos: Vector3) -> bool:
	if cam == null or not is_instance_valid(cam):
		return true
	if cam.global_position.distance_squared_to(pos) > EJECTA_LOD_RADIUS * EJECTA_LOD_RADIUS:
		return false
	return cam.is_position_in_frustum(pos)


## THE INJECT SEAM. Launch a spray of ejecta parcels carrying `mass` (mineral) + heat from `world_pos`, thrown
## with `energy` outward along the radial blended with `dir_bias`. Shared by volcano bombs, meteor debris, and
## geyser/steam blasts — the ONE momentum primitive. Bounded by the global budget + view-LOD (see class doc);
## all mass is conserved either as an arcing parcel or an immediate deposit. No-op if the field is not ready.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _f == null or mass <= 0.0 or energy <= 0.0 or is_nan(world_pos.x):
		return
	_budget = _resolve_budget()                          # live re-read (mid-game settings re-apply)
	var cam: Camera3D = _camera()
	var per_mass: float = mass / float(PARCELS_PER_EJECT)
	# ACTIVITY-LOD at the source: an off-screen / far impact spawns NO arcing parcels — deposit its whole mass
	# in one shot (conserved, no invisible arcs). The dominant win for a volley the player is not looking at.
	if not _airborne_visible(cam, world_pos):
		_ejected += mass
		_deposit(world_pos, mass)
		return
	var radial: Vector3 = world_pos - _center
	if radial.length_squared() < 1.0e-6:
		radial = Vector3.UP
	radial = radial.normalized()
	var base_speed: float = clampf(sqrt(2.0 * energy / mass) * SPEED_GAIN, SPEED_MIN, SPEED_MAX)
	var launch_dir: Vector3 = (radial + dir_bias).normalized() if (radial + dir_bias).length_squared() > 1.0e-6 else radial
	var launch_r: float = (world_pos - _center).length()
	# Build a tangent basis for the spray cone.
	var tan_a: Vector3 = launch_dir.cross(Vector3.UP)
	if tan_a.length_squared() < 1.0e-6:
		tan_a = launch_dir.cross(Vector3.RIGHT)
	tan_a = tan_a.normalized()
	var tan_b: Vector3 = launch_dir.cross(tan_a).normalized()
	for i in range(PARCELS_PER_EJECT):
		# GLOBAL BUDGET: at the cap, spawn FEWER parcels — deposit this share's mass immediately at the impact
		# (conserved). The live count therefore plateaus at _budget through any volley, never growing unbounded.
		if _p_mass.size() >= _budget:
			_ejected += per_mass
			_deposit(world_pos, per_mass)
			continue
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
	if _p_mass.size() > _peak_inflight:
		_peak_inflight = _p_mass.size()


func _process(delta: float) -> void:
	if _p_mass.size() == 0:
		if _multimesh != null and _multimesh.visible_instance_count != 0:
			_multimesh.visible_instance_count = 0
		return
	var dt: float = minf(delta, 0.05)                     # clamp to keep the arc stable under a frame spike
	var cam: Camera3D = _camera()
	var i: int = _p_mass.size() - 1
	while i >= 0:
		var pos: Vector3 = _p_pos[i]
		# ACTIVITY-LOD FAST-SETTLE: a parcel that has drifted off-screen or far from the camera settles NOW —
		# deposit its mass/heat (conserved) and retire it, skipping the invisible arc. Only visible parcels tick.
		if not _airborne_visible(cam, pos):
			_deposit(pos, _p_mass[i])
			_remove_parcel(i)
			i -= 1
			continue
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
	var n: int = mini(_p_mass.size(), BUDGET_CEIL)
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
