class_name LAFieldLithostaticSeed
extends RefCounted

## Rock at depth is COMPRESSED. The seed integrates the hydrostatic profile of the mass it just laid
## down — g(r) = G M(<r) / r^2 over radial bins, p inward from the surface — and squeezes each lithic
## phase by its own bulk modulus: v = v0 (1 - (p - p_std)/K), so the fill rises by v0/v.
static func compress(field) -> float:
	if field == null or field._grid == null or field._silicate.size() != field._cell_count:
		return 0.0
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var dr: float = field._grid.cell_size
	var cell_vol: float = pow(dr, 3.0)
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var mirrors: Array = []
	var lithic: Array = []
	for name in rows:
		if String(rows[name].get("unit", "")) != "mol_m3":
			continue
		var arr = field.get("_" + String(name))
		if not (arr is PackedFloat32Array) or arr.size() != field._cell_count:
			continue
		var s: Dictionary = table.get(String(rows[name].get("substance", "")), {})
		var mm: float = float(s.get("molar_mass", 0.0))
		mirrors.append([arr, mm])
		if bool(rows[name].get("lithic", false)):
			var k_pa: float = float(s.get("bulk_modulus_solid_pa", s.get("bulk_modulus_pa", 0.0)))
			lithic.append([arr, k_pa])
	var bins: int = int(ceil(field._grid.max_span() / dr)) + 2
	var mass_kg: PackedFloat64Array = PackedFloat64Array()
	mass_kg.resize(bins)
	var cells_in: PackedInt32Array = PackedInt32Array()
	cells_in.resize(bins)
	var bin_of: PackedInt32Array = PackedInt32Array()
	bin_of.resize(field._cell_count)
	for c in field._cell_count:
		var b: int = mini(int((field._grid.cell_world_pos(c) - centre).length() / dr), bins - 1)
		bin_of[c] = b
		cells_in[b] += 1
		var m: float = 0.0
		for pair in mirrors:
			m += maxf(pair[0][c], 0.0) * float(pair[1])
		mass_kg[b] += m * cell_vol
	# g at each bin's outer edge from the mass inside it, then p inward from one atmosphere at the top.
	var p_at: PackedFloat64Array = PackedFloat64Array()
	p_at.resize(bins)
	var m_in: float = 0.0
	var g_at: PackedFloat64Array = PackedFloat64Array()
	g_at.resize(bins)
	for b in bins:
		m_in += mass_kg[b]
		var r: float = (float(b) + 1.0) * dr
		g_at[b] = LAPhysical.GRAVITATIONAL_CONSTANT * m_in / (r * r)
	var p: float = LAPhysical.STANDARD_PRESSURE_PA
	for b in range(bins - 1, -1, -1):
		var rho: float = float(mass_kg[b]) / (float(maxi(cells_in[b], 1)) * cell_vol)
		p += rho * g_at[b] * dr
		p_at[b] = p
	var added: float = 0.0
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		var strain_p: float = float(p_at[bin_of[c]]) - LAPhysical.STANDARD_PRESSURE_PA
		for pair in lithic:
			var k_pa: float = float(pair[1])
			if k_pa <= 0.0:
				continue
			var strain: float = strain_p / k_pa
			# A linear EOS has no answer past its own modulus; that is the model's limit, not a symptom.
			if strain >= 1.0 or strain <= 0.0:
				continue
			var arr: PackedFloat32Array = pair[0]
			var amt: float = arr[c] / (1.0 - strain)
			added += amt - arr[c]
			arr[c] = amt
	return added


## AN ATMOSPHERE IS A SHELL ON A SURFACE, not a uniform fill of the box: gas falls off with altitude
## by the barometric relation about the mean solid radius, scale height from the seeded state.
static func shape_atmosphere(field, temp_c: float) -> void:
	if field == null or field._grid == null or field._solid.size() != field._cell_count:
		return
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var cell_vol: float = pow(field._grid.cell_size, 3.0)
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var mirrors: Array = []
	for name in rows:
		if String(rows[name].get("unit", "")) != "mol_m3":
			continue
		var arr = field.get("_" + String(name))
		if arr is PackedFloat32Array and arr.size() == field._cell_count:
			mirrors.append([arr,
				float(table.get(String(rows[name].get("substance", "")), {}).get("molar_mass", 0.0))])
	var surface_r: float = 0.0
	var mass_kg: float = 0.0
	for c in field._cell_count:
		if field._solid[c] == 0:
			continue
		surface_r = maxf(surface_r, (field._grid.cell_world_pos(c) - centre).length())
		for pair in mirrors:
			mass_kg += maxf(pair[0][c], 0.0) * float(pair[1]) * cell_vol
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


## POURED WATER DISPLACES THE GAS: liquid holding an atmosphere's worth of gas in no free volume is
## a pressure bomb, not a sea.
static func displace_gas_from_water(field) -> void:
	if field == null or field._h2o.size() != field._cell_count:
		return
	var full: float = LASubstances.full_mol_m3("h2o")
	for c in field._cell_count:
		var room: float = clampf(1.0 - field._h2o[c] / full, 0.0, 1.0)
		if room < 1.0:
			field._o2[c] *= room
			field._co2[c] *= room
			field._n2[c] *= room
