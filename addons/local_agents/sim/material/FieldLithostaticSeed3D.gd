class_name LAFieldLithostaticSeed
extends RefCounted

## Rock at depth is COMPRESSED. Seeding every solid cell at the reference density gives a body whose
## pressure, read off the equation of state, is one standard atmosphere all the way down.
##
## A uniform self-gravitating sphere has, exactly, p(r) = (2/3) pi G rho^2 (R^2 - r^2) — the same closed
## form scripts/check_gravity_solve.sh checks g against. Inverting the linear condensed EOS at that
## pressure gives the fill that holds it: v = v0 (1 - (p - p_std)/K), and the fill is v0/v.
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
