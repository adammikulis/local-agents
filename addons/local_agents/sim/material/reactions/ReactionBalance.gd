class_name LAReactionBalance
extends RefCounted


const DefsScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionDefs.gd")

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"

## Relative tolerance on a substance sum.
const TOL: float = 1.0e-6

## Constants of LAReactionDefs that are not channel slots and carry no namespace prefix.
const NON_SLOT_CONSTS: PackedStringArray = ["RECORD_BYTES"]


## Slots that may only drive a record, never be a reactant or a product.
static func driver_only() -> PackedInt32Array:
	return PackedInt32Array([DefsScript.TEMP, DefsScript.WINDSPEED, DefsScript.LIGHT, DefsScript.FIRE,
		DefsScript.DISCHARGE, DefsScript.ORG_C])



## Views of LAChannels, the one declaration of what a channel is.
static func slot_substance() -> Dictionary: return LAChannels.slot_substance()


## Atoms per mole of each slot's substance, from `LASubstances.formula`.
static func composition() -> Dictionary:
	var out: Dictionary = {}
	var tbl: Dictionary = LASubstances.table()
	var subs: Dictionary = slot_substance()
	for slot in subs:
		var id: String = String(subs[slot])
		out[int(slot)] = tbl.get(id, {}).get("formula", {}).duplicate()
	return out


## The stored channels the inventory sums, mapped to the slot whose composition they carry.
static func inventory_channels() -> Dictionary: return LAChannels.inventory_channels()


static func lithosphere_channels() -> PackedStringArray: return LAChannels.lithosphere_channels()


## Elements a unit of `channel` contains. Empty for a channel that carries no matter.
static func channel_elements(channel: String) -> Dictionary:
	var slot: int = int(inventory_channels().get(channel, -1))
	if slot < 0:
		return {}
	return composition().get(slot, {})


## Every stored channel whose composition carries `element`. Asking where the carbon went costs the
## channels that hold carbon, not every channel.
static func channels_with(element: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in inventory_channels():
		if channel_elements(ch).has(element):
			out.append(String(ch))
	return out


## Every element any stored channel carries.
static func all_elements() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in inventory_channels():
		for el in channel_elements(ch):
			if not out.has(String(el)):
				out.append(String(el))
	return out


## Slot number -> the LAReactionDefs constant name that declares it.
static func slot_names() -> Dictionary:
	var out: Dictionary = {}
	var consts: Dictionary = DefsScript.get_script_constant_map()
	for key in consts:
		var cname: String = String(key)
		# A slot id is what is left once the namespaced constants are removed.
		if cname.begins_with("GATE_") or cname.begins_with("TGT_") or cname.begins_with("RM_") \
				or NON_SLOT_CONSTS.has(cname):
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

		if reactants.is_empty() and not products.is_empty():
			out.append("%s: NO REACTANT — this record creates matter from nothing. " % label
				+ "Every product must come out of something the record debits.")

		# A coefficient is base + h*(H:C) + o*(O:C); each part balances on its own.
		var sums: Array = [{}, {}, {}]
		var scales: Array = [{}, {}, {}]
		var bad_slot: bool = false
		for side in ["reactants", "products"]:
			var sgn: float = -1.0 if side == "reactants" else 1.0
			var is_prod: bool = side == "products"
			for entry in rec.get(side, []):
				var slot: int = int(entry[0])
				var parts_v: Vector2 = DefsScript.comp_parts(entry, is_prod)
				var coeffs: Array = [float(entry[1]), parts_v.x, parts_v.y]
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
				for p in 3:
					var moles: float = float(coeffs[p])
					var sp: Dictionary = sums[p]
					var sc: Dictionary = scales[p]
					for sub in parts:
						sp[sub] = float(sp.get(sub, 0.0)) + sgn * moles * float(parts[sub])
						sc[sub] = float(sc.get(sub, 0.0)) + absf(moles * float(parts[sub]))
		if bad_slot:
			continue
		var part_names: PackedStringArray = PackedStringArray(["", " (the H:C-scaled part of)", " (the O:C-scaled part of)"])
		for p in 3:
			var sump: Dictionary = sums[p]
			var scalep: Dictionary = scales[p]
			for sub in sump:
				var net: float = float(sump[sub])
				if absf(net) <= TOL * maxf(float(scalep.get(sub, 0.0)), 1.0):
					continue
				var verb: String = "CREATES" if net > 0.0 else "DESTROYS"
				# `%s` on a String.num: GDScript's format has no `g` conversion.
				out.append("%s:%s this record %s %s units of %s per unit of extent " % [
					label, part_names[p], verb, String.num(absf(net), 8), sub]
					+ "(products minus reactants). Products must balance reactants in every substance.")
	return out


## Cross-check the slot enum against the kernel's `#define`s and its read_ch/add_ch ladders.
static func check_kernel(recs: Array, labels: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var f: FileAccess = FileAccess.open(KERNEL_PATH, FileAccess.READ)
	if f == null:
		out.append("CANNOT RUN: %s is unreadable, so the enum/kernel cross-check examined nothing."
			% KERNEL_PATH)
		return out
	var src: String = f.get_as_text()
	f.close()
	# The slot #defines live in the generated include, not the kernel.
	for inc in ["generated.glsli"]:
		var g: FileAccess = FileAccess.open(KERNEL_PATH.get_base_dir() + "/" + inc, FileAccess.READ)
		if g == null:
			out.append("CANNOT RUN: %s is unreadable, so the slot enums could not be compared." % inc)
			return out
		src += "\n" + g.get_as_text()
		g.close()

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


## Substance balance followed by the enum/kernel cross-check.
static func check_all(recs: Array, labels: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out: PackedStringArray = check_records(recs, labels)
	out.append_array(check_kernel(recs, labels))
	return out
