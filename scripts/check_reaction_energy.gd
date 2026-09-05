extends SceneTree

## THE ENERGY GATE'S RUNNER — the sibling of check_reaction_balance.gd, which proves ATOMS and nothing
## about enthalpy. Four checks, from the table alone with no run:
##   1. HESS ON CYCLES. Every simple loop up to length 4 in the phase graph sums to zero.
##   2. REVERSIBILITY. A->B and B->A are equal and opposite.
##   3. HESS ON EVERY RECORD. A record's heat is the one its own formation enthalpies give.
##   4. INTERNAL ENERGY. Each record carries its net moles of gas and the kernel spends dn_gas R T.

const REGISTRY_PATH: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"
const WORLD_PATH: String = "res://addons/local_agents/sim/SimWorld.gd"

## Relative tolerance on a cycle sum, against the largest enthalpy in that cycle. Float32 round-trips through
## the GPU record buffer, so exact zero is not available; anything above this is a real imbalance.
const CYCLE_REL_TOL: float = 1.0e-4

## The kernel line that must take the pV work of the gas back off a standard reaction enthalpy.
const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"


## A record is a PHASE TRANSFER when it moves one substance slot to one other slot with unit coefficients.
## Those are the records whose enthalpy is a latent heat and whose cycles must close. A record with several
## reactants is chemistry, not a phase change, and its cycle structure is not this gate's business.
func _phase_edge(rec: Dictionary) -> Array:
	var reactants: Array = rec.get("reactants", [])
	var products: Array = rec.get("products", [])
	if reactants.size() != 1 or products.size() != 1:
		return []
	var r: Array = reactants[0]
	var p: Array = products[0]
	if absf(float(r[1]) - 1.0) > 1.0e-6 or absf(float(p[1]) - 1.0) > 1.0e-6:
		return []
	return [int(r[0]), int(p[0]), float(rec.get("enthalpy_j_mol", 0.0))]


## A flux-derived rate spreads a per-square-metre flux through a cell, so the table cannot be built without
## a grid. This is the grid LocalAgentSimWorld builds at its own defaults.
func _declare_cell_height() -> void:
	var world: GDScript = load(WORLD_PATH)
	if world == null:
		return
	var w: Node = world.new()
	LAReactionDefs.cell_size_m = w.field_cell_size_m()
	w.free()


## Standard formation enthalpy of what `slot` holds, J/mol, NAN when the table has none. A DERIVED slot
## reads a condensed reservoir, so the vapour-referenced datum is walked down its heat of vaporisation.
func _formation_j_mol(slot: int) -> float:
	var id: String = String(LAChannels.slot_substance().get(slot, ""))
	var s: Dictionary = LASubstances.table().get(id, {})
	if not s.has("formation_enthalpy_j_mol"):
		return NAN
	var dh: float = float(s["formation_enthalpy_j_mol"])
	if not LAChannels.derived_slots().has(slot):
		return dh
	return dh - float(s.get("molar_mass", 0.0)) \
		* LASubstances.latent_vaporisation_at(id, LAPhysical.LAB_REFERENCE_TEMP_C)


## [heat released per mole of extent, as base/H:C/O:C parts]; empty when the table cannot price a
## participant.
func _hess_parts(rec: Dictionary) -> Array:
	var out: Vector3 = Vector3.ZERO
	for side in ["reactants", "products"]:
		var sgn: float = -1.0 if side == "reactants" else 1.0
		for entry in rec.get(side, []):
			var dh: float = _formation_j_mol(int(entry[0]))
			if is_nan(dh):
				return []
			out -= sgn * dh * Vector3(float(entry[1]), _part(entry, 2), _part(entry, 3))
	return [out]


func _part(entry: Array, k: int) -> float:
	return float(entry[k]) if entry.size() > k else 0.0


## Net moles of each substance the record moves; all zero means matter only changed slots and the
## enthalpy ladder, not the record, books whatever phase change that was.
func _net_substance(rec: Dictionary) -> Dictionary:
	var subs: Dictionary = LAChannels.slot_substance()
	var net: Dictionary = {}
	for side in ["reactants", "products"]:
		var sgn: float = -1.0 if side == "reactants" else 1.0
		for entry in rec.get(side, []):
			var id: String = String(subs.get(int(entry[0]), ""))
			net[id] = Vector3(net.get(id, Vector3.ZERO)) \
				+ sgn * Vector3(float(entry[1]), _part(entry, 2), _part(entry, 3))
	return net


func _is_transport(rec: Dictionary) -> bool:
	var net: Dictionary = _net_substance(rec)
	for id in net:
		if Vector3(net[id]).length() > 1.0e-9:
			return false
	return true


## Net moles of GAS the record makes, recomputed here from the channel and substance declarations.
func _dn_gas(rec: Dictionary) -> Vector3:
	var subs: Dictionary = LAChannels.slot_substance()
	var tbl: Dictionary = LASubstances.table()
	var out: Vector3 = Vector3.ZERO
	for side in ["reactants", "products"]:
		var sgn: float = -1.0 if side == "reactants" else 1.0
		for entry in rec.get(side, []):
			var slot: int = int(entry[0])
			if LAChannels.derived_slots().has(slot):
				continue
			if float(tbl.get(String(subs.get(slot, "")), {}).get("entropy_gas_j_molk", 0.0)) <= 0.0:
				continue
			out += sgn * Vector3(float(entry[1]), _part(entry, 2), _part(entry, 3))
	return out


## The record buffer must carry dn_gas and the kernel must spend it. Returns the violation count.
func _check_internal_energy(registry: GDScript) -> int:
	var bad: int = 0
	for path in registry.RECORD_MODULES:
		var mod: GDScript = load(path)
		if mod == null:
			continue
		var recs: Array = mod.records()
		for i in range(recs.size()):
			var want: Vector3 = _dn_gas(recs[i])
			var r: Dictionary = recs[i]
			var got: Vector3 = Vector3(float(r.get("dn_gas", 0.0)), float(r.get("dn_gas_h", 0.0)),
				float(r.get("dn_gas_o", 0.0)))
			if (got - want).length() > 1.0e-9:
				print("REACTION_ENERGY_FAIL={\"kind\":\"dn_gas\",\"record\":%s,\"table\":%f,\"got\":%f}"
					% [JSON.stringify("%s record %d" % [String(path).get_file(), i]), want.x, got.x])
				bad += 1
	# The serialiser must put those three where the kernel struct reads them, 140 / 216 / 220.
	var probe: Dictionary = LAReactionThermo.priced(LAReactionDefs.rec(LAReactionDefs.TB_PER_STEP, "",
		LAReactionDefs.RM_CONST_FRAC, 0.0, LAReactionDefs.N2,
		[[LAReactionDefs.N2, 1.0, 3.0, 5.0]], [[LAReactionDefs.FERT, 2.0]]))
	var buf: PackedByteArray = LAReactionDefs.serialize([probe])
	var want_probe: Vector3 = _dn_gas(probe)
	var got_probe: Vector3 = Vector3(buf.decode_float(140), buf.decode_float(216), buf.decode_float(220))
	if (got_probe - want_probe).length() > 1.0e-6:
		print("REACTION_ENERGY_FAIL={\"kind\":\"dn_gas_layout\",\"want\":%f,\"got\":%f}"
			% [want_probe.x, got_probe.x])
		bad += 1
	var f: FileAccess = FileAccess.open(KERNEL_PATH, FileAccess.READ)
	if f == null:
		print("REACTION_ENERGY_ERROR: %s unreadable; the kernel half was not checked." % KERNEL_PATH)
		return bad + 1
	var src: String = f.get_as_text()
	f.close()
	for want_txt in ["float dn_gas;", "float dn_gas_h;", "float dn_gas_o;"]:
		if not src.contains(want_txt):
			print("REACTION_ENERGY_FAIL={\"kind\":\"kernel_struct\",\"missing\":%s}"
				% JSON.stringify(want_txt))
			bad += 1
	var re: RegEx = RegEx.new()
	re.compile("h\\[i\\]\\s*\\+=([^;]*);")
	var m: RegExMatch = re.search(src.substr(src.find("float dh = rc.enthalpy_j_mol")))
	if m == null or not (m.get_string(1).contains("dn") and m.get_string(1).contains("R_GAS")
			and m.get_string(1).contains("temp[i]")):
		print('REACTION_ENERGY_FAIL={"kind":"kernel_enthalpy","why":"the heat lands in the energy buffer '
			+ 'as a standard reaction ENTHALPY: dn_gas R T is never taken off it"}')
		bad += 1
	return bad


func _init() -> void:
	_declare_cell_height()
	var registry: GDScript = load(REGISTRY_PATH)
	if registry == null:
		print("REACTION_ENERGY_ERROR: could not load %s" % REGISTRY_PATH)
		print('REACTION_ENERGY={"edges":0,"violations":-1}')
		quit(2)
		return

	var edges: Array = []           # [from_slot, to_slot, enthalpy, label]
	for path in registry.RECORD_MODULES:
		var mod: GDScript = load(path)
		if mod == null:
			print("REACTION_ENERGY_ERROR: record module missing: %s" % path)
			print('REACTION_ENERGY={"edges":0,"violations":-1}')
			quit(2)
			return
		var domain: Array = mod.records()
		for i in range(domain.size()):
			var e: Array = _phase_edge(domain[i])
			if e.is_empty():
				continue
			e.append("%s record %d" % [String(path).get_file(), i])
			edges.append(e)

	if edges.is_empty():
		print("REACTION_ENERGY_ERROR: no single-substance phase transfers found — the gate examined nothing.")
		print('REACTION_ENERGY={"edges":0,"violations":-1}')
		quit(2)
		return

	var violations: int = 0

	# --- 2. REVERSIBILITY: A->B and B->A must be equal and opposite ---------------------------------------
	for i in range(edges.size()):
		for j in range(i + 1, edges.size()):
			if int(edges[i][0]) != int(edges[j][1]) or int(edges[i][1]) != int(edges[j][0]):
				continue
			var sum: float = float(edges[i][2]) + float(edges[j][2])
			var scale: float = maxf(absf(float(edges[i][2])), absf(float(edges[j][2])))
			if scale <= 0.0:
				continue
			if absf(sum) / scale > CYCLE_REL_TOL:
				print("REACTION_ENERGY_FAIL={\"kind\":\"irreversible\",\"a\":%s,\"b\":%s,\"sum_j_mol\":%f,\"rel\":%f}"
					% [JSON.stringify(String(edges[i][3])), JSON.stringify(String(edges[j][3])), sum,
						absf(sum) / scale])
				violations += 1

	# --- 1. HESS'S LAW: every simple cycle up to length 4 sums to zero -------------------------------------
	# Depth-first from each edge, never revisiting a slot, closing back on the start. Length 2 is the
	# reversible pair above and is skipped here so a defect is not counted twice.
	var seen_cycles: Dictionary = {}
	for start in range(edges.size()):
		var stack: Array = [[start, [int(edges[start][0])], float(edges[start][2]), [String(edges[start][3])]]]
		while not stack.is_empty():
			var top: Array = stack.pop_back()
			var last_edge: int = int(top[0])
			var visited: Array = top[1]
			var running: float = float(top[2])
			var trail: Array = top[3]
			var here: int = int(edges[last_edge][1])
			if here == int(edges[start][0]):
				if trail.size() >= 3:
					var key_parts: Array = trail.duplicate()
					key_parts.sort()
					var key: String = "|".join(PackedStringArray(key_parts))
					if not seen_cycles.has(key):
						seen_cycles[key] = true
						var scale2: float = 0.0
						for t in range(edges.size()):
							if String(edges[t][3]) in trail:
								scale2 = maxf(scale2, absf(float(edges[t][2])))
						if scale2 > 0.0 and absf(running) / scale2 > CYCLE_REL_TOL:
							print("REACTION_ENERGY_FAIL={\"kind\":\"hess\",\"cycle\":%s,\"sum_j_mol\":%f,\"rel\":%f}"
								% [JSON.stringify(trail), running, absf(running) / scale2])
							violations += 1
				continue
			if visited.size() >= 4 or here in visited:
				continue
			for n in range(edges.size()):
				if int(edges[n][0]) != here:
					continue
				var nv: Array = visited.duplicate()
				nv.append(here)
				var nt: Array = trail.duplicate()
				nt.append(String(edges[n][3]))
				stack.append([n, nv, running + float(edges[n][2]), nt])

	# --- 3. HESS ON EVERY RECORD ---------------------------------------------------------------------
	# Recomputed here from LASubstances, never from the module that wrote the record: a record whose heat
	# does not follow from its own participants' formation enthalpies is a second authority on one number.
	var priced_n: int = 0
	for path in registry.RECORD_MODULES:
		var mod3: GDScript = load(path)
		if mod3 == null:
			continue
		var recs3: Array = mod3.records()
		for i in range(recs3.size()):
			var rec: Dictionary = recs3[i]
			var label: String = "%s record %d" % [String(path).get_file(), i]
			var want: Vector3 = Vector3.ZERO
			if not _is_transport(rec):
				var parts: Array = _hess_parts(rec)
				if parts.is_empty():
					print("REACTION_ENERGY_FAIL={\"kind\":\"unpriced\",\"record\":%s}"
						% JSON.stringify(label))
					violations += 1
					continue
				want = Vector3(parts[0])
			priced_n += 1
			var got: Vector3 = Vector3(float(rec.get("enthalpy_j_mol", 0.0)),
				float(rec.get("enthalpy_h_j_mol", 0.0)), float(rec.get("enthalpy_o_j_mol", 0.0)))
			var scale: float = maxf(want.length(), 1.0)
			if (got - want).length() / scale > CYCLE_REL_TOL:
				print("REACTION_ENERGY_FAIL={\"kind\":\"hess_record\",\"record\":%s,"
					% JSON.stringify(label)
					+ "\"booked_j_mol\":%f,\"table_j_mol\":%f}" % [got.x, want.x])
				violations += 1

	# --- 4. THE STATE IS INTERNAL ENERGY -------------------------------------------------------------
	violations += _check_internal_energy(registry)

	print("REACTION_ENERGY={\"edges\":%d,\"cycles\":%d,\"priced\":%d,\"violations\":%d}"
		% [edges.size(), seen_cycles.size(), priced_n, violations])
	quit(1 if violations > 0 else 0)
