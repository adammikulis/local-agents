class_name LAReactionBalance
extends RefCounted


const DefsScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"

## Relative tolerance on a substance sum. Coefficients are authored as float literals and several are derived
## (1.0 / LITTER_C_TO_N), so an exact compare would fail on representation alone. This is far tighter than
## any real imbalance ever found here — R15's was 18%, R20's nitrogen deficit 60%.
const TOL: float = 1.0e-6

## value as FIRE, and it is declared LATER in the file, so `slot_names()` resolved slot 6 to "ARRHENIUS" and
## #define, and any message about slot 6 named a rate model rather than a channel.
const NON_SLOT_CONSTS: PackedStringArray = [
	"CONST_FRAC", "BILINEAR", "EXCESS_OVER_THRESHOLD", "DEFICIT_BELOW_THRESHOLD", "OPTIMUM_BAND",
	"ARRHENIUS", "RECORD_BYTES",
]


## energy: a reaction that releases or absorbs heat needs an enthalpy term, which is a different mechanism
static func driver_only() -> PackedInt32Array:
	return PackedInt32Array([DefsScript.TEMP, DefsScript.WINDSPEED, DefsScript.LIGHT, DefsScript.FIRE])



const SLOT_SUBSTANCE: Dictionary = {
	1: "h2o", 2: "h2o", 12: "h2o", 19: "h2o", 21: "h2o",        # WATER MOISTURE SNOW SOIL_ROOT SOIL_TOP
	3: "o2", 4: "co2",
	11: "cellulose", 7: "cellulose", 8: "cellulose", 5: "cellulose",  # BIOMASS DETRITUS FUNGUS FUEL
	9: "fixed_n",                                                 # FERT
	10: "silicate", 17: "silicate", 23: "silicate", 13: "silicate", 14: "silicate", 15: "silicate",
	24: "carbonate", 25: "silica",
}


## Atoms per CHANNEL UNIT for each slot — `LASubstances` composition scaled by what one unit of that channel
## weighs. The gate counts atoms; this is the only place a channel unit is converted into them.
static func composition() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = LASubstances.table()
	for slot in SLOT_SUBSTANCE:
		var id: String = String(SLOT_SUBSTANCE[slot])
		out[int(slot)] = tbl.get(id, {}).get("formula", {}).duplicate()
	return out


static func mol_per_unit() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = LASubstances.table()
	for slot in SLOT_SUBSTANCE:
		var sub: Dictionary = tbl.get(String(SLOT_SUBSTANCE[slot]), {})
		var m: float = float(sub.get("molar_mass", 0.0))
		out[int(slot)] = (float(sub.get("density", 0.0)) / m) if m > 0.0 else 0.0
	return out



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
	"carbonate": 24, "silica": 25,
}


const LITHOSPHERE_CHANNELS: PackedStringArray = [
	"rock_fill", "lava", "sediment", "susp", "dust", "carbonate", "silica",
]


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
		# lumped mineral mass on one side and atoms on the other, and its own comment named its removal
		# condition: "the day the mineral phases carry real species compositions". They do. Ca and Si are
		# ordinary columns in the sums below now, so the Urey reaction is checked the same way respiration is.)
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
