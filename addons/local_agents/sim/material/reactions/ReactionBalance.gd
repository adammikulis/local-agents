class_name LAReactionBalance
extends RefCounted

## THE BALANCE GATE — a reaction record that creates or destroys matter is UNWRITABLE.
##
## WHY THIS EXISTS. The DEFS engine was a rate table, not a chemistry: `rec()` took `reactants[]` and
## `products[]` as two independent lists of hand-written coefficients with NOTHING relating them, and there
## was no load-time validation of any kind. Conservation was asserted in comments and enforced nowhere. Two
## records exploited that by construction:
##   * R15 decompose shipped consuming 0.8 O₂ per 1.0 CO₂ produced — 18% under-oxidised, creating oxygen
##     every cycle. It was "fixed" by a person noticing and setting two constants equal by hand.
##   * R11 (O₂) and R12 (CO₂) used the RELAX_TARGET rate model, which has NO REACTANT: the kernel skipped
##     the whole cap-and-debit block, so only the product credit ran. Every carbon atom that ever existed in
##     this simulation was conjured by R12, at a measured +6.5 units per field step.
## A rule that lives only in a comment has already been broken here twice, so this is not a comment. Every
## record is checked at load (LAMaterialReactions3D.records() refuses the whole table on a violation) and
## again by `scripts/check_reaction_balance.sh`, which CI runs through `scripts/agent_harness.sh lint`.
##
## WHAT "BALANCE" MEANS HERE, precisely. Each channel SLOT is declared below as the ELEMENTS one unit of it
## contains. A record balances when, for every element, the sum over its products equals the sum over its
## reactants. Five elements:
##
##   C - carbon atoms.    N - nitrogen atoms.    H - hydrogen atoms.    O - oxygen atoms.
##   M - mineral mass, the one lumped species: bedrock ROCK_FILL, molten LAVA, loose SEDIMENT, airborne DUST
##       and waterborne SUSP are one substance, and every geological record is a phase transfer between them.
##       Silicate stoichiometry is not modelled, so M is a mass rather than an atom count. Nothing converts
##       between M and the other four, so it never needs to be.
##
## THE COMPOSITIONS ARE THE ORDINARY MOLECULAR ONES. CO2 is C1 O2. Free O2 is O2. Liquid WATER, atmospheric
## MOISTURE, frozen SNOW and the rooting column's SOIL_ROOT are all H2 O1 - one substance in four phases and
## places. Living and dead organic matter (BIOMASS, DETRITUS, FUNGUS, cured FUEL) is CH2O, the carbohydrate
## unit, plus nitrogen at the measured C:N ratio of the material (LAPhysical.LITTER_C_TO_N). FERT is
## plant-available mineral nitrogen. Photosynthesis, respiration and decomposition then balance as the real
## reactions do -- CO2 + H2O -> CH2O + O2, and CH2O + O2 -> CO2 + H2O -- and the identity BioRecords.gd used
## to assert in prose, "O2 consumed == CO2 produced", falls out of the oxygen column instead of being
## maintained by hand.
##
## THIS TABLE IS THE ONE DECLARATION, AND THE INVENTORY READS IT TOO. LAMaterialFieldElementInventory3D sums
## the field's channels through this same `composition()`, which is what stops the instrument being circular.
## Before 2026-08-03 the budget summed the CO2, biomass and detritus channels at 1 unit each and called the
## total "carbon" - true only if the reaction coefficients relating those three are carbon-balanced, which is
## exactly the property the gauge existed to check. It assumed what it was measuring, so it could not detect
## the failure it was for. The records and the inventory cannot disagree now, because a disagreement would
## have to be a disagreement with itself.
##
## THE STOICHIOMETRIC WATER IS MODELLED, AND IT WAS NOT BEFORE. An earlier version of this file declared an
## `h2o` substance and an `oxidant` (O2-equivalent) pseudo-substance instead of H and O atoms, and argued
## that photosynthesis's one-water-per-carbon leg could be left out because real transpiration moves 200-1000
## waters per carbon fixed, making the stoichiometric leg well under a percent of a plant's throughput. That
## argument is sound about REALITY and unsound about THIS substrate, whose transpiration coefficient is 0.05
## rather than 400 - so the leg it dismissed as negligible is twenty times the one it kept. Leaving it out
## also meant hydrogen and oxygen had no accounting at all. R19 now debits SOIL_ROOT by
## (1.0 + PHOTO_WATER_COST), and R15/R20 credit the water their oxidation releases.
##
## SLOTS WITH NO SUBSTANCE. TEMP is energy, not matter. WINDSPEED, LIGHT and FIRE are derived drivers or
## intensities, not stocks. None may appear as a reactant or a product — a record that "produces" degrees or
## lux is not a reaction — and the gate refuses one that tries.
##
## THE KERNEL CROSS-CHECK. The slot enum is declared TWICE: once here in GDScript and once as `#define`s in
## reactions_sphere3d.glsl, which resolves a slot through two switch-ladders (`read_ch` for reads, `add_ch`
## for writes). Slots 5 (FUEL) and 6 (FIRE) were declared in BOTH enums and had NO ladder branch at all, so
## they read 0 and any write to them vanished silently. `check_kernel()` parses the kernel and refuses: a
## name or value mismatch between the two enums, a driver whose slot has no `read_ch` branch, a reactant
## whose slot lacks either branch, and a product whose slot has no `add_ch` branch.
## (Explicit types only, no ':=' inferred typing.)

const DefsScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"

## Relative tolerance on a substance sum. Coefficients are authored as float literals and several are derived
## (1.0 / LITTER_C_TO_N), so an exact compare would fail on representation alone. This is far tighter than
## any real imbalance ever found here — R15's was 18%, R20's nitrogen deficit 60%.
const TOL: float = 1.0e-6

## Constant names on LAReactionDefs that are NOT channel slots (rate models, gate bits, product targets, the
## record stride). Everything else in that file's constant map is a slot, so adding a slot needs no edit here.
const NON_SLOT_CONSTS: PackedStringArray = [
	"CONST_FRAC", "BILINEAR", "EXCESS_OVER_THRESHOLD", "DEFICIT_BELOW_THRESHOLD", "OPTIMUM_BAND",
	"RECORD_BYTES",
]


## Slots that carry no conserved substance and may therefore never be a reactant or a product. TEMP is
## energy: a reaction that releases or absorbs heat needs an enthalpy term, which is a different mechanism
## from a mass coefficient because the temperature change depends on the receiving cell's heat capacity. The
## rest are derived drivers computed from geometry (LIGHT, WINDSPEED) or an intensity (FIRE).
static func driver_only() -> PackedInt32Array:
	return PackedInt32Array([DefsScript.TEMP, DefsScript.WINDSPEED, DefsScript.LIGHT, DefsScript.FIRE])


## Slot -> { ELEMENT: atoms per unit of the channel }. A slot absent from BOTH this table and driver_only()
## is an authoring error and the gate says so, rather than silently treating it as massless.
##
## THE INVENTORY READS THIS SAME FUNCTION (LAMaterialFieldElementInventory3D), which is what stops the
## conservation gauge from assuming the property it exists to check.
static func composition() -> Dictionary:
	# CH2O plus the nitrogen the material actually carries, at its measured C:N ratio.
	#
	# THE NITROGEN TERM WAS `1.0 / LAPhysical.LITTER_C_TO_N` = 0.0500, AND THAT MIXED TWO KINDS OF RATIO.
	# *(Corrected 2026-08-07.)* Every other number in this dictionary is a count of ATOMS PER MOLECULE —
	# CH2O is one carbon, two hydrogens, one oxygen — but LITTER_C_TO_N is a ratio of MASSES (20 kg of
	# carbon per kg of nitrogen, PhysicalConstants.gd:396). Spending a mass ratio in a column of mole
	# counts overstated organic nitrogen by 16%. Per mole of CH2O the material carries
	# (CARBON_MOLAR_MASS / LITTER_C_TO_N) kilograms of N, which is 0.0429 mol.
	var organic: Dictionary = {
		"C": 1.0, "H": 2.0, "O": 1.0,
		"N": (LAPhysical.MOLAR_MASS_CARBON_KG_MOL / LAPhysical.LITTER_C_TO_N) / LAPhysical.MOLAR_MASS_NITROGEN_KG_MOL,
	}
	var water: Dictionary = {"H": 2.0, "O": 1.0}
	var mineral: Dictionary = {"M": 1.0}
	return {
		DefsScript.WATER: water,
		DefsScript.MOISTURE: water,
		DefsScript.SNOW: water,
		DefsScript.SOIL_ROOT: water,
		# SOIL_TOP is the same `soil` water as SOIL_ROOT, read through a shallower window (the drying front
		# rather than the whole rooting column), so it is water for exactly the same reason. Like SOIL_ROOT it
		# is a DERIVED VIEW and is deliberately absent from INVENTORY_CHANNELS below — summing it would count
		# the same water a second time.
		DefsScript.SOIL_TOP: water,
		DefsScript.O2: {"O": 2.0},
		DefsScript.CO2: {"C": 1.0, "O": 2.0},
		DefsScript.BIOMASS: organic,
		DefsScript.DETRITUS: organic,
		DefsScript.FUNGUS: organic,
		DefsScript.FUEL: organic,
		DefsScript.FERT: {"N": 1.0},
		DefsScript.LAVA: mineral,
		DefsScript.ROCK_FILL: mineral,
		# BEDROCK_BELOW is the `rock_fill` of the solid cell underneath, reached across one radial neighbour —
		# the same substance ROCK_FILL is, at the same one mineral unit per unit, which is what makes frost
		# shattering and silicate dissolution conserving rock -> sediment/susp transfers rather than sources.
		# DERIVED VIEW: absent from INVENTORY_CHANNELS, since `rock_fill` is already summed there.
		DefsScript.BEDROCK_BELOW: mineral,
		DefsScript.SEDIMENT: mineral,
		DefsScript.DUST: mineral,
		DefsScript.SUSP: mineral,
	}


## HOW MANY MOLES OF ITS SUBSTANCE ONE UNIT OF A CHANNEL HOLDS — the fact `composition()` needs and did
## not have, and without which this gate could not have been telling the truth.
##
## THE DEFECT IT CLOSES. The header above says each slot is "declared as the ELEMENTS one unit of it
## contains". What is declared is the molecular FORMULA, which is elements per MOLE. Those are the same
## statement only if one channel unit is one mole for every channel, and the substrate never worked that
## way — it was never even claimed to:
##   * `o2` and `co2` are in the gas unit PhysicalConstants.gd:377-380 DEFINES as "the amount of O₂ in a
##     cell of ambient air", AMBIENT_O2_DENSITY_KG_M3 = 0.2731 kg/m³, so one unit is 8.535 mol/m³. CO₂'s
##     seed is set from that by MOLE fraction, so a co2 unit is the same molar amount as an o2 unit.
##   * `water`, `moisture`, `snow` and the `soil` the root slots view are a FRACTION OF A CELL FULL OF
##     LIQUID WATER — LAPhysical.saturation_mass_fraction says so in its own docstring and divides by
##     WATER_DENSITY_KG_M3 to produce it. One unit is 997 kg/m³ = 55343 mol/m³.
## Those two differ by a factor of 6484, and `check_records` was comparing them as though they were equal.
## So a record could couple a gas channel to a water channel at coefficient 1:1, pass this gate, and be
## wrong about hydrogen by three and a half orders of magnitude. That is the whole photosynthesis /
## respiration / decomposition set.
##
## WHY THE FIX IS HERE AND NOT IN THE ENGINE. The obvious repair — make records declare molar stoichiometry
## and have `serialize()` convert — is wrong, and worth naming so nobody spends a day on it. A record's
## EXTENT `x` is denominated in the units of its coefficients, and `rate_k` is what produces `x`. Several
## rates are DERIVED from real physics directly in cell-fill units: R23's evaporation k is
## `C_E * U * dt / H`, a bulk aerodynamic mass transfer whose answer is a fraction of a water cell
## (PhaseRecords.gd:67-77). Rewriting coefficients into moles would force every one of those derivations to
## be redone in moles for no physical gain. The coefficients stay in channel units, where the rates are
## natural. It is the GATE and the INVENTORY that must convert — they are the two places that compare
## ACROSS channels, and they are the only two places that need to.
##
## MINERALS ARE 1.0 AND ARE NOT MOLES, AND THAT IS A FENCE, NOT A RESULT. `M` is a lumped mass rather than
## an atom count because silicate stoichiometry is not modelled. All six mineral phases share one cell-fill
## unit so they are consistent with EACH OTHER, which is all the M column can currently be asked to be.
##
## DO NOT JUSTIFY THIS BY "NOTHING CONVERTS BETWEEN M AND C/H/O/N". *(An earlier draft of this comment did,
## and it was circular.)* That is true of the record table today only because D1b CHEMICAL WEATHERING
## (GeoRecords.gd:172) takes WATER as its driver and CO2 as its driver2 — CATALYSTS — and consumes neither.
## The real reaction consumes both: CaSiO3 + 2CO2 + H2O -> Ca(2+) + 2HCO3(-) + SiO2. Silicate weathering is
## the long-term carbon sink that has regulated Earth's climate for four billion years, and this planet does
## not have it. So the absence of an M<->CHON conversion is a DEFECT being described, not a property being
## relied on, and the fence below exists because that defect is going to get fixed.
##
## Rock is roughly 46% oxygen by mass, so a molar basis for M is perfectly measurable — that is not why it is
## absent. It is absent because crustal oxygen would swamp `element_O` by orders of magnitude and destroy the
## one thing that ledger is for, which is watching the ATMOSPHERE. Geochemistry keeps those reservoirs on
## separate books for the same reason. When mineralogy lands, M gets real species (silicate, carbonate) with
## their own compositions, and carbonate is where weathered carbon goes.
##
## UNTIL THEN THE GATE REFUSES TO BE QUIET ABOUT IT — see the M-mixing check in `check_records`. A record
## with M on one side and C, H, O or N on the other cannot be balanced by anything here, and passing it
## silently is how a carbon sink would get written that leaks every atom it moves.
static func mol_per_unit() -> Dictionary:
	var gas: float = LAPhysical.AMBIENT_O2_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_O2_KG_MOL
	var water: float = LAPhysical.WATER_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
	# ORGANIC MATTER HAD NO DECLARED UNIT ANYWHERE — that absence is itself a finding. It is fixed here by
	# the one relation the substrate already asserts: fire_sphere3d.glsl:186-189 oxidises fuel and O₂
	# ONE FOR ONE (`burned = min(fuel_i, o2_i)`, then debits both by `burned`), and CH₂O + O₂ -> CO₂ + H₂O
	# is one mole of each. So a unit of organic matter IS a unit of O₂ in moles, by the kernel's own
	# arithmetic — 8.535 mol/m³, which is 0.2563 kg/m³ of CH₂O. Like the gas unit above it is a FREE CHOICE
	# whose ratios are the physics; this one is the choice already embedded in the code.
	var organic: float = gas
	return {
		DefsScript.WATER: water, DefsScript.MOISTURE: water, DefsScript.SNOW: water,
		DefsScript.SOIL_ROOT: water, DefsScript.SOIL_TOP: water,
		DefsScript.O2: gas, DefsScript.CO2: gas,
		DefsScript.BIOMASS: organic, DefsScript.DETRITUS: organic,
		DefsScript.FUNGUS: organic, DefsScript.FUEL: organic,
		# FERT is mineral nitrogen and its unit follows organic matter's, because decomposition is where it
		# comes from: one unit of organic matter releases `organic["N"]` moles of N, so pinning FERT to the
		# same molar basis makes that a 1:1 relation a record can state without a conversion factor.
		DefsScript.FERT: organic,
		DefsScript.LAVA: 1.0, DefsScript.ROCK_FILL: 1.0, DefsScript.BEDROCK_BELOW: 1.0,
		DefsScript.SEDIMENT: 1.0, DefsScript.DUST: 1.0, DefsScript.SUSP: 1.0,
	}


## How many units of `slot` hold the same number of MOLES as one unit of `ref_slot`.
##
## This is the number a record needs whenever it couples two channel families, and having to write it by
## hand is what let the biological records ship a 1:1 gas-to-water coefficient that was wrong by 6484x.
## A record says `[[MOISTURE, 1.0 * unit_ratio(MOISTURE, CO2)]]` and means "one H2O per CO2" — the
## stoichiometry stays visible and the conversion cannot be mistyped, because both halves come from
## mol_per_unit().
static func unit_ratio(slot: int, ref_slot: int) -> float:
	var mpu: Dictionary = mol_per_unit()
	var to: float = float(mpu.get(slot, 0.0))
	var from: float = float(mpu.get(ref_slot, 0.0))
	if to <= 0.0 or from <= 0.0:
		return 1.0
	return from / to


## The stored channels the inventory sums, mapped to the slot whose composition they carry. SOIL_ROOT is
## deliberately absent: it is a DERIVED VIEW of the `soil` channel (the regolith column beneath an open
## cell), so counting both would count the same water twice.
const INVENTORY_CHANNELS: Dictionary = {
	"water": 1, "moisture": 2, "snow": 12, "soil": 1,
	"o2": 3, "co2": 4,
	"biomass": 11, "detritus": 7, "fungus": 8, "fuel": 5, "fert": 9,
	"lava": 10, "rock_fill": 17, "sediment": 13, "dust": 14, "susp": 15,
}


## Elements a unit of `channel` contains. Empty for a channel that carries no matter.
static func channel_elements(channel: String) -> Dictionary:
	var slot: int = int(INVENTORY_CHANNELS.get(channel, -1))
	if slot < 0:
		return {}
	return composition().get(slot, {})


## Slot number -> the constant NAME that declares it, read off LAReactionDefs so it cannot drift from the
## numbers it names.
static func slot_names() -> Dictionary:
	var out: Dictionary = {}
	var consts: Dictionary = DefsScript.get_script_constant_map()
	for key in consts:
		var cname: String = String(key)
		if cname.begins_with("GATE_") or cname.begins_with("TGT_") or NON_SLOT_CONSTS.has(cname):
			continue
		var value: Variant = consts[key]
		if typeof(value) == TYPE_INT:
			out[int(value)] = cname
	return out


static func _name_of(slot: int, names: Dictionary) -> String:
	return String(names.get(slot, "slot#%d" % slot))


## Check every record's substance balance. Returns one message per violation; an empty result means clean.
static func check_records(recs: Array, labels: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var comp: Dictionary = composition()
	var names: Dictionary = slot_names()
	var drivers: PackedInt32Array = driver_only()
	# THE CONVERSION THIS GATE RAN WITHOUT UNTIL 2026-08-07. `comp` is elements per MOLE; a record's
	# coefficients are in CHANNEL UNITS, and a channel unit is not a mole. Multiplying by `mpu` is what turns
	# a coefficient into an amount of substance, and it is the difference between comparing atoms and
	# comparing two arbitrary scales. Without it a gas-to-water coefficient of 1:1 read as balanced while
	# being wrong by 6484x. See mol_per_unit() for where each factor comes from.
	var mpu: Dictionary = mol_per_unit()
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var label: String = String(labels[r]) if r < labels.size() else "record[%d]" % r
		var reactants: Array = rec.get("reactants", [])
		var products: Array = rec.get("products", [])

		# A record with no reactants but real products is matter from nothing, and it deserves to be said in
		# those words rather than to surface as five separate substance sums. This is the RELAX_TARGET shape.
		if reactants.is_empty() and not products.is_empty():
			out.append("%s: NO REACTANT — this record creates matter from nothing. " % label
				+ "Every product must come out of something the record debits.")

		var sums: Dictionary = {}
		var bad_slot: bool = false
		for side in ["reactants", "products"]:
			var sgn: float = -1.0 if side == "reactants" else 1.0
			for entry in rec.get(side, []):
				var slot: int = int(entry[0])
				var coeff: float = float(entry[1])
				if drivers.has(slot):
					out.append("%s: %s is a DRIVER, not a substance — it cannot be a %s. " % [
						label, _name_of(slot, names), "reactant" if sgn < 0.0 else "product"]
						+ "A reaction cannot consume or produce degrees, wind, light or flame intensity.")
					bad_slot = true
					continue
				if not comp.has(slot):
					out.append("%s: %s has no declared substance composition. " % [
						label, _name_of(slot, names)]
						+ "Add it to LAReactionBalance.composition() saying what it is made OF, or the gate "
						+ "cannot tell whether this record conserves anything.")
					bad_slot = true
					continue
				var parts: Dictionary = comp[slot]
				var moles: float = coeff * float(mpu.get(slot, 1.0))
				for sub in parts:
					sums[sub] = float(sums.get(sub, 0.0)) + sgn * moles * float(parts[sub])
		if bad_slot:
			continue
		# MINERAL MASS AND ATOMS CANNOT BE WEIGHED AGAINST EACH OTHER, so a record that puts them on opposite
		# sides is refused rather than silently summed. `M` is a lumped mass with no stoichiometry (see
		# composition()), so "1 unit of M becomes 1 mole of CO2" is not a statement this table can check.
		#
		# THIS BLOCK IS SCAFFOLDING AND IT HAS A REMOVAL CONDITION: it comes out the day the mineral phases
		# carry real species compositions — silicate CaSiO3, carbonate CaCO3, residue SiO2 — because then
		# `M` no longer exists and the ordinary element sums cover it. That work is what makes the Urey
		# reaction CaSiO3 + CO2 -> CaCO3 + SiO2 writable, and with it silicate weathering as a genuine carbon
		# sink instead of the catalysed rate GeoRecords.gd:172 currently models. Delete this, do not extend it.
		var has_mineral: bool = false
		var has_atoms: bool = false
		for sub in sums:
			if absf(float(sums[sub])) <= 0.0:
				continue
			if String(sub) == "M":
				has_mineral = true
			else:
				has_atoms = true
		if has_mineral and has_atoms:
			out.append("%s: puts lumped mineral mass (M) on one side and atoms on the other. " % label
				+ "Mineral has no stoichiometry here, so this cannot be balanced. Silicate weathering needs "
				+ "real species (CaSiO3 / CaCO3 / SiO2) before a record may convert rock into or out of C, "
				+ "H, O or N — see LAReactionBalance.composition().")
			continue
		for sub in sums:
			var net: float = float(sums[sub])
			var scale: float = 0.0
			for side2 in ["reactants", "products"]:
				for e2 in rec.get(side2, []):
					var s2: int = int(e2[0])
					if comp.has(s2) and comp[s2].has(sub):
						scale += absf(float(e2[1]) * float(mpu.get(s2, 1.0)) * float(comp[s2][sub]))
			if absf(net) > TOL * maxf(scale, 1.0):
				var verb: String = "CREATES" if net > 0.0 else "DESTROYS"
				# `%s` on a String.num, not a `%g` — GDScript's format has no `g` conversion and silently
				# emits the unformatted template when it meets one, which is how this gate's first firing
				# printed a message full of literal `%s`.
				out.append("%s: this record %s %s units of %s per unit of extent " % [
					label, verb, String.num(absf(net), 8), sub]
					+ "(products minus reactants). Products must balance reactants in every substance.")
	return out


## Cross-check the GDScript slot enum against the kernel's `#define`s and its read_ch/add_ch ladders, and
## verify every slot the live records reference is actually resolvable there.
static func check_kernel(recs: Array, labels: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var f: FileAccess = FileAccess.open(KERNEL_PATH, FileAccess.READ)
	if f == null:
		# A gate that cannot run must FAIL, never pass. This repo has already shipped three checks that
		# reported success while examining zero files.
		out.append("CANNOT RUN: %s is unreadable, so the enum/kernel cross-check examined nothing."
			% KERNEL_PATH)
		return out
	var src: String = f.get_as_text()
	f.close()

	var names: Dictionary = slot_names()
	var defines: Dictionary = {}
	var re: RegEx = RegEx.new()
	re.compile("^#define\\s+([A-Z_0-9]+)\\s+(\\d+)")
	for line in src.split("\n"):
		var m: RegExMatch = re.search(line)
		if m != null:
			defines[m.get_string(1)] = int(m.get_string(2))
	for slot in names:
		var nm: String = String(names[slot])
		if not defines.has(nm):
			out.append("KERNEL: slot %s = %d is declared in LAReactionDefs but has no #define in %s." % [
				nm, int(slot), KERNEL_PATH.get_file()])
		elif int(defines[nm]) != int(slot):
			out.append("KERNEL: slot %s is %d in LAReactionDefs but %d in %s — the two enums have drifted."
				% [nm, int(slot), int(defines[nm]), KERNEL_PATH.get_file()])

	var readable: Dictionary = _ladder_slots(src, "float read_ch(")
	var writable: Dictionary = _ladder_slots(src, "void add_ch(")
	if readable.is_empty() or writable.is_empty():
		out.append("CANNOT RUN: could not find the read_ch/add_ch switch-ladders in %s, so the slot "
			% KERNEL_PATH.get_file() + "resolvability check examined nothing.")
		return out
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var label: String = String(labels[r]) if r < labels.size() else "record[%d]" % r
		for key in ["driver_slot", "driver2_slot"]:
			var d: int = int(rec.get(key, -1))
			if d >= 0 and not readable.has(_name_of(d, names)):
				out.append("%s: drives on %s, which has no read_ch branch in the kernel — it reads 0." % [
					label, _name_of(d, names)])
		for entry in rec.get("reactants", []):
			var s: String = _name_of(int(entry[0]), names)
			if not readable.has(s):
				out.append("%s: reactant %s has no read_ch branch — the kernel reads 0, so its reactant cap "
					% [label, s] + "never binds.")
			if not writable.has(s):
				out.append("%s: reactant %s has no add_ch branch — the kernel cannot debit it, so this "
					% [label, s] + "record would consume nothing while still crediting its products.")
		for entry in rec.get("products", []):
			if entry.size() > 2 and int(entry[2]) == DefsScript.TGT_SCRATCH:
				continue                    # SCRATCH is a per-cell accumulator, not a channel slot
			var sp: String = _name_of(int(entry[0]), names)
			if not writable.has(sp):
				out.append("%s: product %s has no add_ch branch — the kernel drops this write silently." % [
					label, sp])
	return out


## The set of slot NAMES a kernel switch-ladder actually branches on, e.g. `if (slot == CO2) return co2[i];`.
static func _ladder_slots(src: String, header: String) -> Dictionary:
	var out: Dictionary = {}
	var start: int = src.find(header)
	if start < 0:
		return out
	var end: int = src.find("\n}", start)
	if end < 0:
		end = src.length()
	var body: String = src.substr(start, end - start)
	var re: RegEx = RegEx.new()
	re.compile("slot\\s*==\\s*([A-Z_0-9]+)")
	for m in re.search_all(body):
		out[m.get_string(1)] = true
	return out


## Everything, in the order a reader wants it: substance balance first (the physics), then the enum/kernel
## cross-check (the plumbing that would make even a balanced record a lie).
static func check_all(recs: Array, labels: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out: PackedStringArray = check_records(recs, labels)
	out.append_array(check_kernel(recs, labels))
	return out
