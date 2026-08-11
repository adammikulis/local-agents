class_name LAMaterialEjecta3D
extends Node3D

## WHERE MASS LANDS MAY NOT DEPEND ON WHERE THE CAMERA IS POINTED.
##
## LOD may skip DRAWING, never where matter ends up. Parcels always arc; the multimesh is culled.

## LAMaterialEjecta3D: THE KEYSTONE momentum/ejecta primitive of the substrate. When a pressure release throws

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
# Safety lifetime — a parcel that never lands (numerical edge) is culled after this many seconds.
const MAX_LIFETIME: float = 12.0
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
var _impact_energy_j: float = 0.0                        # cumulative landing kinetic energy given to the field
var _peak_inflight: int = 0                              # high-water mark of live parcels (plateau check)

# Active camera, cached once per render frame (a single get_camera_3d() lookup shared by every parcel, not one
# per parcel — mirrors LocalAgentCreature._camera_pos).

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
	_multimesh.instance_count = BUDGET_CEIL
	_multimesh.visible_instance_count = 0
	_mm = MultiMeshInstance3D.new()
	_mm.name = "EjectaEmbers"
	_mm.multimesh = _multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


# --- Diagnostics -------------------------------------------------------------

func in_flight() -> int:
	return _p_mass.size()

func ejected_total() -> float:
	return _ejected

func deposited_total() -> float:
	return _deposited
