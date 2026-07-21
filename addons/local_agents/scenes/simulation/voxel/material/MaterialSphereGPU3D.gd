class_name LAMaterialSphereGPU3D
extends RefCounted

## Cubed-sphere GPU field driver (Phase B). Drop-in for LAMaterialGPU3D when the field is a planet: same
## 8-method contract (setup/begin_frame/step/end_frame/set_field/set_precip/set_prevailing/set_raining). It
## allocates ALL field channels (ping-pong pairs) + the shared single buffers + the SphereGrid neighbour /
## radial / position SSBOs, exposes them as a `bufs` dict, and runs a list of per-domain PASS MODULES
## (sphere_passes/*.gd) that each wire their kernels via that dict. Passes are authored independently; the
## driver owns buffer allocation, parity, ctx, dispatch ordering, and readback.
##
## PING-PONG PHASE (NOT CPU parity — there is no CPU oracle). `_phase` ∈ {0,1} selects which half of each
## double-buffered PAIR channel is the read/"live" half (`bufs[k][_phase]`) vs the write/"back" half
## (`bufs[k][1-_phase]`) within a step. One flip per step. Passes are dispatched in DATA-FLOW ORDER so a
## channel written to "back" by an earlier pass is read from "back" by a later one (per-pass submit+sync makes
## each pass see prior passes' GPU writes). Order below encodes the hard dependencies:
##   WaterSlumpLava (water/lava/sediment→back; carry-heat into live temp) → Thermal (reads water/lava/temp,
##   writes final temp/lava→back) → GasWind (o2/co2→back, velocities) → Atmosphere (reads temp/water back +
##   velocities; moisture→back, rain into water back) → Reactions (generic DEFS reaction engine: reads settled
##   temp/water/o2/co2/moisture back + fungus live; folds gas sky-exchange/vent + fungus decompose as records)
##   → FireDust (reads temp/water back) → EcoSurface.
## Remaining cross-pass clashes (o2/co2/fire/fungus in-place-on-live reads, snow meltwater into live water) are
## one-step coupling-fidelity lags, NOT crashes — acceptable under perf-over-parity; tighten later if needed.

# Ping-pong (double-buffered) channels — one _a/_b pair each.
const PAIR_CHANNELS: PackedStringArray = [
	"temp", "water", "moisture", "lava", "sediment", "fire", "dust",
	"o2", "co2", "shock", "fungus", "susp", "fert", "soil"]
# scent is a 5-plane packed pair (5*cell_count); handled specially.
# Single (non-ping-pong) float buffers. `rock_fill` is the fractional bedrock-mineral channel (rock unification
# Stage B): `solid` is DERIVED from it each step (solid iff rock_fill >= 0.5, see SolidDerivePass). It is GPU-owned
# and GPU-evolved (M5 solidify / M6 melt records write it), re-uploaded from the CPU only on an add_lava injection.
const SINGLE_CHANNELS: PackedStringArray = [
	"solid", "static", "fuel", "charge", "detritus", "biomass", "pressure",
	"vel_x", "vel_y", "vel_z", "dust_outscale", "fungus_fert", "surf_vx", "surf_vz", "snow", "rock_fill",
	"regolith"]     # aquifer permeability mask (1 = groundwater-bearing rock) — static; seeded once

# Data-flow dispatch order (see the PING-PONG PHASE note above). WaterSlumpLava MUST precede Thermal
# (Thermal reads water/lava from "back" + consumes the lava carry-heat left in "live" temp); Atmosphere/
# FireDust MUST follow Thermal (they read the finished temp/water from "back").
const PASS_SCRIPTS: PackedStringArray = [
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/SolidDerivePass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/WaterSlumpLavaPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/ThermalPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/GasWindPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/AtmospherePass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/SoilPass.gd",
	# EROSION PICKUP (Stage D): scours rock_fill→susp where water flows, and CARRIES susp live→back — MUST run
	# right before Reactions so M3 SETTLE (susp→sediment) reads the freshly-scoured susp the same step.
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/ErosionPickupPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/ReactionsPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/FireDustPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/EcoSurfacePass.gd"]

const SCENT_PLANES: int = 5

static func available() -> bool:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

var _rd: RenderingDevice = null
var _field = null
var _grid: RefCounted = null
var _cc: int = 0
var _phase: int = 0                 # ping-pong phase ∈ {0,1}; flips once per step (NOT CPU parity)
var _groups: int = 0
var _bufs: Dictionary = {}          # key → RID (single) or [rid_a, rid_b] (pair)
var _passes: Array = []
var _ctx: Dictionary = {}
# Async readback pipeline (perf B2): step() submits its ONE compute list WITHOUT syncing; the sync + channel
# readback is deferred to the NEXT begin_frame's _drain_pending(), so the GPU compute overlaps the inter-frame
# CPU work (render/actor cognition) instead of stalling the field step. end_frame() then hands back `_cached`
# (the previous step's channels) — a one-frame coupling lag, already an accepted "coupling-fidelity" lag (see
# header ~:22). A local RenderingDevice allows exactly ONE submit() per sync(), which this respects.
var _pending: bool = false          # a step() submit is in flight, not yet synced/read
var _cached: Dictionary = {}        # channels read back from the last drained step (what end_frame returns)
var _slow_gate: int = 0             # cadence counter for the slow (ledger/baker) channel readback set

# DEMAND-DRIVEN readback for the situational disaster channels (lava/fire/dust/shock/charge/rock_fill). These
# are consumed ONLY by disaster actors (while one is alive) + debug overlays (while shown) + save — not by any
# per-frame path — so on a calm planet copying them back every step is pure waste. A channel is read back only
# while it has been REQUESTED (injected into, or queried) within the last CHANNEL_HOLD_DRAINS drains; the field
# facade requests on inject/query. A skipped channel keeps its prior CPU array (the scatter is size-guarded),
# so a stale read is at most a one-frame lag on first access — the same coupling lag the pipeline already has.
# Gated set = the disaster channels with NO per-frame CPU consumer (verified: their only CPU-array reads are
# injection, save/snapshot, and the _at queries — rendering reads the GPU buffers directly). charge (scanned by
# MaterialCharge on breakdown) and rock_fill (scanned by MineralStamp during volcano land-building) are kept
# always-hot because those modules read them per active-frame; gating them would need those modules to request.
const SITUATIONAL_CHANNELS: Array = ["lava", "fire", "dust", "shock"]
const CHANNEL_HOLD_DRAINS: int = 20     # stay hot ~20 drains past the last request so intermittent queries don't thrash
var _channel_hold: Dictionary = {}      # channel name -> drain index it stays hot through
var _drain_count: int = 0               # monotonic drain counter the holds are measured against

# Slow channels are read back only every Nth drain (their CPU consumers are coarse-cadence ledgers/bakers, not
# every-frame world queries) — a direct cut of ~6 of 21 blocking readbacks on the other frames. Between reads the
# CPU array keeps its prior value (the _apply_readback scatter is res.has()-guarded), which the consumers tolerate.
const SLOW_READBACK_EVERY: int = 4
# LEDGER/BAKER channels: mineral-conservation ledger (sediment/susp), decomposer fertility (fert), water-table
# reservoir (soil), eco biomass metric + coarse fuel-refill source (biomass) — all coarse-cadence consumers, so a
# stale read never matters. `fuel`/`charge`/`rock_fill` are deliberately NOT here: fuel/charge consumers edit +
# re-upload the channel, and ROCK_FILL is scanned EVERY frame by MineralStamp3D to stamp the terrain SDF (the
# volcano land-building) + rewrite _solid — a stale/coarse rock_fill made eruptions grow FLOATING CUBES. Stay hot.
const SLOW_CHANNELS: PackedStringArray = ["sediment", "susp", "fert", "soil", "biomass"]


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
	# Sphere geometry SSBOs: neighbour table (int32, kernel slot order), radial + position (flat float3).
	var nbr_bytes: PackedByteArray = _grid.neighbours_kernel_order().to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_bufs["radial"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_radial(c))
	_bufs["pos"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_world_pos(c))

	# Seed channels from the field's CPU state.
	_seed("temp", field._temp)
	_seed("o2", field._o2)
	_seed("soil", field._soil)          # initial water table (regolith primed by _compute_regolith)
	_seed_solid()
	_seed_rock_fill()
	_seed_regolith()                    # aquifer permeability mask (static)

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


func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6, wind: Vector2 = Vector2.ZERO) -> void:
	if _rd == null:
		return
	# Drain the previous frame's in-flight step FIRST: sync it (usually already done — the GPU ran it during the
	# inter-frame CPU work) and read its channels into `_cached`. Must happen before the temp/water uploads below,
	# which write the same live buffers the step wrote. This is the CPU↔GPU overlap that hides the field step cost.
	_drain_pending()
	_upload_f(_live("temp"), temp)
	_upload_f(_live("water"), water)
	_seed_solid()
	_ctx["solar"] = solar
	_ctx["wind"] = wind
	_ctx["dt"] = 0.1
	_ctx["cell_size"] = _grid.cell_size
	_ctx["core_radius"] = _grid.core_radius     # groundwater aquifer needs the shell geometry for cell elevation
	_ctx["depth"] = _grid.depth
	_ctx["sea_radius"] = _field.sphere_grid().core_radius   # placeholder; overridden by set_sea_radius
	if not _ctx.has("sun_dir"):
		_ctx["sun_dir"] = Vector3(0, 1, 0)

func set_sun_dir(v: Vector3) -> void:
	_ctx["sun_dir"] = v if v.length() > 0.001 else Vector3(0, 1, 0)

## Global atmospheric humidity signal (cloud cover 0..1), fed to atmos_evap so the infinite static sea stops
## pumping once the air holds its target moisture — the GLOBAL bound on the water cycle (a local per-cell brake
## can't cap a total that transport keeps redistributing). Slowly-varying; last cached value is fine.
func set_atmos_humidity(h: float) -> void:
	_ctx["atmos_humidity"] = clampf(h, 0.0, 1.0)

func set_sea_radius(r: float) -> void:
	_ctx["sea_radius"] = r

func step() -> void:
	if _rd == null:
		return
	# A local RenderingDevice permits exactly ONE submit() per sync(). The rare 2-steps-per-frame catch-up calls
	# step() twice: sync the earlier submit before opening a new list (this also makes its writes visible to this
	# step, replacing the old per-step sync for that boundary).
	if _pending:
		_rd.sync()
		_pending = false
	# B1 — ALL passes into ONE compute list, then a SINGLE submit()+deferred-sync (was: compute_list_begin →
	# dispatch → end → submit → sync PER pass = 10 blocking CPU↔GPU round-trips/step, up to 20/frame). The kernel
	# math is cheap; those round-trips were the cost. Godot 4.7 does NOT auto-insert memory barriers between
	# dispatches in a list (every multi-dispatch pass already barriers internally), so we insert a GPU-side
	# `compute_list_add_barrier` between passes: the passes are authored in strict data-flow order and each reads
	# channels a prior pass wrote to "back", so pass N+1 must see pass N's writes. This barrier is what the
	# single-dispatch passes (SolidDerive / ErosionPickup / Reactions) previously got from the per-pass sync. A
	# barrier is a GPU pipeline barrier, NOT a CPU stall — correctness > a marginal extra barrier (perf-over-parity:
	# verified behaviourally, not bit-exact).
	# The `send` outflow scratch needs no external clear: the 2-pass finite-volume kernels (WaterSlumpLava)
	# self-zero all 6 of each cell's send slots at the top of pass 0, before any read. Clearing here (or inside
	# the pass) is both redundant and — inside an open compute list — illegal, so it is omitted.
	var cl: int = _rd.compute_list_begin()
	var last: int = _passes.size() - 1
	for i in _passes.size():
		_passes[i].dispatch(_rd, cl, _phase, _ctx, _cc, _groups)
		if i < last:
			_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	_rd.submit()                        # deferred sync — drained at the next begin_frame (GPU overlaps CPU frame work)
	_pending = true
	_phase = 1 - _phase

## Hand back the channels read from the LAST drained step (populated in begin_frame → _drain_pending). This is a
## one-frame-lagged snapshot — the accepted coupling-fidelity latency (header ~:22). The actual readback + sync
## now happen in _drain_pending, overlapped with the inter-frame CPU work, not synchronously here. The legacy
## `_r*` params are ignored (per-channel cadence is decided in _read_channels).
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


## Sync the in-flight step and read its channels into `_cached`. Called at the top of begin_frame so the GPU had
## the whole inter-frame gap to finish — the sync is usually already satisfied (that is the overlap win). HOT
## channels (actor world-queries / senses / render every frame) are read every drain; SLOW ledger/baker channels
## only every SLOW_READBACK_EVERY drains (a direct readback cut on the other frames).
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
	# Direct sub-timings (noise-immune, unlike fps): how long the GPU sync stall vs the channel copy/convert
	# actually cost this drain. The readback (buffer_get_data + to_float32_array over ~17 full-grid channels) is
	# the suspected field bottleneck; measuring it directly is how we know what gating it can win.
	LASimReport.gauge("field_sync_ms", float(t_sync - t0) / 1000.0)
	LASimReport.gauge("field_readback_ms", float(Time.get_ticks_usec() - t_sync) / 1000.0)


## Read the GPU channels the CPU consumes back into a result dict. Split HOT (every drain) vs SLOW (coarse cadence).
## `sediment`/`susp` feed the mineral-conservation ledger (loose-regolith + waterborne phases — without them the
## ledger under-counts / sees a false conservation break); `fert` is the decomposer's soil-fertility output;
## `soil` the water-table reservoir; `rock_fill` the authoritative fractional bedrock mass; `biomass` the eco
## metric + coarse fuel-refill source — all coarse-cadence consumers, so they ride the slow set.
func _read_channels(read_slow: bool) -> Dictionary:
	var out: Dictionary = _empty_result()
	# ALWAYS-HOT — read EVERY drain (per-frame consumers: actor world-queries, senses, render, surface-seed).
	# Ping-pong PAIR channels read from their live half; single channels read direct. lava/fire/dust/shock moved
	# to the DEMAND-GATED block below (they have no per-frame consumer on a calm planet).
	for k in ["temp", "water", "moisture", "o2", "co2"]:
		out[k] = _rd.buffer_get_data(_live(k)).to_float32_array()
	# scent is a 5-plane packed pair (SCENT_PLANES * cell_count) — read its live half whole so the CPU bridge
	# scatters all five planes (prey/predator/blood/food/alarm) back for the sense gradients.
	out["scent"] = _rd.buffer_get_data(_live("scent")).to_float32_array()
	# snow (SINGLE) — surface snow render/meltwater. fuel (SINGLE) — fire consumes it in place; kept HOT so the
	# surface-seed refill compares against fresh fuel (avoids over-refill) and fire dynamics don't lag.
	if _bufs.has("snow"):
		out["snow"] = _rd.buffer_get_data(_bufs["snow"]).to_float32_array()
	if _bufs.has("fuel"):
		out["fuel"] = _rd.buffer_get_data(_bufs["fuel"]).to_float32_array()
	# Emergent WIND velocity (SINGLE, in-place) — wind3_at/wind_at expose a real force field that EVERY creature
	# samples per frame (LACreatureFieldForces), so it stays always-hot. CHARGE (breakdown→bolt firing edits +
	# re-uploads it) and ROCK_FILL (MineralStamp scans it every active frame to stamp SDF grow/carve) also have
	# per-frame-ish module consumers, so they stay hot too.
	for k in ["vel_x", "vel_y", "vel_z", "charge", "rock_fill"]:
		if _bufs.has(k):
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	# DEMAND-GATED situational channels — read back ONLY while requested (a disaster is injecting/querying them,
	# or a debug overlay is showing them). On a calm planet nothing requests them, so this is the readback cut.
	# A skipped channel keeps its prior CPU array; the size-guarded scatter makes a stale read a 1-frame lag.
	# lava/fire/dust/shock are ping-pong PAIRS (read the live half); charge/rock_fill are SINGLE buffers.
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

## Mark a demand-gated situational channel as NEEDED — its readback resumes now and stays hot for
## CHANNEL_HOLD_DRAINS more drains. The field facade calls this whenever the channel is injected into or queried
## (a live disaster, a debug overlay), so a channel with no active consumer simply stops being copied back.
## No-op for channels that are always read anyway.
func request_channel(name: String) -> void:
	_channel_hold[name] = _drain_count + CHANNEL_HOLD_DRAINS


func set_field(name: String, arr) -> void:
	if _rd == null or not _bufs.has(name):
		return
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


## SAVE snapshot: read back EVERY GPU-resident channel (pair channels from their live half, single channels
## direct) into a { name -> PackedFloat32Array } dict. This is the authoritative field state a save persists;
## restore_channels() uploads it back verbatim. Geometry SSBOs (nbr/radial/pos) are rebuilt from the grid on
## load and are deliberately NOT snapshotted. Returns an empty dict with no device (headless/no-GPU).
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
## so the state is consistent regardless of the current ping-pong phase; single channels write their one buffer.
## Sizes are validated per channel (a channel of the wrong length — e.g. a save from a different grid resolution
## — is skipped rather than corrupting the device). Unknown keys are ignored (forward/backward tolerant).
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

func set_prevailing(v: Vector2) -> void:
	_ctx["wind"] = v

func set_raining(v: bool) -> void:
	_ctx["raining"] = 1 if v else 0


## Free every RID this driver owns, THEN the local RenderingDevice — run while the tree is still up (via
## MaterialField3D._exit_tree), never deferred to engine shutdown. Each pass releases its own uniform sets /
## pipelines / shaders / owned scratch first (borrowed `bufs` entries are freed HERE, not by the pass), so the
## device frees with 0 leaked RIDs. NOTE: this clean teardown does NOT prevent the separate `rc=134`
## SIGABRT that MoltenVK throws in the `NSApplication terminate:` → `recursive_mutex` observer at process exit
## — that fires after dispose() returns, with no GDScript frames. That crash is now avoided at the QUIT
## path (not here): `LAAppExit` hard-exits via `LAProcess.exit_now` before AppKit terminate runs (see
## GODOT_BEST_PRACTICES.md → Error Log, 2026-07-09). This dispose() stays the correct RID hygiene.
func dispose() -> void:
	if _rd == null:
		return
	_flush_pending()        # ensure the GPU is idle (no in-flight step submit) before freeing any RID
	for p in _passes:
		if p != null and p.has_method("dispose"):
			p.dispose(_rd)
	_passes = []
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
	for i in _cc:
		f[i] = 1.0 if _field._static[i] != 0 else 0.0
	var b2: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["static"], 0, b2.size(), b2)

## Seed the fractional bedrock channel `rock_fill` from the CPU solid mask: a solid cell holds a full cell of
## mineral (1.0), a void cell none (0.0). Only run at setup — rock_fill is GPU-authoritative thereafter (the
## derive pass recomputes `solid` from it, and M5/M6 records + add_lava evolve it). Because 1.0 >= 0.5 and
## 0.0 < 0.5, the derived `solid` reproduces `_solid` EXACTLY when nothing has melted/solidified (stability).
## Seed the aquifer permeability mask (1.0 = permeable regolith, 0.0 = bedrock/void) from the field's CPU mask.
## Static after setup (recomputed only if the terrain is carved deeply — a future concern), so seeded once here.
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
