extends SceneTree

## Every condensed phase carries a bulk modulus and its pressure derivative; a channel whose substance
## declares no modulus reads as incompressible and a signal crosses its cell at any speed at all, and one
## with no derivative squeezes at the value Birch-Murnaghan reduces to its second order at.

func _init() -> void:
	var rows: Dictionary = LAChannels.rows()
	var asked: int = 0
	var bare: PackedStringArray = PackedStringArray()
	var flat: PackedStringArray = PackedStringArray()
	var slack: PackedStringArray = PackedStringArray()
	for name in LAMatterChannels.CHANNELS:
		var row: Dictionary = rows.get(String(name), {})
		var id: String = String(row.get("substance", ""))
		if id.is_empty() or LAMatterChannels.GASES.has(id):
			continue
		if String(row.get("phase", "")) == "dissolved":
			continue
		asked += 1
		var eos: Dictionary = LASubstances.eos_of(id)
		var solid: Dictionary = eos["solid"]
		var own: Dictionary = solid if not solid.is_empty() else eos["liquid"]
		if not (float(own.get("k", 0.0)) > 0.0):
			bare.append("%s (%s)" % [String(name), id])
			continue
		for phase in ["solid", "liquid"]:
			var ph: Dictionary = eos[phase]
			if float(ph.get("k", 0.0)) > 0.0 and not (float(ph.get("kp", 0.0)) > 0.0):
				flat.append("%s (%s %s)" % [String(name), id, phase])
		# Squeeze a phase and it gets denser, at every pressure a planet reaches. Birch-Murnaghan is
		# invertible only between the turning points of P(f), and a bracket wider than that returns a
		# root that is not the state.
		var prev: float = 0.0
		for e in range(0, 25):
			# One bar to the pressure at Earth's centre, 364 GPa (Dziewonski & Anderson 1981, PREM).
			var p_pa: float = pow(10.0, 5.0 + 0.2731 * float(e))
			var rho: float = LASubstances.density(id, 1000.0, p_pa)
			if rho < prev:
				slack.append("%s (%s at %s Pa)" % [String(name), id, p_pa])
				break
			prev = rho
	if bare.size() > 0:
		printerr("condensed with no bulk modulus: %s" % String(", ").join(bare))
	if flat.size() > 0:
		printerr("bulk modulus with no pressure derivative: %s" % String(", ").join(flat))
	if slack.size() > 0:
		printerr("density falls as pressure rises: %s" % String(", ").join(slack))
	var failures: int = bare.size() + flat.size() + slack.size()
	print('CONDENSED_MODULI={"asked":%d,"bare":%d,"flat":%d,"slack":%d,"failures":%d}'
		% [asked, bare.size(), flat.size(), slack.size(), failures])
	quit(1 if failures > 0 else 0)
