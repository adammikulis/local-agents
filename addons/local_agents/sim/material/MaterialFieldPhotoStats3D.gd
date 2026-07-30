class_name LAMaterialFieldPhotoStats3D
extends RefCounted

## LAMaterialFieldPhotoStats3D: the SPATIAL telemetry for primary production — what the photosynthesis
## record actually sees, cell by cell, instead of one planet-wide total. A focused report module in the same
## family as the ledger / query / report modules: it holds no state, reaches into the owning field `_f`, and
## every scan runs at SNAPSHOT cadence only, never per frame.
##
## It exists because `biomass_total` alone cannot answer the question this is about: is growth DIFFERENTIATED
## by the things that should limit it (light, root water), or is it uniform? One total reads identical for
## "the whole planet greens evenly" and "only the wet lit half greens". So this reports the DRIVERS and the
## RESPONSE over the same cell set, plus the wet/dry and lit/dark contrasts, which are the falsifiable claims.
##
## CELL SETS (they are not the same set, and that difference was itself a finding — measured 2026-07-29):
##   * GROUND skin — an OPEN cell whose INWARD neighbour is solid rock. This is where a plant physically is:
##     leaves in the air cell, roots in the rock below. Matches heat3d_solar's `ground_hug` + the snowice
##     deposition surface. 2156 cells.
##   * SKY skin — an OPEN cell whose OUTWARD neighbour is space or rock (the reaction kernel's GATE_SURFACE).
##     On a shell that is the TOP OF THE ATMOSPHERE, ~78 world-units above the terrain. 3456 cells.
##   Before Keystone B, R19 photosynthesis was gated GATE_SURFACE, so 100% of it ran at the top of the
##   atmosphere: biomass_sky 2334, biomass_ground 0.0.
##
## ROOT WATER: `soil` is only ever non-zero in REGOLITH cells — soil_sphere3d.glsl:223-229 keys on the regolith
## mask and writes `soil_out[g] = 0.0` for every non-regolith open cell. A plant's root water is therefore the
## soil in the permeable regolith COLUMN beneath it (REGOLITH_CELLS deep; below that is impermeable bedrock),
## which is exactly the agronomic rooting-zone available water. `root_d1..d4` break that column down by shell
## because the shape matters: Darcy drives groundwater toward lower head, so the table sits on the bedrock
## floor and the top shells are dry (measured d1 5.1e-9, d2 1.3e-8, d3 0.199, d4 0.543). Reading `soil` at the
## open cell, or at the single cell directly below it, reads a structural zero — not an absence of land water.
##
## The column walk masks on `regolith`, NOT on `solid`, and that correction is load-bearing (2026-07-30). The
## two masks diverge — `solid` is re-derived from rock_fill every step, `regolith` is seeded once — so an
## eroded or river-carved aquifer cell reads open while still holding and still simulating its soil. Because
## the water sits DEEP (d1/d2 ~0, d3/d4 carry it all), a walk that stopped at such a cell discarded the entire
## water table and reported bone-dry ground: FAKE DESERTS, in the one gauge built to measure real ones.
## (Explicit types only, no ':=' inferred typing.)

const LIT_MIN: float = 0.05                # insolation above which a cell counts as genuinely lit
const WET_SPLIT: float = 0.5               # rooting-column water splitting "dry" ground from "wet" ground
const DRY_EPS: float = 0.01                # rooting-column water below which the ground counts as bone dry

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## World-space unit vector toward the sun, magnitude carrying insolation — the SAME quantity the field hands
## the solar kernel (MaterialFieldSphereStep3D.gd:114) and now the reaction engine's derived LIGHT slot, so
## the light measured here is the light the chemistry sees. No sun node (a bare headless field) -> zero.
func sun_dir() -> Vector3:
	if _f._sun_light == null:
		return Vector3.ZERO
	var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
	return _f._sun_light.global_transform.basis.z * insol


func report() -> Dictionary:
	var out: Dictionary = _blank()
	if _f._sphere == null or _f._cell_count <= 0:
		return out
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var soil: PackedFloat32Array = _f._soil
	var regolith: PackedByteArray = _f._regolith
	var biomass: PackedFloat32Array = _f._biomass
	var temp: PackedFloat32Array = _f._temp
	var co2: PackedFloat32Array = _f._co2
	var fert: PackedFloat32Array = _f._fert
	if solid.size() != cc or biomass.size() != cc:
		return out
	var has_soil: bool = soil.size() == cc
	var has_reg: bool = regolith.size() == cc
	var has_co2: bool = co2.size() == cc
	var has_fert: bool = fert.size() == cc
	var has_temp: bool = temp.size() == cc
	var depth: int = int(_f._sphere.depth)
	var reg: int = LAMaterialField3D.REGOLITH_CELLS
	if depth <= 0:
		return out
	var sun: Vector3 = sun_dir()

	# Column layout is c = surf_index * depth + r (MaterialField3D._compute_regolith), so the inward
	# neighbour is c-1 (r>0) and the outward neighbour is c+1 (r<depth-1). No neighbour table needed.
	var col_vals: PackedFloat32Array = PackedFloat32Array()
	var col_bio: PackedFloat32Array = PackedFloat32Array()   # parallel to col_vals — biomass of the SAME cell
	var light_vals: PackedFloat32Array = PackedFloat32Array()
	var temp_vals: PackedFloat32Array = PackedFloat32Array()
	var co2_vals: PackedFloat32Array = PackedFloat32Array()
	var dsum: PackedFloat32Array = PackedFloat32Array()
	dsum.resize(reg)
	var ground_n: int = 0
	var sky_n: int = 0
	var bio_ground: float = 0.0
	var bio_sky: float = 0.0
	var light_sum: float = 0.0
	var fert_sum: float = 0.0
	var lit_n: int = 0
	var dry_n: int = 0
	var bone_n: int = 0
	var wet_n: int = 0
	var dark_n: int = 0
	var bio_wet: float = 0.0
	var bio_dry: float = 0.0
	var bio_lit: float = 0.0
	var bio_dark: float = 0.0
	var bio_lit_dry: float = 0.0
	var bio_lit_wet: float = 0.0
	var lit_dry_n: int = 0
	var lit_wet_n: int = 0

	for c in cc:
		if solid[c] != 0 or stat[c] != 0:
			continue                                     # rock, and the static sea reservoir, are not plant ground
		var r: int = c % depth
		if (r >= depth - 1) or (solid[c + 1] != 0):      # SKY skin = the kernel's GATE_SURFACE test
			sky_n += 1
			bio_sky += biomass[c]
		if r <= 0 or solid[c - 1] == 0:
			continue                                     # not GROUND skin — no rock beneath, so no roots
		ground_n += 1
		bio_ground += biomass[c]
		# Rooting-zone water: walk inward through the permeable REGOLITH band, counting the first open aquifer
		# cell and stopping there (which is what makes each ground cell's column disjoint from every other's).
		# This MUST stay cell-for-cell identical to reactions_sphere3d.glsl's root_soil() — it is the gauge for
		# that walk, and when it mirrored the kernel's old solid-mask test the two agreed with each other while
		# both were wrong, so the telemetry confirmed the bug instead of catching it. Mask on `regolith`, not
		# `solid`: `solid` is re-derived from rock_fill every step while `regolith` is seeded once, so an
		# eroded or carved aquifer cell reads open yet still holds and still simulates its soil.
		var col: float = 0.0
		if has_soil and has_reg:
			for d in reg:
				var rc: int = c - 1 - d
				if r - 1 - d < 0 or regolith[rc] == 0:
					break
				col += soil[rc]
				dsum[d] += soil[rc]
				if solid[rc] == 0:
					break
		col_vals.append(col)
		col_bio.append(biomass[c])
		var light: float = maxf(0.0, _f.cell_radial(c).dot(sun))
		light_vals.append(light)
		light_sum += light
		if has_temp:
			temp_vals.append(temp[c])
		if has_co2:
			co2_vals.append(co2[c])
		if has_fert:
			fert_sum += fert[c]
		if light > LIT_MIN:
			lit_n += 1
			bio_lit += biomass[c]
			# WETNESS, ISOLATED FROM LIGHT. Wet ground and lit ground are correlated on a planet (the wettest
			# land is often the cold pole), so a raw wet/dry split confounds the two drivers. Restricting the
			# comparison to cells that are already LIT removes light as the limiter, leaving water as the only
			# thing that differs — this is the pair that actually tests the claim.
			if col < DRY_EPS:
				lit_dry_n += 1
				bio_lit_dry += biomass[c]
			elif col >= WET_SPLIT:
				lit_wet_n += 1
				bio_lit_wet += biomass[c]
		else:
			dark_n += 1
			bio_dark += biomass[c]
		if col < DRY_EPS:
			bone_n += 1
		if col < WET_SPLIT:
			dry_n += 1
			bio_dry += biomass[c]
		else:
			wet_n += 1
			bio_wet += biomass[c]

	out["photo_ground_cells"] = ground_n
	out["photo_sky_cells"] = sky_n
	out["biomass_ground"] = bio_ground
	out["biomass_sky"] = bio_sky
	if ground_n <= 0:
		return out
	var gn: float = float(ground_n)
	out["light_mean"] = light_sum / gn
	out["light_lit_frac"] = float(lit_n) / gn
	out["fert_ground_mean"] = fert_sum / gn
	out["root_col_dry_frac"] = float(dry_n) / gn
	out["root_col_bone_frac"] = float(bone_n) / gn
	var col_sorted: PackedFloat32Array = col_vals.duplicate()
	col_sorted.sort()
	light_vals.sort()
	out["root_col_mean"] = _mean(col_sorted)
	out["root_col_p10"] = _pct(col_sorted, 0.10)
	out["root_col_p50"] = _pct(col_sorted, 0.50)
	out["root_col_p90"] = _pct(col_sorted, 0.90)
	out["root_col_max"] = col_sorted[col_sorted.size() - 1]
	# Wetness quartiles: sort the land ground cells by rooting-column water and report mean biomass in each.
	# READ THESE WITH CARE — they are CONFOUNDED and should not be used as the wetness result on their own.
	# On a planet the wettest ground is disproportionately the cold dark pole (that is where water converges and
	# stays), so a raw water-quartile split also sorts by light and temperature, and the quartile means come out
	# NON-MONOTONE even when water is limiting hard (measured: 0.338 / 0.441 / 0.467 / 0.199 while the
	# light-isolated contrast over the same cells was 51.8x). `biomass_lit_wet_dry_ratio` below is the valid
	# statistic; these four are kept because seeing the confound is more useful than not having the shape.
	var q1: float = _pct(col_sorted, 0.25)
	var q2: float = _pct(col_sorted, 0.50)
	var q3: float = _pct(col_sorted, 0.75)
	var qb: PackedFloat32Array = PackedFloat32Array()
	var qn: PackedInt32Array = PackedInt32Array()
	qb.resize(4)
	qn.resize(4)
	var bone_b: float = 0.0
	for i in col_vals.size():
		var v: float = col_vals[i]
		var qi: int = 0
		if v >= q3:
			qi = 3
		elif v >= q2:
			qi = 2
		elif v >= q1:
			qi = 1
		qb[qi] += col_bio[i]
		qn[qi] += 1
		if v < DRY_EPS:
			bone_b += col_bio[i]
	for d in 4:
		out["biomass_wq%d" % (d + 1)] = (qb[d] / float(qn[d])) if qn[d] > 0 else 0.0
	out["biomass_bone_mean"] = (bone_b / float(bone_n)) if bone_n > 0 else 0.0
	var w4: float = float(out["biomass_wq4"])
	var w1: float = float(out["biomass_wq1"])
	out["biomass_wq4_wq1_ratio"] = (w4 / w1) if w1 > 1.0e-9 else 0.0
	out["light_p50"] = _pct(light_vals, 0.50)
	out["light_max"] = light_vals[light_vals.size() - 1]
	if temp_vals.size() > 0:
		temp_vals.sort()
		out["temp_ground_mean"] = _mean(temp_vals)
		out["temp_ground_p10"] = _pct(temp_vals, 0.10)
		out["temp_ground_p50"] = _pct(temp_vals, 0.50)
		out["temp_ground_p90"] = _pct(temp_vals, 0.90)
	if co2_vals.size() > 0:
		co2_vals.sort()
		out["co2_ground_mean"] = _mean(co2_vals)
		out["co2_ground_p10"] = _pct(co2_vals, 0.10)
		out["co2_ground_p50"] = _pct(co2_vals, 0.50)
	for d in dsum.size():
		out["root_d%d" % (d + 1)] = dsum[d] / gn
	out["biomass_wet_mean"] = (bio_wet / float(wet_n)) if wet_n > 0 else 0.0
	out["biomass_dry_mean"] = (bio_dry / float(dry_n)) if dry_n > 0 else 0.0
	out["biomass_lit_mean"] = (bio_lit / float(lit_n)) if lit_n > 0 else 0.0
	out["biomass_dark_mean"] = (bio_dark / float(dark_n)) if dark_n > 0 else 0.0
	# The headline spatial claims. 1.0 = undifferentiated (the old behaviour, where neither water nor light
	# entered the rate at all); >1 = that driver genuinely limits growth somewhere.
	var dm: float = float(out["biomass_dry_mean"])
	out["biomass_wet_dry_ratio"] = (float(out["biomass_wet_mean"]) / dm) if dm > 1.0e-9 else 0.0
	var km: float = float(out["biomass_dark_mean"])
	out["biomass_lit_dark_ratio"] = (float(out["biomass_lit_mean"]) / km) if km > 1.0e-9 else 0.0
	out["lit_dry_cells"] = lit_dry_n
	out["lit_wet_cells"] = lit_wet_n
	out["biomass_lit_dry_mean"] = (bio_lit_dry / float(lit_dry_n)) if lit_dry_n > 0 else 0.0
	out["biomass_lit_wet_mean"] = (bio_lit_wet / float(lit_wet_n)) if lit_wet_n > 0 else 0.0
	var ldm: float = float(out["biomass_lit_dry_mean"])
	out["biomass_lit_wet_dry_ratio"] = (float(out["biomass_lit_wet_mean"]) / ldm) if ldm > 1.0e-9 else 0.0
	return out


func _blank() -> Dictionary:
	return {
		"photo_ground_cells": 0, "photo_sky_cells": 0,
		"root_col_mean": 0.0, "root_col_p10": 0.0, "root_col_p50": 0.0, "root_col_p90": 0.0,
		"root_col_max": 0.0, "root_col_dry_frac": 0.0, "root_col_bone_frac": 0.0,
		"root_d1": 0.0, "root_d2": 0.0, "root_d3": 0.0, "root_d4": 0.0,
		"light_mean": 0.0, "light_p50": 0.0, "light_max": 0.0, "light_lit_frac": 0.0,
		"temp_ground_mean": 0.0, "temp_ground_p10": 0.0, "temp_ground_p50": 0.0, "temp_ground_p90": 0.0,
		"co2_ground_mean": 0.0, "co2_ground_p10": 0.0, "co2_ground_p50": 0.0, "fert_ground_mean": 0.0,
		"biomass_ground": 0.0, "biomass_sky": 0.0,
		"biomass_wet_mean": 0.0, "biomass_dry_mean": 0.0, "biomass_wet_dry_ratio": 0.0,
		"biomass_lit_mean": 0.0, "biomass_dark_mean": 0.0, "biomass_lit_dark_ratio": 0.0,
		"biomass_wq1": 0.0, "biomass_wq2": 0.0, "biomass_wq3": 0.0, "biomass_wq4": 0.0,
		"biomass_wq4_wq1_ratio": 0.0, "biomass_bone_mean": 0.0,
		"biomass_lit_dry_mean": 0.0, "biomass_lit_wet_mean": 0.0, "biomass_lit_wet_dry_ratio": 0.0,
		"lit_dry_cells": 0, "lit_wet_cells": 0,
	}


func _mean(vals: PackedFloat32Array) -> float:
	var n: int = vals.size()
	if n <= 0:
		return 0.0
	var s: float = 0.0
	for v in vals:
		s += v
	return s / float(n)


## Value at a fractional rank of an ALREADY-SORTED array (nearest-rank; the array is never empty here).
func _pct(sorted_vals: PackedFloat32Array, f: float) -> float:
	var n: int = sorted_vals.size()
	var i: int = clampi(int(floor(f * float(n))), 0, n - 1)
	return sorted_vals[i]
