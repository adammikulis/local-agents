extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")

## Dispatch tags: the gather halves, the grain prologue, the list compaction, the RADIATE row's
## reflected-shortwave march, and the acoustic pair.
enum { PASS_OUTFLOW, PASS_GATHER, PASS_GRAIN, PASS_LIST_RESET, PASS_LIST_APPEND, PASS_LIST_ARGS,
	PASS_SW, PASS_ACOUSTIC, PASS_ACOUSTIC_APPLY }

## List-args layout: 0-2 the indirect uvec3, 3 the atomic list length, SLOTS the element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, SLOTS = 8 }

## The grain prologue carries mineral grains, so the Stokes law reads silicate's density off `substance`.
const GRAIN_ROW: Dictionary = {"channel": "silicate", "substance": "silicate",
	"mode": LATransportRecords.POTENTIAL}

## kg/m^3 below which a cell is empty: it donates nothing and holds no bulk velocity. The one emptiness
## floor, read by transport.glsl and state_derive.glsl. Declared in docs/MODEL_PARAMETERS.md.
const EMPTY_RHO_KG_M3: float = 0.0001 * LAPhysical.AIR_DENSITY_KG_M3

## Substeps one row may take inside a field step. Declared in docs/MODEL_PARAMETERS.md.
## LA_APPROX: cfl_substep_budget
const SUBSTEP_MAX: int = 256

var _pipe: RID = RID()
## The stiffest declared substance's celerity sqrt(K/rho), m/s: the budget's a-priori acoustic bound.
var _c_static: float = 0.0
## Per row: its uniform set. An invalid entry is a row whose buffers the driver has not got.
var _sets: Array = []
var _rows: Array = []
## Per-face scratch, cell*6: what left each face this step, and the enthalpy and charge that rode with it.
var _send: RID = RID()
var _send_h: RID = RID()
var _send_q: RID = RID()
## Momentum riding each face's mass flux, one scratch per component.
var _send_m: Array = []
## resist 0 and aux 1 for a row that names neither.
var _zero: RID = RID()
var _one: RID = RID()
## Enthalpy of transported enthalpy: none, so a row moving `h_j_m3` carries this zero buffer.
var _no_h: RID = RID()
## Band edges, absorption coefficients and the Planck CDF the RADIATE row reads.
var _rad_table: RID = RID()
## Broadband longwave emissivity and solar-beam share, the RADIATE row's own within-step scratch.
var _lw_emis: RID = RID()
var _sw_abs: RID = RID()
## The reflected-shortwave march's scratch pair: the share of upwelling flux a cell keeps, and each
## cell's reflected source. Stamped by the RADIATE row's passes 0 and 1, marched by its PASS_SW.
var _sw_keep: RID = RID()
var _sw_src: RID = RID()
var _band_count: int = 0
## The grain prologue's uniform set.
var _grain_set: RID = RID()
## Per row: the dispatch-indirect args RID of the cell list it runs over, invalid for a full-grid row.
var _list_args: Array = []
## Per LATransportRecords.lists() entry: its synthetic row, uniform set, and args/idx RIDs.
var _list_rows: Array = []
var _list_sets: Array = []
var _list_args_rid: Array = []
var _list_idx_rid: Array = []


## The TF_EFIELD row's electric-field outputs (driver-owned so ReducePass can read them), the boundary
## books, and each list's compacted-index, membership-flag and indirect-args buffers.
func _buffers(cc: int) -> Dictionary:
	var out: Dictionary = {"col_e": cc, "strike": cc, "radiogenic": cc,
		"sw_space": cc, "rad_residual": cc,
		"bnd_void": cc, "bnd_h_void": cc, "rim_ghost": cc, "rim_w": cc}
	for ch in BoundaryRowsScript.BOOKED:
		out["bnd_" + String(ch)] = cc
		out["bnd_h_" + String(ch)] = cc
	for ch in BoundaryRowsScript.BOOKED_SIGNED:
		out["bnd_" + String(ch)] = cc
	for lrow: Dictionary in LATransportRecords.lists():
		var keys: Dictionary = LATransportRecords.list_buffers(String(lrow["label"]))
		out[String(keys["idx"])] = cc
		out[String(keys["flag"])] = cc
		out[String(keys["args"])] = {"n": int(Arg.SLOTS), "indirect": true}
	return out


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = LATransportRecords.rows()
	for s: Dictionary in LANativeTables.subs().table().values():
		for pair: Array in [["bulk_modulus_pa", "density"], ["bulk_modulus_solid_pa", "density_solid"]]:
			var k_pa: float = float(s.get(String(pair[0]), 0.0))
			var rho: float = float(s.get(String(pair[1]), float(s.get("density", 0.0))))
			if k_pa > 0.0 and rho > 0.0:
				_c_static = maxf(_c_static, sqrt(k_pa / rho))

	# Ghost tail cells run pass 0, so every buffer the kernel indexes by cell carries the tail.
	var tc: int = cc + ghost_count
	_send = _scratch(tc * 6)
	_send_h = _scratch(tc * 6)
	_send_q = _scratch(tc * 6)
	_send_m = [_scratch(tc * 6), _scratch(tc * 6), _scratch(tc * 6)]
	_zero = _scratch(tc)
	_no_h = _scratch(tc)
	_one = _storage_buffer(_filled(tc, 1.0))
	# By name through ClassDB: the library must parse with the extension unbuilt, and a missing
	# extension still fails hard here on the null call.
	var bands: Variant = LANativeTables.bands()
	var rad_table: PackedFloat32Array = bands.packed()
	_band_count = int(rad_table[0])
	_rad_table = _storage_buffer(rad_table.to_byte_array())
	_lw_emis = _scratch(tc)
	_sw_abs = _scratch(tc)
	_sw_keep = _scratch(tc)
	_sw_src = _scratch(tc)

	for row: Dictionary in _rows:
		_sets.append(_row_set(bufs, row))
		_list_args.append(_single(bufs, String(_list_keys(row).get("args", ""))))
	_grain_set = _row_set(bufs, GRAIN_ROW)
	# The append's predicate reads `drive`, which binds the list's prim channel through `channel`.
	for lrow: Dictionary in LATransportRecords.lists():
		var label: String = String(lrow["label"])
		var keys: Dictionary = LATransportRecords.list_buffers(label)
		_list_rows.append({"label": label, "channel": String(lrow["prim"]), "substance": "",
			"mode": LATransportRecords.POTENTIAL, "halo": bool(lrow.get("halo", false)),
			"emit_idx": bool(lrow.get("emit_idx", false)), "list": label})
		_list_sets.append(_row_set(bufs, _list_rows.back()))
		_list_args_rid.append(_single(bufs, String(keys["args"])))
		_list_idx_rid.append(_single(bufs, String(keys["idx"])))


## XUV irradiance at this body, W/m^2, taken once per dispatch off the ctx the star publishes into.
var _xuv_w_m2: float = 0.0


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# No sun in the ctx is no star, which is no XUV — never an assumed one.
	_xuv_w_m2 = float(ctx.get("xuv_w_m2", 0.0))
	# THE LISTS, rebuilt before any listed row dispatches over one.
	for r in _list_rows.size():
		var lset: RID = _list_sets[r]
		if not lset.is_valid():
			continue
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, lset, 0)
		for spec: Array in [[PASS_LIST_RESET, 1], [PASS_LIST_APPEND, groups], [PASS_LIST_ARGS, 1]]:
			var lpc: PackedByteArray = _pc(_list_rows[r], cc, int(spec[0]), cell_m, dt_s, sun)
			rd.compute_list_set_push_constant(cl, lpc, lpc.size())
			rd.compute_list_dispatch(cl, int(spec[1]), 1, 1)
			rd.compute_list_add_barrier(cl)
	# PROLOGUE: the suspension shares three silicate rows read as `frac`, before anything donates.
	if _grain_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, _grain_set, 0)
		var gpc: PackedByteArray = _pc(GRAIN_ROW, cc, PASS_GRAIN, cell_m, dt_s, sun)
		rd.compute_list_set_push_constant(cl, gpc, gpc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	# THE ACOUSTIC GROUP substeps as one unit: matter advects, the gathers refresh velocity, and the
	# acoustic half-step advances the pressure — the coupled pair on its own time axis.
	var r: int = 0
	while r < _rows.size():
		var group: PackedInt32Array = PackedInt32Array([r])
		if _group_row(_rows[r]):
			while r + 1 < _rows.size() and _group_row(_rows[r + 1]):
				r += 1
				group.append(r)
		var n: int = 1
		var acoustic: bool = false
		for gi in group:
			n = maxi(n, _substeps(_rows[gi], cell_m, dt_s, ctx))
			acoustic = acoustic or _vel_row(_rows[gi])
		for k in n:
			for gi in group:
				_run_row(rd, cl, gi, cc, cell_m, dt_s / float(n), sun, groups, k == n - 1)
			if acoustic:
				_run_acoustic(rd, cl, group[group.size() - 1], cc, cell_m, dt_s / float(n), sun,
					groups, 1.0 / float(n))
		r += 1


## One row's outflow+gather pair; the RADIATE row runs a third pass, PASS_SW, marching the upwelling
## its gather stamped. The rim's nudge is a per-STEP fraction, so only the last substep carries RELAX.
func _run_row(rd: RenderingDevice, cl: int, r: int, cc: int, cell_m: float, dt_s: float,
		sun: Vector3, groups: int, last: bool = true) -> void:
	var uset: RID = _sets[r]
	if not uset.is_valid():
		return
	var args: RID = _list_args[r]
	var passes: Array = [PASS_OUTFLOW, PASS_GATHER]
	if int(_rows[r]["mode"]) == LATransportRecords.RADIATE:
		passes.append(PASS_SW)
	for pass_id in passes:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun, last)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		# A listed row walks the compacted cells, so its cost is O(active), not O(grid).
		if args.is_valid():
			rd.compute_list_dispatch_indirect(cl, args, 0)
		else:
			# Pass 0 covers the ghost tail; the driver's group count covers interior only.
			var g: int = groups
			if pass_id == PASS_OUTFLOW and ghost_count > 0:
				g = int(ceil(float(cc + ghost_count) / 64.0))
			rd.compute_list_dispatch(cl, g, 1, 1)
		rd.compute_list_add_barrier(cl)


## One acoustic half-step: compute dp into the face scratch, then apply it.
func _run_acoustic(rd: RenderingDevice, cl: int, r: int, cc: int, cell_m: float, dt_s: float,
		sun: Vector3, groups: int, frac: float) -> void:
	var uset: RID = _sets[r]
	if not uset.is_valid():
		return
	for pass_id in [PASS_ACOUSTIC, PASS_ACOUSTIC_APPLY]:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun, true, frac)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## A signed per-axis momentum row, whose gather refreshes its velocity component.
func _vel_row(row: Dictionary) -> bool:
	return row.has("axis") and bool(row.get("signed", false))


## A row of the acoustic substep group: a momentum row, or compressible matter flagged into it.
func _group_row(row: Dictionary) -> bool:
	return _vel_row(row) or bool(row.get("acoustic", false))


## Substeps the row's stability needs, off the LAST drained maxima: per-face share <= 1/6, donor
## courant v dt <= L, acoustic c dt sqrt(3)/L <= 1, gravity adjustment g h (dt/n)^2/L^2 <= 1/6.
func _substeps(row: Dictionary, cell_m: float, dt_s: float, ctx: Dictionary) -> int:
	var mode: int = int(row["mode"])
	var law: int = int(row.get("law", LATransportRecords.Law.NONE))
	var vmax: float = maxf(float(ctx.get("cfl_speed_max", 0.0)), 0.0)
	var tk_max: float = maxf(float(ctx.get("cfl_temp_max_k", 0.0)), 0.0)
	var need: float = 0.0
	# The peak celerity, floored a-priori: no mixture outruns its stiffest pure constituent, and a
	# one-step drain lag at the water sound speed is all a runaway needs.
	if _vel_row(row):
		var c_max: float = maxf(float(ctx.get("cfl_celerity_max", 0.0)), _c_static)
		if tk_max > 0.0:
			c_max = maxf(c_max, sqrt(LAPhysical.AIR_ADIABATIC_INDEX
				* LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK * tk_max))
		need = sqrt(3.0) * c_max * dt_s / cell_m
	if mode == LATransportRecords.ADVECT or mode == LATransportRecords.BOTH:
		var v: float = vmax
		if bool(row.get("settle", false)):
			var fl: Vector2 = LATransportRecords.fluid_properties(
				int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
			var rho_s: float = float(LANativeTables.subs().table().get(String(row["substance"]), {})
				.get("density", 0.0))
			# Stokes terminal velocity at the row's seed grain; mean solved g is the only g drained.
			v += maxf(rho_s - fl.x, 0.0) * maxf(float(ctx.get("cfl_mean_g", 0.0)), 0.0) \
				* LAPhysical.GRAIN_D_UPLAND_M * LAPhysical.GRAIN_D_UPLAND_M / (18.0 * maxf(fl.y, 1.0e-30))
		need += v * dt_s / cell_m
	# Gravity adjustment, at a full cell of head.
	if law == LATransportRecords.Law.SHALLOW or law == LATransportRecords.Law.FILM:
		var g0: float = maxf(float(ctx.get("cfl_mean_g", 0.0)), 0.0)
		need = maxf(need, sqrt(6.0 * g0 * cell_m) * dt_s / cell_m)
	# A signed EDDY row is the pair-exact viscous relaxation: no diffusion CFL applies to it.
	if law == LATransportRecords.Law.EDDY and not _vel_row(row):
		var fl2: Vector2 = LATransportRecords.fluid_properties(
			int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
		var nu_mol: float = (fl2.y / fl2.x) if fl2.x > 0.0 else 0.0
		var mix: float = LAPhysical.SMAGORINSKY_COEFF * cell_m
		# |S| <= sqrt(18) vmax / L bounds the strain the kernel can read off the drained peak speed.
		var nu: float = nu_mol + mix * mix * sqrt(18.0) * vmax / cell_m
		need += 6.0 * nu * dt_s / (cell_m * cell_m)
	if law == LATransportRecords.Law.SOUND and tk_max > 0.0:
		need = maxf(need, 6.0 * sqrt(LAPhysical.AIR_ADIABATIC_INDEX
			* LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK * tk_max) * dt_s / cell_m)
	var want: int = int(ceil(need))
	if want > SUBSTEP_MAX:
		_deny(row, want, "celerity=%s wind=%s temp_k=%s cell_m=%s dt_s=%s"
			% [_c_static, vmax, tk_max, cell_m, dt_s])
	return clampi(want, 1, SUBSTEP_MAX)


## A SUBSTEP BUDGET THAT CANNOT BE MET IS A FAILURE, NEVER A CLAMP. Silently capping it runs the row at
## thousands of times its stable timestep and every number after that is fiction.
func _deny(row: Dictionary, want: int, terms: String) -> void:
	var label: String = String(row.get("label", row.get("substance", "?")))
	if _denied.has(label):
		return
	_denied[label] = want
	push_error("SUBSTEPS_DENIED row=%s want=%d cap=%d %s" % [label, want, SUBSTEP_MAX, terms])


var _denied: Dictionary = {}



## Cells each list holds after the last step; an `emit_idx` list also returns its occupied prefix.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {}
	for r in _list_rows.size():
		var raw: PackedByteArray = rd.buffer_get_data(_list_args_rid[r])
		if raw.size() < int(Arg.SLOTS) * 4:
			continue
		var label: String = String(_list_rows[r]["label"])
		var n: int = raw.to_int32_array()[int(Arg.LIST_COUNT)]
		out[label + "_list_cells"] = float(n)
		if n > 0 and bool(_list_rows[r].get("emit_idx", false)):
			out[label + "_list_idx"] = rd.buffer_get_data(_list_idx_rid[r], 0, n * 4).to_int32_array()
	return out


## The cell-list buffer keys a row runs over; empty for a row that sweeps the whole grid.
func _list_keys(row: Dictionary) -> Dictionary:
	var label: String = String(row.get("list", ""))
	return {} if label == "" else LATransportRecords.list_buffers(label)

## The uniform set for one row, or RID() when a buffer it names does not exist.
func _row_set(bufs: Dictionary, row: Dictionary) -> RID:
	var channel: String = String(row["channel"])
	var drive: String = String(row.get("drive", ""))
	var resist: String = String(row.get("resist", ""))
	var aux: String = String(row.get("aux", ""))
	var frac: String = String(row.get("frac", ""))
	var moves_enthalpy: bool = channel == "h_j_m3"
	# Mass does not move without its heat, so the enthalpy field is required of every row that carries mass.
	var list: Dictionary = _list_keys(row)
	if String(row.get("list", "")) != "" and list.is_empty():
		push_error("TransportPass: no \"%s\" list, so the %s row does not move."
			% [String(row["list"]), channel])
		return RID()
	var needed: Array = [channel, drive, resist, aux, frac, "" if moves_enthalpy else "h_j_m3",
		String(list.get("idx", "")), String(list.get("args", "")), String(list.get("flag", ""))]
	for key in needed:
		if String(key) != "" and not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row does not move." % [key, channel])
			return RID()
	# The material state every law and the band model read. A missing one is a dead row, not a default.
	for key in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible",
			"temp", "pressure", "porosity", "grain", "co2", "ch4", "co", "so2", "h2s",
			"o2", "n2", "h2", "grav_phi",
			"h2o", "h2o_solid", "h2o_liquid",
			"h2o_vapour", "silicate", "biomass", "silicate_melt", "cement",
			"silicate_susp_water", "silicate_susp_air", "silicate_bed",
			"rad_absorbed", "rad_emitted", "col_e", "strike",
			"rad_w_m3", "radiogenic", "sw_space", "rad_residual",
			"ghost", "bnd_void", "bnd_h_void", "rho_bulk",
			"mom_x", "mom_y", "mom_z", "celerity", "speed", "bodyf_x", "bodyf_y", "bodyf_z"]:
		if not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row has no law." % [key, channel])
			return RID()
	var amount: RID = _single(bufs, channel)
	var entries: Array = [
		[0, amount],
		[1, _no_h if moves_enthalpy else _single(bufs, "h_j_m3")],
		[2, _single(bufs, "nbr")],
		[3, _single(bufs, "solid")],
		[4, _single(bufs, "gravity")],
		[5, _single(bufs, "vel_x")], [6, _single(bufs, "vel_y")], [7, _single(bufs, "vel_z")],
		[8, _send], [9, _send_h],
		[10, _zero if resist == "" else _single(bufs, resist)],
		[11, amount if drive == "" else _single(bufs, drive)],
		[12, _one if aux == "" else _single(bufs, aux)],
		[13, _single(bufs, "charge")], [14, _send_q],
		[15, _single(bufs, "temp")],
		[16, _single(bufs, "pressure")],
		[17, _single(bufs, "porosity")],
		[18, _single(bufs, "grain")],
		[19, _single(bufs, "co2")],
		[20, _single(bufs, "h2o")],
		[21, _rad_table],
		[22, _single(bufs, "h2o_solid")],
		[23, _single(bufs, "h2o_liquid")],
		[24, _single(bufs, "silicate")],
		[25, _single(bufs, "biomass")],
		[26, _single(bufs, "silicate_melt")],
		[27, _single(bufs, "ghost")],
		[28, _single(bufs, "h2o_vapour")],
		[29, _one if frac == "" else _single(bufs, frac)],
		[30, _single(bufs, "cement")],
		[31, _single(bufs, "silicate_susp_water")],
		[32, _single(bufs, "silicate_susp_air")],
		[33, _single(bufs, "silicate_bed")],
		# A full-grid row never reads these; the kernel touches them only under TF_LISTED.
		[34, _zero if list.is_empty() else bufs[String(list["idx"])]],
		[35, _zero if list.is_empty() else bufs[String(list["args"])]],
		[36, _zero if list.is_empty() else bufs[String(list["flag"])]],
		# Every row binds these; only a MODE_RADIATE gather writes them.
		[37, _single(bufs, "rad_absorbed")],
		[38, _single(bufs, "rad_emitted")],
		[39, _single(bufs, "col_e")],
		[40, _single(bufs, "strike")],
		# The composition-derived radiogenic power, and where its tail books what it deposited.
		[41, _single(bufs, "rad_w_m3")],
		# The minor greenhouse gases the band table resolves.
		[42, _single(bufs, "ch4")],
		[43, _single(bufs, "radiogenic")],
		[44, _lw_emis],
		[45, _sw_abs],
		# Heat travels with the matter that holds it, so a row reads the enthalpy of ITS OWN entry.
		[46, _single(bufs, _carried_key(String(row["substance"])))],
		[47, _single(bufs, "cap_sensible")],
		# A booked channel's boundary crossings; an unbooked row writes a void pair nothing reads.
		# A signed channel books its amount leg only; the kernel never writes its heat leg.
		[48, _single(bufs, ("bnd_" + channel) if (BoundaryRowsScript.BOOKED.has(channel)
			or BoundaryRowsScript.BOOKED_SIGNED.has(channel)) else "bnd_void")],
		[49, _single(bufs, ("bnd_h_" + channel) if BoundaryRowsScript.BOOKED.has(channel) else "bnd_h_void")],
		# The REPLAY relaxation rim, filled by LAFieldBoundary3D.attach; all-zero weights without one.
		[50, _single(bufs, "rim_ghost")],
		[51, _single(bufs, "rim_w")],
		# The reflected-shortwave field: pass-owned scratch pair, then the escape book and the
		# Stefan-Boltzmann residual the reduce rows read.
		[52, _sw_keep],
		[53, _sw_src],
		[54, _single(bufs, "sw_space")],
		[55, _single(bufs, "rad_residual")],
		# O3 partial density, kg/m^3: zeros until a photochemical o3 channel exists to swap in.
		[56, _zero],
		[57, _single(bufs, "rho_bulk")],
		[58, _single(bufs, "mom_x")],
		[59, _single(bufs, "mom_y")],
		[60, _single(bufs, "mom_z")],
		[61, _send_m[0]], [62, _send_m[1]], [63, _send_m[2]],
		[64, _single(bufs, "celerity")],
		[65, _single(bufs, "speed")],
		[66, _single(bufs, "bodyf_x")],
		[67, _single(bufs, "bodyf_y")],
		[68, _single(bufs, "bodyf_z")],
		# The momentum riding a mass row's exterior crossing; a signed row books through binding 48
		# and binds the void here.
		[69, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_x")],
		[70, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_y")],
		[71, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_z")],
		[72, _single(bufs, "co")],
		[73, _single(bufs, "so2")],
		[74, _single(bufs, "h2s")],
		[75, _single(bufs, "o2")],
		[76, _single(bufs, "n2")],
		[77, _single(bufs, "h2")],
		# The solved potential, J/kg: -phi is the escape energy LAW_ESCAPE lifts against.
		[78, _single(bufs, "grav_phi")],
		# The charge riding a mass row's crossing; a signed channel books its own through binding 48.
		[79, _single(bufs, "bnd_void" if BoundaryRowsScript.BOOKED_SIGNED.has(channel) else "bnd_charge")],
	]
	return _uset(_pipe, entries)


## The buffer holding the enthalpy of the mixture entry a substance's heat sits in.
func _carried_key(substance: String) -> String:
	match LAMatterChannels.entry_of(substance):
		LAMatterChannels.Entry.H2O:
			return "h_h2o"
		LAMatterChannels.Entry.SILICATE:
			return "h_silicate"
	return "h_sensible"


# --- push constant ----------------------------------------------------------------------------------------

## transport.glsl's Params block, in its declared order — 112 bytes.
func _pc(row: Dictionary, cc: int, pass_id: int, cell_m: float, dt_s: float,
		sun: Vector3, relax_ok: bool = true, substep_frac: float = 1.0) -> PackedByteArray:
	var substance: String = String(row["substance"])
	var entry: Dictionary = LANativeTables.subs().table().get(substance, {})
	var fluid: Vector2 = LATransportRecords.fluid_properties(
		int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
	var flags: int = 0
	if bool(row.get("signed", false)):
		flags |= LATransportRecords.Flag.SIGNED
	if bool(row.get("settle", false)):
		flags |= LATransportRecords.Flag.SETTLE
	if bool(row.get("efield", false)):
		flags |= LATransportRecords.Flag.EFIELD
	if String(row.get("drive", "")) != "":
		flags |= LATransportRecords.Flag.DRIVEN
	if String(row.get("frac", "")) != "":
		flags |= LATransportRecords.Flag.FRACTION
	if bool(row.get("dilute", false)):
		flags |= LATransportRecords.Flag.DILUTE
	if String(row.get("list", "")) != "":
		flags |= LATransportRecords.Flag.LISTED
	if bool(row.get("halo", false)):
		flags |= LATransportRecords.Flag.LIST_HALO
	if relax_ok and bool(row.get("relax", false)):
		flags |= LATransportRecords.Flag.RELAX
	if bool(row.get("radiogenic", false)):
		flags |= LATransportRecords.Flag.RADIOGENIC
	if _vel_row(row):
		flags |= LATransportRecords.Flag.VEL
	# The row whose amount IS enthalpy books joules on both boundary legs.
	if String(row["channel"]) == "h_j_m3":
		flags |= LATransportRecords.Flag.ENTHALPY
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(108)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, int(row["mode"]))
	pc.encode_u32(12, int(row.get("law", LATransportRecords.Law.NONE)))
	pc.encode_u32(16, _band_count)
	pc.encode_u32(20, flags)
	pc.encode_float(24, cell_m)
	pc.encode_float(28, dt_s)
	pc.encode_float(32, float(row.get("repose_tan", 0.0)))
	var max_fill: float = LATransportRecords.max_fill(substance) if substance != "" else INF
	pc.encode_float(36, EMPTY_RHO_KG_M3)
	pc.encode_float(40, float(entry.get("density", 0.0)))
	# Enthalpy, momentum and a shock front are not matter occupying volume, so no cell is ever full of them.
	pc.encode_float(44, max_fill)
	pc.encode_float(48, fluid.x)
	pc.encode_float(52, fluid.y)
	# Seed diameter for cells whose own grain field is unset; the cell's value wins wherever it has one.
	pc.encode_float(56, LAPhysical.GRAIN_D_UPLAND_M)
	pc.encode_float(60, sun.x)
	pc.encode_float(64, sun.y)
	pc.encode_float(68, sun.z)
	var water: Vector2 = LATransportRecords.fluid_properties(LATransportRecords.Fluid.WATER)
	var air: Vector2 = LATransportRecords.fluid_properties(LATransportRecords.Fluid.AIR)
	pc.encode_float(72, water.x)
	pc.encode_float(76, water.y)
	pc.encode_float(80, air.x)
	pc.encode_float(84, air.y)
	# J/m^3/K one mol/m^3 of the substance contributes to the sensible entry (molar mass times specific
	# heat); 0 for a substance on a phase ladder, whose entry is the channel itself.
	pc.encode_float(88, float(entry.get("molar_mass", 0.0)) * LAMatterChannels.specific_heat(substance))
	pc.encode_u32(92, cc + ghost_count)
	pc.encode_u32(96, int(row.get("axis", 0)))
	pc.encode_float(100, substep_frac)
	# XUV irradiance AT THIS BODY, already distance-corrected by the star that emitted it; the zenith
	# cosine is what still scales it in-kernel.
	pc.encode_float(104, _xuv_w_m2)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
