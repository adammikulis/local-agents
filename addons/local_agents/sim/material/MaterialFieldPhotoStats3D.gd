class_name LAMaterialFieldPhotoStats3D
extends RefCounted

## LAMaterialFieldPhotoStats3D: the SPATIAL telemetry for primary production — what the photosynthesis

const LIT_MIN: float = 0.05                # insolation above which a cell counts as genuinely lit
const WET_SPLIT: float = 0.5               # rooting-column water splitting "dry" ground from "wet" ground
const DRY_EPS: float = 0.01                # rooting-column water below which the ground counts as bone dry

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


func sun_dir() -> Vector3:
	if _f._sun_light == null:
		return Vector3.ZERO
	var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
	return _f.dir_to_field(_f._sun_light.global_transform.basis.z * insol)


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
	var open_n: int = 0                                      # ground columns whose walk ended on an OPEN aquifer cell
	var open_soil: float = 0.0                               # soil in those cells — what the old solid-masked walk lost

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
		var col: float = 0.0
		if has_soil and has_reg:
			for d in reg:
				var rc: int = c - 1 - d
				if r - 1 - d < 0 or regolith[rc] == 0:
					break
				col += soil[rc]
				dsum[d] += soil[rc]
				if solid[rc] == 0:
					open_n += 1
					open_soil += soil[rc]
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
	out["root_col_open_frac"] = float(open_n) / gn
	out["root_col_open_soil"] = open_soil / gn
	var col_sorted: PackedFloat32Array = col_vals.duplicate()
	col_sorted.sort()
	light_vals.sort()
	out["root_col_mean"] = _mean(col_sorted)
	out["root_col_p10"] = _pct(col_sorted, 0.10)
	out["root_col_p50"] = _pct(col_sorted, 0.50)
	out["root_col_p90"] = _pct(col_sorted, 0.90)
	out["root_col_max"] = col_sorted[col_sorted.size() - 1]
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
		"root_col_open_frac": 0.0, "root_col_open_soil": 0.0,
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
