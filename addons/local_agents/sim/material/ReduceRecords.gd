class_name LAReduceRecords
extends RefCounted

## What the field reduces itself over. reduce.glsl runs every row through one shared-memory tree reduce.

## How a row folds its cells. Generated into reduce.glsl as OP_*.
enum Op { SUM, COUNT_GT, COUNT_GE, SUM_ABS_DIFF, LATCH, MIN, MAX, COUNT }

## Which cells a row counts. Generated into reduce.glsl as MASK_*.
enum Mask { ALL, OPEN, SOLID }

## Channels whose stock the conservation ledger books, mask-free and open-only.
const AMOUNTS: PackedStringArray = ["h2o", "silicate", "carbonate", "silica",
	"co2", "o2", "n2", "detritus", "biomass", "fert", "fungus", "fuel"]

static var _by_key: Dictionary = {}


## The row declared under `key`, or an empty dictionary. A gauge's threshold is declared here and read back
## from here: the number the kernel compares against and the number a caller names are the same one.
static func row(key: String) -> Dictionary:
	if _by_key.is_empty():
		for r: Dictionary in rows():
			_by_key[String(r["key"])] = r
	return _by_key.get(key, {})


## Value per cell is `source` * (`aux` + `aux2`), or its count of solid neighbours under `nbr_solid`, and
## `weight` multiplies it by the cell's volume in m^3. `ref` is the field a diff is taken from, and
## `gate`(* `gate_aux`) admits only cells inside [`gate_lo`, `gate_hi`).
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
	out.append_array(_water_rows())
	out.append_array(_heat_rows())
	out.append_array(_mineral_rows())
	out.append_array(_air_rows())
	out.append_array(_life_rows())
	return out


## LIQUID h2o: the one water channel times the share the enthalpy ladder leaves liquid at this cell.
static func _water_rows() -> Array:
	var wet_min: float = 0.01           # volume fraction of a cell below which it is not holding water
	var wet: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid", "gate_lo": wet_min}
	return [
		{"key": "water_liquid_total", "source": "h2o", "aux": "h2o_liquid", "op": Op.SUM,
			"mask": Mask.ALL, "weight": true},
		{"key": "wet_cells", "source": "h2o", "aux": "h2o_liquid", "op": Op.COUNT_GE,
			"mask": Mask.OPEN, "threshold": LAMaterialField3D.RENDER_MIN},
		# Airborne h2o over every cell, in moles, mask-free.
		{"key": "vapour_amount", "source": "h2o", "aux": "h2o_vapour", "op": Op.SUM,
			"mask": Mask.ALL, "weight": true},
		# Surface water hot enough to be a spring, and the peak it reaches. Gated on holding water at all,
		# so the peak is the hottest WATER rather than the hottest cell.
		{"key": "hotspring_wet", "source": "h2o", "aux": "h2o_liquid", "op": Op.COUNT_GE,
			"mask": Mask.OPEN, "threshold": wet_min},
		_merged({"key": "hotspring_max_c", "source": "temp", "op": Op.MAX, "mask": Mask.OPEN}, wet),
		_merged({"key": "hotspring_mild", "source": "temp", "op": Op.COUNT_GT, "mask": Mask.OPEN,
			"threshold": 30.0}, wet),
		_merged({"key": "hotspring_cells", "source": "temp", "op": Op.COUNT_GT, "mask": Mask.OPEN,
			"threshold": 60.0}, wet),
		_merged({"key": "hotspring_boiling", "source": "temp", "op": Op.COUNT_GE, "mask": Mask.OPEN,
			"threshold": LAPhysical.WATER_BOIL_C}, wet),
	]


static func _heat_rows() -> Array:
	return [
		{"key": "open_temp_max", "source": "temp", "op": Op.MAX, "mask": Mask.OPEN},
		{"key": "open_temp_min", "source": "temp", "op": Op.MIN, "mask": Mask.OPEN},
		# Unweighted: over the open-cell count this is a mean over CELLS, not volume. all_temp_max is the
		# deep rock the open-only rows cannot see; pressure_written's complement is the cells no walk reached.
		{"key": "open_temp_sum", "source": "temp", "op": Op.SUM, "mask": Mask.OPEN},
		{"key": "all_temp_max", "source": "temp", "op": Op.MAX, "mask": Mask.ALL},
		{"key": "pressure_written", "source": "pressure", "op": Op.COUNT_GE, "threshold": 0.0},
		# 60 °C: the one temperature "a hot open cell" means here. Read back through row("hot_cells").
		{"key": "hot_cells", "source": "temp", "op": Op.COUNT_GE, "mask": Mask.OPEN, "threshold": 60.0},
		{"key": "fire_peak", "source": "fire", "op": Op.MAX, "mask": Mask.ALL},
		{"key": "fire_cells", "source": "fire", "op": Op.COUNT_GT, "mask": Mask.ALL,
			"threshold": LAMaterialFieldQueries3D.FIRE_PRESENT},
		# J/m^3 per step, so volume-weighted these are joules per step. Mask-free: the outflow pass emits
		# from solid cells too, so an OPEN mask would drop the ground's emission.
		{"key": "rad_absorbed", "source": "rad_absorbed", "op": Op.SUM, "mask": Mask.ALL, "weight": true},
		{"key": "rad_emitted", "source": "rad_emitted", "op": Op.SUM, "mask": Mask.ALL, "weight": true},
	]


## Melt is mask-free: it lingers the instant a cell crosses to derived-solid, so an open-only sum would
## drop matter that physically exists. Melt confined by rock is magma; melt in the open is lava.
static func _mineral_rows() -> Array:
	var drained: Dictionary = {"gate": "silicate", "gate_aux": "silicate_melt",
		"gate_hi": LAMaterialFieldQueries3D.TUBE_MELT_NEAR_ZERO}
	var melt: Dictionary = {"source": "silicate", "aux": "silicate_melt", "mask": Mask.OPEN}
	return [
		{"key": "melt_total", "source": "silicate", "aux": "silicate_melt", "op": Op.SUM,
			"mask": Mask.ALL, "weight": true},
		{"key": "magma_cells", "source": "silicate", "aux": "silicate_melt", "op": Op.COUNT_GE,
			"mask": Mask.SOLID, "threshold": LAMaterialFieldQueries3D.MOLTEN_MIN},
		{"key": "lava_cells", "source": "silicate", "aux": "silicate_melt", "op": Op.COUNT_GE,
			"mask": Mask.OPEN, "threshold": LAMaterialFieldQueries3D.MOLTEN_MIN},
		# Wind-borne mineral, per cell, unweighted: its consumer is a mean over cells, not an amount.
		{"key": "airborne_mineral_sum", "source": "silicate", "aux": "silicate_susp_air", "op": Op.SUM,
			"mask": Mask.ALL},
		# Open cells carrying a real suspended load; then a melt body, one over half full, and its peak.
		{"key": "suspended_cells", "source": "silicate", "aux": "silicate_susp_water", "op": Op.COUNT_GT,
			"mask": Mask.OPEN, "threshold": LAMaterialFieldMineralProfile3D.SUSP_ACTIVE},
		_merged(melt, {"key": "lava_hot", "op": Op.COUNT_GE, "threshold": 0.001}),
		_merged(melt, {"key": "lava_thick", "op": Op.COUNT_GE, "threshold": 0.5}),
		_merged(melt, {"key": "lava_maxmass", "op": Op.MAX}),
		# An open cell walled in by rock and no longer melt-filled — a drained lava tube.
		_merged({"key": "enclosed_void4", "source": "solid", "op": Op.COUNT_GE, "mask": Mask.OPEN,
			"threshold": 4.0, "nbr_solid": true}, drained),
		_merged({"key": "enclosed_void5", "source": "solid", "op": Op.COUNT_GE, "mask": Mask.OPEN,
			"threshold": 5.0, "nbr_solid": true}, drained),
	]


## Air: the gases a lung meets, the condensate a cloud is, and the mean flow.
static func _air_rows() -> Array:
	# A cell over half full of liquid water has displaced its air, so it is not part of the open sky.
	var breathable: Dictionary = {"gate": "h2o", "gate_aux": "h2o_liquid",
		"gate_hi": LAMaterialField3D.MAX_MASS * 0.5}
	# Suspended condensate: the liquid and frozen shares of this cell's h2o, together.
	var cond: Dictionary = {"source": "h2o", "aux": "h2o_liquid", "aux2": "h2o_solid", "mask": Mask.OPEN}
	var warm: Dictionary = {"gate": "temp", "gate_lo": LAMaterialField3D.FOG_MAX_TEMP}
	var cool: Dictionary = {"gate": "temp", "gate_hi": LAMaterialField3D.FOG_MAX_TEMP}
	return [
		_merged({"key": "o2_open_min", "source": "o2", "op": Op.MIN, "mask": Mask.OPEN}, breathable),
		_merged({"key": "o2_open_sum", "source": "o2", "op": Op.SUM, "mask": Mask.OPEN}, breathable),
		_merged({"key": "o2_open_cells", "source": "o2", "op": Op.COUNT, "mask": Mask.OPEN}, breathable),
		{"key": "co2_open_max", "source": "co2", "op": Op.MAX, "mask": Mask.OPEN},
		{"key": "co2_open_sum", "source": "co2", "op": Op.SUM, "mask": Mask.OPEN},
		_merged(cond, {"key": "precip_cells", "op": Op.COUNT_GT,
			"threshold": LAMaterialFieldAtmos3D.rain_threshold()}),
		_merged(_merged(cond, {"key": "cloud_cells", "op": Op.COUNT_GE,
			"threshold": LAMaterialField3D.CONDENSE_COVER_MIN}), warm),
		_merged(_merged(cond, {"key": "fog_cells", "op": Op.COUNT_GE,
			"threshold": LAMaterialField3D.CONDENSE_COVER_MIN}), cool),
		{"key": "wind_x_sum", "source": "vel_x", "op": Op.SUM, "mask": Mask.OPEN},
		{"key": "wind_z_sum", "source": "vel_z", "op": Op.SUM, "mask": Mask.OPEN},
		{"key": "shock_cells", "source": "shock", "op": Op.COUNT_GT, "mask": Mask.OPEN,
			"threshold": LAMaterialShock3D.SHOCK_ACTIVE},
	]


static func _life_rows() -> Array:
	return [
		{"key": "fert_peak", "source": "fert", "op": Op.MAX, "mask": Mask.OPEN},
		{"key": "fungus_peak", "source": "fungus", "op": Op.MAX, "mask": Mask.OPEN},
		{"key": "fungus_cells", "source": "fungus", "op": Op.COUNT_GE, "mask": Mask.OPEN,
			"threshold": LAMaterialFieldChannels3D.FUNGUS_PRESENT},
		{"key": "detritus_peak", "source": "detritus", "op": Op.MAX, "mask": Mask.OPEN},
		{"key": "detritus_cells", "source": "detritus", "op": Op.COUNT_GE, "mask": Mask.OPEN,
			"threshold": LAMaterialFieldChannels3D.DETRITUS_PRESENT},
	]


## `b`'s entries over `a`'s: a gate or a shared value expression applied to a row.
static func _merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = a.duplicate()
	out.merge(b, true)
	return out
