class_name LAMaterialSphereGPU3D
extends RefCounted

## Cubed-sphere GPU field driver (Phase B). Drop-in for LAMaterialGPU3D when the field is a planet: same
## 7-method contract (setup/begin_frame/step/end_frame/set_field/set_precip/set_prevailing). It
## allocates ALL field channels (ping-pong pairs) + the shared single buffers + the SphereGrid neighbour /
## radial / position SSBOs, exposes them as a `bufs` dict, and runs a list of per-domain PASS MODULES
## (sphere_passes/*.gd) that each wire their kernels via that dict. Passes are authored independently; the
## driver owns buffer allocation, parity, ctx, dispatch ordering, and readback.
##
## PING-PONG PHASE (NOT CPU parity, since there is no CPU oracle). `_phase` ∈ {0,1} selects which half of each
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
## one-step coupling-fidelity lags, NOT crashes, and acceptable under perf-over-parity; tighten later if needed.
##
## THERE IS NO CAMERA-RELEVANCE LOD IN THIS FIELD, AND THERE MUST NOT BE ONE (deleted 2026-08-03). A per-cell
## `activity` channel (ActivityPass + activity_sphere3d.glsl) used to score every cell 0..1 from a local wake
## bubble AND its distance to the camera, and seven kernels turned that score into a per-thread update stride
## and early-outed on it. Two reasons it is gone, in order of weight:
##   1. IT MADE THE PLANET'S PHYSICS DEPEND ON WHERE THE PLAYER WAS LOOKING. Erosion, groundwater, combustion,
##      dust and charge all ran slower in cells nobody was near. Nothing in the world works that way. Measured
##      cost: 4.5 C of global mean temperature (38.65/39.11/39.20 gated vs 34.73/34.17 ungated) and -2.7% of
##      sediment_total, on matched runs with an identical disaster load.
##   2. IT WAS ALSO SLOWER. Skipping 61% of all per-cell work (active_cells 26,966 of 69,120) LOST time:
##      field_ms 5.210 gated vs 4.938 ungated, field_dispatch_ms 0.188 vs 0.184. Every kernel still dispatched
##      the full grid, so the stride bought only ALU inside threads that had already been scheduled and had
##      already read their inputs — while ActivityPass itself paid a whole extra full-grid dispatch to decide
##      what to skip. Dispatch is ~4% of field cost here; the readback is ~75% (field_readback_ms 4.020 of
##      5.210). Gating compute was optimising the wrong term.
## A SKIPPED STEP IS NOT RECOVERABLE, WHICH IS THE POINT. The gate was documented as "behaviourally exact"
## because a skipped cell writes what an inert cell would. Measured otherwise: the `LA_NO_ACTIVITY_LOD=1`
## bypass left exactly ONE step gated (the `activity` buffer allocates zero, so on step 0 every pass reading
## activity[LIVE] saw relevance 0 -> stride 16), and that single step out of 798 permanently moved the
## groundwater budget — `soil_total` 373.8 with it vs 442.8 without, +18%, and `sediment_total` 1005.2 vs
## 957.3. Seeding the relevance buffer to 1.0 reproduced the ungated numbers on the old code exactly, which is
## how this was isolated. The aquifer is nowhere near equilibrium at 80 sim-seconds, so perturbing its filling
## trajectory once changes where the water sits for the rest of the run. Do not describe a stride gate over an
## integrating process as free.
## The good asymptotic form survives, in LavaCellListPass: a real O(active) compaction feeding an INDIRECT
## dispatch, now selecting cells by the PHYSICAL predicate "holds molten rock in open space" rather than by
## camera distance. If another kernel needs to scale with its phenomenon instead of the planet, copy THAT —
## compact on what the matter is doing, never on where the viewer is.

# Ping-pong (double-buffered) channels — one _a/_b pair each.
# `air` is the atmosphere's conserved mass (GasWindPass / wind_pressure_sphere3d): pressure is its weight, so
# the vertical structure, the lapse and the thermal wind all come off this one quantity. Ping-ponged because
# the column kernel reads its four neighbour COLUMNS' air while writing its own.
const PAIR_CHANNELS: PackedStringArray = [
	"temp", "water", "moisture", "lava", "sediment", "fire", "dust",
	"o2", "co2", "shock", "fungus", "susp", "fert", "soil", "air"]
# ^ Every entry is a physical quantity. There is no bookkeeping channel here, and there must not be one — the
#   `activity` relevance channel that used to sit in this list is gone (see the header note).
# scent is a 5-plane packed pair (5*cell_count); handled specially.
# Single (non-ping-pong) float buffers. `rock_fill` is the fractional bedrock-mineral channel (rock unification
# Stage B): `solid` is DERIVED from it each step (solid iff rock_fill >= 0.5, see SolidDerivePass). It is GPU-owned
# and GPU-evolved (M5 solidify / M6 melt records write it), re-uploaded from the CPU only on an add_lava injection.
const SINGLE_CHANNELS: PackedStringArray = [
	"solid", "static", "fuel", "charge", "detritus", "biomass", "pressure",
	"vel_x", "vel_y", "vel_z", "fungus_fert", "surf_vx", "surf_vz", "snow", "rock_fill",
	# THE TWO NON-SILICATE MINERAL SPECIES (2026-08-08). `carbonate` (CaCO3) is where silicate weathering puts
	# the CO2 it consumes — the only carbon sink this planet has — and `silica` (SiO2) is the residue the same
	# reaction has to put its silicon in. SINGLE rather than PAIR because nothing advects them: ReactionsPass
	# is their only reader and only writer (D1b credits, D1c decarbonation debits), so there is no producer
	# pass to ping-pong against. Both start at zero, which is correct: an unweathered planet has neither.
	"carbonate", "silica",
	# ATHY POROSITY, the pore fraction of a regolith cell (0 outside regolith). Written every step by
	# soil_sphere3d.glsl, which is the one place that already computes it, so the formula is not copied.
	# WHY IT IS A CHANNEL AND NOT A LOCAL: `rock_fill` is a SATURATION of a cell's rock matrix, not a volume
	# fraction of mineral, and four consumers were reading it as the latter — the heat capacity, the
	# overburden walk, the mineral mole book and the erosion supply cap. A full surface regolith cell is
	# ~64% mineral and ~36% pore, so reading its 1.0 as a mineral volume fraction, then adding the `soil`
	# standing in those pores, made the cell claim 1.362 cell-volumes of matter. The conversion needs phi,
	# and phi is a static function of burial depth that several passes need, so it is precomputed once per
	# step rather than re-walked per consumer.
	"porosity",
	"regolith",     # aquifer permeability mask (1 = groundwater-bearing rock) — static; seeded once
	"grain"]        # representative grain diameter in METRES per regolith cell — static; seeded once. The
	                # aquifer kernel turns it into hydraulic conductivity through Kozeny-Carman, so K varies
	                # over four orders of magnitude across the planet instead of being one number.

# Data-flow dispatch order (see the PING-PONG PHASE note above). WaterSlumpLava MUST precede Thermal
# (Thermal reads water/lava from "back" + consumes the lava carry-heat left in "live" temp); Atmosphere/
# FireDust MUST follow Thermal (they read the finished temp/water from "back").
const PASS_SCRIPTS: PackedStringArray = [
	# PLATE TRANSPORT runs FIRST, ahead of the solidity derive. It carries rock_fill and sediment with the
	# velocity of the plate each cell sits on, so `solid` — which SolidDerivePass recomputes from rock_fill at
	# the top of every step — is derived from where the crust NOW is. Everything downstream (water, heat,
	# reactions, the mineral stamp) then sees a planet whose continents have moved. Nothing runs before it, so
	# the shared `send` scratch is free.
	"res://addons/local_agents/sim/material/sphere_passes/PlateAdvectPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/SolidDerivePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/WaterSlumpLavaPass.gd",
	# ACTIVE-CELL COMPACTION — builds the compacted cell list + dispatch-indirect args that ThermalPass's
	# lava_phase leg consumes, from the PHYSICAL predicate "this cell holds molten rock in open space". MUST sit
	# after WaterSlumpLava (which finalises lava[back]) and before Thermal (which consumes the list); nothing in
	# between writes lava or solid, so the list cannot go stale.
	"res://addons/local_agents/sim/material/sphere_passes/LavaCellListPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ThermalPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/GasWindPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/AtmospherePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/SoilPass.gd",
	# EROSION, in three ordered steps that share one ping-pong half. TRANSPORT advects last step's suspended
	# load (susp[live] → susp[back], a two-pass gather on the water's own flux); PICKUP then adds this step's
	# fresh scour to susp[back] in place; Reactions' M3 SETTLE then reads that one consistent half. Transport
	# must precede pickup — it is the pass that writes the back half whole, and a grain has to be in the water
	# before the water can carry it. Both must precede Reactions. Transport also borrows the shared `send`
	# scratch, so nothing between SoilPass and it may leave state there.
	"res://addons/local_agents/sim/material/sphere_passes/ErosionTransportPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ErosionPickupPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/FireDustPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/EcoSurfacePass.gd"]

const SCENT_PLANES: int = 5
# PER-LEG SOIL BUDGET PROBE. soil_sphere3d.glsl writes DBG_SLOTS floats per cell (its own, no atomics) naming
# every leg that moves groundwater: sent vs received for each of Darcy / spring / up-seep / infiltration, plus
# the clamp gain and the two branches that silently drop what they gather. Always written (a handful of stores
# next to six neighbour gathers) but read back only on demand — LAMaterialFieldSoilBudget3D under LA_SOIL_BUDGET.
# MUST match DBG_SLOTS in soil_sphere3d.glsl.
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
# GPU-SIDE EXECUTION TIMING (distinct from field_dispatch_ms, which only ever measured CPU command-recording
# time — step() just records + submit()s, deferred; the GPU may still be chewing on last step's work). Uses
# RenderingDevice's timestamp-query API (capture_timestamp / get_captured_timestamp_*), which is a lightweight
# command inserted INTO the already-open compute list — no extra CPU<->GPU round-trip, since the values only
# become readable after the SAME single sync() _drain_pending already performs. Godot returns GPU time in
# nanoseconds (confirmed empirically, see below).
#
# KNOWN ENGINE GAP (verified 2026-07-23, isolated with a minimal standalone repro outside this driver): on
# Godot 4.7's METAL RenderingDevice backend — this project's actual default, hardcoded in
# scripts/run_sim_offscreen.sh — get_captured_timestamp_gpu_time ALWAYS returns 0 (get_captured_timestamp_cpu_time
# still works fine; it's plain CPU-side bookkeeping). The SAME repro under `--rendering-driver vulkan`
# (MoltenVK, same machine) returns real nonzero GPU deltas. So this instrumentation is CORRECT and will
# report real per-pass numbers the moment Metal support lands (or immediately under Vulkan) — but reads 0
# across the board on the normal Metal dev loop. Not a bug here; don't re-debug this from scratch. Use
# `LA_RENDER_DRIVER=vulkan scripts/run_sim_offscreen.sh ...` for a one-off GPU-timing deep-dive.
var _gpu_pass_ms: Dictionary = {}   # pass name -> this step's GPU execution time (ms)
var _gpu_dispatch_ms: float = 0.0   # sum of all passes — the real GPU counterpart to field_dispatch_ms
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
# `pressure` joined this set 2026-08-03 and is the one entry here that is NOT a disaster channel. It is the
# hydrostatic weight of the air above a cell, written every step by wind_pressure_sphere3d and, until now,
# NEVER READ BACK AT ALL — so the CPU mirror `_f._pressure` sat at its all-zero seed for the life of every
# process. That matters because heat3d_solar_sphere3d derives the greenhouse EMISSIVITY from it
# (glsl:200-204), which is where the whole altitude structure of the surface temperature comes from, and any
# CPU-side reading of the energy balance built on a zero pressure silently falls back to a uniform sea-level
# column. Demand-gated like the rest: LAMaterialFieldEnergyBudget3D requests it, so a build that never asks
# pays nothing.
# `detritus` and `fungus` joined at the same time and for the same reason: NEITHER WAS EVER READ BACK, by any
# set, so their CPU mirrors held the all-zero allocation for the life of every process. SIM_REPORT's
# `detritus_peak`, `fungus_cells` and `fungus_peak` read those mirrors, so all three have been publishing the
# seed rather than the simulation, and a carbon ledger built on them would have measured nothing at all.
const SITUATIONAL_CHANNELS: Array = ["lava", "fire", "dust", "shock", "co2", "fuel", "rock_fill",
	"pressure", "detritus", "fungus"]
const CHANNEL_HOLD_DRAINS: int = 20     # stay hot ~20 drains past the last request so intermittent queries don't thrash
var _channel_hold: Dictionary = {}      # channel name -> drain index it stays hot through
var _drain_count: int = 0               # monotonic drain counter the holds are measured against
# READ-ONLY INSTRUMENT PROBE (see request_probe/take_probe). `_probe_want` is armed by a ledger and consumed at
# the next drain, where the device has just been synced and a buffer read is free of side effects; `_probe`
# holds the resulting arrays. Deliberately separate from `_cached` and `_channel_hold` so sampling it cannot
# change which mirrors the SIMULATION sees.
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
# LEDGER/BAKER channels: mineral-conservation ledger (sediment/susp), decomposer fertility (fert), water-table
# reservoir (soil), eco biomass metric + coarse fuel-refill source (biomass) — all coarse-cadence consumers, so a
# stale read never matters. `fuel`/`charge`/`rock_fill` are deliberately NOT here: fuel/charge consumers edit +
# re-upload the channel, and ROCK_FILL is scanned EVERY frame by MineralStamp3D to stamp the terrain SDF (the
# volcano land-building) + rewrite _solid — a stale/coarse rock_fill made eruptions grow FLOATING CUBES. Stay hot.
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
	# ACTIVE-CELL LIST. `active_idx` holds the compacted cell ids a compacted pass iterates; `active_args` is
	# BOTH the uvec3 dispatch-indirect argument (slots 0-2) and the atomic list-length counter (slot 3) — one
	# buffer, because a storage buffer created with
	# the DISPATCH_INDIRECT usage bit is still an ordinary SSBO the kernel can atomicAdd into. Neither is a
	# field CHANNEL: they are rebuilt from scratch every step, so they are deliberately absent from
	# PAIR_CHANNELS/SINGLE_CHANNELS and therefore never read back, snapshotted or restored.
	_bufs["active_idx"] = _new_u32(_cc)
	_bufs["active_args"] = _rd.storage_buffer_create(
		ACTIVE_ARGS_SLOTS * 4, _zeros(ACTIVE_ARGS_SLOTS),
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	# Sphere geometry SSBOs: neighbour table (int32, kernel slot order), radial + position (flat float3).
	var nbr_bytes: PackedByteArray = _grid.neighbours_kernel_order().to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_bufs["radial"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_radial(c))
	_bufs["pos"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_world_pos(c))
	# TANGENT-FRAME table, the neighbour table's counterpart: per SURFACE cell and lateral slot (kernel slots
	# 1..4 as l = 0..3), the unit direction toward that neighbour in the cell's own (tan_a, tan_b) components.
	# Per-surface, not per-cell — the direction is the same in every radial layer of a column, so it is 1/depth
	# the memory and stays cache-resident. Kernels index it as ((g / depth) * 4 + l) * 2.
	var ltan_bytes: PackedByteArray = _grid.link_tan.to_byte_array()
	_bufs["link_tan"] = _rd.storage_buffer_create(ltan_bytes.size(), ltan_bytes)
	# Angular separation per lateral link — the lateral RUN a slope test needs (see LASphereGrid.link_arc).
	var larc_bytes: PackedByteArray = _grid.link_arc.to_byte_array()
	_bufs["link_arc"] = _rd.storage_buffer_create(larc_bytes.size(), larc_bytes)
	# PLATE TABLE — the drifting Voronoi plates PlateAdvectPass carries the crust with. PLATE_STRIDE floats per
	# plate (seed.xyz, rate, pole.xyz, pad); allocated at a fixed ceiling and refilled by set_plates(), which is
	# called from OUTSIDE the compute list because a buffer_update while one is open is illegal. Zero-filled, so
	# a build with no tectonics node simply advects nothing (n_plates stays 0 and the pass is an exact no-op).
	_bufs["plates"] = _rd.storage_buffer_create(MAX_PLATES * PLATE_STRIDE * 4,
		_zeros(MAX_PLATES * PLATE_STRIDE))

	# Seed channels from the field's CPU state.
	#
	# A CPU `.fill()` THAT IS NOT IN THIS LIST NEVER REACHES THE SIMULATION. Every GPU buffer is created
	# zero-filled, so a channel the field seeds on the CPU but not here simply starts at zero on the device,
	# and the CPU mirror's value is wiped by the first readback. Two channels were in exactly that state
	# until 2026-08-03: `moisture` was `.fill(VAPOR_AMBIENT)` in MaterialField3D and had never once been
	# uploaded, and `co2` had neither a CPU fill nor an upload. Both are here now.
	_seed("temp", field._temp)
	_seed("o2", field._o2)
	_seed("co2", field._co2)            # the atmosphere's carbon — finite, at Earth's measured mole fraction
	_seed("soil", field._soil)          # initial water table (regolith primed by _compute_regolith)
	# `moisture` IS DELIBERATELY NOT SEEDED, and the reason is worth the four lines. MaterialField3D used to
	# `.fill(VAPOR_AMBIENT = 0.3)` it and that fill was never uploaded — so it was dead, and adding it to this
	# list looked like the obvious fix. It is not: 0.3 per cell over ~123,000 cells is about 37,000 units of
	# H2O against a whole-planet `h2o_total` of ~7,000, i.e. seeding five times the planet's entire water
	# budget as vapour. The dead fill is deleted at its source instead. A physically-sized starting humidity
	# (real air at 15 C and 60% RH is ~1e-4 of a cell of liquid water, which is negligible) needs the
	# water channel's kg-per-unit convention pinned down first; the atmosphere fills by evaporation meanwhile.
	_seed_solid()
	_seed_rock_fill()
	_seed_regolith()                    # aquifer permeability mask + grain-size field (static)

	# The reaction table's flux-derived rates (evaporation and its kin) turn a real per-square-metre flux into a
	# per-cell extent, which needs the cell HEIGHT. This is the one place that knows the grid and runs before
	# ReactionsPass.setup() builds the table.
	LAReactionDefs.cell_size_m = float(_grid.cell_size)

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
	# temp used to be re-uploaded UNCONDITIONALLY every step — 122,880 floats, 492 KB — for one reason: the
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


## The DRIFTING PLATES, as PLATE_STRIDE floats each (seed.xyz, rate, pole.xyz, pad). LAPlateTectonics owns the
## kinematics — it integrates the seeds on the physics clock and classifies the boundaries — and pushes the
## table here each frame; PlateAdvectPass then carries rock_fill and sediment with the velocity it implies, so
## the plates that decide where a volcano goes are the SAME plates that move the ground under it.
##
## Uploaded here rather than inside the pass because a `buffer_update` while a compute list is open is illegal;
## this is called from the field's step orchestration, outside the list. An empty table leaves n_plates 0, and
## the pass then sends nothing — the crust stands still, which is what a world with no tectonics node should do.
func set_plates(table: PackedFloat32Array) -> void:
	if _rd == null or not _bufs.has("plates"):
		return
	var n: int = mini(int(table.size() / PLATE_STRIDE), MAX_PLATES)
	_ctx["n_plates"] = n
	if n <= 0:
		return
	var b: PackedByteArray = table.slice(0, n * PLATE_STRIDE).to_byte_array()
	_rd.buffer_update(_bufs["plates"], 0, b.size(), b)

## The geothermal boundary: the TEMPERATURE of the rock ghost cell one shell below the grid's bottom face.
## Published by LAMaterialFieldGeotherm3D each step and consumed by heat_sphere3d.glsl, which bonds to it with
## the same finite-volume expression it uses for a real neighbour — so what each base cell draws depends on
## that cell's own temperature. A scalar because the interior CONVECTS and is isothermal at its top; the
## per-cell part happens in the kernel. <= 0 disarms the bond.
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
	# A local RenderingDevice permits exactly ONE submit() per sync(). The "rare" 2-steps-per-frame catch-up
	# (MAX_STEPS_PER_FRAME=2 in MaterialFieldSphereStep3D) calls step() twice in one tick: sync the earlier
	# submit before opening a new list (this also makes its writes visible to this step, replacing the old
	# per-step sync for that boundary). NOT actually rare under this project's typical loaded --sandbox run:
	# process_ms routinely exceeds 2×STEP_DT (200ms), so this fires most ticks, not occasionally. It must read
	# that step's GPU timestamps here too (not only in _drain_pending), or they're discarded unread whenever
	# two steps fire in one tick (2026-07-23).
	if _pending:
		_rd.sync()
		_pending = false
		_read_gpu_pass_timings()
	_ctx["step_index"] = _step_index
	if _step_probe.is_valid():
		_step_checkpointed()
		return
	# B1 — ALL passes into ONE submit()+deferred-sync (was: compute_list_begin → dispatch → end → submit →
	# sync PER pass = 10 blocking CPU↔GPU round-trips/step, up to 20/frame). The kernel math is cheap; those
	# round-trips were the cost. Still only ONE submit() here — ending+reopening compute_list per pass does NOT
	# reintroduce them (submit()/sync() are the only actual CPU↔GPU round-trip; list begin/end are pure
	# recording-time bookkeeping into the same not-yet-submitted command buffer).
	#
	# EACH PASS gets its OWN compute_list_begin()/end() pair (rather than one list spanning all passes), because
	# capture_timestamp() is ONLY legal OUTSIDE an open compute list — Godot throws "Capturing timestamps during
	# compute list creation is not allowed" otherwise. This is a REAL, confirmed engine constraint (found
	# 2026-07-23 chasing why gpu_dispatch_ms always read 0: the error was firing every step and silently
	# discarding the entire capture set, since a failed capture_timestamp call doesn't abort the list — it just
	# never got created).
	#
	# NO EXPLICIT BARRIER BETWEEN PASSES (corrected 2026-08-03). This loop used to call `_rd.full_barrier()`
	# between passes, under a comment asserting "Godot 4.7 does NOT auto-barrier between separate list segments".
	# The engine disagrees, in writing: every one of those calls raised `Deprecated. Barriers are automatically
	# inserted by RenderingDevice.` from `full_barrier (servers/rendering/rendering_device.cpp:7106)` — 29326
	# warnings in a single 2000-frame run, one per pass per step, each carrying a formatted GDScript backtrace.
	# RenderingDevice has tracked resource state and inserted its own barriers since the 4.3 rework, so the call
	# bought nothing and the assertion it rested on was stale. Verified behaviourally rather than assumed: same
	# seed, same frame count, with and without — field aggregates match (see the commit message for the table).
	# If a genuine cross-pass hazard ever shows up, it is a driver-level bug to report, not a barrier to re-add.
	#
	# STILL UNRESOLVED (2026-07-23, do not re-attempt from scratch): fixing the above error stopped the crash,
	# but get_captured_timestamps_count() still reads 0 in THIS driver specifically, even for the smallest
	# possible case (one real pass, one capture pair, no barrier). A battery of isolated repros — matching the
	# capture pattern, deferred submit timing, physics-tick callback, distinct-pipeline count, push constants,
	# realistic dispatch scale, and running concurrently inside this same busy scene — all reproduced CORRECTLY
	# (real nonzero counts/times under Vulkan; Metal's own get_captured_timestamp_gpu_time is separately known
	# to always return 0, see below, but the COUNT itself was fine). The one remaining, untested difference is
	# this driver's total GPU resource footprint at setup() time (dozens of buffers/uniform sets across all 11
	# passes) vs. every synthetic repro's much smaller footprint — a real next lead, not yet chased down.
	_rd.capture_timestamp("field_start")   # marker 0 — the interval to pass 0's own marker is pass 0's GPU time
	for i in _passes.size():
		var cl: int = _rd.compute_list_begin()
		_passes[i].dispatch(_rd, cl, _phase, _ctx, _cc, _groups)
		_rd.compute_list_end()
		_rd.capture_timestamp(_pass_names[i])
	_rd.submit()                        # deferred sync — drained at the next begin_frame (GPU overlaps CPU frame work)
	_pending = true
	_phase = 1 - _phase
	_step_index += 1

## Arm / disarm the between-pass probe. A VALID callable makes the NEXT step() take the checkpointed path;
## `Callable()` restores the normal one-submit path. Armed per step (not once at setup) because the checkpointed
## path costs one CPU↔GPU round-trip PER PASS — fine on a 1-in-N sampled step, not fine every step.
## Signature: `probe.call(pass_index: int, pass_name: String)`, pass_index -1 = before any pass ran.
func set_step_probe(cb: Callable) -> void:
	_step_probe = cb


## CHECKPOINTED STEP (LA_H2O_BUDGET only) — the same passes, same order, same parity as step(), but each pass
## gets its own submit()+sync() so a probe can read the channels BETWEEN passes.
##
## THAT SPLIT IS THE WHOLE INSTRUMENT. A per-leg budget built this way is DIFFERENCES OF MEASURED BUFFER STATE,
## so the legs sum to the step's total change by construction — no kernel needs a probe slot, no kernel's
## arithmetic has to be restated in GDScript (and so cannot be restated WRONG), and a pass added tomorrow is
## instrumented for free. The soil budget had to go the other way (dbg slots inside soil_sphere3d.glsl) because
## it needed to separate legs WITHIN one kernel; naming which PASS loses water needs nothing that fine.
##
## Timestamps are deliberately skipped here: capture_timestamp is only legal outside an open compute list AND
## its captures are read after a sync, so interleaving them with per-pass submits would report garbage for a
## diagnostic run nobody profiles.
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


## Real per-pass GPU execution time, read from the timestamp markers step() capture()'d across its per-pass
## compute lists, just sync()'d above. N+1 markers ("field_start" + one per pass) -> N intervals; interval i is
## [marker(i), marker(i+1)) = pass i's own GPU time, regardless of how long its CPU-side dispatch() call took
## to just RECORD the commands (field_dispatch_ms). Reports both the per-pass breakdown (which kernel is
## actually the hot one) and the aggregate (the true GPU counterpart to field_dispatch_ms). Currently always
## reads 0 captures in this driver for a still-unresolved reason — see the comment in step() before
## re-investigating; the plumbing itself is correct and will report real numbers once that's found.
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


## SPARSITY TELEMETRY — the two numbers that make the O(active) claim checkable, read from the just-sync()'d
## `active_args` counters. This is a 32-BYTE readback next to the ~4.4MB of channels _read_channels already
## copies each drain, so it does not move field_readback_ms.
##   field_cells     — grid size, the denominator.
##   lava_list_cells — invocations lava_phase actually dispatched this step (was: field_cells, always). Zero on
##                     a planet with no molten rock anywhere, which is the correct answer and the whole point.
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


## Read the GPU channels the CPU consumes back into a result dict. Split HOT (every drain) vs SLOW (coarse cadence).
## `sediment`/`susp` feed the mineral-conservation ledger (loose-regolith + waterborne phases — without them the
## ledger under-counts / sees a false conservation break); `fert` is the decomposer's soil-fertility output;
## `soil` the water-table reservoir; `rock_fill` the authoritative fractional bedrock mass; `biomass` the eco
## metric + coarse fuel-refill source — all coarse-cadence consumers, so they ride the slow set.
func _read_channels(read_slow: bool) -> Dictionary:
	var out: Dictionary = _empty_result()
	# ALWAYS-HOT — read EVERY drain (per-frame consumers: actor world-queries, senses, render, surface-seed).
	# Ping-pong PAIR channels read from their live half; single channels read direct. lava/fire/dust/shock/
	# co2/fuel/rock_fill moved to the DEMAND-GATED block below (verified: no per-frame consumer — co2 is
	# debug-overlay-only; fuel's own consumer only ACTS every 40 drains; rock_fill's claimed "every active
	# frame" consumer is a real no-op unless armed by a CPU-side edit). moisture stays hot: it looked like a
	# demand-gating candidate (no creature reads it directly) until tracing `avg_cloud_cover()`/
	# `moisture_total()` found `_atmos_dirty` gets set every drain regardless of which channel actually
	# refreshed (temp always does), and VoxelSkyCycle polls `avg_cloud_cover()` at ~150Hz — demand-gating it
	# would either go stale or get re-requested every drain anyway, so there's nothing to win.
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
	# DEMAND-GATED situational channels — read back ONLY while requested (a disaster is injecting/querying them,
	# or a debug overlay is showing them). On a calm planet nothing requests them, so this is the readback cut.
	# A skipped channel keeps its prior CPU array; the size-guarded scatter makes a stale read a 1-frame lag.
	# lava/fire/dust/shock/co2 are ping-pong PAIRS (read the live half); rock_fill/fuel are SINGLE
	# buffers (SINGLE_CHANNELS decides which below — charge stays always-hot above, not in this list).
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
##
## **`request_channel` IS NOT READ-ONLY — ONLY A SIMULATION CONSUMER MAY CALL IT, NEVER A GAUGE.** Residency
## decides what the CPU MIRRORS hold, and the field's own write paths read those mirrors and act on what they
## find, so waking a channel changes the run:
##   • `avg_atmos_dust()` sums `_f._dust` into the atmospheric opacity that sets INSOLATION — a dead dust mirror
##     pins impact winter at transmission 1.0, a live one dims the sun (measured 2026-08-03: `dust_total`
##     0.00 → 181-217, `atmos_transmission` 0.926 → 0.915 on otherwise identical runs).
##   • `add_lava` pushes the WHOLE `lava` + `rock_fill` mirrors back with `set_field`, so how stale the mirror is
##     decides how much GPU-evolved mass that upload rewinds (see `_audit_mirror_upload`).
##   • `LAMineralStamp3D._scan()` compares the `rock_fill` mirror against `_solid` and emits SDF grow/shrink
##     stamps plus a `displace("soil" → "water")` for every shrink.
## A ledger that wants fresh legs must use `request_probe`/`take_probe` below instead.
func request_channel(name: String) -> void:
	_channel_hold[name] = _drain_count + CHANNEL_HOLD_DRAINS


## ARM a READ-ONLY channel sample for a pure instrument (a conservation ledger). Taken at the NEXT drain and
## collected with `take_probe()`.
##
## WHY IT IS DEFERRED TO THE DRAIN INSTEAD OF READ ON THE SPOT, and this cost several measured runs to learn:
## **`buffer_get_data` is NOT a passive read on a local RenderingDevice.** Calling it from the report path
## while `step()` has an outstanding `submit()` (`_pending == true`) makes the device flush that work outside
## the one-submit-per-sync discipline this driver is built on, and the simulation comes out different.
## Measured 2026-08-03, same seed and frame count, the only change being WHERE the mineral ledger's five legs
## were read from: on-the-spot device reads took `h2o_total` 5062 → 9803, `sediment_total` 1073 → 1449,
## `rock_shrinks` 816 → 1602 and `temp_mean` 39.8 → 44.6 °C. Restoring every `request_channel` call did NOT
## bring it back, which is what identifies the READ rather than the residency. `read_raw`'s "no sync is done
## here" describes what this file does not call; it does not describe what the engine does underneath, and
## `read_raw` is only ever used from the checkpointed path where the device has just been synced.
##
## Taken inside `_drain_pending`, immediately after `_rd.sync()`, the read is the same operation
## `_read_channels` is already performing on its neighbours and costs a copy. It still touches NOTHING the
## simulation can observe: not `_channel_hold` (no channel becomes hot because a gauge looked at it), not
## `_cached`, not `_drain_count`, not `_slow_gate`. See `request_channel` above for why that matters.
## Several ledgers arm this in the same report block, so names UNION rather than replace and the whole set is
## sampled from one drain — every ledger's legs then come from the same instant, which is the inclusion rule
## they all depend on.
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


## Diagnostic (LA_INJECT_AUDIT=1): what a whole-mirror `set_field` upload does to a channel's TOTAL.
##
## This is the direct measurement of the thing the injection queue exists to avoid. The mirror was last filled
## by a readback one frame (up to two steps) old, so uploading it writes away everything the kernels did in
## between; the printed `delta` is exactly that mass, signed. It is measurement only and changes nothing.
##
## Two CPU writers still take this path — `add_lava` (rock_fill + lava) and the stamp's `debug_deposit` — and
## `MaterialFieldSphereStep3D.gd:152` runs their upload AHEAD of the queue flush at :187. Ordering-wise that is
## the safe direction and reversing it would be worse: the crater's `transfer` resolves its bedrock debit
## against the LIVE buffer, so flushing FIRST and uploading the (unwritten) mirror SECOND would restore the rock
## the crater had just removed while the sediment/dust credit stood, minting mineral. The real cost is the
## rewind itself, which this gauge exposes and which no ordering can remove — only moving `add_lava` onto
## `move_field_sparse` would, and that lives in the field hub, outside this module.
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
#
# WHY THESE EXIST. set_field uploads the WHOLE CPU mirror over the live GPU buffer, but that mirror was last
# filled by _apply_readback from a drain one frame (up to two steps) OLD. So an injection frame replaced the
# device's current state with a stale snapshot plus the injection, silently discarding everything the kernels
# did in between — the injection did not add to the channel, it REWOUND it. These two primitives read the live
# buffer, fold a sparse per-cell edit into it, and write it back, so an injection composes with live state.
# They must be called between _drain_pending() and step() (the GPU is idle there) — the sphere-step flush point,
# which is exactly where the old set_field injections ran.
#
# The read is a full-buffer copy, but the write-back is only the touched INDEX SPAN, and both happen only on
# frames something actually injected — the old path paid a full-buffer upload on those same frames anyway.

## A delta this negative empties a cell exactly (the clamp floor is 0), so callers that want to DRAIN a cell
## without knowing what is in it pass this and read the returned total.
const DRAIN_ALL: float = -1.0e30

## Fold a sparse per-cell delta into a channel's LIVE device buffer. `deltas[i]` is applied to `cells[i]`.
## Returns the total actually applied (sum of new - old), whose shortfall against sum(deltas) is what the
## floor/ceiling refused — report that, never assume it was zero.
##
## `ceiling` limits a POSITIVE delta to the cell's remaining headroom; it is not a clamp on the result. The
## distinction is mass. `clampf(before + delta, 0.0, ceiling)` reduced any cell already sitting above the
## ceiling, so a credit of +0.5 into a cell holding 1.4 with ceiling 1.0 left it at 1.0 and destroyed 0.4 —
## an "add" that subtracts. Water reaches those values legitimately (the compression model at
## MaterialField3D.gd:562 lets a cell exceed MAX_MASS) and `add_water_pooled` passes MAX_MASS as its ceiling,
## so the one live caller of this path was exactly the case that lost mass. Measured 2026-07-30: four cells at
## 1.4 given +0.5 each returned -1.6. Headroom-limiting instead means a full cell simply absorbs nothing and
## an over-full cell is left alone, matching `move_field_sparse`'s `dst_ceiling` rule (take only what the
## destination can hold) so the two primitives no longer disagree about what a ceiling means.
##
## A cells/deltas length mismatch is a caller bug that used to return 0.0 silently, which is indistinguishable
## from "every target was saturated" and is how a malformed queue op hid for as long as it did. It is loud now.
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


## Move mass between channels ON DEVICE, per-cell paired: take up to `amounts[i]` from `src` at `src_cells[i]`
## — whatever is actually there, read live, so a debit can never drive a cell negative — and credit exactly
## that into `dst` at `dst_cells[i]`. A `dst_cells[i]` of -1 discards the debited mass (the caller is expected
## to report it as an explicit loss). Returns the total moved.
##
## This is the primitive a CONSERVING injection needs. Because the source is read live and the credit is
## whatever the debit actually yielded, the two sides are the same number BY CONSTRUCTION — a transfer cannot
## mint even when the CPU mirror it was planned against was stale or the source turned out to be empty. The
## caller's shortfall is simply sum(amounts) - returned.
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


## PER-LEG SOIL BUDGET readback (LA_SOIL_BUDGET diagnostics only). Returns the probe array soil_sphere3d.glsl
## filled this step AND the soil channel as it stands right now, read after ONE flush so both describe the SAME
## step — which is the whole point. `_soil` on the field cannot be used for the second half: it rides the SLOW
## readback cadence (every 4th drain) and is a frame behind, so differencing it against a current probe would
## attribute one step's transfers to another step's total.
##
## The LIVE half after step()'s phase flip is exactly the buffer SoilPass wrote as SoilOut and ReactionsPass
## then edited in place (R19 root uptake), so `soil` here is the FINAL post-everything value and
## `soil - DBG_REG_OUT` isolates what ran after the soil kernel.
func read_soil_budget() -> Dictionary:
	if _rd == null or not _bufs.has("soil_dbg"):
		return {}
	_flush_pending()
	return {
		"dbg": _rd.buffer_get_data(_bufs["soil_dbg"]).to_float32_array(),
		"soil": _rd.buffer_get_data(_live("soil")).to_float32_array(),
		"step_index": _step_index,
	}


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
