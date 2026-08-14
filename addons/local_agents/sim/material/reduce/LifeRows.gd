class_name LAReduceLifeRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

static func rows() -> Array:
	return [
		{"key": "fert_peak", "source": "fert", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "fungus_peak", "source": "fungus", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "fungus_cells", "source": "fungus", "op": Rec.Op.COUNT_GE, "mask": Rec.Mask.OPEN,
			"threshold": LAMaterialFieldChannels3D.FUNGUS_PRESENT},
		{"key": "detritus_peak", "source": "detritus", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "detritus_cells", "source": "detritus", "op": Rec.Op.COUNT_GE, "mask": Rec.Mask.OPEN,
			"threshold": LAMaterialFieldChannels3D.DETRITUS_PRESENT},
	]
