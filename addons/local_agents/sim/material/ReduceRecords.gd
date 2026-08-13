class_name LAReduceRecords
extends RefCounted

## What the field reduces itself over. reduce.glsl runs every row through one shared-memory tree reduce.

## How a row folds its cells. Generated into reduce.glsl as OP_*.
enum Op { SUM, COUNT_GT, COUNT_GE, SUM_ABS_DIFF, LATCH }

## Which cells a row counts. Generated into reduce.glsl as MASK_*.
enum Mask { ALL, OPEN, SOLID }

## Channels whose stock the conservation ledger books, mask-free and open-only.
const AMOUNTS: PackedStringArray = ["h2o", "silicate", "carbonate", "silica",
	"co2", "o2", "n2", "detritus", "biomass", "fert", "fungus", "fuel"]


## `weight` multiplies by the cell's volume in cubic metres: a channel value is intensive and the amount is
## value * volume. A row comparing a per-cell FRACTION against a fraction threshold carries no weight, or
## the threshold would move per cell. `aux` multiplies the source; `ref` is the field a diff is taken from.
static func rows() -> Array:
	var out: Array = []
	for name in AMOUNTS:
		out.append({"key": "all_" + name, "source": name, "op": Op.SUM, "mask": Mask.ALL, "weight": true})
		out.append({"key": "open_" + name, "source": name, "op": Op.SUM, "mask": Mask.OPEN, "weight": true})
	out.append({"key": "energy_stock", "source": "h_j_m3", "op": Op.SUM, "mask": Mask.ALL, "weight": true})
	out.append({"key": "solid_cells", "source": "solid", "op": Op.COUNT_GT, "threshold": 0.0})
	out.append({"key": "carbonate_cells", "source": "carbonate", "op": Op.COUNT_GT, "threshold": 0.0})
	# The frozen share of the one h2o channel: the ladder's own solid fraction, not a separate stock.
	out.append({"key": "snow_cells", "source": "h2o", "aux": "h2o_solid", "op": Op.COUNT_GT,
		"threshold": LAMaterialField3D.SNOW_PRESENT})
	out.append({"key": "ice_cells", "source": "h2o", "aux": "h2o_solid", "op": Op.COUNT_GE,
		"threshold": LAMaterialField3D.ICE_DEPTH})
	# Consolidated rock against the bedrock the world was built with. Loose grains blowing about are
	# sediment transport, not continental drift, so the row is cemented rock and carries no volume weight.
	out.append({"key": "crust_latch", "source": "silicate", "aux": "cement", "op": Op.LATCH,
		"ref": "crust_ref"})
	out.append({"key": "crust_moved", "source": "silicate", "aux": "cement", "op": Op.SUM_ABS_DIFF,
		"ref": "crust_ref"})
	return out
