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

func set_sea_radius(r: float) -> void:
	_ctx["sea_radius"] = r

func step() -> void:
	if _rd == null:
		return
	# The `send` outflow scratch needs no external clear: the 2-pass finite-volume kernels (WaterSlumpLava)
	# self-zero all 6 of each cell's send slots at the top of pass 0, before any read. Clearing here (or inside
	# the pass) is both redundant and — inside an open compute list — illegal, so it is omitted.
	for p in _passes:
		var cl: int = _rd.compute_list_begin()
		p.dispatch(_rd, cl, _phase, _ctx, _cc, _groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
	_phase = 1 - _phase

func end_frame(_rv: bool = true, _rc: bool = true, _rf: bool = true, _rr: bool = true, _rl: bool = true, _rs: bool = true) -> Dictionary:
	var out: Dictionary = _empty_result()
	if _rd == null:
		return out
	# `sediment` joins the readback so the mineral conservation ledger (mineral_total) sees the loose-regolith
	# phase — without it, dust→sediment deposits/settles stayed GPU-only and the ledger under-counted.
	# `fert` (PAIR): the decomposer's soil-fertility output, read back so fertility_at/fertility_peak see the
	# live GPU channel (was never read → hardcoded 0). Its live half after the step carries the accumulated deposit.
	# `susp` (waterborne suspended sediment) joins the readback so the mineral conservation ledger (mineral_total)
	# counts the phase erosion pickup lifts into the water — without it the scoured mass would look VANISHED (the
	# rock_fill dropped but susp was GPU-only), a false conservation break. Its live half after the flip is the
	# post-pickup+settle susp.
	for k in ["temp", "water", "moisture", "lava", "fire", "o2", "co2", "dust", "shock", "sediment", "soil", "fert", "susp"]:
		out[k] = _rd.buffer_get_data(_live(k)).to_float32_array()
	# scent is a 5-plane packed pair (SCENT_PLANES * cell_count) — read its live half whole so the CPU bridge
	# scatters all five planes (prey/predator/blood/food/alarm) back for the sense gradients.
	out["scent"] = _rd.buffer_get_data(_live("scent")).to_float32_array()
	# biomass + snow are SINGLE (non-ping-pong) GPU-resident channels — read their one buffer directly, not _live().
	if _bufs.has("biomass"):
		out["biomass"] = _rd.buffer_get_data(_bufs["biomass"]).to_float32_array()
	if _bufs.has("snow"):
		out["snow"] = _rd.buffer_get_data(_bufs["snow"]).to_float32_array()
	# fuel is a SINGLE GPU channel: the fire kernel consumes it in place each step. Read it back so fuel_total
	# reflects the burn (drops where fire is active) and the seed module can maxf-refill it from biomass.
	if _bufs.has("fuel"):
		out["fuel"] = _rd.buffer_get_data(_bufs["fuel"]).to_float32_array()
	# rock_fill is a SINGLE GPU-owned channel (the fractional bedrock mass); read it back so the CPU mineral
	# ledger (mineral_total) counts the authoritative bedrock phase and add_lava sees the current rock mass.
	if _bufs.has("rock_fill"):
		out["rock_fill"] = _rd.buffer_get_data(_bufs["rock_fill"]).to_float32_array()
	# Emergent WIND velocity (SINGLE, in-place channels) — read back so wind3_at/wind_at expose a real force
	# field (was ZERO). CHARGE (SINGLE, in-place) too, so the breakdown→bolt firing sees the accumulated charge.
	for k in ["vel_x", "vel_y", "vel_z", "charge"]:
		if _bufs.has(k):
			out[k] = _rd.buffer_get_data(_bufs[k]).to_float32_array()
	return out

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
