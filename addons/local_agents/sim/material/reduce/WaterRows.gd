class_name LAReduceWaterRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## LIQUID h2o: the one water channel times the share the enthalpy ladder leaves liquid at this cell.
static func rows() -> Array:
	var wet_min: float = 0.01 * LAMaterialField3D.MAX_MASS  # below this a cell is not holding water, mol/m^3
	var wet: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "gate_lo": wet_min}
	var open_surf: Dictionary = {"source": "temp", "gate": "surface_class", "gate_lo": 0.5, "gate_hi": 1.5}
	var ice_surf: Dictionary = {"source": "temp", "gate": "surface_class", "gate_lo": 1.5, "gate_hi": 2.5}
	return [
		{"key": "water_liquid_total", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL, "weight": true},
		{"key": "wet_cells", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": wet_min},
		# Airborne h2o over every cell, in moles, mask-free.
		{"key": "vapour_amount", "source": "h2o", "aux": "h2o_vapour", "op": Rec.Op.SUM,
			"mask": Rec.Mask.ALL, "weight": true},
		# Surface water hot enough to be a spring, and the peak it reaches. Gated on holding water at all,
		# so the peak is the hottest WATER rather than the hottest cell.
		{"key": "hotspring_wet", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": wet_min},
		wet.merged({"key": "hotspring_max_c", "source": "temp", "op": Rec.Op.MAX,
			"mask": Rec.Mask.OPEN}, true),
		wet.merged({"key": "hotspring_mild", "source": "temp", "op": Rec.Op.COUNT_GT,
			"mask": Rec.Mask.OPEN, "threshold": 30.0}, true),
		wet.merged({"key": "hotspring_cells", "source": "temp", "op": Rec.Op.COUNT_GT,
			"mask": Rec.Mask.OPEN, "threshold": 60.0}, true),
		wet.merged({"key": "hotspring_boiling", "source": "temp", "op": Rec.Op.COUNT_GE,
			"mask": Rec.Mask.OPEN, "threshold": LAPhysical.WATER_BOIL_C}, true),
		# Cells actually HOLDING liquid water, how many of those sit below freezing, and the coldest.
		{"key": "clim_water_cells", "source": "h2o", "aux": "h2o_liquid", "op": Rec.Op.COUNT_GT,
			"mask": Rec.Mask.OPEN, "threshold": LAMaterialField3D.MIN_MASS},
		{"key": "clim_water_frozen", "source": "temp", "op": Rec.Op.COUNT_LT, "mask": Rec.Mask.OPEN,
			"threshold": LAPhysical.WATER_FREEZE_C, "gate": "h2o", "gate_aux": "h2o_liquid",
			"gate_lo": LAMaterialField3D.MIN_MASS},
		{"key": "clim_water_coldest", "source": "temp", "op": Rec.Op.MIN, "mask": Rec.Mask.OPEN,
			"gate": "h2o", "gate_aux": "h2o_liquid", "gate_lo": LAMaterialField3D.MIN_MASS},
		# THE FREE WATER SURFACE, split by whether it carries ice: state_derive.glsl classes it 1 open
		# and 2 frozen. Sum and count, so the reading published beside them is a mean over its own half.
		open_surf.merged({"key": "open_sea_cells", "op": Rec.Op.COUNT}, true),
		open_surf.merged({"key": "open_sea_temp_sum", "op": Rec.Op.SUM}, true),
		ice_surf.merged({"key": "sea_ice_cells", "op": Rec.Op.COUNT}, true),
		ice_surf.merged({"key": "sea_ice_temp_sum", "op": Rec.Op.SUM}, true),
	]
