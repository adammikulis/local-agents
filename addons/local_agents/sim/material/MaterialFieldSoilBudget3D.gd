class_name LAMaterialFieldSoilBudget3D
extends RefCounted

## LAMaterialFieldSoilBudget3D: a per-LEG mass budget for the groundwater channel, so a soil drain has to name
## itself instead of being hand-traced. Diagnostic only — created by LAMaterialFieldSphereStep3D and only when
## `LA_SOIL_BUDGET` is in the environment, because it costs a ~6.9 MB readback per sample.
##
## WHY A LEG-BY-LEG LEDGER RATHER THAN MORE READING. soil_total was falling 684 -> 51.8 between field steps 53
## and 746 with every individual transfer looking correct on inspection: springs cannot discharge into a full
## sea cell, Darcy is conserving by construction, up-seep never reaches its threshold, and infiltration only
## adds. Every one of those statements is about what a leg is SUPPOSED to move. This measures what each leg
## ACTUALLY moved and makes them sum, which is the only version of the argument that can be wrong out loud.
##
## THE ONE IDENTITY IT CHECKS. Over the regolith mask, for one step:
##     reg_out - reg_in  ==  darcy_recv + infil_recv - own_out + clamp_gain
## every term read straight out of the kernel. It holds exactly (to fp) if the soil kernel's apply pass is
## self-consistent, so a residual there means the kernel's own arithmetic is not what the code appears to say.
## Then, separately:
##     soil_final - reg_out    = everything that ran AFTER the soil kernel (ReactionsPass R19 root uptake)
##     darcy_sent - darcy_recv = groundwater debited by a sender and credited to nobody
##     infil_sent - infil_recv = surface water debited from `water` and credited to no aquifer cell
##     (spring_sent + seep_sent) - spring_recv = exfiltration that left the soil and never reached the surface
## The three `sent - recv` residuals are all zero if and only if the neighbour table is SLOT-OPPOSITE
## reciprocal. LASphereGrid.validate() checks the WEAKER property (adjacency is mutual — A lists B somewhere
## among its four) and reports symmetric/ok, but every 2-pass gather kernel in this project assumes the
## stronger one: pass 1 reads `send[neighbour * 6 + opposite(slot)]`, so B must list A in the OPPOSITE slot,
## not merely somewhere.
##
## THE TABLE SATISFIES IT. (Corrected 2026-08-03, while landing the erosion transport gather. This line used
## to end "Across the cube-face seams it does not." It does.) Built at the shipped res 24 / depth 20 and
## checked exhaustively: of **407808 directed links, 0 are non-reciprocal** — in the kernel slot order the
## gathers actually use (pairing 0<->5, 1<->2, 3<->4) and in the grid-native order (pairing d^1) alike — with
## `lateral_bends` 48 = 2*res, exactly what LASphereGrid's header predicts for an even res. The seam repair
## works. So a nonzero `*_lost` residual here is a defect in the KERNEL that produced it, not in the geometry
## underneath: do not go looking at the seams first.
##
## (Explicit types only, no ':=' inferred typing.)

# MUST match soil_sphere3d.glsl's DBG_* defines and LAMaterialSphereGPU3D.SOIL_DBG_SLOTS.
const SLOTS: int = 20
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
## 50 steps still puts a line either side of both horizons the drain was measured at (53 and 746).
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

	var leg: PackedFloat64Array = PackedFloat64Array()
	leg.resize(SLOTS)
	for c in cc:
		var base: int = c * SLOTS
		for k in SLOTS:
			leg[k] += dbg[base + k]
	# The FINAL soil (post-ReactionsPass) over the same regolith mask the ledger's soil_total uses, read from
	# the same flush as the probe so the two describe one step rather than two.
	var final_soil: float = 0.0
	var reg_cells: int = 0
	for c in cc:
		if has_reg and regolith[c] == 0:
			continue
		final_soil += soil[c]
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


## THE WATER TABLE'S SHAPE, not its total. `soil_total` is a scalar and a scalar cannot say whether the
## aquifer is surface-following (the header's claim) or pooled in the bottom regolith shells with the top dry
## (what soil_sphere3d.glsl's own comment said the slot-order greed produced). Returns
## [saturation_by_depth, cells_by_depth], indexed by SHELLS BELOW THE GROUND SURFACE: index 0 is the outermost
## regolith shell (the one whose lateral neighbours daylight as springs and whose roof is open air), index
## REGOLITH_CELLS-1 the deepest, sitting on impermeable bedrock. Each entry is the MEAN SATURATION over that
## depth's cells (soil / SOIL_CAPACITY), so the numbers are comparable across depths that hold different cell
## counts, and a surface-following table reads roughly flat while a bottom-pinned one reads as a ramp.
##
## Column layout is c = surf_index * depth + r with r increasing outward (LAMaterialField3D._compute_regolith),
## so the ground surface of a column is simply its OUTERMOST regolith cell — no neighbour table needed, and no
## dependence on the live `solid` mask, which erosion moves out from under the once-seeded regolith band.
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
	var cap: float = LAMaterialField3D.SOIL_CAPACITY
	for d in bands:
		cells.append(n_d[d])
		if n_d[d] > 0 and cap > 0.0:
			sat.append(snappedf(float(sum_d[d]) / (float(n_d[d]) * cap), 0.0001))
		else:
			sat.append(0.0)
	return [sat, cells]
