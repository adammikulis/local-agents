extends SceneTree

## THE ENERGY GATE'S RUNNER — the sibling of check_reaction_balance.gd.
##
## That gate proves every record balances in ATOMS. Nothing proves anything about its ENTHALPY, so a record
## carrying a wrong sign, a wrong magnitude, or no latent heat at all is shippable today. This project has
## already shipped exactly that: a water cycle that released 2.433e5 J/kg from nothing per traverse, because
## sublimation was DECLARED as its own number instead of being fusion + vaporisation.
##
## WHAT IT CHECKS, both from the table alone with no run:
##   1. HESS'S LAW ON CYCLES. Phase changes form loops in state space — water to vapour to snow to water. The
##      enthalpies around any closed loop must sum to zero, or a substance can be walked round the loop as an
##      energy source. Checked over every simple cycle up to length 4 in the phase graph.
##   2. REVERSIBILITY. If A becomes B and B becomes A, the two enthalpies must be equal and opposite. A
##      freeze that releases more than its melt absorbs is a perpetual-motion machine with a rate limit.
##
## It does NOT check magnitudes against measured latent heats — check_physical_constants.sh owns values, and
## LAPhaseRecords already derives all of these from LASubstances rather than writing them down.
## (Explicit types only, no ':=' inferred typing.)

const REGISTRY_PATH: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"
const WORLD_PATH: String = "res://addons/local_agents/sim/SimWorld.gd"

## Relative tolerance on a cycle sum, against the largest enthalpy in that cycle. Float32 round-trips through
## the GPU record buffer, so exact zero is not available; anything above this is a real imbalance.
const CYCLE_REL_TOL: float = 1.0e-4


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
	return [int(r[0]), int(p[0]), float(rec.get("enthalpy_j_m3", 0.0))]


## A flux-derived rate spreads a per-square-metre flux through a cell, so the table cannot be built without
## a grid. This is the grid LocalAgentSimWorld builds at its own defaults.
func _declare_cell_height() -> void:
	var world: GDScript = load(WORLD_PATH)
	if world == null:
		return
	var w: Node = world.new()
	LAReactionDefs.cell_size_m = w.field_cell_size_m()
	w.free()


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
				print("REACTION_ENERGY_FAIL={\"kind\":\"irreversible\",\"a\":%s,\"b\":%s,\"sum_j_m3\":%f,\"rel\":%f}"
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
							print("REACTION_ENERGY_FAIL={\"kind\":\"hess\",\"cycle\":%s,\"sum_j_m3\":%f,\"rel\":%f}"
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

	print("REACTION_ENERGY={\"edges\":%d,\"cycles\":%d,\"violations\":%d}"
		% [edges.size(), seen_cycles.size(), violations])
	quit(1 if violations > 0 else 0)
