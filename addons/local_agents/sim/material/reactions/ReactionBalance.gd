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
	var organic: Dictionary = {"C": 1.0, "H": 2.0, "O": 1.0, "N": 1.0 / LAPhysical.LITTER_C_TO_N}
	var water: Dictionary = {"H": 2.0, "O": 1.0}
	var mineral: Dictionary = {"M": 1.0}
	return {
		DefsScript.WATER: water,
		DefsScript.MOISTURE: water,
		DefsScript.SNOW: water,
		DefsScript.SOIL_ROOT: water,
		DefsScript.O2: {"O": 2.0},
		DefsScript.CO2: {"C": 1.0, "O": 2.0},
		DefsScript.BIOMASS: organic,
		DefsScript.DETRITUS: organic,
		DefsScript.FUNGUS: organic,
		DefsScript.FUEL: organic,
		DefsScript.FERT: {"N": 1.0},
		DefsScript.LAVA: mineral,
		DefsScript.ROCK_FILL: mineral,
		DefsScript.SEDIMENT: mineral,
		DefsScript.DUST: mineral,
		DefsScript.SUSP: mineral,
	}


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
				for sub in parts:
					sums[sub] = float(sums.get(sub, 0.0)) + sgn * coeff * float(parts[sub])
		if bad_slot:
			continue
		for sub in sums:
			var net: float = float(sums[sub])
			var scale: float = 0.0
			for side2 in ["reactants", "products"]:
				for e2 in rec.get(side2, []):
					var s2: int = int(e2[0])
					if comp.has(s2) and comp[s2].has(sub):
						scale += absf(float(e2[1]) * float(comp[s2][sub]))
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
