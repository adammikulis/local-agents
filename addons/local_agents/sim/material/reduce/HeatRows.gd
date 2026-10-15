class_name LAReduceHeatRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

static func rows() -> Array:
	return [
		{"key": "open_temp_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.OPEN},
		{"key": "open_temp_min", "source": "temp", "op": Rec.Op.MIN, "mask": Rec.Mask.OPEN},
		# Unweighted: over the open-cell count this is a mean over CELLS, not volume. all_temp_max is the
		# deep rock the open-only rows cannot see.
		{"key": "open_temp_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN},
		{"key": "open_temp_n", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.OPEN},
		{"key": "all_temp_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		# The ground SKIN: an open cell whose gravity-below neighbour is solid. Unweighted, so over
		# ground_cells this is a mean over cells. First rows to dispatch Mask.GROUND.
		{"key": "ground_cells", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.GROUND},
		{"key": "temp_ground_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.GROUND},
		# 60 °C: the one temperature "a hot open cell" means here. Read back through row("hot_cells").
		{"key": "hot_cells", "source": "temp", "op": Rec.Op.COUNT_GE, "mask": Rec.Mask.OPEN, "threshold": 60.0},
		{"key": "fire_peak", "source": "fire", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		{"key": "fire_cells", "source": "fire", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.ALL, "threshold": 0.0},
		# J/m^3 per step, so volume-weighted these are joules per step. Mask-free: the outflow pass emits
		# from solid cells too, so an OPEN mask would drop the ground's emission. `energy_book` is the sign
		# the energy books fold a row's joules with: +1 into the field, -1 out of it.
		{"key": "rad_absorbed", "source": "rad_absorbed", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": 1.0},
		{"key": "rad_emitted", "source": "rad_emitted", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": -1.0},
		# The rock's own decay, J/m^3 per step, volume-weighted to joules.
		{"key": "radiogenic", "source": "radiogenic", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": 1.0},
		{"key": "sw_reflected", "source": "sw_space", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true},
		{"key": "rad_sb_rel_max", "source": "rad_residual", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		# THE GEOTHERM DETECTOR: temperature step against the cell above, K, over the solid interior.
		{"key": "geo_grad_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.SOLID,
			"nbr": Rec.Nbr.ABOVE},
		{"key": "geo_grad_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.SOLID,
			"nbr": Rec.Nbr.ABOVE},
		{"key": "geo_grad_pairs", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.SOLID,
			"nbr": Rec.Nbr.ABOVE},
		{"key": "clim_ground_cells", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.GROUND},
		{"key": "clim_ground_frozen", "source": "temp", "op": Rec.Op.COUNT_LT, "mask": Rec.Mask.GROUND,
			"threshold": LAPhysical.WATER_FREEZE_C},
		{"key": "clim_ground_min", "source": "temp", "op": Rec.Op.MIN, "mask": Rec.Mask.GROUND},
		{"key": "clim_air_cells", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.AIR},
		{"key": "clim_air_frozen", "source": "temp", "op": Rec.Op.COUNT_LT, "mask": Rec.Mask.AIR,
			"threshold": LAPhysical.WATER_FREEZE_C},
		# THE LAPSE. Temperature across one cell against the cell one step out of gravity, over the open air.
		{"key": "air_grad_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.OPEN,
			"nbr": Rec.Nbr.ABOVE},
		{"key": "air_grad_pairs", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.OPEN,
			"nbr": Rec.Nbr.ABOVE},
		# THE ROCK SKIN: the outermost rock of a column, which state_derive.glsl classes 3.
		{"key": "rock_skin_cells", "source": "surface_class", "op": Rec.Op.COUNT_GE, "threshold": 2.5},
		{"key": "rock_skin_sum", "source": "temp", "op": Rec.Op.SUM, "gate": "surface_class",
			"gate_lo": 2.5},
	] + _lat_band_rows() + _alt_band_rows() + _rock_profile_rows()


## THE GEOTHERM AGAINST RADIUS: five samples of the rock's temperature, each a sixteenth of the sea
## shell's radius wide, the outermost open above so a peak standing over the shell falls in it.
## `r_frac` is |r| over that radius, NaN where the body carries no shell.
const PROFILE_WIDTH: float = 1.0 / 16.0
const PROFILE_SAMPLES: Dictionary = {"core": 0, "q25": 4, "mid": 8, "q75": 12, "surf": 15}


static func _rock_profile_rows() -> Array:
	var out: Array = []
	for tag: String in PROFILE_SAMPLES:
		var b: int = int(PROFILE_SAMPLES[tag])
		var g: Dictionary = {"source": "temp", "mask": Rec.Mask.SOLID, "gate": "r_frac",
			"gate_lo": float(b) * PROFILE_WIDTH}
		if b < 15:
			g["gate_hi"] = float(b + 1) * PROFILE_WIDTH
		out.append(g.merged({"key": "rock_%s_sum" % tag, "op": Rec.Op.SUM}, true))
		out.append(g.merged({"key": "rock_%s_n" % tag, "op": Rec.Op.COUNT}, true))
	return out


## Ground temperature per |lat| band: `lat` is signed, so each band is a north gate plus a south gate.
static func _lat_band_rows() -> Array:
	var out: Array = []
	var bands: int = LAMaterialFieldReport3D.CLIMATE_BANDS
	var width: float = 90.0 / float(bands)
	for b in bands:
		var lo: float = float(b) * width
		var last: bool = b == bands - 1
		var north: Dictionary = {"gate": "lat", "gate_lo": lo}
		var south: Dictionary = {"gate": "lat", "gate_hi": -lo}
		if not last:
			north["gate_hi"] = lo + width
			south["gate_lo"] = -(lo + width)
		for hemi: Array in [["n", north], ["s", south]]:
			var tag: String = String(hemi[0])
			var gate: Dictionary = hemi[1]
			out.append(gate.merged({"key": "clim_lat%d%s_sum" % [b, tag], "source": "temp",
				"op": Rec.Op.SUM, "mask": Rec.Mask.GROUND}, true))
			out.append(gate.merged({"key": "clim_lat%d%s_n" % [b, tag], "source": "temp",
				"op": Rec.Op.COUNT, "mask": Rec.Mask.GROUND}, true))
			out.append(gate.merged({"key": "clim_lat%d%s_min" % [b, tag], "source": "temp",
				"op": Rec.Op.MIN, "mask": Rec.Mask.GROUND}, true))
	return out


## Floor of each altitude band above the sea shell, metres, the last open-ended above. The edges are the
## tropopause, stratopause and mesopause of the US Standard Atmosphere 1976.
const ALT_BAND_FLOORS_M: Array = [0.0, 1.2e4, 5.0e4, 8.5e4]


## Coldest open cell per altitude band. `alt` is metres above the shell, NaN where the body carries none.
static func _alt_band_rows() -> Array:
	var out: Array = []
	for b in ALT_BAND_FLOORS_M.size():
		var g: Dictionary = {"gate": "alt", "gate_lo": float(ALT_BAND_FLOORS_M[b]),
			"source": "temp", "mask": Rec.Mask.OPEN}
		if b < ALT_BAND_FLOORS_M.size() - 1:
			g["gate_hi"] = float(ALT_BAND_FLOORS_M[b + 1])
		out.append(g.merged({"key": "clim_alt%d_min" % b, "op": Rec.Op.MIN}, true))
		out.append(g.merged({"key": "clim_alt%d_n" % b, "op": Rec.Op.COUNT}, true))
	return out
