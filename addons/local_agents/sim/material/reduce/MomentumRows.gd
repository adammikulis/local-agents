extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")


## The momentum ledger's device folds: the open stock, its mass and motion, and the body impulse
## state_derive deposits each step. Weighted rows integrate over cell volume.
static func rows() -> Array:
	var out: Array = []
	for ax in ["x", "y", "z"]:
		out.append({"key": "open_mom_" + ax, "source": "mom_" + ax,
			"op": Rec.Op.SUM, "mask": Rec.Mask.OPEN, "weight": true})
		out.append({"key": "bodyf_" + ax, "source": "bodyf_" + ax,
			"op": Rec.Op.SUM, "mask": Rec.Mask.OPEN, "weight": true})
	out.append({"key": "momentum_mass_kg", "source": "rho_bulk",
		"op": Rec.Op.SUM, "mask": Rec.Mask.OPEN, "weight": true})
	out.append({"key": "momentum_carried", "source": "rho_bulk", "aux": "speed",
		"op": Rec.Op.SUM, "mask": Rec.Mask.OPEN, "weight": true})
	out.append({"key": "momentum_cells", "source": "speed",
		"op": Rec.Op.COUNT_GT, "mask": Rec.Mask.OPEN, "threshold": 0.0})
	# Momentum in a cell that holds no mass. Gated by check_momentum_orphans.sh.
	out.append({"key": "momentum_orphan_cells", "source": "mom_orphan",
		"op": Rec.Op.COUNT_GT, "mask": Rec.Mask.OPEN, "threshold": 0.0})
	# The peak Mach number: a cell's speed over its own sound speed. Gated by check_rung_acoustic.sh.
	out.append({"key": "mach_max", "source": "mach", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN})
	out.append({"key": "rho_max_open", "source": "rho_bulk", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN})
	# WHERE the non-finite values sit, so a NaN population names its cell class.
	out.append({"key": "nonfinite_solid", "source": "nonfinite", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID})
	out.append({"key": "nonfinite_ground", "source": "nonfinite", "op": Rec.Op.SUM, "mask": Rec.Mask.GROUND})
	out.append({"key": "nonfinite_air", "source": "nonfinite", "op": Rec.Op.SUM, "mask": Rec.Mask.AIR})
	return out
