class_name LAProcessSet
extends RefCounted

## Which processes a world contains. A rung is a smaller, physically complete world; a process outside
## the set is absent — never allocated, dispatched, reduced or booked. Resolved once at seeding, so no
## pass reads a flag per step.

enum { STATE, GRAVITY, HYDROSTATIC, ACOUSTIC, CONDUCTION, ADVECT, WATER, RADIATION,
	CHEMISTRY }

const TOP: int = CHEMISTRY
const UNSET: int = -1

const SETTING: String = "local_agents/sim/process_rung"
const ENV_VAR: String = "LA_RUNG"
const ARG: String = "--rung="
const RECORDS_ARG: String = "--processes="

## A `rung` argument meaning "whatever this world declared".
const ANY: int = -2
const PLAYABLE_PATH: String = "res://docs/PLAYABLE_RUNG"

const TransportRecordsScript: GDScript = preload("res://addons/local_agents/sim/material/TransportRecords.gd")
const ReduceRecordsScript: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")
const ReactionsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialReactions3D.gd")
const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")

## `@amounts` expands to the conserved stock pair of every LAReduceRecords.AMOUNTS entry. A trailing `*`
## matches a prefix; an exact key outranks a pattern, and two patterns may not both match one key.
const AMOUNTS_TOKEN: String = "@amounts"

## Record kind -> the rung field that declares it.
const FIELD_OF: Dictionary = {"pass": "passes", "transport": "transport", "reaction": "reactions"}

static var _active: int = TOP
## Non-empty when an explicit set was declared instead of a rung.
static var _custom: PackedStringArray = PackedStringArray()
static var _reduce_cache: Array = []
static var _reduce_key: String = ""


## The rungs, bottom first. Each names the passes, transport rows, reaction modules and reduce rows it
## adds to the rung below, and the gates that prove it. Booked channels are derived, never named twice.
static func rungs() -> Array:
	return [
		{"rung": STATE, "name": "state", "gates": ["check_rung_state.sh"],
			"passes": ["StateDerivePass.gd"],
			"transport": [], "reactions": [], "reduce": []},

		{"rung": GRAVITY, "name": "gravity", "gates": ["check_gravity_solve.sh"],
			"passes": ["GravityPass.gd", "ReducePass.gd"],
			"transport": [], "reactions": [],
			"reduce": [AMOUNTS_TOKEN, "energy_stock", "solid_cells", "carbonate_cells", "snow_cells",
				"ice_cells", "crust_latch", "crust_moved", "nonfinite_cells", "nonfinite_*",
				"bodyf_*",
				"open_temp_*", "all_temp_max", "ground_cells", "temp_ground_sum", "hot_cells",
				"geo_grad_*", "air_grad_*", "clim_ground_*", "clim_air_*", "clim_lat*", "clim_alt*",
				"water_liquid_total", "wet_cells", "vapour_amount", "hotspring_*", "clim_water_*",
				"melt_total", "magma_cells", "lava_*", "enclosed_void*",
				"o2_open_*", "co2_open_*", "precip_cells", "cloud_cells", "fog_cells",
				"fert_peak", "fungus_peak", "fungus_cells", "detritus_peak", "detritus_cells",
				"all_org_h", "open_org_h", "all_org_o", "open_org_o",
				"solid_detritus", "solid_fuel", "solid_org_h", "solid_org_o",
				"organic_hc_min", "organic_oc_min", "organic_coalified"]},

		{"rung": HYDROSTATIC, "name": "hydrostatic", "gates": ["check_atmosphere_at_rest.sh"],
			"passes": ["PressurePass.gd"],
			"transport": [], "reactions": [], "reduce": ["pressure_*"]},

		{"rung": ACOUSTIC, "name": "acoustic", "gates": ["check_rung_acoustic.sh"],
			"passes": ["TransportPass.gd"], "reactions": [],
			"transport": ["h2o_liquid_advect", "h2o_vapour_eddy", "o2_eddy", "co2_eddy", "n2_eddy",
				"h2_eddy", "co_eddy", "so2_eddy", "h2s_eddy", "ch4_eddy",
				"mom_x_pgf", "mom_y_pgf", "mom_z_pgf", "mom_x_eddy", "mom_y_eddy", "mom_z_eddy",
				"shock_sound"],
			"reduce": ["open_mom_*", "momentum_*", "celerity_max", "rho_max_open",
				"wind_speed_max", "wind_x_sum", "wind_z_sum", "shock_cells"]},

		{"rung": CONDUCTION, "name": "conduction", "gates": ["check_rung_conduction.sh"],
			"passes": [], "reactions": [], "reduce": ["radiogenic"],
			"transport": ["heat_conduct"]},

		{"rung": ADVECT, "name": "advect", "gates": ["check_rung_advect.sh"],
			"passes": [], "reactions": [],
			"transport": ["h2o_surface", "h2o_groundwater", "silicate_melt_film",
				"silicate_susp_water", "silicate_susp_air", "silicate_bed",
				"fungus_wind", "fert_soil"],
			"reduce": ["airborne_mineral_sum", "suspended_cells"]},

		{"rung": WATER, "name": "water", "gates": ["check_rung_water.sh"],
			"passes": ["ReactionsPass.gd"], "reactions": ["PhaseRecords.gd"],
			"transport": ["charge_separate", "charge_ohmic"],
			"reduce": ["charge_stock", "charge_gross", "charge_peak", "e_peak", "bolt_cells"]},

		{"rung": RADIATION, "name": "radiation", "gates": ["check_radiative_row.sh"],
			"passes": [], "reactions": [],
			"transport": ["heat_radiate"],
			"reduce": ["rad_absorbed", "rad_emitted", "sw_reflected", "rad_sb_rel_max"]},

		{"rung": CHEMISTRY, "name": "chemistry",
			"gates": ["check_reaction_balance.sh", "check_conservation.sh"],
			"passes": [],
			"reactions": ["BioRecords.gd", "GeoRecords.gd", "CombustionRecords.gd",
				"LightningRecords.gd"],
			"transport": ["escape_*"],
			"reduce": ["fire_peak", "fire_cells"]},
	]


## `node` is the world record's own declaration and outranks everything. Then the command line, which is
## this invocation speaking and outranks the ambient project setting and environment, and last the rung
## the ladder proved.
static func resolve(node: int) -> int:
	if node != UNSET:
		return clampi(node, STATE, TOP)
	var arg: int = _from_args()
	if arg != UNSET:
		return arg
	if ProjectSettings.has_setting(SETTING):
		return clampi(int(ProjectSettings.get_setting(SETTING)), STATE, TOP)
	var env: String = OS.get_environment(ENV_VAR)
	if env != "":
		return clampi(int(env), STATE, TOP)
	return playable()


static func _from_args() -> int:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if String(a).begins_with(ARG):
			return clampi(int(String(a).trim_prefix(ARG)), STATE, TOP)
	return UNSET


## An explicit process set named on the command line; empty when none is.
static func records_from_args() -> PackedStringArray:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if String(a).begins_with(RECORDS_ARG):
			return String(a).trim_prefix(RECORDS_ARG).split(",", false)
	return PackedStringArray()


## The rung the demo world runs at, from docs/PLAYABLE_RUNG. The ladder raises it; nothing lowers it.
static func playable() -> int:
	var f: FileAccess = FileAccess.open(PLAYABLE_PATH, FileAccess.READ)
	if f == null:
		return TOP
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			return clampi(int(line), STATE, TOP)
	return TOP


## Declared once, while the world is being seeded. Every table below answers for this world afterwards.
static func declare(rung: int) -> void:
	_active = clampi(rung, STATE, TOP)
	_custom = PackedStringArray()
	_reduce_key = ""


## An explicit set: exactly these process records and nothing else, whatever rung each sits on.
static func declare_records(ids: PackedStringArray) -> void:
	_custom = ids
	_reduce_key = ""


static func active() -> int:
	return _active


static func custom() -> PackedStringArray:
	return _custom


static func name_of(rung: int) -> String:
	for r: Dictionary in rungs():
		if int(r["rung"]) == rung:
			return String(r["name"])
	return ""


## Every process record a world can contain, bottom rung first: one row per pass, transport row and
## reaction module. A control draws one entry per row and keeps no list of its own.
static func records() -> Array:
	var out: Array = []
	for r: Dictionary in rungs():
		var at: int = int(r["rung"])
		for f in (r["passes"] as Array):
			out.append({"kind": "pass", "label": String(f), "rung": at})
		for row: Dictionary in TransportRecordsScript.rows():
			var lbl: String = String(row.get("label", ""))
			if lbl != "" and _matches(lbl, r["transport"] as Array):
				out.append({"kind": "transport", "label": lbl, "rung": at})
		for m in (r["reactions"] as Array):
			out.append({"kind": "reaction", "label": String(m), "rung": at})
	return out


## The one spelling of a record in a serialised set.
static func record_id(rec: Dictionary) -> String:
	return String(rec["kind"]) + ":" + String(rec["label"])


## The record ids of every process at or below `rung` — what a rung selection serialises to.
static func records_upto(rung: int) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for rec: Dictionary in records():
		if int(rec["rung"]) <= rung:
			out.append(record_id(rec))
	return out


## Is this process in the world? An explicit set answers by name, a rung by height.
static func has_record(kind: String, label: String, rung: int = ANY) -> bool:
	if label == "":
		return false
	if rung == ANY and not _custom.is_empty():
		return _custom.has(kind + ":" + label)
	var at: int = _rung_or_active(rung)
	for r: Dictionary in rungs():
		if int(r["rung"]) > at:
			continue
		if kind == "transport":
			if _matches(label, r["transport"] as Array):
				return true
		elif (r[FIELD_OF[kind]] as Array).has(label):
			return true
	return false


## Every rung holding at least one process this world contains.
static func live_rungs() -> Array:
	var out: Array = []
	for rec: Dictionary in records():
		var at: int = int(rec["rung"])
		if not out.has(at) and has_record(String(rec["kind"]), String(rec["label"])):
			out.append(at)
	return out


## Absolute paths of the pass scripts this world runs, in the driver's dispatch order.
static func pass_paths(all_paths: PackedStringArray, rung: int = ANY) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for p in all_paths:
		if has_record("pass", String(p).get_file(), rung):
			out.append(String(p))
	return out


## The transport rows this world moves. A row outside the set is never bound and never dispatched.
static func transport_rows(rung: int = ANY) -> Array:
	var out: Array = []
	for row: Dictionary in TransportRecordsScript.rows():
		if has_record("transport", String(row.get("label", "")), rung):
			out.append(row)
	return out


## The reduce rows this world folds. A row whose rung holds no live process is the instrument of
## nothing here, so it is never dispatched and its reading is absent rather than zero.
static func reduce_rows(rung: int = ANY) -> Array:
	# The ledger folds these on every field step; the set is settled at seeding, so the walk runs once.
	var key: String = "%d:%s" % [rung, ",".join(_custom)] if rung == ANY else str(rung)
	if key == _reduce_key:
		return _reduce_cache
	var live: Array = live_rungs() if rung == ANY and not _custom.is_empty() else []
	var at: int = _rung_or_active(rung)
	var book: PackedStringArray = booked(rung)
	var out: Array = []
	for row: Dictionary in ReduceRecordsScript.rows():
		var owner: int = reduce_rung(String(row["key"]), book)
		if owner == UNSET:
			continue
		if not live.is_empty():
			if not live.has(owner):
				continue
		elif owner > at:
			continue
		out.append(row)
	_reduce_key = key
	_reduce_cache = out
	return out


## The rung that declared a reduce row; UNSET when none did. A boundary book follows its own channel.
static func reduce_rung(key: String, book: PackedStringArray = PackedStringArray()) -> int:
	for r: Dictionary in rungs():
		if _matches(key, r["reduce"] as Array):
			return int(r["rung"])
	for ch in book:
		if key == BoundaryRowsScript.BOOKED_PREFIX + String(ch) \
				or key == BoundaryRowsScript.HEAT_PREFIX + String(ch):
			return channel_rung(String(ch))
	return UNSET


## The lowest rung carrying a transport row for `channel`; UNSET when nothing moves it.
static func channel_rung(channel: String) -> int:
	for r: Dictionary in rungs():
		for row: Dictionary in TransportRecordsScript.rows():
			if String(row["channel"]) == channel \
					and _matches(String(row.get("label", "")), r["transport"] as Array):
				return int(r["rung"])
	return UNSET


## Channels whose boundary crossings this world books: those a live transport row can carry across.
static func booked(rung: int = ANY) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for row: Dictionary in transport_rows(rung):
		var ch: String = String(row["channel"])
		if not out.has(ch) and (BoundaryRowsScript.BOOKED.has(ch)
				or BoundaryRowsScript.BOOKED_SIGNED.has(ch)):
			out.append(ch)
	return out


static func books(channel: String) -> bool:
	return booked().has(channel)


## The reaction records this world runs, balance-checked as one table.
static func reaction_records(rung: int = ANY) -> Array:
	var paths: PackedStringArray = PackedStringArray()
	for p in ReactionsScript.RECORD_MODULES:
		if has_record("reaction", String(p).get_file(), rung):
			paths.append(String(p))
	return ReactionsScript.records_from(paths)


static func _rung_or_active(rung: int) -> int:
	return _active if rung == ANY else clampi(rung, STATE, TOP)


static func _matches(key: String, want: Array) -> bool:
	for w in want:
		var pat: String = String(w)
		if pat == AMOUNTS_TOKEN:
			for n in ReduceRecordsScript.AMOUNTS:
				if key == "all_" + String(n) or key == "open_" + String(n):
					return true
		elif pat.ends_with("*") and key.begins_with(pat.substr(0, pat.length() - 1)):
			return true
		elif pat == key:
			return true
	return false
