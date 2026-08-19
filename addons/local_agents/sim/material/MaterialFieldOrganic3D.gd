class_name LAMaterialFieldOrganic3D
extends RefCounted

## Where the planet's dead organic matter sits on the peat-to-anthracite spectrum. Read-only: every number
## is a reduce row off the device — the sums in LifeRows, the ratio extremes off the org_hc/org_oc buffers
## state_derive.glsl writes.

var _f = null


func setup(field) -> void:
	_f = field
	LASimReport.register(Callable(self, "report"))


## Carbon-weighted mean molar H:C and O:C over the whole planet, and the single most coalified cell. Fresh
## CH2O litter is 2.0 / 1.0; both fall toward zero as burial drives the pool toward carbon.
func report() -> Dictionary:
	var out: Dictionary = {"organic_live": false}
	if _f == null or _f._queries == null:
		return out
	var q: LAMaterialFieldQueries3D = _f._queries
	var det: float = q.row_f("all_detritus")
	var fuel: float = q.row_f("all_fuel")
	var h_tot: float = q.row_f("all_org_h")
	var o_tot: float = q.row_f("all_org_o")
	if is_nan(det) or is_nan(fuel) or is_nan(h_tot) or is_nan(o_tot):
		return out
	var c_tot: float = det + fuel
	if c_tot <= 0.0:
		return out
	out["organic_live"] = true
	out["organic_hc"] = snappedf(h_tot / c_tot, 0.000001)
	out["organic_oc"] = snappedf(o_tot / c_tot, 0.000001)
	out["organic_carbon"] = snappedf(c_tot, 0.0001)
	# MIN rows over the ratio buffers are absent when no cell holds a mole of pool: absent stays absent.
	var hc_min: float = q.row_f("organic_hc_min")
	if not is_nan(hc_min):
		out["organic_hc_min"] = snappedf(hc_min, 0.000001)
	var oc_min: float = q.row_f("organic_oc_min")
	if not is_nan(oc_min):
		out["organic_oc_min"] = snappedf(oc_min, 0.000001)
	var coalified: int = q.row_n("organic_coalified")
	if coalified >= 0:
		out["organic_coalified_cells"] = coalified
	var c_buried: float = q.row_f("solid_detritus") + q.row_f("solid_fuel")
	var h_buried: float = q.row_f("solid_org_h")
	var o_buried: float = q.row_f("solid_org_o")
	if c_buried > 0.0 and not is_nan(h_buried) and not is_nan(o_buried):
		out["organic_buried_hc"] = snappedf(h_buried / c_buried, 0.000001)
		out["organic_buried_oc"] = snappedf(o_buried / c_buried, 0.000001)
		out["organic_buried_carbon"] = snappedf(c_buried, 0.0001)
	return out
