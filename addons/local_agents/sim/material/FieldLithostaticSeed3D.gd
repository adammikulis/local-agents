class_name LAFieldLithostaticSeed
extends RefCounted

## Rock at depth is COMPRESSED. A uniform self-gravitating sphere has p(r) = (2/3) pi G rho^2 (R^2 - r^2);
## inverting the linear condensed EOS there, v = v0 (1 - (p - p_std)/K), gives the fill v0/v.
static func compress(field) -> float:
	if field == null or field._grid == null or field._silicate.size() != field._cell_count:
		return 0.0
	var rho: float = float(LASubstances.table().get("silicate", {}).get("density", 0.0))
	var k_pa: float = LAPhysical.ROCK_BULK_MODULUS_PA
	if rho <= 0.0 or k_pa <= 0.0:
		return 0.0
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var r_max: float = 0.0
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		r_max = maxf(r_max, (field._grid.cell_world_pos(c) - centre).length())
	if r_max <= 0.0:
		return 0.0
	var coeff: float = (2.0 / 3.0) * PI * LAPhysical.GRAVITATIONAL_CONSTANT * rho * rho
	var added: float = 0.0
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		var r: float = (field._grid.cell_world_pos(c) - centre).length()
		var p: float = coeff * maxf(r_max * r_max - r * r, 0.0)
		var strain: float = (p - LAPhysical.STANDARD_PRESSURE_PA) / k_pa
		# A linear EOS has no answer past its own modulus; that is the model's limit, not a symptom.
		if strain >= 1.0:
			continue
		var fill: float = 1.0 / (1.0 - strain)
		added += fill - field._silicate[c]
		field._silicate[c] = fill
	return added


## AN ATMOSPHERE IS A SHELL ON A SURFACE, not a uniform fill of the box: gas falls off with altitude
## by the barometric relation about the mean solid radius, scale height from the seeded state.
static func shape_atmosphere(field, temp_c: float) -> void:
	if field == null or field._grid == null or field._solid.size() != field._cell_count:
		return
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var rho_rock: float = float(LASubstances.table().get("silicate", {}).get("density", 0.0))
	var cell_vol: float = pow(field._grid.cell_size, 3.0)
	var surface_r: float = 0.0
	var mass_kg: float = 0.0
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		surface_r = maxf(surface_r, (field._grid.cell_world_pos(c) - centre).length())
		mass_kg += field._silicate[c] * rho_rock * cell_vol
	if surface_r <= 0.0 or mass_kg <= 0.0:
		return
	# g is SOLVED here, never held: it comes from the mass this seed just laid down.
	var g: float = LAPhysical.GRAVITATIONAL_CONSTANT * mass_kg / (surface_r * surface_r)
	var scale_h: float = LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK * (temp_c + LAPhysical.KELVIN_OFFSET) / g
	if scale_h <= 0.0:
		return
	# A CELL CANNOT HOLD A PROFILE SHORTER THAN ITSELF. Where the scale height is under a cell edge the
	# whole atmosphere sits inside the first open shell, and a per-cell exponential is a shape the grid
	# cannot carry; the honest seed is gas in that shell and vacuum beyond it. docs/PHYSICS_TODO.md D.
	var flat: bool = scale_h < field._grid.cell_size
	for c in field._cell_count:
		if field._solid[c] != 0:
			continue
		var r: float = (field._grid.cell_world_pos(c) - centre).length()
		var above: float = maxf(r - surface_r, 0.0)
		var f: float = (1.0 if above <= field._grid.cell_size else 0.0) if flat \
			else exp(-above / scale_h)
		field._o2[c] *= f
		field._co2[c] *= f
		field._n2[c] *= f


## FREE GAS DOES NOT SIT INSIDE STONE. The channels are filled before solidity is sampled, so every solid
## cell is handed a full atmosphere's worth of o2, co2 and n2 — matter in cells that have no room for it,
## and a gas pressure as flat through the rock as through the sky.
static func clear_gas_in_rock(field) -> void:
	if field == null or field._solid.size() != field._cell_count:
		return
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		field._o2[c] = 0.0
		field._co2[c] = 0.0
		field._n2[c] = 0.0
