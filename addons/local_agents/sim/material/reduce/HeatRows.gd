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
		{"key": "all_temp_max", "source": "temp", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		# The ground SKIN: an open cell whose gravity-below neighbour is solid. Unweighted, so over
		# ground_cells this is a mean over cells. First rows to dispatch Mask.GROUND.
		{"key": "ground_cells", "source": "temp", "op": Rec.Op.COUNT, "mask": Rec.Mask.GROUND},
		{"key": "temp_ground_sum", "source": "temp", "op": Rec.Op.SUM, "mask": Rec.Mask.GROUND},
		# 60 °C: the one temperature "a hot open cell" means here. Read back through row("hot_cells").
		{"key": "hot_cells", "source": "temp", "op": Rec.Op.COUNT_GE, "mask": Rec.Mask.OPEN, "threshold": 60.0},
		{"key": "fire_peak", "source": "fire", "op": Rec.Op.MAX, "mask": Rec.Mask.ALL},
		{"key": "fire_cells", "source": "fire", "op": Rec.Op.COUNT_GT, "mask": Rec.Mask.ALL,
			"threshold": LAMaterialFieldQueries3D.FIRE_PRESENT},
		# J/m^3 per step, so volume-weighted these are joules per step. Mask-free: the outflow pass emits
		# from solid cells too, so an OPEN mask would drop the ground's emission.
		{"key": "rad_absorbed", "source": "rad_absorbed", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": true},
		{"key": "rad_emitted", "source": "rad_emitted", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": true},
		# The rock's own decay, J/m^3 per step, volume-weighted to joules. The energy books read this.
		{"key": "radiogenic", "source": "radiogenic", "op": Rec.Op.SUM, "mask": Rec.Mask.ALL,
			"weight": true, "energy_book": true},
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
	] + _lat_band_rows()


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
