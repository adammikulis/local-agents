class_name LAMaterialSphereGPU3D
extends RefCounted


## Views of LAChannels, the one declaration of what a channel is.
static func channels() -> PackedStringArray: return LAChannels.channels()
static func situational_channels() -> PackedStringArray: return LAChannels.situational_channels()
static func slow_channels() -> PackedStringArray: return LAChannels.slow_channels()


# Dispatch order is a data dependency chain: each pass reads what the one above it published.
const PASS_SCRIPTS: PackedStringArray = [
	"res://addons/local_agents/sim/material/sphere_passes/GravityPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/PressurePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReducePass.gd"]

static func available() -> bool:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

var _rd: RenderingDevice = null
var _audit_mirror: bool = OS.has_environment("LA_INJECT_AUDIT")
var _field = null
var _grid: RefCounted = null
var _cc: int = 0
var _step_index: int = 0            # monotonic field-step counter, published to kernels as ctx["step_index"]
var _groups: int = 0
var _bufs: Dictionary = {}          # channel/buffer name → its one RID
var _passes: Array = []
var _pass_names: PackedStringArray = []   # parallel to _passes — short label per pass, for GPU per-pass timing
var _ctx: Dictionary = {}
var _gpu_pass_ms: Dictionary = {}   # pass name -> this step's GPU execution time (ms)
var _gpu_dispatch_ms: float = 0.0   # sum of all passes — the real GPU counterpart to field_dispatch_ms
var _buf_owner: Dictionary = {}     # _bufs key -> what claimed it, so a collision can name both claimants
var _pass_results: Dictionary = {}  # merged _drain() readings of the last drained step
var _pending: bool = false          # a step() submit is in flight, not yet synced/read
var _cached: Dictionary = {}        # channels read back from the last drained step (what end_frame returns)
var _slow_gate: int = 0             # cadence counter for the slow (ledger/baker) channel readback set

const CHANNEL_HOLD_DRAINS: int = 20     # stay hot ~20 drains past the last request so intermittent queries don't thrash
var _channel_hold: Dictionary = {}      # channel name -> drain index it stays hot through
var _drain_count: int = 0               # monotonic drain counter the holds are measured against
var _probe_want: PackedStringArray = PackedStringArray()
var _probe: Dictionary = {}
# Re-uploaded only when a CPU writer marks them, never per step.
var _solid_dirty: bool = true
var _water_dirty: bool = true
var _h_dirty: bool = true

# Slow channels are read back only every Nth drain (their CPU consumers are coarse-cadence ledgers/bakers, not
# every-frame world queries) — a direct cut of ~6 of 21 blocking readbacks on the other frames. Between reads the
# CPU array keeps its prior value (the _apply_readback scatter is res.has()-guarded), which the consumers tolerate.
const SLOW_READBACK_EVERY: int = 4

# BETWEEN-PASS PROBE, armed per step by LAFieldPassAttribution3D and left invalid otherwise. When valid,
# step() runs the checkpointed path below instead of the normal one-submit path. Nothing on the per-frame
# path reads this.
var _step_probe: Callable = Callable()


func setup(field) -> void:
	_field = field
	_grid = field._grid
	_cc = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("LAMaterialSphereGPU3D: no RenderingDevice")
		return
	_groups = int(ceil(float(_cc) / 64.0))

	for name in channels():
		_bufs[name] = _new_f(_cc)
		_buf_owner[name] = "LAChannels.rows()"
	# Derived: recomputed from the channels every step, so never seeded and never restored.
	for name in LAChannels.derived_buffers():
		_bufs[name] = _new_f(_cc)
		_buf_owner[name] = "LAChannels.derived_buffers()"
	# GRID GEOMETRY, and on a uniform Cartesian grid there are only two pieces of it. The neighbour table,
	# whose slot order is the grid's (`d ^ 1` is the opposite, checked by scripts/check_neighbour_slots.sh),
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_bufs["pos"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_world_pos(c))
	# The SOLVED gravity, flat cell*3, m/s^2. GravityPass writes it, every kernel that asks which way is
	# down reads it, and nothing anywhere holds a gravity constant.
	_bufs["gravity"] = _new_f(_cc * 3)
	# kernels3d/cellvol.glsli, binding 40: model units^3 per cell.
	var vol_bytes: PackedByteArray = _grid.cell_volumes().to_byte_array()
	_bufs["cell_vol"] = _rd.storage_buffer_create(vol_bytes.size(), vol_bytes)

	_seed("h_j_m3", field._h)
	_seed("o2", field._o2)
	_seed("co2", field._co2)            # the atmosphere's carbon — finite, at Earth's measured mole fraction
	_seed("n2", field._n2)              # the atmosphere's nitrogen — finite, at Earth's measured mole fraction
	_seed("h2o", field._h2o)            # the ocean basin + the primed water table
	_seed("porosity", field._porosity)  # Athy pore fraction: the ONE phi permeability and capacity both read
	_seed_solid()
	_seed_silicate()
	_seed_regolith()                    # aquifer permeability mask + grain-size field (static)

	# Cell height in metres for the table's flux-derived rates; the grid is SI. Set before ReactionsPass
	# bakes the table.
	LAReactionDefs.cell_size_m = float(_grid.cell_size)

	for key in _bufs:
		if not _buf_owner.has(key):
			_buf_owner[key] = "the driver"
	# Load the pass modules (skip any that fail to load — WIP-tolerant).
	for path in PASS_SCRIPTS:
		var scr: GDScript = load(path)
		if scr == null:
			push_warning("sphere pass missing: " + path)
			continue
		var p: RefCounted = scr.new()
		if p.has_method("setup"):
			_passes.append(p)
			_pass_names.append(path.get_file().get_basename())   # e.g. "TransportPass" — timestamp label
	# A pass declares the buffers it needs and the DRIVER allocates them, so they are driver-owned and can be
	# read back. Every declaration lands before any _setup, so a pass may bind another pass's buffer.
	for i in _passes.size():
		_allocate_declared(_passes[i], _pass_names[i])
	for p2 in _passes:
		p2.setup(_rd, _bufs, _cc)


## Allocate one pass's declared buffers. A name already in `_bufs` is a collision, not an overwrite: the
## first claimant keeps its RID and both claimants are named.
func _allocate_declared(p: RefCounted, label: String) -> void:
	var want: Dictionary = p._buffers(_cc)
	for key in want:
		var name: String = String(key)
		if _bufs.has(name):
			push_error("%s declares buffer \"%s\", which %s already allocated." % [
				label, name, _buf_owner[name]])
			continue
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		if n <= 0:
			push_error("%s declares buffer \"%s\" of %d elements." % [label, name, n])
			continue
		_bufs[name] = _rd.storage_buffer_create(n * 4, _zeros(n),
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		_buf_owner[name] = label


func begin_frame(h: PackedFloat32Array, water: PackedFloat32Array) -> void:
	if _rd == null:
		return
	# Drain the previous frame's in-flight step FIRST: sync it (usually already done — the GPU ran it during the
	# inter-frame CPU work) and read its channels into `_cached`. Must happen before the temp/water uploads below,
	# which write the same live buffers the step wrote. This is the CPU↔GPU overlap that hides the field step cost.
	_drain_pending()
	# The only CPU writer of _h is injection (meteors / lava / geotherm), which marks it dirty.
	if _h_dirty:
		_upload_f(_bufs["h_j_m3"], h)
		_h_dirty = false
	# water is only CPU-modified by injection (add_water / lakes seed), never per-step; after the readback the CPU
	# copy already equals the GPU's evolved water, so re-uploading it every step is redundant. Gate it on a dirty
	# flag the injectors set.
	if _water_dirty:
		_upload_f(_bufs["h2o"], water)
		_water_dirty = false
	# solid + static masks change only on an SDF edit (volcano stamp, terrain edit) — NOT per step. _seed_solid
	# rebuilt + uploaded BOTH full-grid buffers every frame; gate it so it only fires when the CPU mask changed.
	if _solid_dirty:
		_seed_solid()
		_solid_dirty = false
	_ctx["dt"] = LAMaterialFieldSphereStep3D.real_seconds_per_step()   # simulated seconds, not the cadence
	_ctx["cell_size"] = _grid.cell_size
	# The SOLVED gravity, for the handful of scalar laws a pass evaluates once. A per-cell law reads the
	# g field itself; nothing anywhere reads a gravity constant, because there is not one.
	_ctx["g_m_s2"] = _field._gravity.mean_g() if _field._gravity != null else 0.0
	# March bound: a column cannot be longer than the box.
	_ctx["depth"] = _grid.max_span()
	_ctx["centre"] = _grid.center()      # the spin axis passes through it
	_ctx["spin"] = LAFieldGeometry.spin_axis(_field)

## World-space vector toward the sun; its LENGTH is the relative insolation. Absent = no sun, which is
## dark, not a default direction: an axis chosen here would decide where noon is.
func set_sun_dir(v: Vector3) -> void:
	_ctx["sun_dir"] = v



## Mark the CPU enthalpy mirror dirty so the next begin_frame re-uploads it.
func mark_h_dirty() -> void:
	_h_dirty = true


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
		_passes[i].dispatch(_rd, cl, _ctx, _cc, _groups)
		# EVERY PASS READS WHAT THE PREVIOUS ONE WROTE. Passes barrier internally between their own
		# sub-dispatches but nothing ordered them against EACH OTHER, so in one submit they overlapped and
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_end()
		_rd.capture_timestamp(_pass_names[i])
	_rd.submit()                        # deferred sync — drained at the next begin_frame (GPU overlaps CPU frame work)
	_pending = true
	_step_index += 1

## Signature: `probe.call(pass_index: int, pass_name: String)`, pass_index -1 = before any pass ran.
func set_step_probe(cb: Callable) -> void:
	_step_probe = cb


func _step_checkpointed() -> void:
	_step_probe.call(-1, "start")
	for i in _passes.size():
		var cl: int = _rd.compute_list_begin()
		_passes[i].dispatch(_rd, cl, _ctx, _cc, _groups)
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
	_step_index += 1


## Raw device readback of one buffer. Diagnostic only (the between-pass probe). No sync is done here — the
## checkpointed step already synced, and calling this off that path would read whatever the last sync left.
func read_raw(name: String) -> PackedFloat32Array:
	if _rd == null or not _bufs.has(name):
		return PackedFloat32Array()
	return _rd.buffer_get_data(_bufs[name]).to_float32_array()


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
			_probe[pname] = _rd.buffer_get_data(_bufs[pname]).to_float32_array()
		_probe_want = PackedStringArray()
	# Direct sub-timings (noise-immune, unlike fps): how long the GPU sync stall vs the channel copy/convert
	# actually cost this drain. The readback (buffer_get_data + to_float32_array over ~17 full-grid channels) is
	# the suspected field bottleneck; measuring it directly is how we know what gating it can win.
	LASimReport.gauge("field_sync_ms", float(t_sync - t0) / 1000.0)
	LASimReport.gauge("field_readback_ms", float(Time.get_ticks_usec() - t_sync) / 1000.0)
	_read_gpu_pass_timings()   # real GPU execution time for the step just sync()'d — see field vars above
	LASimReport.gauge("field_cells", float(_cc))
	_drain_passes()


## Each pass's own readings, taken here because the device was just synced. A pass owns its keys; two passes
## claiming one key is a collision, and the first one keeps it.
func _drain_passes() -> void:
	_pass_results = {}
	for i in _passes.size():
		var res: Dictionary = _passes[i]._drain(_rd)
		for key in res:
			var name: String = String(key)
			if _pass_results.has(name):
				push_error("%s publishes \"%s\", which another pass already published." % [_pass_names[i], name])
				continue
			_pass_results[name] = res[key]
			if typeof(res[key]) == TYPE_FLOAT or typeof(res[key]) == TYPE_INT:
				LASimReport.gauge(name, float(res[key]))


## The compacted cell indices a CellListPass row published, empty when it listed nothing. Non-clearing.
func list_indices(label: String) -> PackedInt32Array:
	var v: Variant = _pass_results.get(label + "_list_idx", null)
	return v if v is PackedInt32Array else PackedInt32Array()


## The merged pass readings of the last drained step, and clears them.
func take_pass_results() -> Dictionary:
	var out: Dictionary = _pass_results
	_pass_results = {}
	return out


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


## "TransportPass" -> "transport"; a short, gauge-key-safe name (strip "Pass", snake_case the rest).
func _gpu_gauge_key(pass_index: int) -> String:
	var n: String = _pass_names[pass_index]
	if n.ends_with("Pass"):
		n = n.substr(0, n.length() - 4)
	return n.to_snake_case()


func _read_channels(read_slow: bool) -> Dictionary:
	var out: Dictionary = _empty_result()
	for k in ["h_j_m3", "h2o", "o2"]:
		out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	# Derived: recomputed by StateDerivePass this step rather than carried.
	for k in LAChannels.derived_buffers():
		if _bufs.has(k):
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	# Emergent WIND velocity (SINGLE, in-place) — wind3_at/wind_at expose a real force field that EVERY creature
	# samples per frame (LACreatureFieldForces), so it stays always-hot. CHARGE (breakdown→bolt firing) also has
	# a per-frame consumer with NO CPU-side trigger event to hook a request_channel() call to, so it stays hot too.
	for k in ["vel_x", "vel_y", "vel_z", "charge"]:
		if _bufs.has(k):
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	for k in situational_channels():
		if not _bufs.has(k) or int(_channel_hold.get(k, -1)) < _drain_count:
			continue
		out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	# SLOW — ledger/baker channels on the coarse cadence, from the table that declares which those ARE.
	if read_slow:
		for k in slow_channels():
			if not _bufs.has(k):
				continue
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	return out

func request_channel(name: String) -> void:
	_channel_hold[name] = _drain_count + CHANNEL_HOLD_DRAINS


func request_probe(names: PackedStringArray) -> void:
	for name in names:
		if not _probe_want.has(name):
			_probe_want.append(name)


## The most recent read-only sample, taken at the drain into a dictionary no simulation consumer sees. Empty
## until the first drain after `request_probe`; a leg that is absent is ABSENT, never substituted.
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
	var live: PackedFloat32Array = _rd.buffer_get_data(_bufs[name]).to_float32_array()
	var lt: float = 0.0
	var mt: float = 0.0
	var n: int = mini(live.size(), arr.size())
	for i in n:
		lt += live[i]
		mt += arr[i]
	print("MIRROR_REWIND={\"channel\":\"%s\",\"live\":%.4f,\"mirror\":%.4f,\"delta\":%.4f}" % [name, lt, mt, mt - lt])


## SEEDING ONLY: hands the device a whole channel while the world is being built. The amount is declared to
## LAMaterialFieldSeal3D, which refuses it once the world is SEALED, and a whole-mirror upload past step 0 is
func seed_field(name: String, arr, seal) -> void:
	if _rd == null or not _bufs.has(name):
		return
	if _step_index > 0:
		push_error(("seed_field('%s') after %d steps: a whole-mirror upload past step 0 rewinds live GPU state " +
			"by an amount that depends on channel residency. Queue a sparse edit instead.") % [name, _step_index])
		return
	if seal != null and seal.has_method("note_creation"):
		var total: float = 0.0
		if arr is PackedFloat32Array:
			for v in arr:
				total += float(v)
		if not seal.note_creation("seed_" + name, total):
			return
	if _audit_mirror and arr is PackedFloat32Array:
		_audit_mirror_upload(name, arr)
	if name == "h_j_m3":
		_h_dirty = true         # keep the gated begin_frame upload in step with a whole-mirror seed
	_upload_f(_bufs[name], arr)


# --- SPARSE IN-PLACE EDITS (the only legal step-time write) -----------------------------------------------

## A delta this negative empties a cell exactly (the clamp floor is 0), so callers that want to DRAIN a cell
## without knowing what is in it pass this and read the returned total.
const DRAIN_ALL: float = -1.0e30

func add_field_sparse(name: String, cells: PackedInt32Array, deltas: PackedFloat32Array, ceiling: float = INF) -> float:
	if cells.size() != deltas.size():
		push_error("add_field_sparse('%s'): %d cells vs %d deltas — op dropped" % [name, cells.size(), deltas.size()])
		return 0.0
	if _rd == null or not _bufs.has(name) or cells.size() == 0:
		return 0.0
	var buf: RID = _bufs[name]
	var arr: PackedFloat32Array = _rd.buffer_get_data(buf).to_float32_array()
	if arr.size() < _cc:
		return 0.0
	var applied: float = 0.0
	# Bound on the BUFFER, not on _cc, so a channel wider than one plane is editable at all.
	var n: int = arr.size()
	var lo: int = n
	var hi: int = -1
	for i in cells.size():
		var c: int = cells[i]
		if c < 0 or c >= n:
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
	var sbuf: RID = _bufs[src]
	var dbuf: RID = _bufs[dst]
	# A src==dst move (displacing water from a burying cell into its neighbour) must edit ONE array, or the
	# second write-back would clobber the first. PackedFloat32Array is copy-on-write, so aliasing the handle is
	# not enough — the branch below keeps a single array and a single touched span in that case.
	var same: bool = sbuf == dbuf
	var sarr: PackedFloat32Array = _rd.buffer_get_data(sbuf).to_float32_array()
	var darr: PackedFloat32Array = PackedFloat32Array() if same else _rd.buffer_get_data(dbuf).to_float32_array()
	if sarr.size() < _cc or (not same and darr.size() < _cc):
		return 0.0
	# A channel value is a fill fraction, so moving the same number between two cells of different volume
	# moves a different amount of matter than it delivers. See kernels3d/cellvol.glsli.
	var vol: PackedFloat32Array = _grid.cell_volumes() if _grid != null else PackedFloat32Array()
	if vol.size() != _cc:
		push_error("move_field_sparse: no per-cell volume table")
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
		var ratio: float = 1.0
		if live_dst:
			ratio = vol[sc] / maxf(vol[dc], 1e-30)
			# Honour the destination's own ceiling by taking only what it can hold (never spill mass).
			var held: float = sarr[dc] if same else darr[dc]
			take = minf(take, maxf(0.0, dst_ceiling - held) / maxf(ratio, 1e-30))
		if take <= 0.0:
			continue
		sarr[sc] -= take
		slo = mini(slo, sc)
		shi = maxi(shi, sc)
		if live_dst:
			if same:
				sarr[dc] += take * ratio
				slo = mini(slo, dc)
				shi = maxi(shi, dc)
			else:
				darr[dc] += take * ratio
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


## Sum of a channel's device buffer. Diagnostic only (the injection queue's staleness audit compares it
## against the CPU mirror to measure what a mirror-upload would have written away); nothing on the per-frame
## path calls it, because it is a full-grid readback plus a full-grid sum.
func channel_total(name: String) -> float:
	if _rd == null or not _bufs.has(name):
		return 0.0
	var arr: PackedFloat32Array = _rd.buffer_get_data(_bufs[name]).to_float32_array()
	var sum: float = 0.0
	for i in mini(arr.size(), _cc):
		sum += arr[i]
	return sum


func snapshot_channels() -> Dictionary:
	var out: Dictionary = {}
	if _rd == null:
		return out
	_flush_pending()        # a step submit may be in flight (async pipeline) — sync before reading the buffers
	for name in channels():
		out[name] = _rd.buffer_get_data(_bufs[name]).to_float32_array()
	return out


## LOAD: upload a snapshot_channels() dict back into the GPU buffers.
func restore_channels(data: Dictionary) -> void:
	if _rd == null:
		return
	_flush_pending()        # a step submit may be in flight — sync before overwriting the buffers
	for name in data.keys():
		var key: String = String(name)
		if not _bufs.has(key):
			continue
		var arr: PackedFloat32Array = data[key]
		if arr.size() != _cc:
			continue
		var bytes: PackedByteArray = arr.to_byte_array()
		_rd.buffer_update(_bufs[key], 0, bytes.size(), bytes)

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
		var b: RID = _bufs[k]
		if b.is_valid():
			_rd.free_rid(b)
	_bufs = {}
	_rd.free()
	_rd = null


# --- helpers ------------------------------------------------------------------

func _new_f(n: int) -> RID:
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

## Seed a channel from its CPU mirror.
func _seed(name: String, arr: PackedFloat32Array) -> void:
	if not _bufs.has(name) or arr.size() != _cc:
		return
	var bytes: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(_bufs[name], 0, bytes.size(), bytes)

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


## Seeded rock is bedrock, so it is both present and fully consolidated.
func _seed_silicate() -> void:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc)
	for i in _cc:
		f[i] = 1.0 if _field._solid[i] != 0 else 0.0
	var b: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["silicate"], 0, b.size(), b)
	_rd.buffer_update(_bufs["cement"], 0, b.size(), b)

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
		"h_j_m3": PackedFloat32Array(), "temp": PackedFloat32Array(), "h2o": PackedFloat32Array(),
		"h2o_solid": PackedFloat32Array(), "h2o_liquid": PackedFloat32Array(),
		"h2o_vapour": PackedFloat32Array(), "silicate": PackedFloat32Array(),
		"fire": PackedFloat32Array(), "fuel": PackedFloat32Array(),
		"o2": PackedFloat32Array(),
		"co2": PackedFloat32Array(), "charge": PackedFloat32Array(),
		"fert": PackedFloat32Array(),
		"detritus": PackedFloat32Array(), "shock": PackedFloat32Array(),
		"biomass": PackedFloat32Array(), "cement": PackedFloat32Array(),
		"silicate_melt": PackedFloat32Array(),
		"silicate_susp_water": PackedFloat32Array(), "silicate_susp_air": PackedFloat32Array(),
	}
