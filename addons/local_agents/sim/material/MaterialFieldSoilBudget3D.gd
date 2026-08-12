class_name LAMaterialFieldSoilBudget3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldSoilBudget3D: a per-LEG mass budget for the groundwater channel, so a soil drain has to name

# Leg count of the soil_dbg probe buffer; MaterialSphereGPU3D allocates against it.
const SLOTS: int = 21
const DARCY_SENT: int = 0
const SPRING_SENT: int = 1
const SEEP_SENT: int = 2
const INFIL_SENT: int = 3
const REG_IN: int = 4
const REG_OUT: int = 5
const OWN_OUT: int = 6
const DARCY_RECV: int = 7
const INFIL_RECV: int = 8
const CLAMP_GAIN: int = 9
const OPEN_CLAMP_GAIN: int = 20   # the OPEN leg's twin — see soil_sphere3d.glsl:DBG_OPEN_CLAMP_GAIN
const SPRING_RECV: int = 10
const OPEN_DROP: int = 11
const OPEN_FROM_OPEN: int = 12
const BEDROCK_IN: int = 13
const SPRING_DOWN: int = 14
const SPRING_LAT: int = 15
const SPRING_UP: int = 16
const SPRING_WET: int = 17
const SPRING_CAPPED: int = 18
const SPRING_FREECOL: int = 19

## How many field steps between printed budgets. A sample is a full-grid readback, so this is not free; every
const SAMPLE_EVERY: int = 50

var _f = null                    # back-reference to the owning LAMaterialField3D
var _gate: int = 0
var _prev_final: float = NAN     # soil_total at the previous sample, for the between-samples drain rate
var _prev_step: int = -1


func setup(field) -> void:
	_f = field


## Called once per field step by LAMaterialFieldSphereStep3D. Samples on the SAMPLE_EVERY cadence.
func post_step() -> void:
	_gate += 1
	if _gate < SAMPLE_EVERY:
		return
	_gate = 0
	var b: Dictionary = sample()
	if b.is_empty():
		return
	print("SOIL_BUDGET=", JSON.stringify(b))


## One step's complete groundwater budget. Empty when there is no GPU driver (headless/box mode).
func sample() -> Dictionary:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("read_soil_budget"):
		return {}
	var raw: Dictionary = _f._gpu.read_soil_budget()
	if raw.is_empty():
		return {}
	var dbg: PackedFloat32Array = raw["dbg"]
	var soil: PackedFloat32Array = raw["soil"]
	var step_index: int = int(raw["step_index"])
	var cc: int = _f._cell_count
	if dbg.size() < cc * SLOTS or soil.size() < cc:
		return {}
	var regolith: PackedByteArray = _f._regolith
	var has_reg: bool = regolith.size() == cc

	var profile: Array = _table_profile(soil, regolith, cc)

	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return {}
	var leg: PackedFloat64Array = PackedFloat64Array()
	leg.resize(SLOTS)
	for c in cc:
		var base: int = c * SLOTS
		var w: float = vol[c]
		for k in SLOTS:
			leg[k] += dbg[base + k] * w
	var final_soil: float = 0.0
	var reg_cells: int = 0
	for c in cc:
		final_soil += soil[c] * vol[c]
		if not has_reg or regolith[c] != 0:
			reg_cells += 1

	var darcy_sent: float = leg[DARCY_SENT]
	var spring_sent: float = leg[SPRING_SENT]
	var seep_sent: float = leg[SEEP_SENT]
	var infil_sent: float = leg[INFIL_SENT]
	var reg_in: float = leg[REG_IN]
	var reg_out: float = leg[REG_OUT]
	var own_out: float = leg[OWN_OUT]
	var darcy_recv: float = leg[DARCY_RECV]
	var infil_recv: float = leg[INFIL_RECV]
	var clamp_gain: float = leg[CLAMP_GAIN]
	var spring_recv: float = leg[SPRING_RECV]

	# The kernel's own apply arithmetic, restated from the probe. `identity` is the residual; anything but ~0
	# means pass 1 is not doing what it reads as doing.
	var kernel_delta: float = reg_out - reg_in
	var predicted: float = darcy_recv + infil_recv - own_out + clamp_gain
	# What ran after the soil kernel wrote soil_out — ReactionsPass R19 root uptake is the only other writer.
	var post_kernel: float = final_soil - reg_out
	var drain_rate: float = 0.0
	if not is_nan(_prev_final) and step_index > _prev_step:
		drain_rate = (final_soil - _prev_final) / float(step_index - _prev_step)
	_prev_final = final_soil
	_prev_step = step_index

	return {
		"field_step": step_index,
		"regolith_cells": reg_cells,
		"soil_total": snappedf(final_soil, 0.001),
		# --- WHERE the water table stands, by depth below the ground surface (see _table_profile)
		"table_sat": profile[0],
		"table_cells": profile[1],
		"soil_per_step": snappedf(drain_rate, 0.0001),
		# --- soil-kernel legs, sender side
		"darcy_sent": snappedf(darcy_sent, 0.0001),
		"spring_sent": snappedf(spring_sent, 0.0001),
		"seep_sent": snappedf(seep_sent, 0.0001),
		"infil_sent": snappedf(infil_sent, 0.0001),
		# --- where the springs actually discharge (the same spring_sent, split four ways)
		"spring_down": snappedf(leg[SPRING_DOWN], 0.0001),
		"spring_lat": snappedf(leg[SPRING_LAT], 0.0001),
		"spring_up": snappedf(leg[SPRING_UP], 0.0001),
		"spring_into_wet": snappedf(leg[SPRING_WET], 0.0001),
		"spring_capped": snappedf(leg[SPRING_CAPPED], 0.0001),
		"spring_freecol": snappedf(leg[SPRING_FREECOL], 0.0001),
		# --- soil-kernel legs, receiver side
		"darcy_recv": snappedf(darcy_recv, 0.0001),
		"infil_recv": snappedf(infil_recv, 0.0001),
		"spring_recv": snappedf(spring_recv, 0.0001),
		# --- the three sent-vs-received residuals: groundwater debited and credited to nobody
		"darcy_lost": snappedf(darcy_sent - darcy_recv, 0.0001),
		"infil_lost": snappedf(infil_sent - infil_recv, 0.0001),
		"spring_lost": snappedf(spring_sent + seep_sent - spring_recv, 0.0001),
		# --- the silent sinks that are not transfers at all
		"clamp_gain": snappedf(clamp_gain, 0.0001),
		# WATER rather than soil, which is why no soil total could ever have revealed it and why the H2O
		# ledger could see it only as an unattributed aggregate. Nonzero here is H2O from nothing, named.
		"open_clamp_gain": snappedf(leg[OPEN_CLAMP_GAIN], 0.0001),
		"open_drop": snappedf(leg[OPEN_DROP], 0.0001),
		"open_from_open": snappedf(leg[OPEN_FROM_OPEN], 0.0001),
		"bedrock_in": snappedf(leg[BEDROCK_IN], 0.0001),
		# --- the closing sums
		"own_out": snappedf(own_out, 0.0001),
		"kernel_delta": snappedf(kernel_delta, 0.0001),
		"kernel_predicted": snappedf(predicted, 0.0001),
		"kernel_residual": snappedf(kernel_delta - predicted, 0.0001),
		"post_kernel": snappedf(post_kernel, 0.0001),
	}


func _table_profile(soil: PackedFloat32Array, regolith: PackedByteArray, cc: int) -> Array:
	var bands: int = LAMaterialField3D.REGOLITH_CELLS
	var sat: Array = []
	var cells: Array = []
	if regolith.size() != cc or soil.size() < cc or _f._sphere == null:
		return [sat, cells]
	var depth: int = int(_f._sphere.depth)
	if depth <= 0:
		return [sat, cells]
	var sum_d: PackedFloat64Array = PackedFloat64Array()
	var n_d: PackedInt32Array = PackedInt32Array()
	sum_d.resize(bands)
	n_d.resize(bands)
	var col: int = 0
	while col * depth < cc:
		var base: int = col * depth
		var surf_r: int = -1
		var r: int = depth - 1
		while r >= 0:
			if regolith[base + r] != 0:
				surf_r = r
				break
			r -= 1
		if surf_r >= 0:
			r = surf_r
			while r >= 0:
				if regolith[base + r] == 0:
					break                              # the band is contiguous; the first gap ends it
				var d: int = surf_r - r
				if d >= bands:
					break
				sum_d[d] += soil[base + r]
				n_d[d] += 1
				r -= 1
		col += 1
	# Saturation is soil over the cell's own CAPACITY, and capacity is POROSITY, which closes with burial —
	# flat SOIL_CAPACITY = 0.6, which both overstated the deep bands' saturation and hid the compaction.)
	for d in bands:
		cells.append(n_d[d])
		var cap: float = LAMaterialFieldRegolith3D.porosity_at(d)
		if n_d[d] > 0 and cap > 0.0:
			sat.append(snappedf(float(sum_d[d]) / (float(n_d[d]) * cap), 0.0001))
		else:
			sat.append(0.0)
	return [sat, cells]
