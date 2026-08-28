extends SceneTree

## Every condensed phase carries a bulk modulus; a channel whose substance declares none reads as
## incompressible, and a signal crosses its cell at any speed at all.

func _init() -> void:
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var asked: int = 0
	var bare: PackedStringArray = PackedStringArray()
	for name in LAMatterChannels.CHANNELS:
		var row: Dictionary = rows.get(String(name), {})
		var id: String = String(row.get("substance", ""))
		if id.is_empty() or LAMatterChannels.GASES.has(id):
			continue
		if String(row.get("phase", "")) == "dissolved":
			continue
		asked += 1
		var s: Dictionary = table.get(id, {})
		var k: float = float(s.get("bulk_modulus_pa", s.get("bulk_modulus_solid_pa", 0.0)))
		if not (k > 0.0):
			bare.append("%s (%s)" % [String(name), id])
	if bare.size() > 0:
		printerr("condensed with no bulk modulus: %s" % String(", ").join(bare))
	print('CONDENSED_MODULI={"asked":%d,"bare":%d,"failures":%d}' % [asked, bare.size(), bare.size()])
	quit(1 if bare.size() > 0 else 0)
