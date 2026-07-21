class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D — the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).
##
## The 2.5D field stored one column per XZ cell (a surface height + material *depths*). That could not
## represent caves: water can't pool in a cavern, lava can't drain into a tube, a plume can't rise a
## shaft. This field stores a real 3D volume — a temperature + per-material amount for every (x,y,z)
## cell — so all of that EMERGES from local rules that now include the Y axis.
##
## DENSE (not sparse bricks): at the sim's 5-unit resolution the whole volume is ~0.9M cells × a few
## float layers ≈ ~20 MB, so a flat 3D array is the simplest thing that works. Solid rock cells (from
## the terrain SDF via is_solid) hold no fluid and are skipped; an active-cell list keeps the CPU
## oracle cheap without brick machinery. The GPU kernels become a 3D dispatch over the same arrays.
##
## Index layout: idx = (iy * _dim_z + iz) * _dim_x + ix  (X contiguous, then Z, then Y). World position
## of a cell centre = _origin + Vector3(ix, iy, iz) * _cell_size.
## (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")
const MineralStampScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MineralStamp3D.gd")

# --- Water CA tuning (finite-volume cellular water: fall, pressurise, spread — mass-conserving and
# stable, and it fills sealed caverns bottom-up + supports pressure so water finds its level). Adapted
# from the classic 2D "finite water cells" scheme, generalised to 3D (down, up-if-compressed, 4 lateral).
const MAX_MASS: float = 1.0               # a cell is "full" at this water mass
const MAX_COMPRESS: float = 0.02          # extra mass a cell can hold per cell of water stacked above it
const MIN_MASS: float = 0.0001            # below this a cell is considered dry
const MAX_FLOW: float = 1.0               # max mass moved out of a cell per step (stability cap)
const MIN_FLOW: float = 0.01              # ignore dribbles smaller than this
const LATERAL_FRACTION: float = 0.5      # share of the level-out flow sent to each lateral neighbour

# --- Grid state -------------------------------------------------------------
var _terrain = null
var _cell_size: float = 5.0
var _origin: Vector3 = Vector3.ZERO       # world position of cell (0,0,0) centre
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0

var _solid: PackedByteArray = PackedByteArray()          # 1 = rock (holds no fluid), 0 = void (air/water)
var _water: PackedFloat32Array = PackedFloat32Array()    # water mass per cell (can exceed 1 under pressure)
var _wnext: PackedFloat32Array = PackedFloat32Array()    # double buffer for the water step
# 1 = calm STATIC sea: seeded once below sea level and left at rest — NOT stepped and NOT meshed (the
# GPU ocean plane draws it). Only DYNAMIC water (springs, rivers, cave pools, splashes) is simulated and
# rendered, so the cost tracks the active water, not the whole seabed. Dynamic water that flows into a
# static cell is absorbed (drains into the sea). This is what keeps the dense 3D field cheap.
var _static: PackedByteArray = PackedByteArray()

# --- Shared 3D field state used by the concern modules (heat / atmosphere / lava). Every cell (rock OR
# void) carries a temperature; the atmosphere layers + lava are per-cell amounts like water. The modules
# reach into these arrays through the field (`_f`), 3D-generalising the 2.5D MaterialHeat/Atmosphere/
# Liquid. INITIAL_TEMP seeds a mild ground so nothing freezes before the field settles.
const INITIAL_TEMP: float = 15.0
# Geothermal core: the innermost CORE_LAYERS radial shells are pinned hot each step (a boundary condition,
# NOT an actor injection). Conduction (ThermalPass) carries that heat outward → a radial geothermal gradient
# emerges. add_magma_source arms it (records the pin temperature). Sphere-only.
const CORE_LAYERS: int = 2
# Ambient atmospheric oxygen every OPEN cell is seeded to (LAMaterialGas3D relaxes surface cells back toward
# it; combustion draws it down). MUST match LAMaterialGas3D.O2_AMBIENT.
const O2_AMBIENT: float = 1.0
# Ambient atmospheric humidity every OPEN cell is seeded to — the starting moisture the terminator condenses
# into cloud/fog on the cold (night) side. Evaporation from the static field sea replenishes it.
const VAPOR_AMBIENT: float = 0.3
# Frozen H₂O (snowpack/ice) — the third phase of the ONE conserved water substance (liquid `_water`, airborne
# `_moisture`, frozen `_snow`). GPU-owned: the snowice deposition kernel + freeze/melt reaction records (R21/R22)
# grow and thaw it; read back for queries/telemetry only. SNOW_PRESENT = depth that counts a cell snow-covered;
# ICE_DEPTH = a thick pack that reads as glacial ice (the deep end of the same channel — no separate ice buffer).
const SNOW_PRESENT: float = 0.01
const ICE_DEPTH: float = 0.5
# Saturation curve sat(T) = SAT_BASE * exp(SAT_TEMP_GAIN * (T - EVAP_TEMP_REF)) — the dewpoint the unified
# `moisture` channel is read against. cloud/fog/vapor are DERIVED from moisture vs sat(T), never stored;
# these MUST match the kernel constants (atmos_evap/atmos_precip _sphere3d.glsl). FOG_MAX_TEMP splits the
# cool near-ground condensate (fog) from cloud aloft; CONDENSE_COVER_MIN is the density counted as cover.
const SAT_BASE: float = 0.06
const SAT_TEMP_GAIN: float = 0.055
const EVAP_TEMP_REF: float = 22.0
const FOG_MAX_TEMP: float = 12.0
const CONDENSE_COVER_MIN: float = 0.05
const RAIN_MASS_THRESHOLD: float = 0.42   # matches atmos_precip_sphere3d; aquifer springs supply land water so less rain needed
# Scent channel indices — sourced from the CORE const LAScentChannels (creatures/ScentChannels.gd) so the
# field (writer) and the creature senses/cognition (reader, in the core library) can never drift. The field
# re-exports them as LAMaterialField3D.SCENT_* for the game-side material passes that reference them here.
const SCENT_PREY: int = LAScentChannels.SCENT_PREY
const SCENT_PREDATOR: int = LAScentChannels.SCENT_PREDATOR
const SCENT_BLOOD: int = LAScentChannels.SCENT_BLOOD
const SCENT_FOOD: int = LAScentChannels.SCENT_FOOD
const SCENT_ALARM: int = LAScentChannels.SCENT_ALARM
const SCENT_CHANNELS: int = LAScentChannels.SCENT_CHANNELS
var _temp: PackedFloat32Array = PackedFloat32Array()     # temperature °C per cell (rock + void)
# ONE conserved atmospheric-water channel: total water suspended in a cell's air (Phase 2a — collapses the
# old vapor/cloud/fog trio). vapor = min(moisture, sat(T)); condensed = max(0, moisture − sat(T)); the
# condensed part reads as fog (cool + near ground) or cloud (else) — all DERIVED, nothing else stores it.
var _moisture: PackedFloat32Array = PackedFloat32Array()
# Frozen H₂O per cell (snowpack depth) — the SAME conserved substance as _water/_moisture, just the cold phase.
# GPU-owned (never re-uploaded); read back each frame for snow_cell_count/ice_cell_count/snow_depth_at + h2o_total.
var _snow: PackedFloat32Array = PackedFloat32Array()
# Fractional BEDROCK mineral mass per cell (Stage B). `solid` is DERIVED from it on the GPU (solid iff >= 0.5).
# GPU-owned + GPU-evolved (M5/M6 records); the CPU edits it only on add_lava (dirty-gated upload).
var _rock_fill: PackedFloat32Array = PackedFloat32Array()
var _lava: PackedFloat32Array = PackedFloat32Array()     # lava mass per cell (a hot, viscous liquid)
# --- Emergent FIRE / COMBUSTION (LAMaterialCombustion3D): a FUEL channel (flammable vegetation mass seeded
# on grassy surface cells + under plant/tree actors) and a FIRE channel (burning intensity, 0 = not burning).
# Flammable fuel ignites when its cell reaches ignite temp (lava/lightning/meteor/spreading front), burns —
# injecting heat + consuming fuel — spreads to neighbours on HEAT + the WIND field (downwind), and leaves ash.
var _fuel: PackedFloat32Array = PackedFloat32Array()     # flammable fuel mass per cell (vegetation)
var _fire: PackedFloat32Array = PackedFloat32Array()     # burning intensity per cell (0 = not burning)
# --- Emergent ATMOSPHERIC OXYGEN (LAMaterialGas3D): a per-cell O₂ level, seeded to O2_AMBIENT in every OPEN
# cell and replenished from the sky only at each column's exposed surface. It diffuses/advects on the wind;
# combustion CONSUMES it and can't burn below O2_MIN, so fire suffocates in sealed caves + roars where wind
# replenishes O₂ — emergent, no per-case code. Field-resident so the fire kernel can read/consume it on-GPU.
var _o2: PackedFloat32Array = PackedFloat32Array()       # atmospheric oxygen level per cell (1.0 = ambient)
# --- Emergent CARBON DIOXIDE (LAMaterialGas3D, second channel): a per-cell CO₂ level seeded to a trace ~0.
# Combustion (fuel + O₂ → CO₂ + ash + heat) and decay EMIT it; plants FIX it in daylight (photosynthesis →
# O₂ + biomass), closing the carbon/oxygen loop. It diffuses/advects on the wind like O₂ but is DENSER than
# air, so a gentle downward buoyancy makes it settle into hollows/valleys (emergent suffocation pockets); the
# sky surface vents it to the atmosphere. Field-resident so the fire kernel can EMIT it on-GPU (like O₂).
var _co2: PackedFloat32Array = PackedFloat32Array()      # atmospheric CO₂ level per cell (0 = clean air)
# --- Emergent DECOMPOSER loop (LAMaterialFungus3D): dead organic matter (DETRITUS) deposited by rotting
# carcasses + wildfire ash is colonised by FUNGUS, which rots it back into CO₂ + soil fertility while drawing
# O₂ (aerobic). Closes the carbon/nutrient loop (death→soil→plant). Seeded ~0; only exists where a source made it.
# --- SOIL WATER / water table (LASoilPass / soil_sphere3d): water held in the top GROUND (solid) cell layer.
# The reservoir that lets land water persist — surface water infiltrates in, the ground releases it slowly as
# baseflow (perennial rivers) + saturation overflow. GPU-owned; read back for soil_at()/soil_total() + the
# conserved h2o ledger (infiltrated water lives here, NOT in _water, so it must be counted). The SAME conserved
# H₂O substance as _water/_moisture/_snow, just the subsurface phase.
var _soil: PackedFloat32Array = PackedFloat32Array()     # water stored in the ground per cell (0 = bone dry)
var _detritus: PackedFloat32Array = PackedFloat32Array() # dead decomposable organic matter per cell (0 = none)
var _fungus: PackedFloat32Array = PackedFloat32Array()   # fungal biomass density per cell (0 = none; high = mushrooms)
# Soil FERTILITY per cell — the decomposer loop's output (detritus → fungus → CO₂ + fertility). GPU-owned PAIR
# channel (scent_fert blur/leach + fungus_fert deposit); read back each frame for fertility_at/fertility_peak.
var _fert: PackedFloat32Array = PackedFloat32Array()     # soil nutrient density per cell (0 = barren)
# --- Emergent LIVING BIOMASS (MaterialReactions3D R19/R20 — the plant carbon-fix leg dissolved into the field).
# GPU-produced/consumed ONLY: photosynthesis grows it at sky-exposed surface cells (CO₂ + warmth/light → biomass
# + O₂), respiration/decay oxidizes it back (biomass + O₂ → CO₂ + detritus). Seeded 0; a pure GPU channel that
# reads back for queries/telemetry. Vegetation now EMERGES from the chemistry, not just from plant actor nodes.
var _biomass: PackedFloat32Array = PackedFloat32Array()  # living plant matter density per cell (0 = none)
# --- Emergent 3D wind (LAMaterialWind3D): a per-cell air PRESSURE + 3D VELOCITY field replacing the old
# single global scalar wind. Pressure falls out of temperature (warm=low), velocity accelerates down the
# gradient and deflects off rock, so funneling/fronts/highs-lows EMERGE. Read via wind_at()/wind3_at().
var _pressure: PackedFloat32Array = PackedFloat32Array() # air pressure per cell (derived from temperature)
var _vel_x: PackedFloat32Array = PackedFloat32Array()    # wind velocity X per cell (world +X)
var _vel_y: PackedFloat32Array = PackedFloat32Array()    # wind velocity Y per cell (world +Y, up)
var _vel_z: PackedFloat32Array = PackedFloat32Array()    # wind velocity Z per cell (world +Z)
var _sediment: PackedFloat32Array = PackedFloat32Array() # loose granular mass per cell (landslide slump)
var _susp: PackedFloat32Array = PackedFloat32Array()     # waterborne suspended sediment (erosion pickup → settle); mineral phase read back for the ledger
# --- Emergent ELECTRIFICATION (LAMaterialCharge3D) + airborne DUST (LAMaterialDust3D). Field-resident so the
# GPU backend can own their per-cell compute (charge_accum3d / dust_*3d kernels) and round-trip them each
# frame like fire/fuel/sediment; the CPU modules reach into `_f._charge` / `_f._dust` (the CPU-oracle path).
var _charge: PackedFloat32Array = PackedFloat32Array()   # electrification charge per cell (updraft × supercooled cloud)
var _dust: PackedFloat32Array = PackedFloat32Array()     # airborne dust density per cell (wind-lofted sand storm)
# Seismic / sound SHOCK amplitude per cell — a propagating pressure wave (GPU shock_sphere3d radiates it).
var _shock: PackedFloat32Array = PackedFloat32Array()
# Five-plane SCENT density (SCENT_CHANNELS * _cell_count, plane-major: channel*_cell_count + cell). Prey/
# predator/blood/food/alarm chemical trails the GPU scent kernel diffuses + advects on the wind each step.
var _scent: PackedFloat32Array = PackedFloat32Array()
var _sun_light = null                                    # DirectionalLight3D — solar forcing (top cells)

# CPU-ORACLE CONCERN MODULES RETIRED. The cubed-sphere *_sphere3d GLSL kernels (MaterialSphereGPU3D + its
# sphere_passes) are the sole implementation now; the old per-cell CPU sims (heat/atmosphere/lava/wind/slump/
# combustion/scent/gas/fungus/magma/erosion/snowice/dust/charge/shock/water) and the box GPU driver / box
# render + heat-texture adapters were deleted. The write/read facades below return safe defaults for any
# channel not yet wired through the sphere readback.
var _ecology = null                                      # LAEcologyService back-ref (ash regrowth / actor coupling)
const SphereGPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialSphereGPU3D.gd")
const QueriesScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldQueries3D.gd")
const InjectScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldInject3D.gd")
const SphereStepScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldSphereStep3D.gd")
const BoxStepScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldBoxStep3D.gd")
const SurfaceSeedScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialSurfaceSeed3D.gd")
const CoverBakerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/CoverTextureBaker.gd")
var _cover_baker = null                                  # LACoverTextureBaker — bakes the render cover texture
var _gpu = null                                          # LAMaterialSphereGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false
var _core_temp: float = 0.0                              # geothermal core pin temperature (0 = disarmed)
var _core_cells: PackedInt32Array = PackedInt32Array()  # static innermost-shell cell indices (built once)
# Read-only query accessors + the write-side injection facade (factored out; see those files).
var _queries = null                                      # LAMaterialFieldQueries3D
var _inject = null                                       # LAMaterialFieldInject3D (write-side injection + FX)
var _stamp = null                                        # LAMineralStamp3D — Stage C rock_fill->SDF growth stamp
var _sphere_step = null                                  # LAMaterialFieldSphereStep3D — cubed-sphere per-frame step loop
var _box_step = null                                     # LAMaterialFieldBoxStep3D — box-mode CPU thermal step (setup_dims)
var _surface_seed = null                                 # LAMaterialSurfaceSeed3D — ground-surface fuel + soil detritus seed/refill
# Substrate-foundation primitive modules (the field only delegates; all logic lives in these). Seams the
# per-actor dissolution agents fill: shock (Earthquake/Meteor), charge→bolt (Thunderstorm), ejecta (bombs/debris).
var _shock_mod = null                                    # LAMaterialShock3D — shock channel + emit/readback
var _charge_mod = null                                   # LAMaterialCharge3D — charge readback + breakdown→bolt
var _scent_mod = null                                    # LAMaterialScent3D — 5-plane scent channel + deposit/readback
var _ejecta = null                                       # LAMaterialEjecta3D — momentum/ejecta parcels (Node3D child)
var _pending_lightning_cb: Callable = Callable()         # lightning visual callback (registered pre-activate)
const ShockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialShock3D.gd")
const ScentScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialScent3D.gd")
const ChargeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCharge3D.gd")
const EjectaScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialEjecta3D.gd")


## Wire the real scene sun (DirectionalLight3D); the heat module reads its energy + angle for solar input.
func set_sun(light) -> void:
	_sun_light = light


var sea_level: float = 0.0
var _half_extent: float = 0.0

# --- Frame loop + rendering -------------------------------------------------
const STEP_HZ: float = 10.0
const STEP_DT: float = 1.0 / STEP_HZ
const MAX_STEPS_PER_FRAME: int = 2
const RENDER_MIN: float = 0.08            # min water mass in a cell for its top face to render
const SEA_WAVE_EPS: float = 0.6           # calm-sea top faces within this of sea_level are left to the ocean plane
var _step_accum: float = 0.0
var _ready_sim: bool = false
# --- Per-frame CPU-cost throttles (the field is CPU-bound; these cut redundant full-grid work while
# preserving behavior). Each is a "cadence" counter advanced once per ACTIVE physics frame (a frame that
# ran >=1 sim step, i.e. ~STEP_HZ). The throttled work touches only slow-changing / render-only state, so
# staling it a couple of frames is imperceptible; the authoritative sim state is untouched.
const HEAT_TEX_EVERY: int = 3            # terrain-glow heat texture refresh cadence (full-grid column scan)
const SLOW_READ_EVERY: int = 3           # render-only GPU readback cadence for vapor/cloud/fog
var _heat_tex_tick: int = 0
var _slow_read_tick: int = 0
# Vapor is re-uploaded each frame ONLY to fold CPU-side injections (storm add_vapor); when nothing injected
# it lives fully resident on the GPU (like cloud/fog), so we skip both its upload AND its readback.
var _vapor_dirty: bool = false
# LAVA is GPU-owned + GPU-evolved (the flow CA runs on-device); the CPU edits it only on a disaster/volcano
# (add_lava, or the magma tail's deep-source feed/bore). Its upload+readback are DIRTY-GATED TOGETHER: uploaded
# only when a CPU edit dirtied it (else it stays resident — re-uploading a stale copy would clobber the GPU's
# flow), and read back only on the slow cadence OR the frame the edit round-trips. With no active volcano it
# neither uploads nor downloads on clean frames (a full-grid GPU->CPU download saved); while a volcano vents the
# magma tail dirties it every frame so it round-trips correctly. SHOCK is GPU-authoritative too (only impact
# emits write it on the CPU), so its UPLOAD is dirty-gated; its readback is cadenced (camera shake tolerates a
# 1-in-3-stale amplitude). Charge/detritus were tried here too but reverted to every-frame: charge's bolt tail
# needs fresh charge each frame, and detritus is continuous-evolution + continuous-deposit (see the upload block).
var _lava_dirty: bool = false
var _rock_fill_dirty: bool = false       # add_lava debited bedrock on the CPU → re-upload rock_fill this step
var _shock_dirty: bool = false           # emit_shock seeded shock on the CPU → re-upload shock this step
var _scent_dirty: bool = false           # deposit() seeded scent on the CPU → re-upload the 5-plane scent this step
var _charge_dirty: bool = false          # add_charge seeded charge on the CPU → re-upload charge this step
var _charge_woke: bool = false           # a charge injection woke the breakdown scan (stimulus = compute bubble)
var _fuel_dirty: bool = false            # fuel seed/refill edited the CPU channel → re-upload fuel this step
var _detritus_seed_dirty: bool = false   # one-shot: initial soil detritus seeded → upload once before the first step
# Lazy solidity sampling: the field is created before the terrain has finished streaming, so it samples
# rock/void a budget of columns per frame and self-activates (seed sea + build modules) once complete —
# exactly how the old field lazily sampled heights. No blocking, no external init calls.
const SAMPLE_COLS_PER_FRAME: int = 700
var _sampling_done: bool = false
var _sample_cursor: int = 0
# Persistent water sources (springs) injected each step: [{pos, rate}].
var _sources: Array = []


# --- Setup ------------------------------------------------------------------

## Sample rock/void for every cell from the terrain SDF (is_solid). Eager version — fine at setup for
## the dense grid; a budgeted lazy variant can replace it once wired into the frame loop. Skips the
## per-cell query for cells clearly in open air above the column's surface (cheap win).
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	if _sphere != null:
		# Cubed-sphere: the authoritative solid mask is filled radially per linear cell (_sample_solidity_sphere,
		# run on the first sphere step). The box XZ-column sweep below is meaningless here — skip it.
		return
	var has_surf: bool = _terrain.has_method("surface_height")
	for iz in range(_dim_z):
		for ix in range(_dim_x):
			var wx: float = _origin.x + float(ix) * _cell_size
			var wz: float = _origin.z + float(iz) * _cell_size
			var surf: float = _terrain.surface_height(wx, wz) if has_surf else NAN
			for iy in range(_dim_y):
				var wy: float = _origin.y + float(iy) * _cell_size
				var i: int = _idx(ix, iy, iz)
				# Well above the surface => open air, no need to query (also handles NAN columns as air).
				if not is_nan(surf) and wy > surf + _cell_size:
					_solid[i] = 0
					continue
				_solid[i] = 1 if _terrain.is_solid(Vector3(wx, wy, wz)) else 0


# --- Setup ------------------------------------------------------------------

# Cubed-sphere substrate (Phase B). When _sphere != null the field is a spherical planet: cells are a flat
# array of length surf_count*depth gathered via the SphereGrid's 6-neighbour+radial table (down = inward-radial
# neighbour). The box (_dim_*) path is untouched when _sphere == null. See sphere/SphereGrid.gd.
var _sphere: RefCounted = null

## True when the field is laid out on a cubed-sphere planet rather than an origin box.
func is_sphere() -> bool:
	return _sphere != null

## The SphereGrid backing this field (null in box mode).
func sphere_grid() -> RefCounted:
	return _sphere

## CUBED-SPHERE setup (Phase B): lay the field over a LASphereGrid instead of a box. Allocates every channel
## as a flat array of length `grid.cell_count` (cell = surf*depth + r). Geometry (world↔cell, cell_world_pos,
## radial, neighbours) routes through the grid; the box path is unaffected.
func setup_sphere(grid: RefCounted, terrain = null) -> void:
	_sphere = grid
	if terrain != null:
		_terrain = terrain      # sphere path's terrain wiring (box uses setup()); needed to activate + sample solidity
	_cell_size = maxf(0.5, grid.cell_size)
	_origin = grid.center
	_cell_count = grid.cell_count
	# Keep _dim_* nominally sane (some diagnostics read them); real indexing goes through the grid.
	_dim_x = grid.surf_count
	_dim_y = grid.depth
	_dim_z = 1
	_alloc_channels()
	# Cubed-sphere per-frame step orchestration (begin/step/end + readback) lives in a focused module.
	_sphere_step = SphereStepScript.new()
	_sphere_step.setup(self)

## Explicit-dimension setup (used by tests / when the caller knows the volume directly).
func setup_dims(dim_x: int, dim_y: int, dim_z: int, cell_size: float, origin: Vector3) -> void:
	_sphere = null
	_dim_x = maxi(1, dim_x)
	_dim_y = maxi(1, dim_y)
	_dim_z = maxi(1, dim_z)
	_cell_size = maxf(0.5, cell_size)
	_origin = origin
	_cell_count = _dim_x * _dim_y * _dim_z
	_alloc_channels()
	# Box mode never runs activate() (that is the cubed-sphere GPU path), so wire the injection facade here so
	# add_heat/add_vapor work — it edits the CPU channel arrays directly (box add_heat degrades to the single
	# world_to_cell). Without this _inject is null and add_heat silently no-ops.
	_inject = InjectScript.new()
	_inject.setup(self)
	# Box mode has no cubed-sphere GPU kernels: a small CPU thermal stepper drives the volume so injected heat
	# diffuses + rises (the library box-field sandbox). New module + one-line delegation from _physics_process.
	_box_step = BoxStepScript.new()
	_box_step.setup(self)

## Allocate + seed every per-cell channel for the current `_cell_count`. Shared by setup_dims (box) and
## setup_sphere (cubed-sphere) — both set _cell_count first, then call this.
func _alloc_channels() -> void:
	_solid = PackedByteArray()
	_solid.resize(_cell_count)
	_water = PackedFloat32Array()
	_water.resize(_cell_count)
	_wnext = PackedFloat32Array()
	_wnext.resize(_cell_count)
	_static = PackedByteArray()
	_static.resize(_cell_count)
	_temp = PackedFloat32Array()
	_temp.resize(_cell_count)
	_temp.fill(INITIAL_TEMP)
	_moisture = PackedFloat32Array()
	_moisture.resize(_cell_count)
	_moisture.fill(VAPOR_AMBIENT)
	_lava = PackedFloat32Array()
	_lava.resize(_cell_count)
	# Soil water reservoir (water table): starts BONE DRY (0) everywhere; rain/rivers wet it over the run.
	_soil = PackedFloat32Array()
	_soil.resize(_cell_count)
	# Bedrock mineral fraction: seeded from the solid mask on activate (mirrors _solid), GPU-owned thereafter.
	_rock_fill = PackedFloat32Array()
	_rock_fill.resize(_cell_count)
	_fuel = PackedFloat32Array()
	_fuel.resize(_cell_count)
	_fire = PackedFloat32Array()
	_fire.resize(_cell_count)
	# Oxygen starts at ambient in every cell (solid cells are ignored by the gas/fire loops); the sky
	# exchange keeps open surface cells topped up, combustion draws burning cells down.
	_o2 = PackedFloat32Array()
	_o2.resize(_cell_count)
	_o2.fill(O2_AMBIENT)
	# CO₂ starts at a clean-air trace of 0; combustion/decay raise it, plants + the sky vent draw it back down.
	_co2 = PackedFloat32Array()
	_co2.resize(_cell_count)
	# Detritus + fungus start empty; carcasses/ash deposit detritus, fungus grows on it (decomposer loop).
	_detritus = PackedFloat32Array()
	_detritus.resize(_cell_count)
	_fungus = PackedFloat32Array()
	_fungus.resize(_cell_count)
	# Soil fertility (decomposer output) starts barren; the GPU decomposer grows it where detritus rots.
	_fert = PackedFloat32Array()
	_fert.resize(_cell_count)
	# Biomass starts empty; photosynthesis grows it on the GPU where CO₂ + warmth + sky-exposed surface meet.
	_biomass = PackedFloat32Array()
	_biomass.resize(_cell_count)
	_pressure = PackedFloat32Array()
	_pressure.resize(_cell_count)
	_vel_x = PackedFloat32Array()
	_vel_x.resize(_cell_count)
	_vel_y = PackedFloat32Array()
	_vel_y.resize(_cell_count)
	_vel_z = PackedFloat32Array()
	_vel_z.resize(_cell_count)
	_sediment = PackedFloat32Array()
	_sediment.resize(_cell_count)
	_charge = PackedFloat32Array()
	_charge.resize(_cell_count)
	_dust = PackedFloat32Array()
	_dust.resize(_cell_count)
	_shock = PackedFloat32Array()
	_shock.resize(_cell_count)
	# Five scent planes packed into one flat array (plane-major): SCENT_CHANNELS * _cell_count.
	_scent = PackedFloat32Array()
	_scent.resize(SCENT_CHANNELS * _cell_count)
	# Read-only query accessors bind to this field now; the arrays they read exist from here on.
	_queries = QueriesScript.new()
	_queries.setup(self)


# --- Index helpers ----------------------------------------------------------

func _idx(ix: int, iy: int, iz: int) -> int:
	return (iy * _dim_z + iz) * _dim_x + ix


func _in_bounds(ix: int, iy: int, iz: int) -> bool:
	return ix >= 0 and ix < _dim_x and iy >= 0 and iy < _dim_y and iz >= 0 and iz < _dim_z


func cell_world_pos(ix: int, iy: int, iz: int) -> Vector3:
	return _origin + Vector3(float(ix), float(iy), float(iz)) * _cell_size


# --- Cubed-sphere linear accessors (Phase B; the world↔cell seam that replaces box _idx/_col_i) ----------

## World centre of a LINEAR cell index (cubed-sphere mode). Box mode: decode ix,iy,iz then cell_world_pos.
func cell_world_pos_linear(c: int) -> Vector3:
	if _sphere != null:
		return _sphere.cell_world_pos(c)
	var layer: int = _dim_x * _dim_z
	var iy: int = c / layer
	var rem: int = c - iy * layer
	var iz: int = rem / _dim_x
	var ix: int = rem - iz * _dim_x
	return cell_world_pos(ix, iy, iz)

## World position → linear cell index (cubed-sphere: nearest gnomonic face+surf+radial layer; -1 if outside
## the shell). Box mode: clamp each axis and combine. This is the substrate-agnostic world→cell used by queries.
func world_to_cell(world_pos: Vector3) -> int:
	if _sphere != null:
		return _sphere.world_to_cell(world_pos)
	var ix: int = clampi(int(round((world_pos.x - _origin.x) / _cell_size)), 0, _dim_x - 1)
	var iy: int = clampi(int(round((world_pos.y - _origin.y) / _cell_size)), 0, _dim_y - 1)
	var iz: int = clampi(int(round((world_pos.z - _origin.z) / _cell_size)), 0, _dim_z - 1)
	return _idx(ix, iy, iz)

## Outward radial unit at a linear cell (cubed-sphere). Box mode: +Y (the flat world's "up").
func cell_radial(c: int) -> Vector3:
	if _sphere != null:
		return _sphere.cell_radial(c)
	return Vector3.UP


# --- Authoring (tests + terrain sampling) -----------------------------------

func set_solid(ix: int, iy: int, iz: int, solid: bool) -> void:
	if _in_bounds(ix, iy, iz):
		_solid[_idx(ix, iy, iz)] = 1 if solid else 0


func is_cell_solid(ix: int, iy: int, iz: int) -> bool:
	if not _in_bounds(ix, iy, iz):
		return true                                     # out of bounds reads as wall
	return _solid[_idx(ix, iy, iz)] != 0


func add_water_cell(ix: int, iy: int, iz: int, amount: float) -> void:
	if not _in_bounds(ix, iy, iz):
		return
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return
	_water[i] = maxf(0.0, _water[i] + amount)


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	return _queries.water_at_cell(ix, iy, iz)


func total_water() -> float:
	return _queries.total_water()


# --- The 3D water CA --------------------------------------------------------

# Stable amount for the LOWER of two vertically-stacked water cells given their combined mass. Below
# MAX_MASS all the water sits in the lower cell; above that the excess is compressed upward, letting a
# tall column press down (pressure) so water in a connected cavern finds a common level.
func _stable_below(total_mass: float) -> float:
	if total_mass <= MAX_MASS:
		return total_mass
	if total_mass < 2.0 * MAX_MASS + MAX_COMPRESS:
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS)
	return (total_mass + MAX_COMPRESS) * 0.5


# --- World-space queries (delegated to _queries; the 2.5D-compatible API consumers call) --------

# Water presence at a true-3D world point (sphere-native): water in the point's own cell, or the sea/lake
# shell over the ground beneath it. The dead 2.5D column queries (column_surface_y / surface_y_at / depth_at)
# were removed with the box path — radial callers read terrain.surface_radius / sea_radius / is_submerged_at.
func is_water_at(pos: Vector3) -> bool:
	return _queries.is_water_at(pos)


# World-space WATER CURRENT (sweep) force at a point — downhill × depth × slope; ZERO in still/dry ground.
# The seam creatures (mass-scaled drag) and plants (uproot vs root strength) read to be swept by moving water.
func water_force_at(pos: Vector3) -> Vector3:
	return _queries.water_force_at(pos)


## Register a persistent spring: `rate` water mass per second injected at `pos` each step.
func add_source(pos: Vector3, rate: float) -> void:
	_sources.append({"pos": pos, "rate": rate})


# --- Live frame loop + fluid-surface rendering ------------------------------

## Begin simulating + rendering (called after setup + sample_solidity + seed_sea). Builds the render
## node and starts the throttled step in _physics_process.
func activate() -> void:
	# CPU-ORACLE MODULES RETIRED. The *_sphere3d GLSL kernels (run by MaterialSphereGPU3D + its sphere_passes)
	# ARE the implementation now — no CPU heat/atmosphere/lava/wind/slump/combustion/scent/gas/fungus/magma/
	# erosion/snowice/dust/charge/shock sims are instantiated or stepped. The field's query/inject facades
	# null-guard every one of these (`_x.foo() if _x != null else <default>`), so leaving them null makes the
	# not-yet-sphere-wired channels return safe defaults until their readback lands (fuller-readback step).
	# GPU-RESIDENT backend: persistent SSBOs, the whole heat+water step batched on-GPU, ONE readback per
	# frame (see MaterialGPU3D's frame API). Headless has no local RenderingDevice → CPU oracle.
	# Seed CPU bedrock fraction from the solid mask (GPU seeds its buffer identically): solid=1.0, void=0.0 —
	# keeps the CPU ledger valid before the first readback and matches the derived solid exactly (nothing melted).
	if _rock_fill.size() == _cell_count and _solid.size() == _cell_count:
		for c in _cell_count:
			_rock_fill[c] = 1.0 if _solid[c] != 0 else 0.0
	if is_sphere() and SphereGPUScript.available() and not OS.has_environment("LA_FORCE_CPU"):
		# Cubed-sphere planet: the sphere GPU driver runs the *_sphere3d kernels over the neighbour SSBO.
		_gpu = SphereGPUScript.new()
		_gpu.setup(self)
		_use_gpu = true
	_inject = InjectScript.new()
	_inject.setup(self)
	# Ground-surface substrate: seed baseline flammable fuel (so lightning/lava can ignite) + soil detritus (so the
	# decomposer→fertility loop bootstraps) on surface cells.
	_surface_seed = SurfaceSeedScript.new()
	_surface_seed.setup(self)
	_surface_seed.seed_initial()
	# Stage C: the sparse, event-driven rock_fill 0.5-crossing -> SDF terrain-growth stamp (idle until armed).
	_stamp = MineralStampScript.new()
	_stamp.setup(self)
	# Substrate-foundation primitives (thin delegates; the field only forwards to them).
	_shock_mod = ShockScript.new()
	_shock_mod.setup(self)
	_charge_mod = ChargeScript.new()
	_charge_mod.setup(self)
	if _pending_lightning_cb.is_valid():
		_charge_mod.set_visual(_pending_lightning_cb)
	_scent_mod = ScentScript.new()
	_scent_mod.setup(self)
	_ejecta = EjectaScript.new()
	_ejecta.setup(self)
	add_child(_ejecta)                            # Node3D: integrates ballistic parcels + owns the GPU ejecta particles
	_ready_sim = true


# --- Heat texture (terrain-glow source) — RETIRED with the box path; the cubed-sphere glows via the
# godot_voxel terrain shader + ocean shell, so these return null/zero (no XZ-column heat texture). ----

## The live terrain-glow texture (R = hottest °C per column). Null on the cubed-sphere.
func heat_texture() -> Texture2D:
	return null

func heat_world_min() -> Vector2:
	return Vector2.ZERO

func heat_world_size() -> Vector2:
	return Vector2.ZERO


## Sphere solid mask: sample the terrain SDF per cell (world pos from the grid). One-time at activation.
func _sample_solidity_sphere() -> void:
	for c in _cell_count:
		_solid[c] = 1 if _terrain.is_solid(cell_world_pos_linear(c)) else 0

## Seed the calm ocean into the FIELD water channel: every open cell at/below sea_radius becomes static water
## (mass 1, not simulated → no per-frame cost + it can't fall to the core under radial gravity). This is the
## evaporation SOURCE the water cycle was missing on the sphere — warm day-side sea evaporates → vapor →
## clouds → rain. (The visual sea is still the GPU ocean plane; this is the physics source, mirroring the box.)
func _seed_sphere_sea() -> void:
	if _sphere == null or _terrain == null or not _terrain.has_method("sea_radius"):
		return
	var sea_r: float = _terrain.sea_radius()
	if sea_r <= 0.0:
		return
	var sea_sq: float = sea_r * sea_r
	for c in _cell_count:
		if _solid[c] != 0:
			continue
		if (cell_world_pos_linear(c) - _origin).length_squared() <= sea_sq:
			_water[c] = 1.0
			_static[c] = 1

## The REGOLITH (aquifer) band: the top REGOLITH_CELLS solid shells of each column are PERMEABLE — groundwater
## lives + flows here; everything below is impermeable BEDROCK. This surface-following band is what lets the
## water table flow ridge→valley (through the rock) and DAYLIGHT as springs where it meets open ground, instead
## of the naive "all groundwater sinks to the core". Computed once from the solid mask (grid columns are
## contiguous: cell = surf_col*depth + r, r=depth-1 outermost). Also SEEDS an initial half-full water table so
## springs flow from the start (a planet has an existing aquifer; it then self-maintains via rain/snow recharge).
const REGOLITH_CELLS: int = 4
const INITIAL_TABLE_FRAC: float = 0.5     # regolith starts half-saturated (spring level 0.85); convergence tops valleys over
                                          # the spring gush level, so groundwater CONVERGENCE at valleys triggers springs)
const SOIL_CAPACITY: float = 0.6          # MUST match soil_sphere3d.glsl CAPACITY
var _regolith: PackedByteArray = PackedByteArray()

func _compute_regolith() -> void:
	if _sphere == null or _solid.size() != _cell_count:
		return
	_regolith = PackedByteArray()
	_regolith.resize(_cell_count)                          # 0 = bedrock/void, 1 = permeable regolith
	if _soil.size() != _cell_count:
		_soil = PackedFloat32Array()
		_soil.resize(_cell_count)
	var surf_count: int = int(_sphere.surf_count)
	var depth: int = int(_sphere.depth)
	var seed_soil: float = SOIL_CAPACITY * INITIAL_TABLE_FRAC
	for s in range(surf_count):
		var base: int = s * depth
		var surf_r: int = -1
		for r in range(depth - 1, -1, -1):                # find the outermost solid shell (the ground surface)
			if _solid[base + r] != 0:
				surf_r = r
				break
		if surf_r < 0:
			continue                                      # an all-open column (deep ocean over no floor) — no regolith
		var lo: int = maxi(0, surf_r - REGOLITH_CELLS + 1)
		for r in range(lo, surf_r + 1):
			if _solid[base + r] != 0:
				_regolith[base + r] = 1
				_soil[base + r] = seed_soil               # prime the water table


## The regolith permeability mask (1 = groundwater-bearing rock). Uploaded to the GPU soil pass.
func regolith_mask() -> PackedByteArray:
	return _regolith

## Release the GPU driver's local RenderingDevice while the tree is still up — freeing every RID cleanly so
## the device reports 0 leaked RIDs. (The `rc=134` MoltenVK `recursive_mutex` abort at NSApplication-terminate
## is separately avoided by the clean-quit path — `LAAppExit`/`LAProcess.exit_now`; see GODOT_BEST_PRACTICES.md → Error Log, 2026-07-09.)
## Covers both the box and sphere drivers.
func _exit_tree() -> void:
	if _gpu != null and _gpu.has_method("dispose"):
		_gpu.dispose()


func _physics_process(delta: float) -> void:
	if LAAblate.off("field"):
		return
	# The cubed-sphere is the SOLE substrate: one self-contained GPU step over the *_sphere3d kernels.
	# The fixed-step begin/step/end loop + readback scatter live in LAMaterialFieldSphereStep3D.
	# (The retired box grid + its CPU-oracle tails lived here; deleted with the sphere-only cleanup.)
	if is_sphere() and _sphere_step != null:
		_sphere_step.process(delta)
	elif not is_sphere() and _box_step != null:
		# Box mode (setup_dims): CPU thermal step so an origin-box volume heats/flows without a planet or GPU.
		_box_step.process(delta)


## Temperature °C at a true-3D world point (a mild default outside the shell). Sphere-native single read.
func temp_at(pos: Vector3) -> float:
	return _queries.temp_at(pos)


# --- Consumer-facing API (true-3D world-point reads) --------------------------

## True where the ground beneath a world point is below the sea shell (open salt ocean / a sea basin).
func is_ocean_at(pos: Vector3) -> bool:
	return _queries.is_ocean_at(pos)


## Salinity 0 (fresh inland water) .. brackish shallows .. 1 (deep salt ocean); NAN if dry.
func salinity_at(pos: Vector3) -> float:
	return _queries.salinity_at(pos)


# --- Atmosphere queries — all DERIVED from the one conserved `moisture` channel vs sat(T) (Phase 2a).
# cloud/fog/vapor are no longer stored; every reader below recomputes them instantaneously from _moisture +
# _temp. Signatures are unchanged so WeatherSystem/Thunderstorm/CloudLayer/RainLayer keep working.

## Saturation humidity at temperature `t` — the dewpoint moisture is read against. MUST match the kernel
## constants in atmos_evap/atmos_precip_sphere3d.glsl.
func _sat(t: float) -> float:
	return SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF))

## Suspended condensate (liquid/ice) at a linear cell = the moisture over saturation. 0 for solid/oob cells.
func _condensed_at(cell: int) -> float:
	if cell < 0 or cell >= _cell_count or _solid[cell] != 0:
		return 0.0
	return maxf(0.0, _moisture[cell] - _sat(_temp[cell]))

## Cloud density at a world XZ column (0 if unresolved). Cloud = the condensate that is NOT ground fog.
func cloud_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, cloud_base_y(), z))
	if c < 0:
		return 0.0
	return 0.0 if _temp[c] < FOG_MAX_TEMP else _condensed_at(c)

## Fog density at a world XZ column (0 if unresolved). Fog = cool near-ground condensate.
func fog_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0:
		return 0.0
	return _condensed_at(c) if _temp[c] < FOG_MAX_TEMP else 0.0

# Cached domain aggregates over the derived condensate. A full-grid scan (with an exp() per cell) would be
# far too costly to run per RENDER frame (VoxelSkyCycle/RainLayer poll cover every frame at ~150Hz); instead
# ONE pass recomputes all of them together and caches, invalidated only when a new moisture/temp field is
# read back (~10Hz). Big-O: one O(cells) pass per SIM step, not per query × per frame.
var _atmos_dirty: bool = true
var _cloud_cover_c: float = 0.0
var _fog_cover_c: float = 0.0
var _cloud_cells_c: int = 0
var _precip_c: float = 0.0
var _moisture_total_c: float = 0.0

## Recompute all condensate aggregates in a single grid pass. The fog/cloud split is a temperature proxy
## (cool, T<FOG_MAX_TEMP = fog; warmer = cloud) for the kernel's slot-0 near-ground test, which is not
## replicated on the CPU — these are report/visual metrics only.
func _refresh_atmos_aggregates() -> void:
	_atmos_dirty = false
	var cloud_n: int = 0
	var fog_n: int = 0
	var precip_n: int = 0
	var total: float = 0.0
	for i in range(_cell_count):
		if _solid[i] != 0:
			continue
		var aw: float = _moisture[i]
		total += aw
		var cond: float = aw - _sat(_temp[i])
		if cond <= 0.0:
			continue
		if cond > RAIN_MASS_THRESHOLD:
			precip_n += 1
		if cond >= CONDENSE_COVER_MIN:
			if _temp[i] < FOG_MAX_TEMP:
				fog_n += 1
			else:
				cloud_n += 1
	var inv: float = 1.0 / float(_cell_count) if _cell_count > 0 else 0.0
	_cloud_cells_c = cloud_n
	_cloud_cover_c = float(cloud_n) * inv
	_fog_cover_c = float(fog_n) * inv
	_precip_c = clampf(float(precip_n) * inv * 40.0, 0.0, 1.0)
	_moisture_total_c = total
	# Fold the render cover-texture bake into this same ~10Hz condensate pass (the water-particle renderer
	# samples it per particle). Cheap: one extra O(cell_count) reduction over the CPU readback we already have.
	if _sphere != null:
		_ensure_cover_baker()
		if _cover_baker != null:
			_cover_baker.bake(_moisture, _temp, _snow, _solid, _cell_count)


## Lazily build the cover-texture baker (sphere only). Callable before the first bake so the renderer can
## read the atmosphere band radii at setup.
func _ensure_cover_baker() -> void:
	if _cover_baker != null or _sphere == null:
		return
	var sea_r: float = 248.0
	if _terrain != null and _terrain.has_method("sea_radius"):
		sea_r = _terrain.sea_radius()
	_cover_baker = CoverBakerScript.new()
	_cover_baker.setup(_sphere, sea_r, FOG_MAX_TEMP, RAIN_MASS_THRESHOLD, SAT_BASE, SAT_TEMP_GAIN, EVAP_TEMP_REF)


## Read-only CLIMATE snapshot — the live per-cell moisture/temp/snow/solid readback the biome surface baker
## reduces into a terrain-colour texture (LABiomeShaderController owns the baking; the field just exposes its
## buffers). Thin facade accessor, no behaviour. Empty dict until the field is active. Returns the live arrays
## (not copies) — the baker only reads them, matching how the cover baker consumes the same buffers in-place.
func climate_snapshot() -> Dictionary:
	if _cell_count <= 0 or _moisture.size() != _cell_count or _temp.size() != _cell_count:
		return {}
	return {
		"moisture": _moisture, "temp": _temp, "snow": _snow,
		"solid": _solid, "static": _static, "cell_count": _cell_count,
	}


## The baked 6-layer RGBA cover texture (null until the first atmosphere refresh) — the water-particle
## renderer's field bridge. Plus the atmosphere shell radii it needs to place + classify particles.
func field_cover_texture() -> Texture2DArray:
	return _cover_baker.texture() if _cover_baker != null else null

func atmos_cloud_base_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.cloud_base_r() if _cover_baker != null else sea_level + 62.0

func atmos_fog_top_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.fog_top_r() if _cover_baker != null else sea_level + 16.0

func atmos_fog_lo_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.fog_lo_r() if _cover_baker != null else sea_level

func atmos_outer_r() -> float:
	_ensure_cover_baker()
	return _cover_baker.outer_r() if _cover_baker != null else 330.0

func avg_cloud_cover() -> float:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _cloud_cover_c

func avg_atmos_dust() -> float:
	return _queries.avg_atmos_dust()

func avg_fog_cover() -> float:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _fog_cover_c

## Domain precipitation proxy 0..1 — fraction of open cells whose condensate is over the rain threshold.
func precipitation() -> float:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _precip_c

## Total suspended atmospheric water mass (mass-conservation spot check; used by the SIM_REPORT).
func moisture_total() -> float:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _moisture_total_c

# The flat cloud/fog sheet projection (cloud_grid/fog_grid) was a box-era concept, dissolved with the
# CloudLayer sheets — the water-particle renderer samples the baked cover texture instead. cloud_base_y/
# fog_base_y survive as the near-ground radii the derived point queries (cloud_at/fog_at) sample at.
func cloud_base_y() -> float:
	return sea_level + 62.0

func fog_base_y() -> float:
	return sea_level + 6.0

## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(moisture, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _solid[c] != 0:
		return 0.0
	var s: float = _sat(_temp[c])
	if s <= 0.0:
		return 0.0
	return clampf(_moisture[c] / s, 0.0, 1.0)

## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's moisture would
## saturate (invert sat(T)). NAN if unresolved or bone dry.
func dewpoint_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _solid[c] != 0 or _moisture[c] <= 0.0:
		return NAN
	return EVAP_TEMP_REF + log(_moisture[c] / SAT_BASE) / SAT_TEMP_GAIN

## Prevailing (large-scale) wind input. The emergent wind now lives on the GPU; forward it to the driver.
func set_wind(w: Vector2) -> void:
	if _gpu != null and _gpu.has_method("set_prevailing"):
		_gpu.set_prevailing(w)

## Domain-average horizontal wind (ocean swell / HUD) — a coarse mean of the read-back GPU velocity field.
func wind() -> Vector2:
	return _queries.wind()

## LOCAL horizontal wind (world XZ) at a point — the emergent GPU velocity read back into `_vel_*`.
func wind_at(x: float, z: float) -> Vector2:
	return _queries.wind_at(x, z)

## Radial vorticity (air SPIN about local up) at a world point — storm actors track/scale off the emergent vortex.
func vorticity_at(pos: Vector3) -> float:
	return _queries.vorticity_at(pos)

## Vertical updraft (outward radial wind) at a world point — the convective lift a thunderstorm/tornado feeds on.
func updraft_at(pos: Vector3) -> float:
	return _queries.updraft_at(pos)

## Full LOCAL 3D wind velocity (a real force) — the emergent GPU velocity read back into `_vel_*`; loose mass
## (creatures/debris/sediment) reads this to be advected/flung by storms.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	return _queries.wind3_at(x, y, z)

## The cloud/fog grids project to (dim_x × dim_z) so CloudLayer's texture maps 1:1 with the 2.5D field.
func grid_dim() -> int:
	return _dim_x

func grid_half_extent() -> float:
	return _half_extent


# Heat + lava injection + diagnostics. Local injection (add_heat/add_vapor/add_charge) is REAL — it writes the
# sphere GPU field buffers via the injection module; the field only forwards. add_lava (a conserving move) stays.
## Raise the temperature at a world point (and within `radius`) — a meteor's molten spike, a fire's heat.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_heat(world_pos, amount, radius)

## Real CONSERVING lava source (rock unification Stage B). A volcano/vent erupts by converting bedrock into molten
## lava (`rock_fill -= a; lava += a`), so mineral_total() stays FLAT (phase move, not creation). GPU-authoritative
## → the edited CPU arrays re-upload next step (dirty-gated); the lava then flows/cools on-GPU (M5 re-accretes it).
func add_lava(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _rock_fill.size() != _cell_count or _lava.size() != _cell_count:
		return
	if _gpu != null: _gpu.request_channel("lava")   # an active vent → keep the lava readback hot
	var c: int = world_to_cell(world_pos)
	if c < 0 or c >= _cell_count:
		return
	# A vent sits on OPEN ground, so the erupting lava is bedrock melted from just BENEATH it: walk radially
	# inward (lower index = toward core within the same column) to the first bedrock cell and melt THAT to lava
	# (it rises via magma buoyancy). Conserving: rock_fill -= a; lava += a, capped by the bedrock present.
	var depth: int = _sphere.depth if _sphere != null else 1
	var base: int = c - (c % depth)               # radial index 0 of this surface column (the core-side cell)
	var cell: int = c
	while cell >= base and _rock_fill[cell] <= 0.0:
		cell -= 1
	if cell < base:
		return                                    # whole column void (no bedrock to erupt) — nothing to do
	var a: float = minf(amount, _rock_fill[cell])
	if a <= 0.0:
		return
	_rock_fill[cell] -= a
	_lava[cell] += a
	_lava_dirty = true
	_rock_fill_dirty = true
	if _stamp != null:
		_stamp.arm()                              # wake the SDF stamp — the erupted lava will cool + cross 0.5

## Inject airborne water vapor (humidity) at a world point (+`radius`) — a storm's moisture source. Real (module).
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_vapor(world_pos, amount, radius)

## Cool a volume (negative heat) — a storm's cold aloft. Thin helper over add_heat.
func add_cooling(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	add_heat(world_pos, -absf(amount), maxf(0.0, radius))

## Inject electrification charge at a world point (+`radius`) — an explicit charge seed. Real (module, dirty-gated).
func add_charge(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_charge(world_pos, amount, radius)

## Launch ejected matter (mass + heat) from a world point — the shared momentum/ejecta primitive (volcano
## bombs, meteor debris, geyser blasts). Arcs under radial gravity + re-deposits on landing. See the module.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _ejecta != null:
		_ejecta.eject(world_pos, mass, energy, dir_bias)

func lava_cell_count() -> int:
	return 0

func wet_cell_count() -> int:
	return _queries.wet_cell_count()


# --- Injection API (disasters/flood call these; bodies live in LAMaterialFieldInject3D) ------------

## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside).
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	if _inject != null:
		_inject.add_water_pooled(center, amount, radius)


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _inject != null:
		_inject.resample_terrain(world_pos, radius)


## Count of OPEN cells carrying derived condensate (moisture over saturation) at/above CONDENSE_COVER_MIN.
## Cached with the other atmosphere aggregates (recomputed once per field readback, not per call).
func cloud_cell_count(min_density: float = 0.05) -> int:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _cloud_cells_c


# --- Heat diagnostics -------------------------------------------------------

func peak_heat() -> float:
	return _queries.peak_heat()

func hot_cell_count(threshold: float = 60.0) -> int:
	return _queries.hot_cell_count(threshold)

func lava_peak() -> int:
	return lava_cell_count()


# --- Physical splash droplets (FX; body lives in LAMaterialFieldInject3D) ----
## A few short-lived rigidbody droplets flung from a world point — the splash accent disasters call.
func splash(world_pos: Vector3, strength: float) -> void:
	if _inject != null:
		_inject.splash(world_pos, strength)


# --- Ecology back-ref. Fire/combustion (ignite/is_burning/active_fire_count) AND granular landslides
# (disturb_terrain/slump_count) are now LIVE via their field modules — nothing here is stubbed anymore.
# _ecology backs fire ash regrowth + actor coupling. ---
func set_ecology(e) -> void:
	_ecology = e

## Shake a chunk of ground loose into LANDSLIDE sediment: carve the terrain SDF here into loose granular
## mass that then flows downhill to its angle of repose (crater rims slump inward, debris piles at the base)
## and re-solidifies where it settles. Emergent — one channel every disaster (meteor, volcano breach,
## earthquake) reuses via EcologyService.disturb_ground. Delegates all the granular math to LAMaterialSlump3D.
func disturb_terrain(world_pos: Vector3, radius: float, strength: float) -> void:
	pass

## Cells of loose sediment actively slumping — CPU slump oracle retired; safe default.
func slump_count() -> int:
	return 0

# --- Fire / combustion — CPU combustion oracle retired; safe defaults until the sphere fire readback lands. --

## Light the cell under a node on fire (disaster/scripted ignition). No-op until wired to the sphere driver.
func ignite(node) -> void:
	pass

## Is the cell under this node currently burning?
func is_burning(node) -> bool:
	return false

## Number of cells currently on fire (SMOKE_SUMMARY `fires`).
func active_fire_count() -> int:
	return 0


# --- Scent / waste / fertility — thin forwarders to LAMaterialScent3D (the 5-plane scent channel module).
# The field stays an extract-only facade: deposits seed a plane + set _scent_dirty (uploaded before the next
# GPU step), reads sample the plane the sphere driver read back. Channel indices (SCENT_PREY/…) live at top. --

## Drop feces/urine at a world point. Feces carries a FOOD/musk cue (predators track prey by dung); urine is a
## territorial musk that marks a PREY trail. Simple per-kind channel mapping — the scent kernel diffuses it.
func deposit_waste(world_pos: Vector3, creature, kind: String) -> void:
	if _scent_mod == null:
		return
	var channel: int = SCENT_FOOD if kind == "feces" else SCENT_PREY
	_scent_mod.deposit(world_pos, channel, 1.0)

## A fresh burst of BLOOD scent (a wound or a kill).
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	if _scent_mod != null:
		_scent_mod.deposit(world_pos, SCENT_BLOOD, amount)

## A carcass advertising FOOD (the decaying-corpse cue scavengers follow).
func deposit_food(world_pos: Vector3, amount: float) -> void:
	if _scent_mod != null:
		_scent_mod.deposit(world_pos, SCENT_FOOD, amount)

## Scent density of a channel (SCENT_PREY/PREDATOR/BLOOD/FOOD/ALARM) at a world point.
func scent_at(world_pos: Vector3, channel: int) -> float:
	return _scent_mod.scent_at(world_pos, channel) if _scent_mod != null else 0.0

## Normalized world direction UP a scent channel's gradient (predator tracking, prey avoidance).
func scent_gradient(world_pos: Vector3, channel: int) -> Vector3:
	return _scent_mod.scent_gradient(world_pos, channel) if _scent_mod != null else Vector3.ZERO

## Soil nutrient at a world point (plants grow faster on rich ground) — the read-back GPU fertility channel.
func fertility_at(world_pos: Vector3) -> float:
	return _queries.fertility_at(world_pos) if _queries != null else 0.0

## Columns carrying meaningful airborne scent (SMOKE_SUMMARY `scent_cells`).
func scent_cell_count() -> int:
	return _scent_mod.scent_cell_count() if _scent_mod != null else 0

## Peak soil nutrient (SMOKE_SUMMARY `fertility_peak`) — the read-back GPU fertility channel.
func fertility_peak() -> float:
	return _queries.fertility_peak() if _queries != null else 0.0


# --- Emergent-process forwarders (magma volcano / erosion / snow-ice / dust / charge lightning / shock).
# CPU oracles retired; these channels are not yet read back from the sphere GPU driver, so the emitters are
# no-ops and the diagnostics return safe defaults until their sphere readback lands.
func add_magma_source(world_pos: Vector3, temp: float, rate: float) -> void:
	# Sphere geothermal core: arm the innermost-radial-shell heat pin (world_pos/rate unused — the core is
	# the whole innermost shell, not a point). Conduction spreads it outward into a geothermal gradient.
	_core_temp = maxf(_core_temp, temp)

## Pin the innermost CORE_LAYERS radial shells to the geothermal temperature (cell layout: cell = surf*depth + r,
## so r = c % _dim_y; r < CORE_LAYERS is the core). Precomputes the static core-cell list once. Called each step
## before begin_frame so the upload carries it; conduction then propagates it up through the rock to the surface.
func _pin_core_heat() -> void:
	if _core_temp <= 0.0 or not is_sphere() or _dim_y <= 0:
		return
	if _core_cells.is_empty():
		for c in _cell_count:
			if c % _dim_y < CORE_LAYERS:
				_core_cells.append(c)
	for c in _core_cells:
		_temp[c] = _core_temp
func magma_cell_count() -> int:
	return 0
func magma_erupting() -> bool:
	return false
func erosion_cell_count() -> int:
	return 0
## Snow depth at a world point (frozen H₂O in the cell). 2.5D-style (x,z) calls have no radial point, so they
## return the safe default 0 (matching temp_at); a full 3D call (x,z,y) reads the real cell — three-d-always.
func snow_depth_at(pos: Vector3) -> float:
	if _snow.size() != _cell_count:
		return 0.0
	var c: int = world_to_cell(pos)
	return _snow[c] if c >= 0 else 0.0
## Open cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	if _snow.size() != _cell_count:
		return 0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] == 0 and _snow[c] > SNOW_PRESENT:
			n += 1
	return n
## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	if _snow.size() != _cell_count:
		return 0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] == 0 and _snow[c] >= ICE_DEPTH:
			n += 1
	return n
## Total frozen H₂O over the field (one leg of the conserved h2o_total).
func snow_total() -> float:
	if _snow.size() != _cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _cell_count:
		if _solid[c] == 0:
			sum += _snow[c]
	return sum
## Total dynamic liquid water over the field (excludes the static sea reservoir; one leg of h2o_total).
func water_total() -> float:
	if _water.size() != _cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _cell_count:
		if _solid[c] == 0 and _static[c] == 0:      # exclude the static sea reservoir (matches the docstring) —
			sum += _water[c]                        # else the infinite-reservoir cells inflate the conserved ledger
	return sum
## Total water stored in the SOIL (ground cells) — the subsurface leg of the conserved h2o budget. Infiltrated
## water lives here rather than in _water, so it must be counted or conservation would appear to leak.
func soil_total() -> float:
	if _soil.size() != _cell_count:
		return 0.0
	var sum: float = 0.0
	for c in _cell_count:
		if _solid[c] != 0:
			sum += _soil[c]
	return sum
## Conserved H₂O budget of the DYNAMIC system: liquid water + airborne moisture + frozen snow + SOIL water.
## Freeze/melt/deposition/evap/rain/infiltration are all pure transfers between these, so this stays BOUNDED
## (a slow static-sea source + rain-to-sea sink hold it steady) — the mass-conservation spot check for SIM_REPORT.
func h2o_total() -> float:
	return water_total() + moisture_total() + snow_total() + soil_total()
## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	if _snow.size() != _cell_count:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] == 0 and _snow[c] > SNOW_PRESENT:
			sum += _temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0
func dust_at(x: float, y: float, z: float) -> float:
	return 0.0
func dust_cell_count() -> int:
	return 0

# MINERAL conservation ledger (rock unification) lives in LAMaterialFieldQueries3D (`_queries.*_total()` etc.);
# report() reads it directly. ONE conserved mineral; mineral_total must stay BOUNDED (the unification's proof).
# Emergent atmospheric OXYGEN (LAMaterialGas3D): O₂ level at a point + depletion diagnostics.
func o2_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return _o2[c] if c >= 0 else O2_AMBIENT
	return O2_AMBIENT

## BREATHABLE oxygen at a TRUE-3D world point — the cell's O₂, but ZERO once WATER fills the cell (water
## displaces air) or the cell is rock. One 3D read that lets a lung suffocate underwater OR in O₂-depleted
## smoke, with altitude respected for free (a flying bird's head cell holds no water; a diver's does) — no
## 2.5D depth column, no can_fly special-case. Gills invert it (see is_submerged_at). Above the volume = open sky.
func breathable_o2_at(x: float, y: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, y, z))
	if c < 0:
		return O2_AMBIENT                 # above the atmosphere shell = open sky
	# Water fills the cell → air is displaced → a lung drowns. Real; keep it (drowning + smoke stay 0).
	if _water[c] >= MAX_MASS * 0.5:
		return 0.0
	# ROCK holds no air — but a ground-standing creature whose head cell QUANTISES into the surface rock
	# (body size 0.5 ≪ cell size 5) is NOT buried; it breathes the thin air resting on the ground. Step
	# radially outward to the first open cell and read ITS O₂ (the true surface air — still 0 if choked by
	# smoke there). Only a creature truly encased in rock (no open cell outward within reach) reads 0. This
	# fixes land animals wrongly suffocating on solid ground without breaking drowning/smoke suffocation.
	if _solid[c] != 0:
		if _sphere == null:
			return 0.0                    # box mode (unused in the sim): keep the strict rule
		var steps: int = 0
		while _solid[c] != 0 and steps < 4:
			var up_c: int = _sphere.neighbours[c * 6 + 1]   # N_OUT = 1 (radially outward)
			if up_c < 0:
				return 0.0                # reached space while still in rock → encased
			c = up_c
			steps += 1
		if _solid[c] != 0 or _water[c] >= MAX_MASS * 0.5:
			return 0.0
	return _o2[c]

## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	var c: int = world_to_cell(Vector3(x, y, z))
	return c >= 0 and _solid[c] == 0 and _water[c] >= MAX_MASS * 0.5
# Open-cell O₂ min / mean over the GPU readback (_o2). Proves the sky-refill + transport keep the open air
# oxygenated and expose sealed-cavity draw-down. Falls back to ambient when no field is resident.
func o2_min_open() -> float:
	if _o2.size() != _cell_count or _cell_count <= 0:
		return O2_AMBIENT
	var mn: float = 1.0e20
	var n: int = 0
	for c in _cell_count:
		if _solid[c] != 0 or _water[c] >= MAX_MASS * 0.5:
			continue
		mn = minf(mn, _o2[c])
		n += 1
	return mn if n > 0 else O2_AMBIENT
func o2_avg() -> float:
	if _o2.size() != _cell_count or _cell_count <= 0:
		return O2_AMBIENT
	var sum: float = 0.0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] != 0 or _water[c] >= MAX_MASS * 0.5:
			continue
		sum += _o2[c]
		n += 1
	return sum / float(n) if n > 0 else O2_AMBIENT
# Emergent CARBON DIOXIDE (second gas channel): CO₂ level at a point + build-up diagnostics.
func co2_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return _co2[c] if c >= 0 else 0.0
	return 0.0
func co2_peak() -> float:
	if _co2.size() != _cell_count or _cell_count <= 0:
		return 0.0
	var mx: float = 0.0
	for c in _cell_count:
		if _solid[c] == 0:
			mx = maxf(mx, _co2[c])
	return mx
func co2_avg() -> float:
	if _co2.size() != _cell_count or _cell_count <= 0:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] != 0:
			continue
		sum += _co2[c]
		n += 1
	return sum / float(n) if n > 0 else 0.0
# Emergent LIVING BIOMASS (MaterialReactions3D R19/R20): CO₂ fixed into plant matter on the GPU + queried here.
func biomass_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return _biomass[c] if (c >= 0 and _biomass.size() == _cell_count) else 0.0
	return 0.0
## Total living biomass over every open cell — the emergent-growth spot check (should rise then plateau, not
## explode; bounded by the CO₂ budget + respiration). Fed into SIM_REPORT.
func biomass_total() -> float:
	if _biomass.size() != _cell_count or _cell_count <= 0:
		return 0.0
	var sum: float = 0.0
	for c in _cell_count:
		if _solid[c] == 0:
			sum += _biomass[c]
	return sum
# Emergent DECOMPOSER loop (LAMaterialFungus3D): dead matter (detritus) → fungus → CO₂ + soil fertility.
## Deposit dead decomposable matter at the surface cell under a world point (a rotting carcass, wildfire
## ash). Fungus grows on it + rots it back into the carbon/nutrient loop. Mirrors photosynthesize()'s lookup.
func deposit_detritus(world_pos: Vector3, amount: float) -> void:
	if _cell_count <= 0 or amount <= 0.0:
		return
	var c: int = world_to_cell(world_pos)          # the carcass's own 3D cell on the ground
	if c < 0 or _solid[c] != 0:
		return
	if _detritus.size() != _cell_count:
		_detritus.resize(_cell_count)
	_detritus[c] += amount
# Per-cell debug readers for the phase channels (mirror biomass_at/co2_at): molten mineral, bedrock
# fraction, and pre-lightning electrification. Pure reads for the DebugPanel field-view heatmaps.
func lava_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		if _gpu != null: _gpu.request_channel("lava")   # keep lava readback hot while something queries it
		var c: int = world_to_cell(Vector3(x, y, z))
		return _lava[c] if (c >= 0 and _lava.size() == _cell_count) else 0.0
	return 0.0
func rock_fill_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return _rock_fill[c] if (c >= 0 and _rock_fill.size() == _cell_count) else 0.0
	return 0.0
func charge_at(x: float, y: float, z: float) -> float:
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return _charge[c] if (c >= 0 and _charge.size() == _cell_count) else 0.0
	return 0.0
func fungus_at(x: float, y: float, z: float) -> float:
	return 0.0
func fungus_peak() -> float:
	return 0.0
func fungus_cells() -> int:
	return 0
func detritus_peak() -> float:
	return 0.0
# Photosynthesis (CO₂ → O₂ + biomass) + its daylight gate are DISSOLVED into MaterialReactions3D records R19/R20
# and run entirely on the GPU (see biomass_at/biomass_total). The old CPU `solar_factor()` + `photosynthesize()`
# writes were invisible to the GPU (begin_frame only re-uploads temp/water) and are deleted.
## Wire the lightning bolt visual callback (spawn_lightning); the charge module fires it on breakdown.
func set_lightning_visual(cb: Callable) -> void:
	_pending_lightning_cb = cb
	if _charge_mod != null:
		_charge_mod.set_visual(cb)
func charge_peak() -> float:
	return _charge_mod.charge_peak() if _charge_mod != null else 0.0
func bolts_fired() -> int:
	return _charge_mod.bolts_fired() if _charge_mod != null else 0
## Inject a shock/sound wave (explosion, thunder, impact, stampede) — the real emergent shock channel (module).
func emit_shock(world_pos: Vector3, magnitude: float) -> void:
	if _shock_mod != null:
		if _gpu != null: _gpu.request_channel("shock")   # injecting shock → keep its readback hot
		_shock_mod.emit_shock(world_pos, magnitude)
func shock_at(world_pos: Vector3) -> float:
	if _gpu != null: _gpu.request_channel("shock")
	return _shock_mod.shock_at(world_pos) if _shock_mod != null else 0.0
func shock_gradient(world_pos: Vector3) -> Vector3:
	if _gpu != null: _gpu.request_channel("shock")
	return _shock_mod.shock_gradient(world_pos) if _shock_mod != null else Vector3.ZERO
func shock_cell_count() -> int:
	return _shock_mod.shock_cell_count() if _shock_mod != null else 0


# Box dynamic-water surface mesh render adapter retired; the cubed-sphere renders water via the ocean shell.
func rebuild_surface() -> void:
	pass


## Central-telemetry provider (registered once with LASimReport): this field's channel aggregates, in ONE
## dict, so they flow into SIM_REPORT from their owner instead of being hand-threaded into a format string.
## Open-cell (void) temperature spread — the direct read of whether the solar terminator + heat diffusion
## actually move the temp field (a flat min==max means solar is not depositing). Snapshot-time only.
func _open_temp_stats() -> Dictionary:
	var mn: float = 1.0e20
	var mx: float = -1.0e20
	var sum: float = 0.0
	var n: int = 0
	for c in _cell_count:
		if _solid[c] != 0:
			continue
		var t: float = _temp[c]
		if t < mn:
			mn = t
		if t > mx:
			mx = t
		sum += t
		n += 1
	# All-cell max (incl. solid) exposes the pinned geothermal core + the conduction gradient, which the
	# open-cell stats above hide (the hot core cells are rock).
	var all_mx: float = -1.0e20
	for v in _temp:
		if v > all_mx:
			all_mx = v
	if n == 0:
		return {"temp_min": 0.0, "temp_mean": 0.0, "temp_max": 0.0, "temp_open": 0, "temp_all_max": all_mx}
	return {"temp_min": mn, "temp_mean": sum / float(n), "temp_max": mx, "temp_open": n, "temp_all_max": all_mx}


## Polled only at snapshot time, so these (cheap forwarder) reads don't run per frame.
func report() -> Dictionary:
	var r: Dictionary = {
		"wet_cells": wet_cell_count(), "heat_peak": peak_heat(), "heat_cells": hot_cell_count(),
		"lava_cells": lava_peak(), "cloud_cells": cloud_cell_count(), "cloud_cover": avg_cloud_cover(),
		"fog_cover": avg_fog_cover(), "moisture_total": moisture_total(),
		"wind": wind().length(), "scent_cells": scent_cell_count(),
		"fertility_peak": fertility_peak(), "magma_cells": magma_cell_count(),
		"erosion_cells": erosion_cell_count(), "snow_cells": snow_cell_count(), "ice_cells": ice_cell_count(),
		"sea_ice_cells": _queries.sea_ice_cell_count(), "sea_ice_temp": _queries.sea_ice_temp_avg(), "open_sea_temp": _queries.open_sea_temp_avg(),
		"dust_cells": dust_cell_count(), "charge_peak": charge_peak(), "bolts": bolts_fired(),
		"shock_cells": shock_cell_count(), "o2_min": o2_min_open(), "o2_avg": o2_avg(),
		"co2_peak": co2_peak(), "co2_avg": co2_avg(), "fungus_cells": fungus_cells(),
		"fungus_peak": fungus_peak(), "detritus_peak": detritus_peak(),
		"biomass_total": biomass_total(),
		"fuel_total": _queries.fuel_total(), "fire_peak": _queries.fire_peak(), "fire_cells": _queries.fire_cells(),
		"h2o_total": h2o_total(), "water_total": water_total(), "snow_total": snow_total(), "soil_total": soil_total(),
		"snow_line_temp": snow_line_temp(),
		"mineral_total": _queries.mineral_total(), "rock_cells": _queries.rock_cells(),
		"rock_fill_total": _queries.rock_fill_total(), "lava_total": _queries.lava_total(),
		"sediment_total": _queries.sediment_total(), "dust_total": _queries.dust_total(),
		"susp_total": _queries.susp_total(),
		"rock_grows": (_stamp.grows if _stamp != null else 0), "rock_shrinks": (_stamp.shrinks if _stamp != null else 0),
	}
	r.merge(_open_temp_stats())
	r.merge(_queries.rock_radial_profile())
	r.merge(_queries.hot_spring_stats())
	return r
