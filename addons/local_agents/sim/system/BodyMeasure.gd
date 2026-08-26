class_name LABodyMeasure
extends RefCounted

## THE BODY'S BULK PROPERTIES, MEASURED in one walk of the field: mass is the matter present, radius is
## where it ends, inertia is how it is distributed, gas constant is R over the molar mass of the air.
## Negative is UNMEASURED, and a reader refuses what it was sizing rather than assuming a planet.

var mass_kg: float = -1.0
var surface_r_m: float = -1.0
var inertia_kg_m2: float = -1.0
var gas_constant_j_kgk: float = -1.0
## Channel -> kilograms it holds. WHAT THE BODY IS MADE OF, which is the only honest answer to how heavy
## it is: a total nobody can decompose cannot say which channel is wrong when it disagrees with the seed.
var mass_by_channel: Dictionary = {}


func measured() -> bool:
	return mass_kg > 0.0 and surface_r_m > 0.0


## ONE pass. `spin_axis` is the direction the seeded angular momentum points, so the inertia is about the
## axis the body actually turns on.
## LA_APPROX: seal_time_inertia
func measure(field, spin_axis: Vector3) -> void:
	mass_kg = -1.0
	surface_r_m = -1.0
	inertia_kg_m2 = -1.0
	gas_constant_j_kgk = -1.0
	mass_by_channel = {}
	if field == null or field._grid == null or field._cell_count <= 0:
		return
	if field._solid.size() != field._cell_count:
		return
	var mirrors: Array = LAFieldCellMass3D.mirrors(field)
	var gases: Array = LAFieldCellMass3D.gas_mirrors(field)
	if mirrors.is_empty():
		return
	var names: PackedStringArray = LAFieldCellMass3D.mirror_names(field)
	var per: PackedFloat64Array = PackedFloat64Array()
	per.resize(mirrors.size())
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var n: Vector3 = spin_axis.normalized()
	var m_acc: float = 0.0
	var r_max: float = 0.0
	var i_acc: float = 0.0
	var moles: float = 0.0
	var gas_kg: float = 0.0
	for c in field._cell_count:
		var vol: float = field._grid.cell_volume(c)
		var r: Vector3 = field._grid.cell_world_pos(c) - centre
		var cell_kg: float = 0.0
		for k in mirrors.size():
			var kg: float = maxf(mirrors[k][0][c], 0.0) * float(mirrors[k][1]) * vol
			per[k] += kg
			cell_kg += kg
		m_acc += cell_kg
		var perp: Vector3 = r - n * r.dot(n)
		i_acc += cell_kg * perp.length_squared()
		if field._solid[c] != 0:
			r_max = maxf(r_max, r.length())
			continue
		for pair in gases:
			var g_mol: float = maxf(pair[0][c], 0.0) * vol
			moles += g_mol
			gas_kg += g_mol * float(pair[1])
	if m_acc <= 0.0 or r_max <= 0.0:
		return
	mass_kg = m_acc
	for k in names.size():
		mass_by_channel[names[k]] = per[k]
	surface_r_m = r_max
	inertia_kg_m2 = i_acc
	if moles > 0.0 and gas_kg > 0.0:
		gas_constant_j_kgk = LAPhysical.GAS_CONSTANT_J_MOL_K * moles / gas_kg


## Surface gravity, m/s^2, from the measured mass and radius. NAN while unmeasured.
func surface_gravity_m_s2() -> float:
	if not measured():
		return NAN
	return LAPhysical.GRAVITATIONAL_CONSTANT * mass_kg / (surface_r_m * surface_r_m)


## Spin rate from the seeded angular momentum over the measured inertia, rad/s. NAN while unmeasured.
func angular_velocity_rad_s(spin_l_kg_m2_s: float) -> float:
	return NAN if inertia_kg_m2 <= 0.0 else spin_l_kg_m2_s / inertia_kg_m2


## Scale height of this atmosphere at `temp_c`, metres. NAN while unmeasured.
func scale_height_m(temp_c: float) -> float:
	if gas_constant_j_kgk <= 0.0 or not measured():
		return NAN
	return gas_constant_j_kgk * (temp_c + LAPhysical.KELVIN_OFFSET) / surface_gravity_m_s2()
