class_name LAMaterialEjecta3D
extends Node3D

## LAMaterialEjecta3D: the momentum/ejecta primitive of the substrate — a pressure release throws mass, the
## mass arcs under the field LABallistics integrates, and it lands as sediment plus its kinetic energy as heat.

const PARCELS_PER_EJECT: int = 6
## Crater ejecta leaves near 45 degrees from the horizontal (Melosh 1989, Impact Cratering, ch. 5), which
## is also the angle whose ballistic range is v^2/g.
const EJECTION_ANGLE_RAD: float = PI / 4.0
# Ceiling on simultaneous in-flight parcels, and the MultiMesh allocation. Fixed: it bounds the work, so it
# may not vary with a setting or a viewpoint.
const DRAW_CEIL: int = 256          # multimesh instances. Presentation: it may not reach the physics.
const DRAW_FLOOR: int = 48

var _f = null                                            # owning LAMaterialField3D
var _center: Vector3 = Vector3.ZERO                      # planet centre (radial-gravity origin)
# Parcel state as parallel arrays. Index i is one in-flight parcel; the arc itself is LABallistics'.
var _p_id: PackedInt32Array = PackedInt32Array()         # the free body carrying it
# ONE PARCEL, ONE MASS, ONE UNIT: kilograms, sized at the cell it was debited from.
var _p_kg: PackedFloat32Array = PackedFloat32Array()
var _p_src: PackedInt32Array = PackedInt32Array()        # cell the parcel was thrown out of (the debit site)
var _deposited: float = 0.0                              # cumulative kg deposited (diagnostic)
var _ejected: float = 0.0                                # cumulative kg handed to eject() (diagnostic)
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
		"ejecta_inflight": _p_kg.size(),
		"ejecta_peak": _peak_inflight,
		"ejecta_launched_kg": _ejected,
		"ejecta_deposited_kg": _deposited,
		"ejecta_impact_j": snappedf(_impact_energy_j, 0.01),
	}


func _ready() -> void:
	add_to_group("la_ballistics")
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


## A pressure release throws mineral out of the cell at `world_pos` at `speed_m_s`, in the axisymmetric
## curtain a crater throws. Returns the kinetic energy it actually launched, J: a cell cannot give up more
## mineral than it holds, so the caller sizes the rest of its energy budget against what came back.
func eject(world_pos: Vector3, mass_kg: float, speed_m_s: float) -> float:
	if _f == null or mass_kg <= 0.0 or speed_m_s <= 0.0 or is_nan(world_pos.x):
		return 0.0
	var src: int = _f.world_to_cell(world_pos)
	var unit_kg: float = _mass_unit_kg(src)
	if unit_kg <= 0.0 or src >= _f._silicate.size():
		return 0.0
	var units: float = minf(mass_kg / unit_kg, _f._silicate[src])
	if units <= 0.0:
		return 0.0
	var per_kg: float = units * unit_kg / float(PARCELS_PER_EJECT)
	var radial: Vector3 = world_pos - _center
	if radial.length_squared() < 1.0e-6:
		radial = Vector3.UP
	radial = radial.normalized()
	var tan_a: Vector3 = radial.cross(Vector3.UP)
	if tan_a.length_squared() < 1.0e-6:
		tan_a = radial.cross(Vector3.RIGHT)
	tan_a = tan_a.normalized()
	var tan_b: Vector3 = radial.cross(tan_a).normalized()
	for i in range(PARCELS_PER_EJECT):
		var az: float = TAU * float(i) / float(PARCELS_PER_EJECT)
		var horizontal: Vector3 = tan_a * cos(az) + tan_b * sin(az)
		var dir: Vector3 = radial * sin(EJECTION_ANGLE_RAD) + horizontal * cos(EJECTION_ANGLE_RAD)
		# A parcel is a cloud of grains, not a sphere: it declares no size, so nothing rams air with it.
		_p_id.append(LABallistics.drop(world_pos, dir.normalized() * speed_m_s, 0.0, 0.0))
		_p_kg.append(per_kg)
		_p_src.append(src)
		_ejected += per_kg
	if _p_kg.size() > _peak_inflight:
		_peak_inflight = _p_kg.size()
	return 0.5 * per_kg * float(PARCELS_PER_EJECT) * speed_m_s * speed_m_s


## The integrator's landing report: the debris the parcel carried out of its source cell arrives here.
func on_bodies_landed(rows: Array) -> void:
	for row in rows:
		var i: int = _p_id.find(int(row["id"]))
		if i < 0:
			continue
		_deposit(_p_src[i], row["position"], _p_kg[i], float(row["speed"]))
		_remove_parcel(i)


## A parcel that has left the box has left the ground its debris came from; the transfer never happens, so
## the mass simply stays in the cell it was debited from.
func _physics_process(_delta: float) -> void:
	var i: int = _p_kg.size() - 1
	while i >= 0:
		var st: Dictionary = LABallistics.state(_p_id[i])
		if st.is_empty() or _f.world_to_cell(st["position"]) < 0:
			LABallistics.release(_p_id[i])
			_remove_parcel(i)
		i -= 1
	_refresh_visual()


## Kilograms in one channel unit (1 mol/m^3 of silicate) at `cell`: molar mass times the cell volume.
func _mass_unit_kg(cell: int) -> float:
	if _f == null:
		return 0.0
	var vol: PackedFloat32Array = _f._grid.cell_volumes() if _f._grid != null else PackedFloat32Array()
	if cell < 0 or cell >= vol.size():
		return 0.0
	return LAPhysical.MOLAR_MASS_CASIO3_KG_MOL * vol[cell]


## A parcel lands: the debris it carried out of `src` arrives here, and its kinetic energy arrives as heat.
## Its kilograms were sized at `src`, the cell that was debited; on a graded grid the cell it lands in has
## a different volume, so the destination may not size either the transfer or the joules.
func _deposit(src: int, pos: Vector3, kg: float, speed: float) -> void:
	var unit_kg: float = _mass_unit_kg(src)
	if unit_kg <= 0.0:
		return
	_deposited += kg
	if _f._inject != null:
		_f._inject.land_ejecta(src, pos, kg / unit_kg)
	if _f._inject != null and speed > 0.0:
		var joules: float = 0.5 * kg * speed * speed
		_impact_energy_j += joules
		_f._inject.add_heat_energy(pos, joules)


func _remove_parcel(i: int) -> void:
	LABallistics.release(_p_id[i])
	var last: int = _p_kg.size() - 1
	_p_id[i] = _p_id[last]
	_p_kg[i] = _p_kg[last]
	_p_src[i] = _p_src[last]
	_p_id.remove_at(last)
	_p_kg.remove_at(last)
	_p_src.remove_at(last)


func _refresh_visual() -> void:
	if _multimesh == null:
		return
	var n: int = mini(_p_kg.size(), _draw_cap())
	for i in range(n):
		var st: Dictionary = LABallistics.state(_p_id[i])
		if st.is_empty():
			continue
		_multimesh.set_instance_transform(i, Transform3D(Basis(), st["position"]))
	_multimesh.visible_instance_count = n


# --- Diagnostics -------------------------------------------------------------

func in_flight() -> int:
	return _p_kg.size()
