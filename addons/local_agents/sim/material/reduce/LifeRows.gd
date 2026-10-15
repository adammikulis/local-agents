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
		# The BURIED share of the dead pool, under the derived solid flag.
		{"key": "solid_detritus", "source": "detritus", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID,
			"weight": true},
		{"key": "solid_fuel", "source": "fuel", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID, "weight": true},
		{"key": "solid_org_h", "source": "org_h", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID, "weight": true},
		{"key": "solid_org_o", "source": "org_o", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID, "weight": true},
		# COALIFICATION. state_derive.glsl writes the pool's molar ratios, +inf under the mole floor; a cell
		# under 99% of fresh litter on its nearer ratio has moved along the peat-to-anthracite spectrum.
		{"key": "organic_hc_min", "source": "org_hc", "op": Rec.Op.MIN, "mask": Rec.Mask.ALL},
		{"key": "organic_oc_min", "source": "org_oc", "op": Rec.Op.MIN, "mask": Rec.Mask.ALL},
		{"key": "organic_coalified", "source": "org_fresh", "op": Rec.Op.COUNT_LT, "mask": Rec.Mask.ALL,
			"threshold": 0.99},
	]
