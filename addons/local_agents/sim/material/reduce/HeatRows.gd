class_name LAReduceHeatRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

static func rows() -> Array:
	return [
		{"key": "open_temp_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "open_temp_min", "source": "temp", "op": Rec.Op.MIN, "mask": Rec.Mask.OPEN},
		# Unweighted: over the open-cell count this is a mean over CELLS, not volume. all_temp_max is the
		# deep rock the open-only rows cannot see.
		{"key": "open_temp_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		{"key": "all_temp_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		# 60 °C: the one temperature "a hot open cell" means here. Read back through row("hot_cells").
		{"key": "hot_cells", "source": "temp", "op": Rec.Op.COUNT_GE, "mask": Rec.Mask.OPEN, "threshold": 60.0},
		{"key": "fire_peak", "source": "fire", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		{"key": "fire_cells", "source": "fire", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.ALL,
			"threshold": LAMaterialFieldQueries3D.FIRE_PRESENT},
		# J/m^3 per step, so volume-weighted these are joules per step. Mask-free: the outflow pass emits
		# from solid cells too, so an OPEN mask would drop the ground's emission.
		{"key": "rad_absorbed", "source": "rad_absorbed", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL, "weight": true},
		{"key": "rad_emitted", "source": "rad_emitted", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL, "weight": true},
	]
