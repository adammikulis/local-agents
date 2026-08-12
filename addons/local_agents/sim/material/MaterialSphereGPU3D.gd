class_name LAMaterialSphereGPU3D
extends RefCounted


const PAIR_CHANNELS: PackedStringArray = [
	"temp", "water", "moisture", "lava", "sediment", "fire", "dust",
	"o2", "co2", "shock", "fungus", "susp", "fert", "soil", "air"]
const SINGLE_CHANNELS: PackedStringArray = [
	"solid", "fuel", "charge", "detritus", "biomass", "pressure",
	"vel_x", "vel_y", "vel_z", "fungus_fert", "snow", "rock_fill",
	"carbonate", "silica",
	"porosity",
	"regolith",     # aquifer permeability mask (1 = groundwater-bearing rock) — static; seeded once
	"grain"]        # representative grain diameter in METRES per regolith cell — static; seeded once. The
	                # aquifer kernel turns it into hydraulic conductivity through Kozeny-Carman, so K varies
	                # over four orders of magnitude across the planet instead of being one number.

# Data-flow dispatch order (see the PING-PONG PHASE note above). WaterSlumpLava MUST precede Thermal
# (Thermal reads water/lava from "back" + consumes the lava carry-heat left in "live" temp); Atmosphere/
# FireDust MUST follow Thermal (they read the finished temp/water from "back").
const PASS_SCRIPTS: PackedStringArray = [
	"res://addons/local_agents/sim/material/sphere_passes/PlateAdvectPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/SolidDerivePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/WaterSlumpLavaPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/LavaCellListPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ThermalPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/GasWindPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/AtmospherePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/SoilPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ErosionTransportPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ErosionPickupPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/FireDustPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/EcoSurfacePass.gd"]

const SCENT_PLANES: int = 5
const SOIL_DBG_SLOTS: int = 21
# Slots in the `active_args` buffer (see setup()). 0-2 are the uvec3 dispatch-indirect argument; 3 is the
# compacted list length a compacted kernel uses as its loop bound. 8 rather than 4 purely for 32-byte alignment.
const ACTIVE_ARGS_SLOTS: int = 8
const ARG_SLOT_LIST_COUNT: int = 3
# Plate table layout, shared with plate_advect_sphere3d.glsl: per plate, seed.xyz + rate + pole.xyz + pad.
# MAX_PLATES is only the buffer ceiling; the live count travels in ctx["n_plates"].
const PLATE_STRIDE: int = 8
const MAX_PLATES: int = 32

static func available() -> bool:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

var _rd: RenderingDevice = null
# LA_INJECT_AUDIT=1 -> every whole-mirror set_field upload prints how much mass it wrote away (see
# _audit_mirror_upload). Read once here, not per call: it costs a full-grid readback plus two sums.
var _audit_mirror: bool = OS.has_environment("LA_INJECT_AUDIT")
var _field = null
var _grid: RefCounted = null
var _cc: int = 0
var _phase: int = 0                 # ping-pong phase ∈ {0,1}; flips once per step (NOT CPU parity)
var _step_index: int = 0            # monotonic field-step counter; wind_pressure_sphere3d reads step_index == 0
                                    # as "seed the standard atmosphere" (the air channel allocates all-zero)
var _groups: int = 0
var _bufs: Dictionary = {}          # key → RID (single) or [rid_a, rid_b] (pair)
var _passes: Array = []
var _pass_names: PackedStringArray = []   # parallel to _passes — short label per pass, for GPU per-pass timing
var _ctx: Dictionary = {}
var _gpu_pass_ms: Dictionary = {}   # pass name -> this step's GPU execution time (ms)
var _gpu_dispatch_ms: float = 0.0   # sum of all passes — the real GPU counterpart to field_dispatch_ms
var _pending: bool = false          # a step() submit is in flight, not yet synced/read
var _cached: Dictionary = {}        # channels read back from the last drained step (what end_frame returns)
var _slow_gate: int = 0             # cadence counter for the slow (ledger/baker) channel readback set

const SITUATIONAL_CHANNELS: Array = ["lava", "fire", "dust", "shock", "co2", "fuel", "rock_fill",
	"pressure", "detritus", "fungus"]
const CHANNEL_HOLD_DRAINS: int = 20     # stay hot ~20 drains past the last request so intermittent queries don't thrash
var _channel_hold: Dictionary = {}      # channel name -> drain index it stays hot through
var _drain_count: int = 0               # monotonic drain counter the holds are measured against
var _probe_want: PackedStringArray = PackedStringArray()
var _probe: Dictionary = {}
# begin_frame upload gates: the solid/static masks and CPU water copy are re-uploaded only when actually edited
# (SDF stamp / water injection), not every step — the per-step re-upload was pure CPU↔GPU transfer waste. Both
# default true so the first begin_frame seeds them.
var _solid_dirty: bool = true
var _water_dirty: bool = true
# Set by MaterialFieldInject3D whenever anything writes the CPU temp mirror (add_heat, meteor, lava).
# True at construction so the seeded field reaches the GPU on the first step.
var _temp_dirty: bool = true

# Slow channels are read back only every Nth drain (their CPU consumers are coarse-cadence ledgers/bakers, not
# every-frame world queries) — a direct cut of ~6 of 21 blocking readbacks on the other frames. Between reads the
# CPU array keeps its prior value (the _apply_readback scatter is res.has()-guarded), which the consumers tolerate.
const SLOW_READBACK_EVERY: int = 4
const SLOW_CHANNELS: PackedStringArray = ["sediment", "susp", "fert", "soil", "biomass", "porosity"]

# BETWEEN-PASS PROBE (LA_H2O_BUDGET diagnostics only; armed per step by LAMaterialFieldH2OBudget3D, left
# invalid otherwise). When valid, step() runs the checkpointed path below instead of the normal one-submit
# path. Nothing on the per-frame path reads this.
var _step_probe: Callable = Callable()


func setup(field) -> void:
	_field = field
	_grid = field.sphere_grid()
	_cc = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("LAMaterialSphereGPU3D: no RenderingDevice")
		return
	_groups = int(ceil(float(_cc) / 64.0))

	for name in PAIR_CHANNELS:
		_bufs[name] = [_new_f(_cc), _new_f(_cc)]
	_bufs["scent"] = [_new_f(_cc * SCENT_PLANES), _new_f(_cc * SCENT_PLANES)]
	for name in SINGLE_CHANNELS:
		_bufs[name] = _new_f(_cc)
	_bufs["send"] = _new_f(_cc * 6)
	_bufs["soil_dbg"] = _new_f(_cc * SOIL_DBG_SLOTS)     # per-leg groundwater budget probe (see SOIL_DBG_SLOTS)
	# BOTH the uvec3 dispatch-indirect argument (slots 0-2) and the atomic list-length counter (slot 3) — one
	_bufs["active_idx"] = _new_u32(_cc)
	_bufs["active_args"] = _rd.storage_buffer_create(
		ACTIVE_ARGS_SLOTS * 4, _zeros(ACTIVE_ARGS_SLOTS),
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	# Sphere geometry SSBOs: neighbour table (int32, LASphereGrid slot order), radial + position (flat float3).
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_bufs["radial"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_radial(c))
	_bufs["pos"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_world_pos(c))
	var ltan_bytes: PackedByteArray = _grid.link_tan.to_byte_array()
	_bufs["link_tan"] = _rd.storage_buffer_create(ltan_bytes.size(), ltan_bytes)
	# The slot that answers each link. A gather indexes this instead of computing `d ^ 1`.
	var partner_bytes: PackedByteArray = _grid.link_partner.to_byte_array()
	_bufs["link_partner"] = _rd.storage_buffer_create(partner_bytes.size(), partner_bytes)
	# Angular separation per lateral link — the lateral RUN a slope test needs (see LASphereGrid.link_arc).
	var larc_bytes: PackedByteArray = _grid.link_arc.to_byte_array()
	_bufs["link_arc"] = _rd.storage_buffer_create(larc_bytes.size(), larc_bytes)
	# Per-shell radial geometry: thickness, centre radius, centre-to-centre runs. See kernels3d/shell.glsli.
	var shell_bytes: PackedByteArray = _grid.shell_table().to_byte_array()
	_bufs["shell"] = _rd.storage_buffer_create(shell_bytes.size(), shell_bytes)
	_bufs["plates"] = _rd.storage_buffer_create(MAX_PLATES * PLATE_STRIDE * 4,
		_zeros(MAX_PLATES * PLATE_STRIDE))

	_seed("temp", field._temp)
	_seed("o2", field._o2)
	_seed("co2", field._co2)            # the atmosphere's carbon — finite, at Earth's measured mole fraction
	_seed("soil", field._soil)          # initial water table (regolith primed by _compute_regolith)
	_seed_solid()
	_seed_rock_fill()
	_seed_regolith()                    # aquifer permeability mask + grain-size field (static)

	# The reaction table's flux-derived rates (evaporation and its kin) turn a real per-square-metre flux into a
	# per-cell extent, which needs the cell HEIGHT. The table is baked once, so it gets the SURFACE shell's
	# thickness — the shell those fluxes cross — not the column mean.
	var surf_shell: int = _grid.shell_of(field.sea_level)
	LAReactionDefs.cell_size_m = float(_grid.shell_dr[surf_shell]) if surf_shell >= 0 \
		else float(_grid.cell_size)

	# Load + set up the pass modules (skip any that fail to load — WIP-tolerant).
	for path in PASS_SCRIPTS:
		var scr: GDScript = load(path)
		if scr == null:
			push_warning("sphere pass missing: " + path)
			continue
		var p: RefCounted = scr.new()
		if p.has_method("setup"):
			p.setup(_rd, _bufs, _cc)
			_passes.append(p)
			_pass_names.append(path.get_file().get_basename())   # e.g. "ThermalPass" — timestamp label


func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6, wind: Vector2 = Vector2.ZERO) -> void:
	if _rd == null:
		return
	# Drain the previous frame's in-flight step FIRST: sync it (usually already done — the GPU ran it during the
	# inter-frame CPU work) and read its channels into `_cached`. Must happen before the temp/water uploads below,
	# which write the same live buffers the step wrote. This is the CPU↔GPU overlap that hides the field step cost.
	_drain_pending()
	# geothermal core pin wrote _temp on the CPU every step. It does not any more. The core is a flux
	# boundary applied inside heat_sphere3d.glsl (LAMaterialFieldGeotherm3D pushes one scalar), so the only
	# CPU writer left is injection (add_heat / meteors / lava), which marks it dirty. Same gate as water.
	if _temp_dirty:
		_upload_f(_live("temp"), temp)
		_temp_dirty = false
	# water is only CPU-modified by injection (add_water / lakes seed), never per-step; after the readback the CPU
	# copy already equals the GPU's evolved water, so re-uploading it every step is redundant. Gate it on a dirty
	# flag the injectors set.
	if _water_dirty:
		_upload_f(_live("water"), water)
		_water_dirty = false
	# solid + static masks change only on an SDF edit (volcano stamp, terrain edit) — NOT per step. _seed_solid
	# rebuilt + uploaded BOTH full-grid buffers every frame; gate it so it only fires when the CPU mask changed.
	if _solid_dirty:
		_seed_solid()
		_solid_dirty = false
	_ctx["solar"] = solar
	_ctx["wind"] = wind
	_ctx["dt"] = 0.1
	_ctx["cell_size"] = _grid.cell_size
	# LATERAL cell spacing. It is the mean radial thickness only because nothing measures the real arc yet;
	# the true run is `link_arc * shell_mid`, which varies 1.07-4.08 across a face. Named so the two stop
	# sharing a symbol — the radial half now comes from the shell table, this one does not.
	_ctx["lat_size"] = _grid.cell_size
	_ctx["core_radius"] = _grid.core_radius     # groundwater aquifer needs the shell geometry for cell elevation
	_ctx["depth"] = _grid.depth
	_ctx["sea_radius"] = _field.sphere_grid().core_radius   # placeholder; overridden by set_sea_radius
	_ctx["max_mass"] = _field.MAX_MASS                      # a full cell of one phase — PlateAdvectPass uplifts the surplus
	if not _ctx.has("sun_dir"):
		_ctx["sun_dir"] = Vector3(0, 1, 0)

## Planet spin axis in the FIELD's frame. GasWindPass reads ctx["spin_axis"] for its latitude bands and
## Coriolis handedness; until this existed nothing set it, so it fell back to world +Y while the planet's
## real axis is 23.5 degrees away — every wind band was referenced to the wrong pole.
func set_spin_axis(v: Vector3) -> void:
	_ctx["spin_axis"] = v.normalized() if v.length() > 0.001 else Vector3(0, 1, 0)


func set_sun_dir(v: Vector3) -> void:
	_ctx["sun_dir"] = v if v.length() > 0.001 else Vector3(0, 1, 0)


func set_plates(table: PackedFloat32Array) -> void:
	if _rd == null or not _bufs.has("plates"):
		return
	var n: int = mini(int(table.size() / PLATE_STRIDE), MAX_PLATES)
	_ctx["n_plates"] = n
	if n <= 0:
		return
	var b: PackedByteArray = table.slice(0, n * PLATE_STRIDE).to_byte_array()
	_rd.buffer_update(_bufs["plates"], 0, b.size(), b)

func set_core_boundary_c(v: float) -> void:
	_ctx["core_boundary_c"] = v


## Mark the CPU temp mirror dirty so the next begin_frame re-uploads it.
func mark_temp_dirty() -> void:
	_temp_dirty = true


func set_sea_radius(r: float) -> void:
	_ctx["sea_radius"] = r

func step() -> void:
	if _rd == null:
		return
	if _pending:
		_rd.sync()
		_pending = false
		_read_gpu_pass_timings()
	_ctx["step_index"] = _step_index
	if _step_probe.is_valid():
		_step_checkpointed()
		return
	_rd.capture_timestamp("field_start")   # marker 0 — the interval to pass 0's own marker is pass 0's GPU time
	for i in _passes.size():
		var cl: int = _rd.compute_list_begin()
		_passes[i].dispatch(_rd, cl, _phase, _ctx, _cc, _groups)
		# EVERY PASS READS WHAT THE PREVIOUS ONE WROTE. Passes barrier internally between their own
		# sub-dispatches but nothing ordered them against EACH OTHER, so in one submit they overlapped and
		# read half-written buffers. The checkpointed path syncs per pass and was therefore correct, which is
		# how this showed up: with LA_PASS_PROBE armed o2 stays at 69120, without it o2 reaches 4e17.
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_end()
		_rd.capture_timestamp(_pass_names[i])
	_rd.submit()                        # deferred sync — drained at the next begin_frame (GPU overlaps CPU frame work)
	_pending = true
	_phase = 1 - _phase
	_step_index += 1

## Total of one channel's LIVE half, read at a checkpoint. Only safe between passes on the checkpointed
## path, where the driver has already synced — a read anywhere else flushes work mid-flight and changes the
## simulation. PAIR channels resolve their live half; SINGLE channels are read directly.
func channel_total_now(name: String) -> float:
	return channel_total_half(name, _phase)


## BOTH halves of a PAIR, because mid-step the live half is the one being read FROM and the written half is
## the other one. A probe that only reads `_live` never sees what the step produced.
func channel_totals_now(name: String) -> Dictionary:
	if not _bufs.has(name):
		return {}
	if name in SINGLE_CHANNELS:
		return {"single": channel_total_half(name, 0)}
	return {"live": channel_total_half(name, _phase), "back": channel_total_half(name, 1 - _phase)}


func channel_total_half(name: String, half: int) -> float:
	if _rd == null or not _bufs.has(name):
		return NAN
	var entry = _bufs[name]
	var rid: RID = entry[half] if entry is Array else entry
	if not rid.is_valid():
		return NAN
	var a: PackedFloat32Array = _rd.buffer_get_data(rid).to_float32_array()
	var t: float = 0.0
	for v in a:
		t += v
	return t


## Signature: `probe.call(pass_index: int, pass_name: String)`, pass_index -1 = before any pass ran.
func set_step_probe(cb: Callable) -> void:
	_step_probe = cb


func _step_checkpointed() -> void:
	_step_probe.call(-1, "start")
	for i in _passes.size():
		var cl: int = _rd.compute_list_begin()
		_passes[i].dispatch(_rd, cl, _phase, _ctx, _cc, _groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		_step_probe.call(i, _pass_names[i])
	# Leave an in-flight submit so _drain_pending's contract is unchanged (it syncs, then reads this frame's
	# channels into _cached). An empty compute list is a legal no-op submit.
	var tail: int = _rd.compute_list_begin()
	_rd.compute_list_end()
	_rd.submit()
	_pending = true
	_phase = 1 - _phase
	_step_index += 1


## Current ping-pong phase — the probe needs it to know which half of a PAIR channel is live at a checkpoint.
func probe_phase() -> int:
	return _phase


## Raw device readback of one channel half. Diagnostic only (the between-pass probe): `half` picks the ping-pong
## slot for PAIR channels and is ignored for SINGLE ones. No sync is done here — the checkpointed step already
## synced, and calling this off that path would read whatever the last sync left.
func read_raw(name: String, half: int) -> PackedFloat32Array:
	if _rd == null or not _bufs.has(name):
		return PackedFloat32Array()
	var b = _bufs[name]
	var buf: RID = b[half] if b is Array else b
	return _rd.buffer_get_data(buf).to_float32_array()


func end_frame(_rv: bool = true, _rc: bool = true, _rf: bool = true, _rr: bool = true, _rl: bool = true, _rs: bool = true) -> Dictionary:
	if _rd == null:
		return _empty_result()
	return _cached if not _cached.is_empty() else _empty_result()


## Sync an in-flight step submit WITHOUT reading channels — for save/load/dispose paths that touch buffers
## outside the normal begin/step/end loop. Leaves `_cached` untouched (those paths don't feed the CPU query arrays).
func _flush_pending() -> void:
	if not _pending:
		return
	_rd.sync()
	_pending = false


func _drain_pending() -> void:
	if not _pending:
		return
	var t0: int = Time.get_ticks_usec()
	_rd.sync()
	var t_sync: int = Time.get_ticks_usec()
	_pending = false
	_drain_count += 1
	_slow_gate += 1
	var read_slow: bool = _slow_gate >= SLOW_READBACK_EVERY
	if read_slow:
		_slow_gate = 0
	_cached = _read_channels(read_slow)
	# Read-only instrument sample, taken HERE because the device was just synced (see request_probe). It is
	# written to its own dictionary, never to `_cached`, so no simulation consumer's view changes.
	if not _probe_want.is_empty():
		_probe = {}
		for pname in _probe_want:
			if not _bufs.has(pname):
				continue
			var pb = _bufs[pname]
			_probe[pname] = _rd.buffer_get_data(pb[_phase] if pb is Array else pb).to_float32_array()
		_probe_want = PackedStringArray()
	# Direct sub-timings (noise-immune, unlike fps): how long the GPU sync stall vs the channel copy/convert
	# actually cost this drain. The readback (buffer_get_data + to_float32_array over ~17 full-grid channels) is
	# the suspected field bottleneck; measuring it directly is how we know what gating it can win.
	LASimReport.gauge("field_sync_ms", float(t_sync - t0) / 1000.0)
	LASimReport.gauge("field_readback_ms", float(Time.get_ticks_usec() - t_sync) / 1000.0)
	_read_gpu_pass_timings()   # real GPU execution time for the step just sync()'d — see field vars above
	_read_active_list_counts()


func _read_gpu_pass_timings() -> void:
	var n: int = _rd.get_captured_timestamps_count()
	if n < 2:
		return   # timestamp queries unsupported/unavailable on this backend — leave gauges at their last value
	_gpu_pass_ms.clear()
	var total_ns: int = 0
	var t_prev: int = _rd.get_captured_timestamp_gpu_time(0)
	for i in range(1, n):
		var t_cur: int = _rd.get_captured_timestamp_gpu_time(i)
		var dt_ns: int = t_cur - t_prev
		var pass_ms: float = float(dt_ns) / 1_000_000.0
		_gpu_pass_ms[_rd.get_captured_timestamp_name(i)] = pass_ms
		LASimReport.gauge("gpu_" + _gpu_gauge_key(i - 1) + "_ms", pass_ms)
		total_ns += dt_ns
		t_prev = t_cur
	_gpu_dispatch_ms = float(total_ns) / 1_000_000.0
	LASimReport.gauge("gpu_dispatch_ms", _gpu_dispatch_ms)


func _read_active_list_counts() -> void:
	if not _bufs.has("active_args"):
		return
	var raw: PackedByteArray = _rd.buffer_get_data(_bufs["active_args"])
	if raw.size() < ACTIVE_ARGS_SLOTS * 4:
		return
	var slots: PackedInt32Array = raw.to_int32_array()
	LASimReport.gauge("field_cells", float(_cc))
	LASimReport.gauge("lava_list_cells", float(slots[ARG_SLOT_LIST_COUNT]))


## "ThermalPass" -> "thermal"; a short, gauge-key-safe name (strip the "Pass" suffix, snake_case the rest).
func _gpu_gauge_key(pass_index: int) -> String:
	var n: String = _pass_names[pass_index]
	if n.ends_with("Pass"):
		n = n.substr(0, n.length() - 4)
	return n.to_snake_case()


func _read_channels(read_slow: bool) -> Dictionary:
	var out: Dictionary = _empty_result()
	for k in ["temp", "water", "moisture", "o2"]:
		out[k] = _rd.buffer_get_data(_live(k)).to_float32_array()
	# scent is a 5-plane packed pair (SCENT_PLANES * cell_count) — read its live half whole so the CPU bridge
	# scatters all five planes (prey/predator/blood/food/alarm) back for the sense gradients.
	out["scent"] = _rd.buffer_get_data(_live("scent")).to_float32_array()
	# snow (SINGLE) — read every physics frame per living carcass (decomposition/permafrost gating), not just
	# render/debug, so it stays hot even though most consumers are periodic.
	if _bufs.has("snow"):
		out["snow"] = _rd.buffer_get_data(_bufs["snow"]).to_float32_array()
	# Emergent WIND velocity (SINGLE, in-place) — wind3_at/wind_at expose a real force field that EVERY creature
	# samples per frame (LACreatureFieldForces), so it stays always-hot. CHARGE (breakdown→bolt firing) also has
	# a per-frame consumer with NO CPU-side trigger event to hook a request_channel() call to, so it stays hot too.
	for k in ["vel_x", "vel_y", "vel_z", "charge"]:
		if _bufs.has(k):
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	for k in SITUATIONAL_CHANNELS:
		if not _bufs.has(k) or int(_channel_hold.get(k, -1)) < _drain_count:
			continue
		var src: RID = _bufs[k] if k in SINGLE_CHANNELS else _live(k)
		out[k] = _rd.buffer_get_data(src).to_float32_array()
	# SLOW — ledger/baker channels, read only on the coarse cadence. PAIR channels (sediment/susp/fert/soil) from
	# the live half; single channel (biomass) direct.
	if read_slow:
		for k in ["sediment", "susp", "fert", "soil"]:
			out[k] = _rd.buffer_get_data(_live(k)).to_float32_array()
		if _bufs.has("biomass"):
			out["biomass"] = _rd.buffer_get_data(_bufs["biomass"]).to_float32_array()
	return out

func request_channel(name: String) -> void:
	_channel_hold[name] = _drain_count + CHANNEL_HOLD_DRAINS


func request_probe(names: PackedStringArray) -> void:
	for name in names:
		if not _probe_want.has(name):
			_probe_want.append(name)


## Collect the most recent read-only sample — one drain old at most, the same lag the CPU mirrors carry. Empty
## until the first drain after `request_probe`, so a caller falls back to the mirrors and publishes which legs
## it actually got (`mineral_live` / `mass_live`).
func take_probe() -> Dictionary:
	return _probe


## The CPU solid/static mask changed (initial solidity sample, a volcano SDF stamp, a terrain edit) — re-seed
## the GPU solid/static buffers on the next begin_frame instead of every step.
func mark_solid_dirty() -> void:
	_solid_dirty = true


## The CPU water channel was edited (add_water injection, lake seed) — re-upload it on the next begin_frame.
func mark_water_dirty() -> void:
	_water_dirty = true


func _audit_mirror_upload(name: String, arr) -> void:
	var b = _bufs[name]
	var buf: RID = _live(name) if b is Array else b
	var live: PackedFloat32Array = _rd.buffer_get_data(buf).to_float32_array()
	var lt: float = 0.0
	var mt: float = 0.0
	# Whole array, not the first _cc entries: `scent` is a 5-plane pair (SCENT_PLANES * _cc) and capping at _cc
	# would report one plane's drift as the channel's.
	var n: int = mini(live.size(), arr.size())
	for i in n:
		lt += live[i]
		mt += arr[i]
	print("MIRROR_REWIND={\"channel\":\"%s\",\"live\":%.4f,\"mirror\":%.4f,\"delta\":%.4f}" % [name, lt, mt, mt - lt])


func set_field(name: String, arr) -> void:
	if _rd == null or not _bufs.has(name):
		return
	if _audit_mirror and arr is PackedFloat32Array:
		_audit_mirror_upload(name, arr)
	if name == "temp":
		_temp_dirty = true      # keep the gated begin_frame upload in step with a whole-mirror set
	var b = _bufs[name]
	if b is Array:
		# scent is a 5-plane pair (SCENT_PLANES * cell_count); every other pair channel is one plane (cell_count).
		# Upload the whole array into the live half when it matches the channel's expected length (mirrors
		# restore_channels) — the shared _upload_f only accepts a single-plane cell_count array, so route directly.
		var expect: int = _cc * (SCENT_PLANES if name == "scent" else 1)
		if arr.size() == expect:
			var bytes: PackedByteArray = arr.to_byte_array()
			_rd.buffer_update(b[_phase], 0, bytes.size(), bytes)
	else:
		_upload_f(b, arr)


# --- SPARSE IN-PLACE EDITS (the additive counterpart to set_field) ----------------------------------------

## A delta this negative empties a cell exactly (the clamp floor is 0), so callers that want to DRAIN a cell
## without knowing what is in it pass this and read the returned total.
const DRAIN_ALL: float = -1.0e30

func add_field_sparse(name: String, cells: PackedInt32Array, deltas: PackedFloat32Array, ceiling: float = INF) -> float:
	if cells.size() != deltas.size():
		push_error("add_field_sparse('%s'): %d cells vs %d deltas — op dropped" % [name, cells.size(), deltas.size()])
		return 0.0
	if _rd == null or not _bufs.has(name) or cells.size() == 0:
		return 0.0
	var buf: RID = _live(name) if _bufs[name] is Array else _bufs[name]
	var arr: PackedFloat32Array = _rd.buffer_get_data(buf).to_float32_array()
	if arr.size() < _cc:
		return 0.0
	var applied: float = 0.0
	var lo: int = _cc
	var hi: int = -1
	for i in cells.size():
		var c: int = cells[i]
		if c < 0 or c >= _cc:
			continue
		var before: float = arr[c]
		var delta: float = deltas[i]
		if delta > 0.0:
			delta = minf(delta, maxf(0.0, ceiling - before))   # fill the headroom only; never push a cell down
		var after: float = maxf(0.0, before + delta)
		if after == before:
			continue
		arr[c] = after
		applied += after - before
		lo = mini(lo, c)
		hi = maxi(hi, c)
	if hi < lo:
		return 0.0
	var span: PackedFloat32Array = arr.slice(lo, hi + 1)
	var bytes: PackedByteArray = span.to_byte_array()
	_rd.buffer_update(buf, lo * 4, bytes.size(), bytes)
	return applied


func move_field_sparse(src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, dst_ceiling: float = INF) -> float:
	if _rd == null or not _bufs.has(src) or not _bufs.has(dst):
		return 0.0
	if src_cells.size() == 0 or src_cells.size() != amounts.size() or src_cells.size() != dst_cells.size():
		return 0.0
	var sbuf: RID = _live(src) if _bufs[src] is Array else _bufs[src]
	var dbuf: RID = _live(dst) if _bufs[dst] is Array else _bufs[dst]
	# A src==dst move (displacing water from a burying cell into its neighbour) must edit ONE array, or the
	# second write-back would clobber the first. PackedFloat32Array is copy-on-write, so aliasing the handle is
	# not enough — the branch below keeps a single array and a single touched span in that case.
	var same: bool = sbuf == dbuf
	var sarr: PackedFloat32Array = _rd.buffer_get_data(sbuf).to_float32_array()
	var darr: PackedFloat32Array = PackedFloat32Array() if same else _rd.buffer_get_data(dbuf).to_float32_array()
	if sarr.size() < _cc or (not same and darr.size() < _cc):
		return 0.0
	var moved: float = 0.0
	var slo: int = _cc
	var shi: int = -1
	var dlo: int = _cc
	var dhi: int = -1
	for i in src_cells.size():
		var sc: int = src_cells[i]
		if sc < 0 or sc >= _cc:
			continue
		var take: float = minf(maxf(amounts[i], 0.0), sarr[sc])
		var dc: int = dst_cells[i]
		var live_dst: bool = dc >= 0 and dc < _cc
		if live_dst:
			# Honour the destination's own ceiling by taking only what it can hold (never spill mass).
			var held: float = sarr[dc] if same else darr[dc]
			take = minf(take, maxf(0.0, dst_ceiling - held))
		if take <= 0.0:
			continue
		sarr[sc] -= take
		slo = mini(slo, sc)
		shi = maxi(shi, sc)
		if live_dst:
			if same:
				sarr[dc] += take
				slo = mini(slo, dc)
				shi = maxi(shi, dc)
			else:
				darr[dc] += take
				dlo = mini(dlo, dc)
				dhi = maxi(dhi, dc)
		moved += take
	if shi >= slo:
		var sspan: PackedByteArray = sarr.slice(slo, shi + 1).to_byte_array()
		_rd.buffer_update(sbuf, slo * 4, sspan.size(), sspan)
	if not same and dhi >= dlo:
		var dspan: PackedByteArray = darr.slice(dlo, dhi + 1).to_byte_array()
		_rd.buffer_update(dbuf, dlo * 4, dspan.size(), dspan)
	return moved


## Sum of a channel's LIVE device buffer. Diagnostic only (the injection queue's staleness audit compares it
## against the CPU mirror to measure what a mirror-upload would have written away); nothing on the per-frame
## path calls it, because it is a full-grid readback plus a full-grid sum.
func channel_total(name: String) -> float:
	if _rd == null or not _bufs.has(name):
		return 0.0
	var buf: RID = _live(name) if _bufs[name] is Array else _bufs[name]
	var arr: PackedFloat32Array = _rd.buffer_get_data(buf).to_float32_array()
	var sum: float = 0.0
	for i in mini(arr.size(), _cc):
		sum += arr[i]
	return sum


func read_soil_budget() -> Dictionary:
	if _rd == null or not _bufs.has("soil_dbg"):
		return {}
	_flush_pending()
	return {
		"dbg": _rd.buffer_get_data(_bufs["soil_dbg"]).to_float32_array(),
		"soil": _rd.buffer_get_data(_live("soil")).to_float32_array(),
		"step_index": _step_index,
	}


func snapshot_channels() -> Dictionary:
	var out: Dictionary = {}
	if _rd == null:
		return out
	_flush_pending()        # a step submit may be in flight (async pipeline) — sync before reading the buffers
	for name in PAIR_CHANNELS:
		out[name] = _rd.buffer_get_data(_live(name)).to_float32_array()
	out["scent"] = _rd.buffer_get_data(_bufs["scent"][_phase]).to_float32_array()
	for name in SINGLE_CHANNELS:
		out[name] = _rd.buffer_get_data(_bufs[name]).to_float32_array()
	return out


## LOAD: upload a snapshot_channels() dict back into the GPU buffers. Pair channels are written to BOTH halves
func restore_channels(data: Dictionary) -> void:
	if _rd == null:
		return
	_flush_pending()        # a step submit may be in flight — sync before overwriting the buffers
	for name in data.keys():
		var key: String = String(name)
		if not _bufs.has(key):
			continue
		var arr: PackedFloat32Array = data[key]
		var bytes: PackedByteArray = arr.to_byte_array()
		var b = _bufs[key]
		if b is Array:
			var expect: int = _cc * (SCENT_PLANES if key == "scent" else 1)
			if arr.size() != expect:
				continue
			_rd.buffer_update(b[0], 0, bytes.size(), bytes)
			_rd.buffer_update(b[1], 0, bytes.size(), bytes)
		elif b is RID:
			if arr.size() != _cc:
				continue
			_rd.buffer_update(b, 0, bytes.size(), bytes)

func set_precip(v: float) -> void:
	_ctx["precip"] = v


func dispose() -> void:
	if _rd == null:
		return
	_flush_pending()        # ensure the GPU is idle (no in-flight step submit) before freeing any RID
	for p in _passes:
		if p != null and p.has_method("dispose"):
			p.dispose(_rd)
	_passes = []
	_pass_names = PackedStringArray()
	for k in _bufs:
		var b = _bufs[k]
		if b is Array:
			for r in b:
				if r is RID and r.is_valid():
					_rd.free_rid(r)
		elif b is RID and b.is_valid():
			_rd.free_rid(b)
	_bufs = {}
	_rd.free()
	_rd = null


# --- helpers ------------------------------------------------------------------

func _live(name: String) -> RID:
	return _bufs[name][_phase]

func _new_f(n: int) -> RID:
	var z: PackedByteArray = _zeros(n)
	return _rd.storage_buffer_create(z.size(), z)

## An n-element uint32 storage buffer. Same 4-bytes-per-element allocation as _new_f — the distinction is only
## how the kernel declares it — but named separately so the active-cell list reads as the index buffer it is.
func _new_u32(n: int) -> RID:
	var z: PackedByteArray = _zeros(n)
	return _rd.storage_buffer_create(z.size(), z)

func _make_vec3_flat(getter: Callable) -> RID:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc * 3)
	for c in _cc:
		var v: Vector3 = getter.call(c)
		f[c * 3 + 0] = v.x
		f[c * 3 + 1] = v.y
		f[c * 3 + 2] = v.z
	var b: PackedByteArray = f.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)

func _seed(name: String, arr: PackedFloat32Array) -> void:
	if _bufs.has(name) and arr.size() == _cc:
		var b = _bufs[name]
		var bytes: PackedByteArray = arr.to_byte_array()
		_rd.buffer_update(b[0], 0, bytes.size(), bytes)
		_rd.buffer_update(b[1], 0, bytes.size(), bytes)

func _seed_solid() -> void:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc)
	for i in _cc:
		f[i] = 1.0 if _field._solid[i] != 0 else 0.0
	var b: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["solid"], 0, b.size(), b)

func _seed_regolith() -> void:
	var m: PackedByteArray = _field._regolith
	if m.size() != _cc:
		return
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc)
	for i in _cc:
		f[i] = 1.0 if m[i] != 0 else 0.0
	var b: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["regolith"], 0, b.size(), b)
	# Grain size rides along: same lifetime, same derivation pass (LAMaterialFieldRegolith3D.compute), and it
	# is meaningless without the mask that says which cells are aquifer.
	var g: PackedFloat32Array = _field._grain
	if g.size() == _cc:
		var gb: PackedByteArray = g.to_byte_array()
		_rd.buffer_update(_bufs["grain"], 0, gb.size(), gb)


func _seed_rock_fill() -> void:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc)
	for i in _cc:
		f[i] = 1.0 if _field._solid[i] != 0 else 0.0
	var b: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["rock_fill"], 0, b.size(), b)

func _upload_f(buf: RID, arr: PackedFloat32Array) -> void:
	if arr.size() == _cc:
		var b: PackedByteArray = arr.to_byte_array()
		_rd.buffer_update(buf, 0, b.size(), b)

func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()

func _empty_result() -> Dictionary:
	return {
		"temp": PackedFloat32Array(), "water": PackedFloat32Array(),
		"moisture": PackedFloat32Array(), "lava": PackedFloat32Array(),
		"fire": PackedFloat32Array(), "fuel": PackedFloat32Array(),
		"sediment": PackedFloat32Array(), "o2": PackedFloat32Array(),
		"co2": PackedFloat32Array(), "charge": PackedFloat32Array(),
		"scent": PackedFloat32Array(), "fert": PackedFloat32Array(),
		"detritus": PackedFloat32Array(), "shock": PackedFloat32Array(),
		"dust": PackedFloat32Array(), "snow": PackedFloat32Array(),
		"susp": PackedFloat32Array(), "biomass": PackedFloat32Array(),
		"rock_fill": PackedFloat32Array(), "soil": PackedFloat32Array(),
	}
