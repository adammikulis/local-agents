class_name LAMaterialFieldOrganic3D
extends RefCounted

## Where the planet's dead organic matter sits on the peat-to-anthracite spectrum. Read-only: it samples at
## the drain through request_probe/take_probe, so it changes no channel residency and flushes no submit.

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## The four channels the composition is read from: the dead pool's carbon (detritus + fuel) and its hydrogen
## and oxygen.
const LEGS: PackedStringArray = ["detritus", "fuel", "org_h", "org_o"]

## One mole of organic carbon per cubic metre, in channel units. Below that a cell's C:H:O is fp32 noise.
const MIN_POOL: float = 1.0 / LASubstances.ORGANIC_MOL_PER_M3

var _f = null


func setup(field) -> void:
	_f = field
	LASimReport.register(Callable(self, "report"))


## Carbon-weighted mean molar H:C and O:C over the whole planet, and the single most coalified cell. Fresh
## CH2O litter is 2.0 / 1.0; both fall toward zero as burial drives the pool toward carbon.
func report() -> Dictionary:
	var out: Dictionary = {"organic_live": false}
	if _f == null or _f._cell_count <= 0 or _f._gpu == null or not _f._gpu.has_method("take_probe"):
		return out
	var cc: int = _f._cell_count
	var probe: Dictionary = _f._gpu.take_probe()
	_f._gpu.request_probe(LEGS)
	var det: PackedFloat32Array = probe.get("detritus", PackedFloat32Array())
	var fuel: PackedFloat32Array = probe.get("fuel", PackedFloat32Array())
	var h: PackedFloat32Array = probe.get("org_h", PackedFloat32Array())
	var o: PackedFloat32Array = probe.get("org_o", PackedFloat32Array())
	if det.size() != cc or fuel.size() != cc or h.size() != cc or o.size() != cc:
		return out
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return out
	var solid: PackedByteArray = _f._solid
	var have_solid: bool = solid.size() == cc
	var c_tot: float = 0.0
	var h_tot: float = 0.0
	var o_tot: float = 0.0
	var c_buried: float = 0.0
	var h_buried: float = 0.0
	var o_buried: float = 0.0
	var min_hc: float = INF
	var min_oc: float = INF
	var coalified: int = 0
	for i in cc:
		var pool: float = (det[i] + fuel[i]) * vol[i]
		if pool <= MIN_POOL:
			continue
		var hv: float = h[i] * vol[i]
		var ov: float = o[i] * vol[i]
		c_tot += pool
		h_tot += hv
		o_tot += ov
		if have_solid and solid[i] != 0:
			c_buried += pool
			h_buried += hv
			o_buried += ov
		var hc: float = hv / pool
		var oc: float = ov / pool
		min_hc = minf(min_hc, hc)
		min_oc = minf(min_oc, oc)
		# Below 99% of fresh CH2O on either ratio: this cell has actually moved along the spectrum.
		if hc < 1.98 or oc < 0.99:
			coalified += 1
	if c_tot <= 0.0:
		return out
	out["organic_live"] = true
	out["organic_hc"] = snappedf(h_tot / c_tot, 0.000001)
	out["organic_oc"] = snappedf(o_tot / c_tot, 0.000001)
	out["organic_hc_min"] = snappedf(min_hc, 0.000001) if is_finite(min_hc) else 0.0
	out["organic_oc_min"] = snappedf(min_oc, 0.000001) if is_finite(min_oc) else 0.0
	out["organic_coalified_cells"] = coalified
	out["organic_carbon"] = snappedf(c_tot, 0.0001)
	if c_buried > 0.0:
		out["organic_buried_hc"] = snappedf(h_buried / c_buried, 0.000001)
		out["organic_buried_oc"] = snappedf(o_buried / c_buried, 0.000001)
		out["organic_buried_carbon"] = snappedf(c_buried, 0.0001)
	return out
