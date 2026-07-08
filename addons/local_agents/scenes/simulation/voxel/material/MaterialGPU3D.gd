class_name LAMaterialGPU3D
extends RefCounted

## ██ PERF OVER PARITY (repo rule) ██ This is the AUTHORITATIVE runtime path. The CPU GDScript modules are
## the HEADLESS/no-compute FALLBACK — NOT a parity contract. Do NOT preserve, restore, or gate on bit-exact
## CPU↔GPU agreement; break it freely for performance. Verify changes BEHAVIOURALLY (`--run-frames=N` smoke:
## field aggregates sane, no NaN/runaway, fps good).
##
## GPU-RESIDENT compute backend for the DENSE 3D MaterialField3D. Owns a LOCAL RenderingDevice
## (RenderingServer.create_local_rendering_device()), persistent SSBOs that live across the WHOLE run,
## the compiled compute pipelines, and pre-built ping-pong uniform sets. Every per-cell simulation loop runs
## as a GPU pass here; a frame batches N steps on-GPU and reads back ONCE. The passes (race-free double-
## buffered kernels) mirror MaterialField3D.gd + MaterialHeat3D.gd:
##   HEAT (full MaterialHeat3D.step(), in order):
##     kernels3d/heat3d.glsl          <- PART 1 conduction  (6-neighbour relax, double-buffered gather)
##     kernels3d/heat3d_solar.glsl    <- PART 2 solar/ambient at the column-top sky cell (per-column)
##     kernels3d/heat3d_buoyancy.glsl <- PART 3 buoyant convection of hot void (per-column ascending sweep)
##     kernels3d/heat3d_cool.glsl     <- PART 4 evaporative cooling of wet cells (per-cell)
##   WATER (full MaterialField3D.step_water()):
##     kernels3d/water3d.glsl         <- down / lateral level-out / up overflow (two-pass gather)
##
## ============================================================================================
## RESIDENT FRAME API — the whole point (readback happens AT MOST ONCE PER FRAME)
## ============================================================================================
## A frame is exactly: 1 upload block + N x (all passes) + 1 readback block. Call order per physics
## frame (N = the field's steps this frame, 1..MAX_STEPS_PER_FRAME):
##
##   gpu.begin_frame(temp, water, solar)   # cheap uploads of the CPU-mutated state into the live SSBOs;
##                                         #   `solar` = MaterialHeat3D._solar() (the sun factor the GPU
##                                         #   can't read). Resets ping-pong parity. Uploads do NOT stall.
##   for i in range(N): gpu.step()         # water CA + FULL heat (conduction->solar->buoyancy->cooling)
##                                         #   on the resident buffers, ping-ponging in place — NO readback,
##                                         #   NO submit, NO sync. Just queues compute work.
##   var out: Dictionary = gpu.end_frame() # the ONLY submit + sync + readback of the frame.
##   temp = out["temp"] ; water = out["water"]
##
## `solid` and `static` are the terrain rock mask + calm-sea sink mask; they rarely change, so they are
## uploaded ONCE in setup() (re-push with upload_static_state() if the terrain is carved). Only temp +
## water round-trip, once each way per frame.
##
## STEP ORDER: each on-GPU step runs water CA before the full heat step (conduction→solar→buoyancy→cooling),
## matching the field's _physics_process order, so heat's wet-cooling reads the post-flow water.
##
## ADD-A-PASS SEAM (for the atmosphere + lava kernels bolted on next): vapor/cloud/fog/lava already have
## resident ping-pong buffers (see `_fields`). To add a pass: (1) compile the kernel + pipeline in
## _init_rd(), (2) build its two ping-pong uniform sets in _ensure_buffers() with live_buffer()/
## back_buffer(), (3) record its dispatch(es) in step() at the marked seam. ONE global `_parity` flips
## once per step(), so every field ping-pongs in lockstep and stays mutually consistent.
##
## The CPU GDScript loops are the headless fallback (NOT a parity oracle): available() is false when no
## local RenderingDevice can be made (--headless / no-compute), so those environments keep the CPU rules.
##
## Index layout (matches MaterialField3D): idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).
## (Explicit types only — no ':=' inferred typing.)
##
## The OLD per-call methods step_heat_conduction()/flow_water() are retained ONLY as the benchmark
## baseline (each does upload -> dispatch -> submit -> sync -> readback, a GPU->CPU stall EVERY call).

const HEAT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d.glsl"
const SOLAR_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_solar.glsl"
const BUOY_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_buoyancy.glsl"
const COOL_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_cool.glsl"
const WATER_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water3d.glsl"
const EVAP_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_evap3d.glsl"
const TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_transport3d.glsl"
const CONDENSE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_condense3d.glsl"
const RAIN_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_rain3d.glsl"
const LAVA_FLOW_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_flow3d.glsl"
const LAVA_PHASE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_phase3d.glsl"
const SLUMP_FLOW_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/slump3d.glsl"
const FIRE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/fire3d.glsl"
const WIND_PRESSURE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/wind_pressure3d.glsl"
const WIND_STEP_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/wind_step3d.glsl"
const CHARGE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/charge_accum3d.glsl"
const DUST_LOFT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/dust_loft3d.glsl"
const DUST_OUTSCALE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/dust_outscale3d.glsl"
const DUST_TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/dust_transport3d.glsl"
const O2_TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/o2_transport3d.glsl"
const CO2_TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/co2_transport3d.glsl"
const GAS_SKY_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/gas_sky3d.glsl"
const SHOCK_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/shock3d.glsl"
const SCENT_WIND_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/scent_wind3d.glsl"
const SCENT_TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/scent_transport3d.glsl"
const SCENT_FERT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/scent_fert3d.glsl"
const FUNGUS_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/fungus3d.glsl"
const FUNGUS_FERT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/fungus_fert3d.glsl"
const LOCAL_SIZE_X: int = 64
const SCENT_CHANNELS: int = 5              # airborne scent channels packed as c*area+col (MaterialScent3D.CHANNELS)

# Push-constant encoders (byte-packers matching each kernel's Params block) live in a sibling module so
# this hot backend file stays under the size gate; call as Push.<name>(self, ...).
const Push: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3DPush.gd")
# Geological-tail passes (erosion / snowice / magma per-cell cores) live in a sibling module so this hot
# backend file stays under the size gate; the backend only records their dispatches at the step() seams.
const Geo: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3DGeo.gd")

# Field timestep (MaterialField3D.STEP_DT = 1/STEP_HZ) — the atmosphere wind advection needs it to turn a
# world wind velocity into a per-step cell-fraction. Kept in sync with MaterialField3D.
const STEP_DT: float = 0.1
# Per-field atmosphere transport gains (copies of MaterialAtmosphere3D's constants), applied via the ONE
# shared atmos_transport3d kernel dispatched three times.
const VAPOR_DIFFUSE: float = 0.14
const CLOUD_DIFFUSE: float = 0.06
const FOG_DIFFUSE: float = 0.03
const VAPOR_RISE: float = 0.10
const CLOUD_RISE: float = 0.04
const VAPOR_WIND_GAIN: float = 1.0
const CLOUD_WIND_GAIN: float = 1.0
const FOG_WIND_GAIN: float = 0.5
const ORO_CONDENSE_GAIN: float = 1.3       # windward-slope condensation boost (mirrors MaterialAtmosphere3D)

var _rd: RenderingDevice = null
var _field = null                          # LAMaterialField3D (shared grid back-reference)
var _cell_count: int = 0
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0

# Field constants captured at setup (the GPU kernels can't read the field). _solar is refreshed each
# begin_frame (it tracks the day/night sun); the rest are fixed geometry.
var _origin_y: float = 0.0
var _cell_size: float = 5.0
var _sea_level: float = 0.0
var _solar: float = 0.6
var _wind: Vector2 = Vector2.ZERO          # world XZ wind, refreshed each begin_frame (drives atmosphere advection)
var _raining: bool = false                 # precipitation()>RAIN_MAX — suppresses dust lofting (wet-sand rule); set per frame
var _precip: float = 0.0                    # precipitation() — scent rain-wash / fertility leach / fungus moisture; set per frame

var _heat_pipeline: RID = RID()
var _solar_pipeline: RID = RID()
var _buoy_pipeline: RID = RID()
var _cool_pipeline: RID = RID()
var _water_pipeline: RID = RID()
var _evap_pipeline: RID = RID()
var _transport_pipeline: RID = RID()
var _condense_pipeline: RID = RID()
var _rain_pipeline: RID = RID()
var _lava_flow_pipeline: RID = RID()
var _lava_phase_pipeline: RID = RID()
var _slump_flow_pipeline: RID = RID()      # granular slump flow (sediment CA)
var _fire_pipeline: RID = RID()            # emergent fire/combustion (ember-gather + phase, gather-form)
var _wind_pressure_pipeline: RID = RID()   # emergent wind PASS A: pressure from temperature (per-cell)
var _wind_step_pipeline: RID = RID()       # emergent wind PASS B: velocity update (in-place, per-cell)
var _charge_pipeline: RID = RID()          # emergent electrification: per-cell charge accumulate (in place)
var _dust_loft_pipeline: RID = RID()       # emergent dust: scour dry loose sediment into airborne dust
var _dust_outscale_pipeline: RID = RID()   # emergent dust: per-cell out-flux CFL scale precompute
var _dust_transport_pipeline: RID = RID()  # emergent dust: gather advect/diffuse/settle + deposit to sediment
var _o2_transport_pipeline: RID = RID()    # emergent O₂: gather diffusion + wind advection (seals caves)
var _co2_transport_pipeline: RID = RID()   # emergent CO₂: same + a downward settle share (pools in hollows)
var _gas_sky_pipeline: RID = RID()         # emergent O₂/CO₂ sky exchange/vent at each column's surface cell
var _shock_pipeline: RID = RID()           # emergent shock/sound pressure-wave (per-cell diffuse+decay, reflects off rock)
var _scent_wind_pipeline: RID = RID()      # scent surface-wind precompute (per-column: topmost-open vel → surf scratch)
var _scent_transport_pipeline: RID = RID() # scent airborne transport (per-column 5-channel diffuse+advect+decay+rain-wash)
var _scent_fert_pipeline: RID = RID()      # scent soil fertility blur+leach (per-column)
var _fungus_pipeline: RID = RID()          # emergent decomposer CA (per-cell grow/decompose/spread over fungus/detritus)
var _fungus_fert_pipeline: RID = RID()     # fungus fertility per-column reduce (folds decomposition fert into the scent field)
var _shaders: Array[RID] = []              # every compiled shader RID (freed in dispose)
var _pipeline_shader: Dictionary = {}      # pipeline RID -> its shader RID (for uniform_set_create)

# --- Persistent SSBOs (sized to _cell_count), created ONCE, kept resident across the whole run. -----
# EVERY dynamic field is a PING-PONG PAIR (a <-> b). ONE global `_parity` selects the live buffer for ALL
# fields, so they ping-pong in lockstep; a pass reads live_buffer(name) and writes back_buffer(name) and
# stays consistent after the single flip. temp + water are stepped now; vapor/cloud/fog/lava are resident
# but not yet stepped (their kernels plug into the step() seam later). solid/static are single MASK
# buffers uploaded ONCE. send = 6-float-per-cell per-direction outflow scratch (water gather).
var _buf_temp_a: RID = RID()
var _buf_temp_b: RID = RID()
var _buf_water_a: RID = RID()
var _buf_water_b: RID = RID()
var _buf_vapor_a: RID = RID()
var _buf_vapor_b: RID = RID()
var _buf_cloud_a: RID = RID()
var _buf_cloud_b: RID = RID()
var _buf_fog_a: RID = RID()
var _buf_fog_b: RID = RID()
var _buf_lava_a: RID = RID()
var _buf_lava_b: RID = RID()
var _buf_sediment_a: RID = RID()           # loose granular sediment (landslide slump), ping-pong pair
var _buf_sediment_b: RID = RID()
var _buf_fire_a: RID = RID()               # burning intensity (0..1), ping-pong pair (reads fire_in, writes fire_out)
var _buf_fire_b: RID = RID()
var _buf_fuel: RID = RID()                 # flammable fuel mass per cell — resident SINGLE buffer, read+write IN PLACE
# O₂/CO₂ are PING-PONG PAIRS: the fire kernel consumes/emits them IN PLACE on the LIVE buffer, then the gas
# transport gather (o2_transport3d/co2_transport3d) reads LIVE and writes BACK, ping-ponging in lockstep with
# every other resident field (set_field uploads / end_frame downloads the live buffer).
var _buf_o2_a: RID = RID()                  # atmospheric oxygen per cell — ping-pong pair (fire consumes, gas transports)
var _buf_o2_b: RID = RID()
var _buf_co2_a: RID = RID()                 # atmospheric CO₂ per cell — ping-pong pair (fire EMITS, gas transports)
var _buf_co2_b: RID = RID()
var _buf_charge: RID = RID()               # electrification charge per cell — resident SINGLE buffer (accumulate reads/writes IN PLACE)
var _buf_dust_a: RID = RID()               # airborne dust density (sand storm), ping-pong pair
var _buf_dust_b: RID = RID()
var _buf_dust_outscale: RID = RID()        # per-cell dust out-flux CFL scale (single scratch, recomputed each step)
# Emergent shock/sound (per-cell, ping-pong): the CPU folds emit() impulses into the live buffer, the GPU
# radiates + decays it (reflecting off rock), we read it back for camera-shake / creature-panic consumers.
var _buf_shock_a: RID = RID()
var _buf_shock_b: RID = RID()
# Emergent scent stigmergy (per-COLUMN, dim_x*dim_z). scent = 5 packed airborne channels (ping-pong); fert =
# soil fertility (ping-pong); surf_vx/vz = the per-column surface wind scratch the transport reads (single,
# recomputed each step by scent_wind3d). The CPU tail folds actor emits + waste deposits into the live buffers.
var _buf_scent_a: RID = RID()              # SCENT_CHANNELS * area
var _buf_scent_b: RID = RID()
var _buf_fert_a: RID = RID()               # area
var _buf_fert_b: RID = RID()
var _buf_surf_vx: RID = RID()              # area — per-column surface wind X (scratch)
var _buf_surf_vz: RID = RID()              # area — per-column surface wind Z (scratch)
# Emergent decomposer (per-cell). detritus = dead organic matter (single, mutated in place + CPU deposits);
# fungus = fungal biomass (ping-pong); fungus_fert = per-cell fertility produced this step (scratch → reduced
# per-column into the scent fert field by fungus_fert3d).
var _buf_detritus: RID = RID()
var _buf_fungus_a: RID = RID()
var _buf_fungus_b: RID = RID()
var _buf_fungus_fert: RID = RID()
var _buf_solid: RID = RID()                # byte->float mirror of _solid (1 = rock)
var _buf_static: RID = RID()               # byte->float mirror of _static (1 = calm sea sink)
# Emergent wind velocity (world X/Y/Z). GPU-COMPUTED + RESIDENT: wind_pressure3d + wind_step3d write these
# in place each step (PASS B is per-cell, no neighbour-vel reads); the atmosphere transport reads the fresh
# resident vel_x/vel_z. Single (non-ping-pong) buffers, evolve across frames; upload_wind() only SEEDS them.
var _buf_vel_x: RID = RID()
var _buf_vel_y: RID = RID()
var _buf_vel_z: RID = RID()
var _buf_pressure: RID = RID()             # per-cell air pressure (PASS A writes, PASS B reads); resident single buffer
var _buf_send: RID = RID()                 # cell_count * 6 floats: per-direction outflow (water AND lava reuse)
var _buf_rain: RID = RID()                 # cell_count floats: per-cell rain mass scratch (condense -> rain gather)
var _buf_boil: RID = RID()                 # cell_count floats: per-cell boiled-water scratch (condense -> rain drain)

# name -> [rid_a, rid_b] for every ping-pong field, so future passes fetch buffers by name.
var _fields: Dictionary = {}

# Two pre-built uniform sets per kernel so we ping-pong by SELECTING a set, never recreating one.
#   parity 0: live data in *_a  -> conduction/water read a, write b; forcing passes act on b  (index 0)
#   parity 1: live data in *_b  -> conduction/water read b, write a; forcing passes act on a  (index 1)
var _heat_set: Array[RID] = [RID(), RID()]     # conduction: in=live, out=back
var _solar_set: Array[RID] = [RID(), RID()]    # in-place on back temp (+ solid)
var _buoy_set: Array[RID] = [RID(), RID()]     # in-place on back temp (+ solid)
var _cool_set: Array[RID] = [RID(), RID()]     # in-place on back temp (+ back water + solid)
var _water_set: Array[RID] = [RID(), RID()]    # in=live water, out=back water (+ solid/static/send)
# Atmosphere sets. evap: in=vapor live, out=vapor back. transport: dispatched 3x — vapor reads its post-evap
# back and writes the (now-free) live buffer as scratch; cloud/fog read their live and write back. condense:
# reads post-transport vapor(live)/cloud(back)/fog(back), writes final vapor(back) + rain scratch. rain: adds
# the gathered rain into back water.
var _evap_set: Array[RID] = [RID(), RID()]
var _transport_vapor_set: Array[RID] = [RID(), RID()]
var _transport_cloud_set: Array[RID] = [RID(), RID()]
var _transport_fog_set: Array[RID] = [RID(), RID()]
var _condense_set: Array[RID] = [RID(), RID()]
var _rain_set: Array[RID] = [RID(), RID()]
# Lava sets. flow: in=lava live, out=lava back (+ solid/send/back temp for carry-heat). phase: in-place on
# back lava + back temp + solid (solidify/sustain).
var _lava_flow_set: Array[RID] = [RID(), RID()]
var _lava_phase_set: Array[RID] = [RID(), RID()]
# Slump flow: in=sediment live, out=sediment back (+ solid/send). No temp (sediment is cold, no carry-heat).
var _slump_flow_set: Array[RID] = [RID(), RID()]
# Fire: in=fire live, out=fire back (+ fuel in-place, temp[back] in-place, water[back], solid, vel_x, vel_z).
var _fire_set: Array[RID] = [RID(), RID()]
# Gas transport (runs AFTER fire): o2/co2 gather in=live, out=back (+ solid + vel_x/y/z). Sky = per-column
# in-place on the transport OUTPUT (back) o2/co2 + solid.
var _o2_transport_set: Array[RID] = [RID(), RID()]
var _co2_transport_set: Array[RID] = [RID(), RID()]
var _gas_sky_set: Array[RID] = [RID(), RID()]
# Wind PASS A (pressure): in=temp[back post-heat], solid; out=pressure. PASS B (velocity): in=pressure, temp[back],
# solid; in-place on vel_x/vel_y/vel_z. Both read temp[back] so the sets are per-parity (temp buffer differs).
var _wind_pressure_set: Array[RID] = [RID(), RID()]
var _wind_step_set: Array[RID] = [RID(), RID()]
# Charge: in=charge(single, in place), temp[back post-everything], cloud[back post-atmos], vel_y, solid. Reads
# temp/cloud so the set is per-parity. Dust: loft in=sediment[back post-slump]+dust[live]+water[back]+vel+solid;
# outscale in=vel+solid out=outscale; transport in=dust[live]+outscale+vel+solid, out=dust[back]+sediment[back].
var _charge_set: Array[RID] = [RID(), RID()]
var _dust_loft_set: Array[RID] = [RID(), RID()]
var _dust_outscale_set: Array[RID] = [RID(), RID()]
var _dust_transport_set: Array[RID] = [RID(), RID()]
# Shock: in=shock live, out=shock back (+ solid). Scent: wind precompute reads vel_x/vel_z/solid, writes surf;
# transport in=scent live, out=scent back (+ surf); fert in=fert live, out=fert back. Fungus: in=fungus live,
# out=fungus back (+ detritus/co2[back]/o2[back] in place, temp/vapor/fire/solid read, fert_out scratch); the
# fert reduce reads fert_out, adds into fert back in place.
var _shock_set: Array[RID] = [RID(), RID()]
var _scent_wind_set: Array[RID] = [RID(), RID()]
var _scent_transport_set: Array[RID] = [RID(), RID()]
var _scent_fert_set: Array[RID] = [RID(), RID()]
var _fungus_set: Array[RID] = [RID(), RID()]
var _fungus_fert_set: Array[RID] = [RID(), RID()]
var _prevailing: Vector2 = Vector2.ZERO     # large-scale base wind forced by the wind_step3d kernel (set_prevailing)
var _parity: int = 0                        # 0 -> live in *_a, 1 -> live in *_b
var _static_uploaded: bool = false
var _geo = null                             # LAMaterialGPU3DGeo (erosion/snowice/magma geological-tail passes)


## True only when a local RenderingDevice can be created (false in --headless / no-compute → the caller
## keeps running the CPU modules). Probes with a throwaway device so it never leaks.
static func available() -> bool:
	var probe: RenderingDevice = RenderingServer.create_local_rendering_device()
	if probe == null:
		return false
	probe.free()
	return true


## Create the RenderingDevice + pipelines, size the persistent SSBOs to the field's cell_count, capture
## the field geometry constants, and upload the (rarely-changing) solid/static masks ONCE.
func setup(field) -> void:
	_field = field
	_origin_y = field._origin.y
	_cell_size = field._cell_size
	_sea_level = field.sea_level
	_init_rd()
	if _rd == null:
		return
	_ensure_buffers(field._dim_x, field._dim_y, field._dim_z)
	upload_static_state(field._solid, field._static)
	# Geological-tail passes (erosion/snowice/magma). Built AFTER the buffers/masks so its sets can bind them.
	_geo = Geo.new()
	_geo.setup(self)


func _init_rd() -> void:
	if _rd != null:
		return
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return
	_heat_pipeline = _pipeline(HEAT_SHADER_PATH)
	_solar_pipeline = _pipeline(SOLAR_SHADER_PATH)
	_buoy_pipeline = _pipeline(BUOY_SHADER_PATH)
	_cool_pipeline = _pipeline(COOL_SHADER_PATH)
	_water_pipeline = _pipeline(WATER_SHADER_PATH)
	_evap_pipeline = _pipeline(EVAP_SHADER_PATH)
	_transport_pipeline = _pipeline(TRANSPORT_SHADER_PATH)
	_condense_pipeline = _pipeline(CONDENSE_SHADER_PATH)
	_rain_pipeline = _pipeline(RAIN_SHADER_PATH)
	_lava_flow_pipeline = _pipeline(LAVA_FLOW_SHADER_PATH)
	_lava_phase_pipeline = _pipeline(LAVA_PHASE_SHADER_PATH)
	_slump_flow_pipeline = _pipeline(SLUMP_FLOW_SHADER_PATH)
	_fire_pipeline = _pipeline(FIRE_SHADER_PATH)
	_wind_pressure_pipeline = _pipeline(WIND_PRESSURE_SHADER_PATH)
	_wind_step_pipeline = _pipeline(WIND_STEP_SHADER_PATH)
	_charge_pipeline = _pipeline(CHARGE_SHADER_PATH)
	_dust_loft_pipeline = _pipeline(DUST_LOFT_SHADER_PATH)
	_dust_outscale_pipeline = _pipeline(DUST_OUTSCALE_SHADER_PATH)
	_dust_transport_pipeline = _pipeline(DUST_TRANSPORT_SHADER_PATH)
	_o2_transport_pipeline = _pipeline(O2_TRANSPORT_SHADER_PATH)
	_co2_transport_pipeline = _pipeline(CO2_TRANSPORT_SHADER_PATH)
	_gas_sky_pipeline = _pipeline(GAS_SKY_SHADER_PATH)
	_shock_pipeline = _pipeline(SHOCK_SHADER_PATH)
	_scent_wind_pipeline = _pipeline(SCENT_WIND_SHADER_PATH)
	_scent_transport_pipeline = _pipeline(SCENT_TRANSPORT_SHADER_PATH)
	_scent_fert_pipeline = _pipeline(SCENT_FERT_SHADER_PATH)
	_fungus_pipeline = _pipeline(FUNGUS_SHADER_PATH)
	_fungus_fert_pipeline = _pipeline(FUNGUS_FERT_SHADER_PATH)


func _pipeline(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	_shaders.append(shader)
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	_pipeline_shader[pipeline] = shader
	return pipeline


func _make_uniform(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


# --- Ping-pong buffer lookup (used to build sets + by future passes) -------------------------------
# For parity p: live = *_a when p==0 else *_b; back = the other. Conduction/water READ live + WRITE back;
# the in-place forcing passes act on back (the buffer conduction just wrote).

func buffer_pair(name: String) -> Array:
	return _fields.get(name, [RID(), RID()])


func live_buffer(name: String, parity: int) -> RID:
	var pair: Array = buffer_pair(name)
	return pair[0] if parity == 0 else pair[1]


func back_buffer(name: String, parity: int) -> RID:
	var pair: Array = buffer_pair(name)
	return pair[1] if parity == 0 else pair[0]


## (Re)allocate the persistent SSBOs + the two ping-pong uniform sets per kernel when the volume size
## changes. Idempotent for a fixed size (does NOT recreate buffers on repeat calls — the whole point).
func _ensure_buffers(dim_x: int, dim_y: int, dim_z: int) -> void:
	if _rd == null:
		return
	var cell_count: int = dim_x * dim_y * dim_z
	if cell_count == _cell_count and _buf_temp_a.is_valid():
		_dim_x = dim_x
		_dim_y = dim_y
		_dim_z = dim_z
		return
	_free_buffers()
	_cell_count = cell_count
	_dim_x = dim_x
	_dim_y = dim_y
	_dim_z = dim_z

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_temp_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_temp_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_lava_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_lava_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_sediment_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_sediment_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fire_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fire_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fuel = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_o2_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_o2_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_co2_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_co2_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_charge = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_dust_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_dust_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_dust_outscale = _rd.storage_buffer_create(zbytes.size(), zbytes)
	# Emergent shock + fungus/detritus — per-cell (cell_count) resident buffers.
	_buf_shock_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_shock_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_detritus = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fungus_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fungus_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fungus_fert = _rd.storage_buffer_create(zbytes.size(), zbytes)
	# Emergent scent — per-COLUMN (area = dim_x*dim_z). scent packs SCENT_CHANNELS planes; fert + surf are one plane.
	var area: int = dim_x * dim_z
	var col_zero: PackedFloat32Array = PackedFloat32Array()
	col_zero.resize(area)
	var col_bytes: PackedByteArray = col_zero.to_byte_array()
	var scent_zero: PackedFloat32Array = PackedFloat32Array()
	scent_zero.resize(SCENT_CHANNELS * area)
	var scent_bytes: PackedByteArray = scent_zero.to_byte_array()
	_buf_scent_a = _rd.storage_buffer_create(scent_bytes.size(), scent_bytes)
	_buf_scent_b = _rd.storage_buffer_create(scent_bytes.size(), scent_bytes)
	_buf_fert_a = _rd.storage_buffer_create(col_bytes.size(), col_bytes)
	_buf_fert_b = _rd.storage_buffer_create(col_bytes.size(), col_bytes)
	_buf_surf_vx = _rd.storage_buffer_create(col_bytes.size(), col_bytes)
	_buf_surf_vz = _rd.storage_buffer_create(col_bytes.size(), col_bytes)
	_buf_solid = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_static = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vel_x = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vel_y = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vel_z = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_pressure = _rd.storage_buffer_create(zbytes.size(), zbytes)
	var send_zero: PackedFloat32Array = PackedFloat32Array()
	send_zero.resize(cell_count * 6)
	var send_bytes: PackedByteArray = send_zero.to_byte_array()
	_buf_send = _rd.storage_buffer_create(send_bytes.size(), send_bytes)
	_buf_rain = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_boil = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_static_uploaded = false

	_fields = {
		"temp": [_buf_temp_a, _buf_temp_b],
		"water": [_buf_water_a, _buf_water_b],
		"vapor": [_buf_vapor_a, _buf_vapor_b],
		"cloud": [_buf_cloud_a, _buf_cloud_b],
		"fog": [_buf_fog_a, _buf_fog_b],
		"lava": [_buf_lava_a, _buf_lava_b],
		"sediment": [_buf_sediment_a, _buf_sediment_b],
		"fire": [_buf_fire_a, _buf_fire_b],
		"dust": [_buf_dust_a, _buf_dust_b],
		"o2": [_buf_o2_a, _buf_o2_b],
		"co2": [_buf_co2_a, _buf_co2_b],
		"shock": [_buf_shock_a, _buf_shock_b],
		"scent": [_buf_scent_a, _buf_scent_b],
		"fert": [_buf_fert_a, _buf_fert_b],
		"fungus": [_buf_fungus_a, _buf_fungus_b],
	}

	# Build the per-parity uniform sets. p=0: live=*_a, back=*_b. p=1: live=*_b, back=*_a.
	for p in [0, 1]:
		var temp_live: RID = live_buffer("temp", p)
		var temp_back: RID = back_buffer("temp", p)
		var water_live: RID = live_buffer("water", p)
		var water_back: RID = back_buffer("water", p)
		var vapor_live: RID = live_buffer("vapor", p)
		var vapor_back: RID = back_buffer("vapor", p)
		var cloud_live: RID = live_buffer("cloud", p)
		var cloud_back: RID = back_buffer("cloud", p)
		var fog_live: RID = live_buffer("fog", p)
		var fog_back: RID = back_buffer("fog", p)
		var lava_live: RID = live_buffer("lava", p)
		var lava_back: RID = back_buffer("lava", p)
		var sediment_live: RID = live_buffer("sediment", p)
		var sediment_back: RID = back_buffer("sediment", p)
		var fire_live: RID = live_buffer("fire", p)
		var fire_back: RID = back_buffer("fire", p)
		var o2_live: RID = live_buffer("o2", p)
		var o2_back: RID = back_buffer("o2", p)
		var co2_live: RID = live_buffer("co2", p)
		var co2_back: RID = back_buffer("co2", p)

		# Conduction: heat3d.glsl bindings 0 = in (live), 1 = out (back).
		_heat_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_live), _make_uniform(1, temp_back)], _shader_of(_heat_pipeline), 0)
		# Solar: heat3d_solar.glsl 0 = temp (back, in-place), 1 = solid.
		_solar_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_back), _make_uniform(1, _buf_solid)], _shader_of(_solar_pipeline), 0)
		# Buoyancy: heat3d_buoyancy.glsl 0 = temp (back, in-place), 1 = solid.
		_buoy_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_back), _make_uniform(1, _buf_solid)], _shader_of(_buoy_pipeline), 0)
		# Cooling: heat3d_cool.glsl 0 = temp (back, in-place), 1 = water (back = post-flow), 2 = solid.
		_cool_set[p] = _rd.uniform_set_create([
			_make_uniform(0, temp_back), _make_uniform(1, water_back),
			_make_uniform(2, _buf_solid)], _shader_of(_cool_pipeline), 0)
		# Water: water3d.glsl 0 = in (live), 1 = solid, 2 = static, 3 = send, 4 = out (back).
		_water_set[p] = _rd.uniform_set_create([
			_make_uniform(0, water_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_static), _make_uniform(3, _buf_send),
			_make_uniform(4, water_back)], _shader_of(_water_pipeline), 0)

		# --- Atmosphere ---------------------------------------------------------
		# Evap: atmos_evap3d.glsl 0=vapor in(live), 1=temp(back post-heat), 2=water(back post-flow),
		# 3=solid, 4=static, 5=vapor out(back).
		_evap_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_live), _make_uniform(1, temp_back),
			_make_uniform(2, water_back), _make_uniform(3, _buf_solid),
			_make_uniform(4, _buf_static), _make_uniform(5, vapor_back)], _shader_of(_evap_pipeline), 0)
		# Transport: atmos_transport3d.glsl 0=in, 1=solid, 2=out. VAPOR reads its post-evap back and writes
		# the (now-free) live buffer as scratch; CLOUD/FOG read their live and write back.
		_transport_vapor_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_back), _make_uniform(1, _buf_solid),
			_make_uniform(2, vapor_live), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_z)], _shader_of(_transport_pipeline), 0)
		_transport_cloud_set[p] = _rd.uniform_set_create([
			_make_uniform(0, cloud_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, cloud_back), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_z)], _shader_of(_transport_pipeline), 0)
		_transport_fog_set[p] = _rd.uniform_set_create([
			_make_uniform(0, fog_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, fog_back), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_z)], _shader_of(_transport_pipeline), 0)
		# Condense: atmos_condense3d.glsl 0=vapor in(post-transport = live scratch), 1=cloud(back, in place),
		# 2=fog(back, in place), 3=temp(back), 4=water(back), 5=solid, 6=static, 7=vapor out(back), 8=rain.
		_condense_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_live), _make_uniform(1, cloud_back),
			_make_uniform(2, fog_back), _make_uniform(3, temp_back),
			_make_uniform(4, water_back), _make_uniform(5, _buf_solid),
			_make_uniform(6, _buf_static), _make_uniform(7, vapor_back),
			_make_uniform(8, _buf_rain), _make_uniform(9, _buf_boil)], _shader_of(_condense_pipeline), 0)
		# Rain: atmos_rain3d.glsl 0=rain, 1=solid, 2=water(back, in place += rain − boil), 3=boil scratch.
		_rain_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_rain), _make_uniform(1, _buf_solid),
			_make_uniform(2, water_back), _make_uniform(3, _buf_boil)], _shader_of(_rain_pipeline), 0)

		# --- Lava ---------------------------------------------------------------
		# Flow: lava_flow3d.glsl 0=lava in(live), 1=solid, 2=send, 3=lava out(back), 4=temp(back, carry-heat).
		_lava_flow_set[p] = _rd.uniform_set_create([
			_make_uniform(0, lava_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_send), _make_uniform(3, lava_back),
			_make_uniform(4, temp_back)], _shader_of(_lava_flow_pipeline), 0)
		# Phase (solidify + sustain): lava_phase3d.glsl 0=lava(back, in place), 1=temp(back, in place),
		# 2=solid(in place).
		_lava_phase_set[p] = _rd.uniform_set_create([
			_make_uniform(0, lava_back), _make_uniform(1, temp_back),
			_make_uniform(2, _buf_solid)], _shader_of(_lava_phase_pipeline), 0)

		# --- Slump (granular landslide) ----------------------------------------
		# Flow: slump3d.glsl 0=sediment in(live), 1=solid, 2=send, 3=sediment out(back). No temp/carry-heat.
		_slump_flow_set[p] = _rd.uniform_set_create([
			_make_uniform(0, sediment_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_send), _make_uniform(3, sediment_back)], _shader_of(_slump_flow_pipeline), 0)

		# --- Fire (emergent combustion) ----------------------------------------
		# fire3d.glsl 0=fire in(live), 1=fire out(back), 2=fuel(single, in place), 3=temp(back, in place +ember/
		# BURN pin), 4=water(back), 5=solid, 6=vel_x, 7=vel_z. Runs LAST on the post-everything state.
		_fire_set[p] = _rd.uniform_set_create([
			_make_uniform(0, fire_live), _make_uniform(1, fire_back),
			_make_uniform(2, _buf_fuel), _make_uniform(3, temp_back),
			_make_uniform(4, water_back), _make_uniform(5, _buf_solid),
			_make_uniform(6, _buf_vel_x), _make_uniform(7, _buf_vel_z),
			_make_uniform(8, o2_live), _make_uniform(9, co2_live)], _shader_of(_fire_pipeline), 0)

		# --- Gas transport (emergent O₂/CO₂) — runs AFTER fire. o2_transport3d/co2_transport3d gather
		# 0=in(live, post-fire), 1=out(back), 2=solid, 3=vel_x, 4=vel_y, 5=vel_z. gas_sky3d then relaxes each
		# column's surface cell IN PLACE on the transport OUTPUT (back) o2/co2: 0=o2(back), 1=co2(back), 2=solid.
		_o2_transport_set[p] = _rd.uniform_set_create([
			_make_uniform(0, o2_live), _make_uniform(1, o2_back),
			_make_uniform(2, _buf_solid), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_y), _make_uniform(5, _buf_vel_z)], _shader_of(_o2_transport_pipeline), 0)
		_co2_transport_set[p] = _rd.uniform_set_create([
			_make_uniform(0, co2_live), _make_uniform(1, co2_back),
			_make_uniform(2, _buf_solid), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_y), _make_uniform(5, _buf_vel_z)], _shader_of(_co2_transport_pipeline), 0)
		_gas_sky_set[p] = _rd.uniform_set_create([
			_make_uniform(0, o2_back), _make_uniform(1, co2_back),
			_make_uniform(2, _buf_solid)], _shader_of(_gas_sky_pipeline), 0)

		# --- Wind (emergent pressure-driven 3D velocity) — PASS A pressure: wind_pressure3d.glsl
		# 0=temp(back post-heat), 1=solid, 2=pressure(out). PASS B velocity: wind_step3d.glsl 0=pressure,
		# 1=temp(back), 2=solid, 3=vel_x, 4=vel_y, 5=vel_z (vel_* IN PLACE). Runs between HEAT and ATMOSPHERE.
		_wind_pressure_set[p] = _rd.uniform_set_create([
			_make_uniform(0, temp_back), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_pressure)], _shader_of(_wind_pressure_pipeline), 0)
		_wind_step_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_pressure), _make_uniform(1, temp_back),
			_make_uniform(2, _buf_solid), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_y), _make_uniform(5, _buf_vel_z)], _shader_of(_wind_step_pipeline), 0)

		# --- Charge (emergent electrification → lightning) — charge_accum3d.glsl 0=charge(single, in place),
		# 1=temp(back post-everything), 2=cloud(back post-atmos), 3=vel_y, 4=solid. Dispatched LAST so it reads
		# the FINAL temperature (post-fire). The BREAKDOWN reduction + bolt spawn stay a CPU tail (step_scene_only).
		_charge_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_charge), _make_uniform(1, temp_back),
			_make_uniform(2, cloud_back), _make_uniform(3, _buf_vel_y),
			_make_uniform(4, _buf_solid)], _shader_of(_charge_pipeline), 0)

		# --- Dust (emergent sand storm / dune migration). Three passes on the POST-SLUMP sediment[back]:
		# LOFT dust_loft3d.glsl 0=sediment(back, in place -=), 1=dust(live, scatter += to cell above), 2=water(back),
		#   3=vel_x, 4=vel_z, 5=solid.
		_dust_loft_set[p] = _rd.uniform_set_create([
			_make_uniform(0, sediment_back), _make_uniform(1, live_buffer("dust", p)),
			_make_uniform(2, water_back), _make_uniform(3, _buf_vel_x),
			_make_uniform(4, _buf_vel_z), _make_uniform(5, _buf_solid)], _shader_of(_dust_loft_pipeline), 0)
		# OUTSCALE dust_outscale3d.glsl 0=outscale(out), 1=vel_x, 2=vel_y, 3=vel_z, 4=solid.
		_dust_outscale_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_dust_outscale), _make_uniform(1, _buf_vel_x),
			_make_uniform(2, _buf_vel_y), _make_uniform(3, _buf_vel_z),
			_make_uniform(4, _buf_solid)], _shader_of(_dust_outscale_pipeline), 0)
		# TRANSPORT dust_transport3d.glsl 0=dust in(live, post-loft), 1=dust out(back), 2=sediment(back, in place +=
		#   deposit), 3=outscale, 4=vel_x, 5=vel_y, 6=vel_z, 7=solid.
		_dust_transport_set[p] = _rd.uniform_set_create([
			_make_uniform(0, live_buffer("dust", p)), _make_uniform(1, back_buffer("dust", p)),
			_make_uniform(2, sediment_back), _make_uniform(3, _buf_dust_outscale),
			_make_uniform(4, _buf_vel_x), _make_uniform(5, _buf_vel_y),
			_make_uniform(6, _buf_vel_z), _make_uniform(7, _buf_solid)], _shader_of(_dust_transport_pipeline), 0)

		# --- Shock (emergent sound/pressure wave) — shock3d.glsl 0=in(live), 1=out(back), 2=solid. ---
		_shock_set[p] = _rd.uniform_set_create([
			_make_uniform(0, live_buffer("shock", p)), _make_uniform(1, back_buffer("shock", p)),
			_make_uniform(2, _buf_solid)], _shader_of(_shock_pipeline), 0)

		# --- Scent (emergent stigmergy, per-column) — WIND precompute scent_wind3d.glsl 0=vel_x, 1=vel_z,
		# 2=solid, 3=surf_vx(out), 4=surf_vz(out). TRANSPORT scent_transport3d.glsl 0=in(live), 1=out(back),
		# 2=surf_vx, 3=surf_vz. FERT scent_fert3d.glsl 0=in(live), 1=out(back). ---
		_scent_wind_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_vel_x), _make_uniform(1, _buf_vel_z),
			_make_uniform(2, _buf_solid), _make_uniform(3, _buf_surf_vx),
			_make_uniform(4, _buf_surf_vz)], _shader_of(_scent_wind_pipeline), 0)
		_scent_transport_set[p] = _rd.uniform_set_create([
			_make_uniform(0, live_buffer("scent", p)), _make_uniform(1, back_buffer("scent", p)),
			_make_uniform(2, _buf_surf_vx), _make_uniform(3, _buf_surf_vz)], _shader_of(_scent_transport_pipeline), 0)
		_scent_fert_set[p] = _rd.uniform_set_create([
			_make_uniform(0, live_buffer("fert", p)), _make_uniform(1, back_buffer("fert", p))],
			_shader_of(_scent_fert_pipeline), 0)

		# --- Fungus (emergent decomposer) — fungus3d.glsl 0=fungus in(live), 1=fungus out(back), 2=detritus
		# (in place), 3=co2(back, in place +=), 4=o2(back, in place -=), 5=temp(back), 6=vapor(back), 7=fire
		# (back), 8=solid, 9=fert_out(per-cell). fungus_fert3d.glsl 0=fert_out, 1=fert(back, in place +=). ---
		_fungus_set[p] = _rd.uniform_set_create([
			_make_uniform(0, live_buffer("fungus", p)), _make_uniform(1, back_buffer("fungus", p)),
			_make_uniform(2, _buf_detritus), _make_uniform(3, co2_back),
			_make_uniform(4, o2_back), _make_uniform(5, temp_back),
			_make_uniform(6, vapor_back), _make_uniform(7, fire_back),
			_make_uniform(8, _buf_solid), _make_uniform(9, _buf_fungus_fert)], _shader_of(_fungus_pipeline), 0)
		_fungus_fert_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_fungus_fert), _make_uniform(1, back_buffer("fert", p))],
			_shader_of(_fungus_fert_pipeline), 0)


# uniform_set_create needs the SHADER RID, not the pipeline. _pipeline() records the pairing.
func _shader_of(pipeline: RID) -> RID:
	return _pipeline_shader.get(pipeline, RID())


func _free_buffers() -> void:
	if _rd == null:
		return
	for arr in [_heat_set, _solar_set, _buoy_set, _cool_set, _water_set,
			_evap_set, _transport_vapor_set, _transport_cloud_set, _transport_fog_set,
			_condense_set, _rain_set, _lava_flow_set, _lava_phase_set, _slump_flow_set, _fire_set,
			_wind_pressure_set, _wind_step_set, _charge_set, _dust_loft_set, _dust_outscale_set,
			_dust_transport_set, _o2_transport_set, _co2_transport_set, _gas_sky_set,
			_shock_set, _scent_wind_set, _scent_transport_set, _scent_fert_set,
			_fungus_set, _fungus_fert_set]:
		for s in arr:
			if s.is_valid():
				_rd.free_rid(s)
	_heat_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_cool_set = [RID(), RID()]
	_water_set = [RID(), RID()]
	_evap_set = [RID(), RID()]
	_transport_vapor_set = [RID(), RID()]
	_transport_cloud_set = [RID(), RID()]
	_transport_fog_set = [RID(), RID()]
	_condense_set = [RID(), RID()]
	_rain_set = [RID(), RID()]
	_lava_flow_set = [RID(), RID()]
	_lava_phase_set = [RID(), RID()]
	_slump_flow_set = [RID(), RID()]
	_fire_set = [RID(), RID()]
	_wind_pressure_set = [RID(), RID()]
	_wind_step_set = [RID(), RID()]
	_charge_set = [RID(), RID()]
	_dust_loft_set = [RID(), RID()]
	_dust_outscale_set = [RID(), RID()]
	_dust_transport_set = [RID(), RID()]
	_o2_transport_set = [RID(), RID()]
	_co2_transport_set = [RID(), RID()]
	_gas_sky_set = [RID(), RID()]
	_shock_set = [RID(), RID()]
	_scent_wind_set = [RID(), RID()]
	_scent_transport_set = [RID(), RID()]
	_scent_fert_set = [RID(), RID()]
	_fungus_set = [RID(), RID()]
	_fungus_fert_set = [RID(), RID()]
	for buf in [_buf_temp_a, _buf_temp_b, _buf_water_a, _buf_water_b,
			_buf_vapor_a, _buf_vapor_b, _buf_cloud_a, _buf_cloud_b,
			_buf_fog_a, _buf_fog_b, _buf_lava_a, _buf_lava_b,
			_buf_vel_x, _buf_vel_y, _buf_vel_z, _buf_pressure, _buf_sediment_a, _buf_sediment_b,
			_buf_fire_a, _buf_fire_b, _buf_fuel, _buf_o2_a, _buf_o2_b, _buf_co2_a, _buf_co2_b,
			_buf_charge, _buf_dust_a, _buf_dust_b, _buf_dust_outscale,
			_buf_shock_a, _buf_shock_b, _buf_detritus, _buf_fungus_a, _buf_fungus_b, _buf_fungus_fert,
			_buf_scent_a, _buf_scent_b, _buf_fert_a, _buf_fert_b, _buf_surf_vx, _buf_surf_vz,
			_buf_solid, _buf_static, _buf_send, _buf_rain, _buf_boil]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_buf_temp_a = RID(); _buf_temp_b = RID()
	_buf_water_a = RID(); _buf_water_b = RID()
	_buf_vapor_a = RID(); _buf_vapor_b = RID()
	_buf_cloud_a = RID(); _buf_cloud_b = RID()
	_buf_fog_a = RID(); _buf_fog_b = RID()
	_buf_lava_a = RID(); _buf_lava_b = RID()
	_buf_sediment_a = RID(); _buf_sediment_b = RID()
	_buf_fire_a = RID(); _buf_fire_b = RID(); _buf_fuel = RID()
	_buf_o2_a = RID(); _buf_o2_b = RID(); _buf_co2_a = RID(); _buf_co2_b = RID()
	_buf_charge = RID(); _buf_dust_a = RID(); _buf_dust_b = RID(); _buf_dust_outscale = RID()
	_buf_solid = RID(); _buf_static = RID(); _buf_send = RID(); _buf_rain = RID(); _buf_boil = RID()
	_buf_vel_x = RID(); _buf_vel_y = RID(); _buf_vel_z = RID(); _buf_pressure = RID()
	_buf_shock_a = RID(); _buf_shock_b = RID()
	_buf_detritus = RID(); _buf_fungus_a = RID(); _buf_fungus_b = RID(); _buf_fungus_fert = RID()
	_buf_scent_a = RID(); _buf_scent_b = RID(); _buf_fert_a = RID(); _buf_fert_b = RID()
	_buf_surf_vx = RID(); _buf_surf_vz = RID()
	_fields = {}
	_cell_count = 0
	_static_uploaded = false


## Release every GPU resource + the local RenderingDevice. Call when tearing the field down.
func dispose() -> void:
	if _rd == null:
		return
	if _geo != null:
		_geo.dispose(self)                     # free the geological-tail pipelines/buffers/sets before the RD
		_geo = null
	_free_buffers()
	for pipe in [_heat_pipeline, _solar_pipeline, _buoy_pipeline, _cool_pipeline, _water_pipeline,
			_evap_pipeline, _transport_pipeline, _condense_pipeline, _rain_pipeline,
			_lava_flow_pipeline, _lava_phase_pipeline, _slump_flow_pipeline, _fire_pipeline,
			_wind_pressure_pipeline, _wind_step_pipeline, _charge_pipeline, _dust_loft_pipeline,
			_dust_outscale_pipeline, _dust_transport_pipeline,
				_o2_transport_pipeline, _co2_transport_pipeline, _gas_sky_pipeline,
				_shock_pipeline, _scent_wind_pipeline, _scent_transport_pipeline,
				_scent_fert_pipeline, _fungus_pipeline, _fungus_fert_pipeline]:
		if pipe.is_valid():
			_rd.free_rid(pipe)
	for s in _shaders:
		if s.is_valid():
			_rd.free_rid(s)
	_shaders = []
	_pipeline_shader = {}
	_heat_pipeline = RID(); _solar_pipeline = RID(); _buoy_pipeline = RID()
	_cool_pipeline = RID(); _water_pipeline = RID()
	_evap_pipeline = RID(); _transport_pipeline = RID(); _condense_pipeline = RID()
	_rain_pipeline = RID(); _lava_flow_pipeline = RID(); _lava_phase_pipeline = RID()
	_slump_flow_pipeline = RID(); _fire_pipeline = RID()
	_wind_pressure_pipeline = RID(); _wind_step_pipeline = RID()
	_charge_pipeline = RID(); _dust_loft_pipeline = RID()
	_dust_outscale_pipeline = RID(); _dust_transport_pipeline = RID()
	_o2_transport_pipeline = RID(); _co2_transport_pipeline = RID(); _gas_sky_pipeline = RID()
	_shock_pipeline = RID(); _scent_wind_pipeline = RID(); _scent_transport_pipeline = RID()
	_scent_fert_pipeline = RID(); _fungus_pipeline = RID(); _fungus_fert_pipeline = RID()
	_rd.free()
	_rd = null


# --- Buffer transfer helpers -----------------------------------------------------------------------

## Upload a flat grid into an SSBO (native byte copy). Uploads do NOT stall the GPU (no sync).
func upload(buf: RID, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	var bytes: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(buf, 0, bytes.size(), bytes)


## Download an SSBO back to a flat grid. This is the ONLY GPU->CPU sync stall — do it at most once per
## frame per field (temp + water in end_frame).
func download(buf: RID) -> PackedFloat32Array:
	if _rd == null:
		return PackedFloat32Array()
	var bytes: PackedByteArray = _rd.buffer_get_data(buf)
	return bytes.to_float32_array()


func _bytes_to_floats(b: PackedByteArray) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(b.size())
	for k in range(b.size()):
		out[k] = float(b[k])
	return out


func _groups() -> int:
	return int(ceil(float(_cell_count) / float(LOCAL_SIZE_X)))


func _col_groups() -> int:
	return int(ceil(float(_dim_x * _dim_z) / float(LOCAL_SIZE_X)))


## Push the (rarely-changing) rock + calm-sea masks into their resident SSBOs. Called once from setup();
## call again ONLY if the terrain is carved or the sea reseeded. Not part of the per-frame path.
func upload_static_state(solid: PackedByteArray, static_cells: PackedByteArray) -> void:
	if _rd == null:
		return
	upload(_buf_solid, _bytes_to_floats(solid))
	upload(_buf_static, _bytes_to_floats(static_cells))
	_static_uploaded = true


## SEED the resident wind velocity (world XZ) SSBOs. Wind is now GPU-computed + resident (wind_step3d evolves
## vel in place each step), so the field NO LONGER calls this per frame — only to seed an initial velocity
## (e.g. the parity harnesses' fixed test wind, matching the CPU oracle's start).
func upload_wind(vel_x: PackedFloat32Array, vel_z: PackedFloat32Array) -> void:
	if _rd == null:
		return
	upload(_buf_vel_x, vel_x)
	upload(_buf_vel_z, vel_z)


## Set the large-scale PREVAILING wind the wind_step3d kernel relaxes every cell toward (mirrors
## MaterialWind3D.set_prevailing — fed each frame from the field).
func set_prevailing(w: Vector2) -> void:
	_prevailing = w


# --- RESIDENT FRAME API (begin_frame -> step x N -> end_frame) -------------------------------------

## Frame start: upload the CPU-authoritative temp + water (which carry this frame's injections — springs,
## add_heat, meteor splashes) into the CURRENT live resident buffers, and refresh the solar + wind scalars.
## Cheap: two buffer_update copies, no dispatch, no sync. Parity is NOT reset — vapor / cloud / fog / lava
## are fully resident (they persist on the GPU across frames, ping-ponging in lockstep), so uploading temp
## and water into whichever buffer is currently live keeps every field consistent with the last end_frame.
## Seed the resident fields (and push per-frame injections into them) with set_field(); `wind` (world XZ)
## drives the atmosphere advection.
func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6, wind: Vector2 = Vector2.ZERO) -> void:
	_init_rd()
	if _rd == null:
		return
	if _field != null:
		_ensure_buffers(_field._dim_x, _field._dim_y, _field._dim_z)
	_solar = solar
	_wind = wind
	upload(live_buffer("temp", _parity), temp)
	upload(live_buffer("water", _parity), water)


## Seed / inject a resident field (temp / water / vapor / cloud / fog / lava) into its CURRENT live buffer.
## Use it to upload the initial vapor/cloud/fog/lava state once, or to fold a CPU-side injection (an
## add_lava vent, a spring) into the resident buffer before the step loop. No dispatch, no sync.
func set_field(name: String, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	if name == "fuel":
		upload(_buf_fuel, arr)             # single resident buffer (read+write in place; not ping-pong)
		return
	if name == "charge":
		upload(_buf_charge, arr)           # single resident buffer (accumulate reads/writes in place)
		return
	if name == "detritus":
		upload(_buf_detritus, arr)         # single resident buffer (fungus decomposes in place; CPU deposits carcass/ash detritus)
		return
	if name == "snow":
		if _geo != null:
			_geo.upload_snow(self, arr)    # per-column snowpack depth (single buffer, owned by the Geo module)
		return
	if name == "susp":
		if _geo != null:
			_geo.upload_susp(self, arr)    # erosion suspended sediment (ping-pong, owned by the Geo module)
		return
	upload(live_buffer(name, _parity), arr)


## Set the RAINING flag the dust LOFT kernel reads (precipitation() > RAIN_MAX suppresses all lofting — wet
## sand never blows). Fed each frame from the field; the parity harness sets it directly.
func set_raining(raining: bool) -> void:
	_raining = raining


## Set the per-frame precipitation() the scent rain-wash / fertility leach and fungus moisture kernels read.
## Fed each frame from the field before the step loop.
func set_precip(precip: float) -> void:
	_precip = precip


## One resident sim step, queued into a compute list (no submit/sync/readback). Order mirrors the field's
## _physics_process: WATER first, then the FULL heat chain (conduction -> solar -> buoyancy -> cooling),
## so heat's wet-cooling reads the post-flow water. Ping-pongs in place, then flips parity. Successive
## steps run in separate compute lists; Godot inserts a full memory barrier between compute lists, so
## step k+1 correctly reads what step k wrote.
func step() -> void:
	if _rd == null or _cell_count == 0:
		return
	var groups: int = _groups()
	var col_groups: int = _col_groups()
	var cl: int = _rd.compute_list_begin()

	# --- WATER CA: pass 0 outflow -> barrier -> pass 1 gather+apply. water[live] -> water[back]. ---
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.water_pc(self, 0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.water_pc(self, 1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# --- EROSION (geological tail): on the fresh post-flow water[back] — deposit/settle suspended sediment
	# into the shared channel (before slump piles it) + gather-advect it downhill. Rock CARVE stays CPU. ---
	if _geo != null:
		_rd.compute_list_add_barrier(cl)          # water[back] visible to erosion's reads
		_geo.record_erosion(self, cl)
		_rd.compute_list_add_barrier(cl)          # susp[back] + sediment deposits committed

	# --- HEAT PART 1: conduction. temp[live] -> temp[back]. (Disjoint from water; no barrier needed
	# between the water writes and the conduction reads — they touch different buffers.) ---
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.heat_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # conduction (and water pass1) visible to the forcing passes

	# --- HEAT PART 2: solar/ambient at the column-top sky cell. In-place on temp[back]. Per-column. ---
	_rd.compute_list_bind_compute_pipeline(cl, _solar_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _solar_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.solar_pc(self), 32)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	# --- HEAT PART 3: buoyant convection. In-place on temp[back]. Per-column ascending sweep. ---
	_rd.compute_list_bind_compute_pipeline(cl, _buoy_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _buoy_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	# --- HEAT PART 4: evaporative cooling of wet cells toward the sea thermocline. In-place on temp[back],
	# reads water[back]. The push-constant carries origin_y/cell_size/sea_level for the depth profile. ---
	_rd.compute_list_bind_compute_pipeline(cl, _cool_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _cool_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.cool_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# ================= ADD-A-PASS SEAM ==============================================================
	# WIND -> ATMOSPHERE -> LAVA (matching MaterialField3D._physics_process: water -> heat -> WIND ->
	# atmosphere -> lava). This barrier guards the post-heat temp writes (pressure/evap/condense read them).
	_rd.compute_list_add_barrier(cl)

	# --- SNOWICE (geological tail): after the heat chain, on the post-heat temp[back] — per-column snowpack
	# accrete (cold precip) / melt (-> meltwater into water[back], swelling the rivers). The water FREEZE/THAW
	# (SDF + solid mask) stays MaterialSnowIce3D's CPU tail. ---
	if _geo != null:
		_geo.record_snowice(self, cl)
		_rd.compute_list_add_barrier(cl)          # snow depth + meltwater in water[back] visible downstream

	# --- WIND PASS A: air PRESSURE from the post-heat temperature. temp[back] + solid -> pressure. ---
	_rd.compute_list_bind_compute_pipeline(cl, _wind_pressure_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _wind_pressure_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # pressure visible to the velocity update

	# --- WIND PASS B: velocity update (gradient + buoyancy + Coriolis + prevailing + drag + deflection +
	# clamp) IN PLACE on vel_x/vel_y/vel_z. Reads pressure + temp[back] + solid. ---
	_rd.compute_list_bind_compute_pipeline(cl, _wind_step_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _wind_step_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.wind_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # fresh resident vel visible to the atmosphere transport advection

	# --- ATMOSPHERE STAGE 1: EVAPORATION. vapor[live] + evap -> vapor[back]. ---
	_rd.compute_list_bind_compute_pipeline(cl, _evap_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _evap_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-evap vapor visible to its transport read

	# --- ATMOSPHERE STAGE 2: TRANSPORT (vapor / cloud / fog). Each reads a snapshot, writes a disjoint
	# buffer; the three are mutually independent so no barrier is needed BETWEEN them. ---
	_rd.compute_list_bind_compute_pipeline(cl, _transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _transport_vapor_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.transport_pc(self, VAPOR_DIFFUSE, VAPOR_RISE, VAPOR_WIND_GAIN), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_bind_uniform_set(cl, _transport_cloud_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.transport_pc(self, CLOUD_DIFFUSE, CLOUD_RISE, CLOUD_WIND_GAIN), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_bind_uniform_set(cl, _transport_fog_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.transport_pc(self, FOG_DIFFUSE, 0.0, FOG_WIND_GAIN), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-transport vapor/cloud/fog visible to condensation

	# --- ATMOSPHERE STAGE 3: CONDENSATION + rain accounting. Per void cell: dewpoint condense/re-evap/
	# decay + compute rain (stored to the rain scratch). vapor[live] -> vapor[back]; cloud/fog[back] in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _condense_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _condense_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.condense_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # rain scratch visible to the rain gather

	# --- ATMOSPHERE STAGE 4: RAIN GATHER. Route each cell's rain to the ground cell: water[back] += rain. ---
	_rd.compute_list_bind_compute_pipeline(cl, _rain_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _rain_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # temp[back] carry-heat / water[back] settle before lava reads

	# --- LAVA FLOW: viscous 3D CA, two-pass gather (reuses the water send buffer). lava[live] ->
	# lava[back]; a receiving cell's temp[back] is floored to MOLTEN_FLOOR (carry-heat). ---
	_rd.compute_list_bind_compute_pipeline(cl, _lava_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.lava_pc(self, 0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _lava_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.lava_pc(self, 1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-flow lava/temp visible to solidify+sustain

	# --- LAVA PHASE: solidify (cooled lava -> rock) + sustain (keep remaining lava molten), in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_phase_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # send scratch (shared with lava) clear before slump reuses it

	# --- MAGMA (geological tail): on the post-phase lava[back]/temp[back] — the two-pass buoyant overpressure
	# up-flow that climbs the conduit. Conduit PRESSURE-MELT (SDF) + deep-source feed stay CPU. ---
	if _geo != null:
		_geo.record_magma(self, cl)
		_rd.compute_list_add_barrier(cl)      # post-magma lava/temp committed before dust/fire read them

	# --- GRANULAR SLUMP: cold sediment CA, two-pass gather (reuses the send buffer). Gravity down, a
	# LATERAL level-out gated by the angle of repose, then up under pressure. sediment[live] -> sediment[back].
	# Re-solidifying at-rest sediment into terrain is a CPU-only SDF stamp (MaterialSlump3D.settle). ---
	_rd.compute_list_bind_compute_pipeline(cl, _slump_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _slump_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.slump_pc(self, 0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _slump_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _slump_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.slump_pc(self, 1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-everything temp/water + post-slump sediment visible to dust/fire

	# --- DUST / SAND STORM: three passes on the POST-SLUMP sediment (matches CPU order slump -> dust). Runs on
	# the fresh per-cell wind. Independent of fire (disjoint buffers), so it sits before it. LOFT scours dry
	# loose sediment[back] into the airborne dust[live] of the cell above (scatter, unique target → race-free);
	# OUTSCALE precomputes the CFL out-flux scale; TRANSPORT gather-advects/diffuses/settles dust[live]->dust[back]
	# and DEPOSITS settled dust back into sediment[back] (mass-conserving). No CPU tail beyond diagnostics. ---
	_rd.compute_list_bind_compute_pipeline(cl, _dust_loft_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _dust_loft_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dust_loft_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # lofted dust + reduced sediment visible to the transport gather
	_rd.compute_list_bind_compute_pipeline(cl, _dust_outscale_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _dust_outscale_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dust_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # per-cell out-flux scale visible to the transport gather
	_rd.compute_list_bind_compute_pipeline(cl, _dust_transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _dust_transport_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dust_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # dust[back] + sediment deposits committed

	# --- FIRE / COMBUSTION: LAST pass, on the post-everything state. Single gather dispatch — each cell sums
	# ember heat from burning neighbours (downwind/upward biased by vel), mutates its own temp/fuel in place,
	# and writes the next fire intensity to fire[back] (ping-pong). Ash marking + plant/tree coupling + ash->
	# plant regrowth stay on the CPU tail (LAMaterialCombustion3D.step_scene_only), like lava's SDF stamps.
	# fire[live] -> fire[back]; fuel + temp[back] mutated in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _fire_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _fire_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-fire temp[back] visible to charge (reads the FINAL temperature)

	# --- CHARGE / ELECTRIFICATION: per-cell accumulate on the FINAL state (reads post-fire temp[back], post-
	# atmosphere cloud[back], the fresh vertical wind vel_y). In-place on the single charge buffer, no neighbour
	# reads. The BREAKDOWN reduction + bolt spawn + column reset stay a CPU tail (LAMaterialCharge3D.step_scene_only). ---
	_rd.compute_list_bind_compute_pipeline(cl, _charge_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _charge_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.charge_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# --- GAS TRANSPORT: emergent O₂ + CO₂ diffuse/advect on the fresh per-cell wind, then a per-column SKY
	# exchange/vent. Runs AFTER fire consumed O₂ / emitted CO₂ IN PLACE on the live buffers (the fire barrier
	# above made those writes visible; charge touches only _buf_charge, disjoint). o2/co2 transport are a
	# GATHER (in=live, out=back) — independent, disjoint buffers, so no barrier BETWEEN them — then gas_sky3d
	# relaxes each surface cell IN PLACE on the transport output (back). Ping-pongs in lockstep; after the flip
	# the back buffer becomes live (what end_frame reads + fire consumes next step). SEALS caves emergently. ---
	_rd.compute_list_bind_compute_pipeline(cl, _o2_transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _o2_transport_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_bind_compute_pipeline(cl, _co2_transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _co2_transport_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-transport o2/co2 visible to the per-column sky exchange/vent
	_rd.compute_list_bind_compute_pipeline(cl, _gas_sky_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _gas_sky_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-gas o2/co2[back] visible to fungus (which draws/emits them)

	# --- SCENT (emergent stigmergy, per-column) — PRECOMPUTE the surface wind (topmost-open vel per column),
	# then TRANSPORT the 5 airborne channels (diffuse+advect on that wind + decay + rain-wash) and blur/leach
	# the soil FERTILITY. Emits/waste deposits were folded into the live buffers on the CPU (step_scene_only).
	# All per-column dispatches. scent_wind writes surf; transport reads it, so a barrier separates them. ---
	_rd.compute_list_bind_compute_pipeline(cl, _scent_wind_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scent_wind_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.scent_wind_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # surf_vx/vz visible to the transport gather
	# TRANSPORT (scent, per-column), FERT (per-column) and SHOCK (per-cell) are mutually disjoint — no barrier
	# between them. SHOCK: the CPU folded emit() impulses into shock[live]; the wave radiates + decays here.
	_rd.compute_list_bind_compute_pipeline(cl, _scent_transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scent_transport_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.scent_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_bind_compute_pipeline(cl, _scent_fert_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scent_fert_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.scent_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_bind_compute_pipeline(cl, _shock_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _shock_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # fert[back] + fungus reads visible before the decomposer

	# --- FUNGUS (emergent decomposer, per-cell) — grow/decompose/spread over fungus/detritus, drawing O₂[back]
	# + emitting CO₂[back] (post-gas), depositing per-cell fertility to fungus_fert. Detritus was uploaded from
	# the CPU (carcass/ash deposits). fungus[live] -> fungus[back]; detritus/o2/co2 mutated in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _fungus_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _fungus_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.fungus_pc(self), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # per-cell fungus_fert visible to the per-column reduce
	# --- FUNGUS FERTILITY reduce (per-column): sum the column's fungus_fert into fert[back] — closes the loop. ---
	_rd.compute_list_bind_compute_pipeline(cl, _fungus_fert_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _fungus_fert_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, Push.dims_pc(self), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	# ===============================================================================================

	_rd.compute_list_end()
	# Flip parity: this step read the live buffers and wrote the other pair, which is now live.
	_parity = 1 - _parity


## Frame end: the ONLY submit + sync of the frame. Flushes every queued step, waits once, then reads the
## final resident state off whichever ping-pong buffer is live. Returns the full per-cell sim output:
## {"temp", "water", "vapor", "cloud", "fog", "lava"} (temp+water round-trip via begin_frame; the airborne
## fields + lava are resident and returned so the renderer / rain layer / lava visuals can consume them).
func end_frame(read_vapor: bool = true, read_cloud: bool = true, read_fog: bool = true, read_render: bool = true, read_lava: bool = true, read_shock: bool = true) -> Dictionary:
	if _rd == null or _cell_count == 0:
		return {
			"temp": PackedFloat32Array(), "water": PackedFloat32Array(),
			"vapor": PackedFloat32Array(), "cloud": PackedFloat32Array(),
			"fog": PackedFloat32Array(), "lava": PackedFloat32Array(),
			"fire": PackedFloat32Array(), "fuel": PackedFloat32Array(),
			"o2": PackedFloat32Array(), "co2": PackedFloat32Array(),
		}
	_rd.submit()
	_rd.sync()
	# temp / water / lava are consumer-queried continuously -> always read. vapor / cloud / fog are render-
	# only + GPU-resident (they don't feed the next step), so the caller throttles their readback; unread
	# fields are simply omitted and the caller keeps its previous (slightly stale) CPU copy.
	var out: Dictionary = {
		"temp": download(live_buffer("temp", _parity)),
		"water": download(live_buffer("water", _parity)),
		"sediment": download(live_buffer("sediment", _parity)),
		"fire": download(live_buffer("fire", _parity)),
		"fuel": download(_buf_fuel),
		# O₂/CO₂ ping-pong: their LIVE buffer holds the post-transport (diffuse/advect/sky) state this frame.
		"o2": download(live_buffer("o2", _parity)),
		"co2": download(live_buffer("co2", _parity)),
		# charge (BREAKDOWN tail needs it fresh for bolts) + detritus (deposited + decomposed) round-trip every frame.
		"charge": download(_buf_charge),
		"scent": download(live_buffer("scent", _parity)),
		"fert": download(live_buffer("fert", _parity)),
		"detritus": download(_buf_detritus),
	}
	# shock + lava are GPU-resident; the CPU writes them only on a rare emit / disaster, so the caller dirty-gates
	# their readback (a skipped frame keeps the stale CPU copy — no full-grid download; lava round-trips while venting).
	if read_shock:
		out["shock"] = download(live_buffer("shock", _parity))
	if read_lava:
		out["lava"] = download(live_buffer("lava", _parity))
	# READ-ONLY / render-only channels (CPU never writes them; GPU is authoritative): airborne dust, per-cell wind
	# velocity, fungus density. Read on the render cadence (they evolve resident between reads) — cuts ~5 downloads
	# on 2 of every 3 frames; the caller keeps its previous (slightly stale) CPU copy on the skipped frames.
	if read_render:
		out["dust"] = download(live_buffer("dust", _parity))
		out["vel_x"] = download(_buf_vel_x)
		out["vel_y"] = download(_buf_vel_y)
		out["vel_z"] = download(_buf_vel_z)
		out["fungus"] = download(live_buffer("fungus", _parity))
	# Geological-tail channels (erosion suspended sediment + snowpack depth) — GPU-evolved this frame; read
	# back for the CPU tails (SDF carve/freeze/thaw) + diagnostics. Sediment/lava/temp/water round-trip above.
	if _geo != null:
		out["susp"] = _geo.download_susp(self)
		out["snow"] = _geo.download_snow(self)
	if read_vapor:
		out["vapor"] = download(live_buffer("vapor", _parity))
	if read_cloud:
		out["cloud"] = download(live_buffer("cloud", _parity))
	if read_fog:
		out["fog"] = download(live_buffer("fog", _parity))
	return out


## Read back the resident per-cell air pressure (PASS A output). Off the field's hot path — used by the wind
## parity harness to assert PASS A parity. Call after end_frame.
func read_pressure() -> PackedFloat32Array:
	if _rd == null:
		return PackedFloat32Array()
	return download(_buf_pressure)


# --- OLD per-call API (BENCHMARK BASELINE ONLY — do NOT use on the hot path) ------------------------
# Each does a full upload -> dispatch -> submit -> sync -> readback, i.e. a GPU->CPU stall EVERY call.
# Kept so the micro-benchmark can compare this pattern against the resident begin/step/end path. They
# reuse the *_a -> *_b buffers via uniform-set index 0. NOTE: step_heat_conduction covers ONLY the
# conduction pass (the original narrow port) — the resident step() runs the FULL heat chain.

## OLD: one 6-neighbour heat CONDUCTION pass with per-call upload + readback. Baseline only.
func step_heat_conduction(temp: PackedFloat32Array, solid: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_temp_a, temp)

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set[0], 0)
	_rd.compute_list_set_push_constant(cl, Push.heat_pc(self), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_temp_b)


## OLD: one water CA step with per-call upload (incl. solid/static) + readback. Baseline only.
func flow_water(water: PackedFloat32Array, solid: PackedByteArray, static_cells: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_water_a, water)
	upload(_buf_solid, _bytes_to_floats(solid))
	upload(_buf_static, _bytes_to_floats(static_cells))

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[0], 0)
	_rd.compute_list_set_push_constant(cl, Push.water_pc(self, 0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[0], 0)
	_rd.compute_list_set_push_constant(cl, Push.water_pc(self, 1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_water_b)
