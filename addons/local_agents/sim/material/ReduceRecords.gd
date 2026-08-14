class_name LAReduceRecords
extends RefCounted

## What the field reduces itself over. reduce.glsl runs every row through one shared-memory tree reduce.

## How a row folds its cells. Generated into reduce.glsl as OP_*.
enum Op { SUM, COUNT_GT, COUNT_GE, COUNT_LT, SUM_ABS_DIFF, LATCH, MIN, MAX, COUNT }

## Which cells a row counts. GROUND is an open cell resting on solid, AIR every other open cell; together
## they partition OPEN. Generated into reduce.glsl as MASK_*.
enum Mask { ALL, OPEN, SOLID, GROUND, AIR }

## What a cell's value is read against: its solid neighbours, the cell one step along or against gravity,
## or the two faces of one grid axis. Generated into reduce.glsl as NBR_*.
enum Nbr { NONE, SOLID_COUNT, BELOW, ABOVE, GRAD_X, GRAD_Y, GRAD_Z }

## Channels whose stock the conservation ledger books, mask-free and open-only.
const AMOUNTS: PackedStringArray = ["h2o", "silicate", "carbonate", "silica",
	"co2", "o2", "n2", "detritus", "biomass", "fert", "fungus", "fuel"]

## One domain's rows per file, so a lane owns a file instead of queueing on this one. Loaded by path
## because a domain file names the enums above, and a class_name in both directions is a cycle.
const ROW_DIR: String = "res://addons/local_agents/sim/material/reduce/"
const ROW_SCRIPTS: PackedStringArray = ["WaterRows.gd", "HeatRows.gd", "MineralRows.gd",
	"AirRows.gd", "LifeRows.gd"]

static var _by_key: Dictionary = {}


## The row declared under `key`, or an empty dictionary. A gauge's threshold is declared here and read back
## from here: the number the kernel compares against and the number a caller names are the same one.
static func row(key: String) -> Dictionary:
	if _by_key.is_empty():
		for r: Dictionary in rows():
			_by_key[String(r["key"])] = r
	return _by_key.get(key, {})


## Value per cell is `source` * (`aux` + `aux2`), read against `nbr`, and `weight` multiplies it by the
## cell's volume in m^3. `ref` is the field a diff is taken from, and `gate`(* `gate_aux`) admits only
## cells inside [`gate_lo`, `gate_hi`).
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
	for path in ROW_SCRIPTS:
		out.append_array((load(ROW_DIR + String(path)) as GDScript).rows())
	return out
