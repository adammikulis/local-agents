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
# Ambient atmospheric oxygen every OPEN cell is seeded to (LAMaterialGas3D relaxes surface cells back toward
# it; combustion draws it down). MUST match LAMaterialGas3D.O2_AMBIENT.
const O2_AMBIENT: float = 1.0
var _temp: PackedFloat32Array = PackedFloat32Array()     # temperature °C per cell (rock + void)
var _vapor: PackedFloat32Array = PackedFloat32Array()    # airborne water vapor (humidity) per cell
var _cloud: PackedFloat32Array = PackedFloat32Array()    # condensed cloud density per cell
var _fog: PackedFloat32Array = PackedFloat32Array()      # condensed fog density per cell
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
var _detritus: PackedFloat32Array = PackedFloat32Array() # dead decomposable organic matter per cell (0 = none)
var _fungus: PackedFloat32Array = PackedFloat32Array()   # fungal biomass density per cell (0 = none; high = mushrooms)
# --- Emergent 3D wind (LAMaterialWind3D): a per-cell air PRESSURE + 3D VELOCITY field replacing the old
# single global scalar wind. Pressure falls out of temperature (warm=low), velocity accelerates down the
# gradient and deflects off rock, so funneling/fronts/highs-lows EMERGE. Read via wind_at()/wind3_at().
var _pressure: PackedFloat32Array = PackedFloat32Array() # air pressure per cell (derived from temperature)
var _vel_x: PackedFloat32Array = PackedFloat32Array()    # wind velocity X per cell (world +X)
var _vel_y: PackedFloat32Array = PackedFloat32Array()    # wind velocity Y per cell (world +Y, up)
var _vel_z: PackedFloat32Array = PackedFloat32Array()    # wind velocity Z per cell (world +Z)
var _sediment: PackedFloat32Array = PackedFloat32Array() # loose granular mass per cell (landslide slump)
# --- Emergent ELECTRIFICATION (LAMaterialCharge3D) + airborne DUST (LAMaterialDust3D). Field-resident so the
# GPU backend can own their per-cell compute (charge_accum3d / dust_*3d kernels) and round-trip them each
# frame like fire/fuel/sediment; the CPU modules reach into `_f._charge` / `_f._dust` (the CPU-oracle path).
var _charge: PackedFloat32Array = PackedFloat32Array()   # electrification charge per cell (updraft × supercooled cloud)
var _dust: PackedFloat32Array = PackedFloat32Array()     # airborne dust density per cell (wind-lofted sand storm)
var _sun_light = null                                    # DirectionalLight3D — solar forcing (top cells)

# Concern modules (3D generalisations of the 2.5D ones), set by activate().
var _water_sim = null                                    # LAMaterialWater3D (the water CA loop; step_water() forwards here)
var _heat = null                                         # LAMaterialHeat3D
var _atmosphere = null                                   # LAMaterialAtmosphere3D
var _lava_sim = null                                     # LAMaterialLava3D
var _wind_sim = null                                     # LAMaterialWind3D (emergent pressure-driven wind)
var _slump_sim = null                                    # LAMaterialSlump3D (granular landslide slump)
var _combustion = null                                   # LAMaterialCombustion3D (emergent fire/fuel over the field)
var _scent_sim = null                                    # LAMaterialScent3D (emergent scent/waste/fertility stigmergy)
var _gas_sim = null                                      # LAMaterialGas3D (emergent atmospheric O₂ → cave-fire suffocation)
var _fungus_sim = null                                   # LAMaterialFungus3D (emergent decomposer: detritus → fungus → CO₂/fertility)
var _magma_sim = null                                    # LAMaterialMagma3D (emergent volcano/eruption from lava pressure)
var _erosion_sim = null                                  # LAMaterialErosion3D (hydraulic erosion → sediment/canyons/deltas)
var _snowice_sim = null                                  # LAMaterialSnowIce3D (emergent snowpack/melt + frozen ponds)
var _dust_sim = null                                     # LAMaterialDust3D (airborne dust / sand storms + dune migration)
var _charge_sim = null                                   # LAMaterialCharge3D (emergent electrification/lightning)
var _shock_sim = null                                    # LAMaterialShock3D (propagating sound/shock pressure-wave field)
var _ecology = null                                      # LAEcologyService back-ref (ash regrowth / actor coupling)
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmosphereScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const LavaScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialLava3D.gd")
const WindScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWind3D.gd")
const SlumpScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialSlump3D.gd")
const CombustionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCombustion3D.gd")
const ScentScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialScent3D.gd")
const GasScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGas3D.gd")
const FungusScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFungus3D.gd")
const MagmaScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialMagma3D.gd")
const ErosionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialErosion3D.gd")
const SnowIceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialSnowIce3D.gd")
const DustScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialDust3D.gd")
const ChargeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCharge3D.gd")
const ShockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialShock3D.gd")
const WaterScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialWater3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")
const QueriesScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldQueries3D.gd")
const RenderScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldRender3D.gd")
const InjectScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldInject3D.gd")
const HeatTextureScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeatTexture3D.gd")
var _gpu = null                                          # LAMaterialGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false
# TEMP PROFILING (LA_PROFILE): coarse GPU-section vs CPU-tail-modules usec split, printed every 120 steps.
var _prof_gpu: int = 0
var _prof_cpu: int = 0
var _prof_mod: Dictionary = {}
var _prof_n: int = 0
var _prof_last: int = 0
var _slow_tick: int = 0                                  # 4-cycle stagger for the slow geological/bio CPU passes


func _prof_mark(name: String, on: bool) -> void:
	if not on:
		return
	var now: int = Time.get_ticks_usec()
	_prof_mod[name] = int(_prof_mod.get(name, 0)) + (now - _prof_last)
	_prof_last = now


func _prof_mod_avg(n: int) -> Dictionary:
	var out: Dictionary = {}
	for k in _prof_mod.keys():
		out[k] = int(_prof_mod[k]) / n
	return out
# Read-only query accessors + the dynamic-water surface render adapter (factored out; see those files).
var _queries = null                                      # LAMaterialFieldQueries3D
var _render = null                                       # LAMaterialFieldRender3D
var _inject = null                                       # LAMaterialFieldInject3D (write-side injection + FX)
var _heat_texture = null                                 # LAMaterialHeatTexture3D (terrain-glow texture)


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
var _shock_dirty: bool = false
# Lazy solidity sampling: the field is created before the terrain has finished streaming, so it samples
# rock/void a budget of columns per frame and self-activates (seed sea + build modules) once complete —
# exactly how the old field lazily sampled heights. No blocking, no external init calls.
const SAMPLE_COLS_PER_FRAME: int = 700
var _sampling_done: bool = false
var _sample_cursor: int = 0
# Heat texture (terrain-glow source): the hottest temperature in each XZ column baked to an R-float
# texture the terrain shader samples for incandescent glow — owned by LAMaterialHeatTexture3D (`_heat_texture`).
# Persistent water sources (springs) injected each step: [{pos, rate}].
var _sources: Array = []


# --- Setup ------------------------------------------------------------------

## Build the 3D volume covering XZ in [-half_extent, half_extent] and Y in [y_min, y_max] at cell_size,
## bound to `terrain` (for the is_solid rock/void query). Cells are sampled solid/void lazily.
func setup(terrain, half_extent: float, cell_size: float, y_min: float, y_max: float, sea: float) -> void:
	_terrain = terrain
	_half_extent = maxf(1.0, half_extent)
	_cell_size = maxf(0.5, cell_size)
	sea_level = sea
	var dx: int = int(round((2.0 * _half_extent) / _cell_size)) + 1
	var dy: int = int(round((y_max - y_min) / _cell_size)) + 1
	setup_dims(dx, dy, dx, _cell_size, Vector3(-_half_extent, y_min, -_half_extent))
	# Build the heat texture now (not at activate) so consumers can wire heat_texture() immediately, even
	# while the field is still lazily sampling solidity.
	_heat_texture = HeatTextureScript.new()
	_heat_texture.setup(self)
	_heat_texture.build()


## Sample rock/void for every cell from the terrain SDF (is_solid). Eager version — fine at setup for
## the dense grid; a budgeted lazy variant can replace it once wired into the frame loop. Skips the
## per-cell query for cells clearly in open air above the column's surface (cheap win).
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
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


## Budgeted lazy version of sample_solidity: sample SAMPLE_COLS_PER_FRAME columns per call from the
## terrain SDF, advancing a cursor; sets _sampling_done when the whole volume is covered.
func _sample_step() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	var has_surf: bool = _terrain.has_method("surface_height")
	var cols: int = _dim_x * _dim_z
	var processed: int = 0
	while processed < SAMPLE_COLS_PER_FRAME and _sample_cursor < cols:
		var ix: int = _sample_cursor % _dim_x
		var iz: int = _sample_cursor / _dim_x
		var wx: float = _origin.x + float(ix) * _cell_size
		var wz: float = _origin.z + float(iz) * _cell_size
		var surf: float = _terrain.surface_height(wx, wz) if has_surf else NAN
		for iy in range(_dim_y):
			var wy: float = _origin.y + float(iy) * _cell_size
			var i: int = _idx(ix, iy, iz)
			if not is_nan(surf) and wy > surf + _cell_size:
				_solid[i] = 0
			else:
				_solid[i] = 1 if _terrain.is_solid(Vector3(wx, wy, wz)) else 0
		_sample_cursor += 1
		processed += 1
	if _sample_cursor >= cols:
		_sampling_done = true


## Seed the ocean: every VOID cell whose centre is below sea level starts full of water. The sea is a
## known level, so we set it directly (fast) instead of CA-filling the whole seabed from empty; the CA
## then only has to handle dynamics (waves, splashes, rivers meeting the sea, water pouring into caves).
func seed_sea() -> void:
	for iy in range(_dim_y):
		var wy: float = _origin.y + float(iy) * _cell_size
		if wy >= sea_level:
			break                                       # layers above sea level: nothing to seed
		# Seed each sea cell already at its warm-skin/thermocline temperature so hurricane genesis + lively
		# sea evaporation have fuel from frame 0 (the heat cooling stage relaxes toward this same profile).
		var wt: float = HeatScript.sea_water_target(wy, sea_level)
		for iz in range(_dim_z):
			for ix in range(_dim_x):
				var i: int = _idx(ix, iy, iz)
				if _solid[i] == 0:
					_water[i] = MAX_MASS
					_static[i] = 1                       # calm sea: hold it, don't simulate/mesh it
					_temp[i] = wt


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
func setup_sphere(grid: RefCounted) -> void:
	_sphere = grid
	_cell_size = maxf(0.5, grid.cell_size)
	_origin = grid.center
	_cell_count = grid.cell_count
	# Keep _dim_* nominally sane (some diagnostics read them); real indexing goes through the grid.
	_dim_x = grid.surf_count
	_dim_y = grid.depth
	_dim_z = 1
	_alloc_channels()

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
	_vapor = PackedFloat32Array()
	_vapor.resize(_cell_count)
	_cloud = PackedFloat32Array()
	_cloud.resize(_cell_count)
	_fog = PackedFloat32Array()
	_fog.resize(_cell_count)
	_lava = PackedFloat32Array()
	_lava.resize(_cell_count)
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
	# Read-only query accessors bind to this field now; the arrays they read exist from here on.
	_queries = QueriesScript.new()
	_queries.setup(self)
	# Water CA module (the field's step_water() forwards here). Instantiated at dims-setup — not activate() —
	# because the parity harnesses call field.step_water() on a bare setup_dims field (no activate()).
	_water_sim = WaterScript.new()
	_water_sim.setup(self)


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


## One water step (gravity fall, upward pressure relief, lateral levelling — mass-conserving via a double
## buffer). The CA loop lives in LAMaterialWater3D; this forwarder preserves the field's public entry point
## (the parity harnesses + the internal step loop call field.step_water()). `_stable_below` stays on the
## field because MaterialSlump3D + MaterialLava3D also call `_f._stable_below`.
func step_water() -> void:
	if _water_sim != null:
		_water_sim.step()


# --- World-space queries (delegated to _queries; the 2.5D-compatible API consumers call) --------

func _col_i(w: float, o: float) -> int:
	return clampi(int(round((w - o) / _cell_size)), 0, _dim_x - 1)


func column_surface_y(ix: int, iz: int) -> float:
	return _queries.column_surface_y(ix, iz)


func surface_y_at(x: float, z: float) -> float:
	return _queries.surface_y_at(x, z)


func is_water_at(x: float, z: float) -> bool:
	return _queries.is_water_at(x, z)


func depth_at(x: float, z: float) -> float:
	return _queries.depth_at(x, z)


## Inject water at a world point (a spring, rain, a flood surge, a meteor splash).
func add_water_world(pos: Vector3, amount: float) -> void:
	add_water_cell(_col_i(pos.x, _origin.x), _col_i(pos.y, _origin.y), _col_i(pos.z, _origin.z), amount)


## Register a persistent spring: `rate` water mass per second injected at `pos` each step.
func add_source(pos: Vector3, rate: float) -> void:
	_sources.append({"pos": pos, "rate": rate})


# --- Live frame loop + fluid-surface rendering ------------------------------

## Begin simulating + rendering (called after setup + sample_solidity + seed_sea). Builds the render
## node and starts the throttled step in _physics_process.
func activate() -> void:
	_heat = HeatScript.new()
	_heat.setup(self)
	_atmosphere = AtmosphereScript.new()
	_atmosphere.setup(self)
	_lava_sim = LavaScript.new()
	_lava_sim.setup(self)
	_wind_sim = WindScript.new()
	_wind_sim.setup(self)
	_slump_sim = SlumpScript.new()
	_slump_sim.setup(self)
	# Emergent fire/combustion over the shared field: seeds the fuel channel from vegetation, then ignites/
	# burns/spreads on heat + wind. CPU-oracle stepped on both paths (like wind); kernels3d/fire3d.glsl is the
	# GPU parity port. Runs AFTER wind each step so ember spread reads the fresh downwind velocity.
	_combustion = CombustionScript.new()
	_combustion.setup(self)
	# Emergent SCENT + WASTE/FERTILITY stigmergy over the shared field (replaced LAScentField + LAPoop):
	# creatures lay musk/blood/alarm derived from their state + drop feces/urine → fertility; it diffuses,
	# advects on the LOCAL wind, decays, and washes in rain. CPU-oracle only. Runs after combustion.
	_scent_sim = ScentScript.new()
	_scent_sim.setup(self)
	# Emergent atmospheric OXYGEN over the shared field: O₂ diffuses/advects on the wind + is replenished at
	# each column's sky surface; combustion consumes it + can't burn below O2_MIN. CPU-oracle stepped on both
	# paths (like scent). Runs after wind (needs velocity) so cave fires draw down trapped O₂ and suffocate.
	_gas_sim = GasScript.new()
	_gas_sim.setup(self)
	# Emergent DECOMPOSER over the shared field: dead matter (detritus, deposited by rotting carcasses +
	# wildfire ash) is colonised by fungus, which rots it back into CO2 + soil fertility while drawing O2 —
	# closing the carbon/nutrient loop (death->soil->plant). CPU-oracle. Runs AFTER combustion/gas (reads fresh
	# CO2/O2) and near scent (its fertility composes with the soil channel).
	_fungus_sim = FungusScript.new()
	_fungus_sim.setup(self)
	# More emergent field processes (all CPU-oracle, own their channels in-module). Magma = lava-pressure
	# volcanoes; erosion = water carving sediment; snow/ice = phase; dust = wind-lofted sand storms;
	# charge = electrification→lightning; shock = a propagating sound/pressure wave (replaces the seismic ring).
	_magma_sim = MagmaScript.new()
	_magma_sim.setup(self)
	_erosion_sim = ErosionScript.new()
	_erosion_sim.setup(self)
	_snowice_sim = SnowIceScript.new()
	_snowice_sim.setup(self)
	_dust_sim = DustScript.new()
	_dust_sim.setup(self)
	_charge_sim = ChargeScript.new()
	_charge_sim.setup(self)
	_shock_sim = ShockScript.new()
	_shock_sim.setup(self)
	# GPU-RESIDENT backend: persistent SSBOs, the whole heat+water step batched on-GPU, ONE readback per
	# frame (see MaterialGPU3D's frame API). Headless has no local RenderingDevice → CPU oracle.
	if GPUScript.available() and not OS.has_environment("LA_FORCE_CPU"):
		_gpu = GPUScript.new()
		_gpu.setup(self)
		_use_gpu = true
		# Seed the resident buffers with the initial CPU state (temp/water from setup+seed_sea; the gas +
		# lava layers start empty). vapor/cloud/fog then live fully on the GPU; temp/water/lava re-upload.
		_gpu.set_field("temp", _temp)
		_gpu.set_field("water", _water)
		_gpu.set_field("vapor", _vapor)
		_gpu.set_field("cloud", _cloud)
		_gpu.set_field("fog", _fog)
		_gpu.set_field("lava", _lava)
		_gpu.set_field("sediment", _sediment)
	_render = RenderScript.new()
	_render.setup(self)
	_render.build()
	_inject = InjectScript.new()
	_inject.setup(self)
	_heat_texture.build()
	rebuild_surface()
	_heat_texture.update()
	_ready_sim = true


# --- Heat texture (terrain-glow source; owned by LAMaterialHeatTexture3D) ----

## The live terrain-glow texture (R = hottest °C per column). Wire once into the terrain shader.
func heat_texture() -> Texture2D:
	return _heat_texture.texture() if _heat_texture != null else null

func heat_world_min() -> Vector2:
	return _heat_texture.world_min() if _heat_texture != null else Vector2.ZERO

func heat_world_size() -> Vector2:
	return _heat_texture.world_size() if _heat_texture != null else Vector2.ZERO


func _physics_process(delta: float) -> void:
	if not _ready_sim:
		# Still sampling rock/void as the terrain streams; self-activate when the volume is fully sampled.
		if _terrain != null and _terrain.has_method("is_solid"):
			_sample_step()
			if _sampling_done:
				seed_sea()
				activate()
		return
	_step_accum += delta
	var steps: int = 0
	while _step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_step_accum -= STEP_DT
		steps += 1
	if steps <= 0:
		return

	var _fstep_t0: int = Time.get_ticks_usec()   # coarse field-step timer → SimReport (isolate field vs "other")
	if _use_gpu:
		var _pg0: int = Time.get_ticks_usec() if OS.has_environment("LA_PROFILE") else 0
		# GPU-RESIDENT: the WHOLE step (water + heat + atmosphere + lava) runs `steps` times on the GPU.
		# temp/water/lava carry CPU injections (springs, disaster heat/lava) so they round-trip every frame;
		# vapor/cloud/fog live fully resident on the GPU and are read back only on a cadence (render-only).
		for src in _sources:
			add_water_world(src["pos"], float(src["rate"]) * STEP_DT * float(steps))
		var solar: float = _heat._solar() if _heat != null else 0.6
		var w: Vector2 = _atmosphere.wind() if _atmosphere != null and _atmosphere.has_method("wind") else Vector2.ZERO
		_gpu.begin_frame(_temp, _water, solar, w)
		# Lava is GPU-resident + GPU-evolved (the flow CA runs on-device). The CPU only injects into it on a
		# disaster/volcano (add_lava) or the magma tail's deep-source feed/bore — so re-upload ONLY when such an
		# edit dirtied it; otherwise the GPU keeps flowing it resident and re-uploading a stale snapshot would
		# clobber that flow. While a volcano vents, the magma tail dirties it every frame, so it round-trips
		# every frame (correct); with no active volcano it stays resident and its readback drops to the cadence.
		var lava_was_dirty: bool = _lava_dirty
		if lava_was_dirty:
			_gpu.set_field("lava", _lava)
		_lava_dirty = false
		# Emergent wind now runs ON-GPU (wind_pressure3d + wind_step3d between the heat and atmosphere passes),
		# so vel_x/vel_y/vel_z are GPU-resident + GPU-written — no per-frame upload_wind. Just push the
		# large-scale PREVAILING input the wind_step kernel relaxes toward (the old --wind= / WeatherSystem base).
		_gpu.set_prevailing(_wind_sim.prevailing() if _wind_sim != null else Vector2.ZERO)
		_gpu.set_field("sediment", _sediment)
		# Fire/fuel round-trip like lava: the fire3d.glsl kernel runs the ember/phase core on-device; the CPU
		# keeps only the scene tail (seed/scan/ash/regrow via step_scene_only). Upload the authoritative CPU
		# fuel/fire (carrying disaster ignitions + the tail's fuel seeding/top-ups) into the resident buffers,
		# run the GPU passes, then read the consumed fuel + evolved fire back below.
		_gpu.set_field("fuel", _fuel)
		_gpu.set_field("fire", _fire)
		# Oxygen rides along like fuel: upload the CPU-authoritative O₂ (carrying the last frame's diffuse/
		# advect/sky-exchange) so the fire3d.glsl kernel CONSUMES it + gates ignition/burn on it on-device,
		# then read the drawn-down O₂ back below for the CPU gas transport tail.
		_gpu.set_field("o2", _o2)
		# CO2 rides along like O2: upload the CPU-authoritative CO2 (last frame's diffuse/advect/settle/sky-vent)
		# so the fire3d.glsl kernel EMITS it (fuel + O2 -> CO2) on-device where a cell burns, then read it back.
		_gpu.set_field("co2", _co2)
		# Charge + dust round-trip like fire/sediment: the charge_accum3d + dust_*3d kernels run the per-cell
		# CORE on-device; the CPU keeps only the tails (charge BREAKDOWN+bolt, dust diagnostics) via
		# step_scene_only(). Upload the authoritative CPU state (carrying the last breakdown's column reset for
		# charge, and the erosion/snowice/magma edits to the shared sediment for dust), then read them back below.
		# Charge is LEFT EVERY-FRAME: the accumulate CA separates charge on-device every step, but the per-column
		# BREAKDOWN tail (bolt spawn + column reset) must scan FRESH charge every frame to trigger bolts on time —
		# cadencing its readback halved charge_peak and delayed strikes. Its round-trip is one cheap channel; keep it.
		_gpu.set_field("charge", _charge)
		# dust is GPU-authoritative (CPU never writes it) — NOT re-uploaded, so it lives fully resident and
		# its readback can be cadenced (render-only). Re-uploading the last readback would clobber the GPU's
		# own evolution on the skipped-readback frames.
		# Rain suppresses all dust lofting (wet sand never blows) — hand the dust LOFT kernel the raining flag.
		_gpu.set_raining(precipitation() > DustScript.RAIN_MAX)
		# Scent/shock/fungus round-trip like fire/dust: the GPU runs the transport/CA cores, the CPU keeps only
		# the scene tails (emit/seed for scent, emit for shock, detritus deposits for fungus). Push the per-frame
		# precipitation (scent rain-wash / fertility leach / fungus moisture) + the authoritative CPU state
		# (carrying this frame's emits/deposits) into the resident buffers, then read the evolved fields back below.
		_gpu.set_precip(precipitation())
		if _scent_sim != null:
			_gpu.set_field("scent", _scent_sim._scent)
			_gpu.set_field("fert", _scent_sim._fert)
		# Shock is GPU-resident + GPU-evolved (the shock3d CA radiates + decays it on-device). The CPU only writes
		# it when an impact EMITS a pulse (rare, discrete) — so re-upload ONLY when an emit dirtied it; the GPU
		# keeps radiating it resident otherwise. Its READBACK stays every-frame (the camera shake samples it each
		# frame), so the emit always adds onto a fresh CPU copy — no clobber, and we still cut the per-frame upload.
		var shock_was_dirty: bool = _shock_dirty
		if _shock_sim != null and shock_was_dirty:
			_gpu.set_field("shock", _shock_sim._shock)
		_shock_dirty = false
		# fungus is GPU-authoritative (CPU only reads it for diagnostics) — NOT re-uploaded (resident); its
		# readback is cadenced with dust/vel below. detritus is LEFT EVERY-FRAME (round-trips like sediment): the
		# GPU DECOMPOSES it every step (fungus kernel) AND a rotting carcass deposits into it EVERY frame, so it is
		# continuous-evolution + continuous-CPU-edit — dirty-gating clobbered the accumulation (detritus_peak → 0).
		_gpu.set_field("detritus", _detritus)
		# Geological tails round-trip like fire/scent: the GPU runs the per-cell CORES (erosion deposit/advect,
		# snowpack accrete/melt, magma buoyant up-flow); the CPU keeps only the SDF/solid-mask stamps via
		# step_scene_only(). Upload the authoritative CPU channels (this frame's CPU carve/freeze/thaw edits)
		# into the resident buffers, then read the evolved fields back below.
		if _erosion_sim != null:
			_gpu.set_field("susp", _erosion_sim._susp)
		if _snowice_sim != null:
			_gpu.set_field("snow", _snowice_sim._snow)
		# Vapor is re-uploaded ONLY when a CPU-side injection (a storm's add_vapor) dirtied it. With nothing
		# injected it lives fully resident on the GPU (re-uploading the last readback would just clobber the
		# GPU's own evolution), so we skip the upload AND the readback below — cloud/fog are never re-uploaded.
		if _vapor_dirty:
			_gpu.set_field("vapor", _vapor)
		for i in range(steps):
			_gpu.step()
		# Render-only fields (vapor/cloud/fog) feed ONLY visuals + slow humidity queries and are NOT read by
		# the next GPU step, so read them back on a cadence (they keep evolving resident between reads). temp/
		# water/lava are queried continuously by consumers, so read them every frame.
		var read_slow: bool = _slow_read_tick == 0
		var read_vapor: bool = read_slow or _vapor_dirty
		# LAVA readback is DIRTY-GATED together with its upload: read only on the slow cadence, OR the frame a CPU
		# edit (magma feed / add_lava) is round-tripping (lava_was_dirty), so the edit lands on a freshly-read copy
		# — never a cadenced readback over a stale every-frame upload (what broke the crude version). With no active
		# volcano lava is fully resident + cadenced; while a volcano vents it dirties every frame and round-trips.
		var read_lava: bool = read_slow or lava_was_dirty
		# Shock: the camera shake integrates trauma (add_shake) from seismic_energy_at each frame and applies a
		# per-frame RANDOM offset scaled by the decaying trauma — so a 1-in-3-stale shock amplitude is invisible
		# (verified). Read it on the cadence, or the frame a fresh impact emit is round-tripping into the buffer.
		var read_shock: bool = read_slow or shock_was_dirty
		var out: Dictionary = _gpu.end_frame(read_vapor, read_slow, read_slow, read_slow, read_lava, read_shock)
		_temp = out["temp"]
		_water = out["water"]
		if out.has("lava"):
			_lava = out["lava"]
		if out.has("fire"):
			_fire = out["fire"]
		if out.has("fuel"):
			_fuel = out["fuel"]
		if out.has("o2"):
			_o2 = out["o2"]                               # O₂ the fire kernel drew down; the gas tail transports it
		if out.has("co2"):
			_co2 = out["co2"]  # CO2 the fire kernel emitted; the gas tail transports it
		if out.has("sediment"):
			_sediment = out["sediment"]
		if out.has("charge"):
			_charge = out["charge"]
		if out.has("dust"):
			_dust = out["dust"]
		# Emergent wind is GPU-resident now — pull the fresh per-cell velocity back for CPU consumers
		# (wind_at / wind3_at / scent advection / debug arrows).
		if out.has("vel_x"):
			_vel_x = out["vel_x"]
		if out.has("vel_y"):
			_vel_y = out["vel_y"]
		if out.has("vel_z"):
			_vel_z = out["vel_z"]
		# Scent stigmergy (airborne + soil fertility), shock wave, fungus/detritus — GPU-evolved this frame;
		# pull them back for the CPU consumers (creature scent gradients, camera shake / panic, mushrooms).
		if out.has("scent") and _scent_sim != null:
			_scent_sim._scent = out["scent"]
		if out.has("fert") and _scent_sim != null:
			_scent_sim._fert = out["fert"]
		if out.has("shock") and _shock_sim != null:
			_shock_sim._shock = out["shock"]
		if out.has("fungus"):
			_fungus = out["fungus"]
		if out.has("detritus"):
			_detritus = out["detritus"]
		# Geological-tail channels evolved on-GPU this frame — pull them back for the CPU tails + diagnostics.
		if out.has("susp") and _erosion_sim != null:
			_erosion_sim._susp = out["susp"]
		if out.has("snow") and _snowice_sim != null:
			_snowice_sim._snow = out["snow"]
		if out.has("vapor"):
			_vapor = out["vapor"]
		if out.has("cloud"):
			_cloud = out["cloud"]
		if out.has("fog"):
			_fog = out["fog"]
		if read_slow and _atmosphere != null:
			# The GPU kernels evolve cloud/fog on-device, but step() (which builds the renderer's column
			# projections + cover aggregates) is skipped on this path — so refresh them from the fresh
			# readback. Without this, cloud_grid()/avg_cloud_cover()/precipitation() (the CloudLayer sheet,
			# storm sun-dimming, scent rain-wash) stay frozen at zero in windowed GPU play.
			_atmosphere.recompute_projections()
		_vapor_dirty = false
		_slow_read_tick = (_slow_read_tick + 1) % SLOW_READ_EVERY
		# Emergent 3D wind ran ON-GPU inside _gpu.step() (pressure -> velocity) and came back above — so here
		# we only refresh the cached domain-average wind (ocean swell / HUD) from it; no CPU wind scan.
		var _prof_on: bool = OS.has_environment("LA_PROFILE")
		var _pc0: int = Time.get_ticks_usec() if _prof_on else 0
		if _prof_on:
			_prof_gpu += _pc0 - _pg0
			_prof_last = _pc0
		# GPU section done (begin_frame + N×step + end_frame READBACK). Gauge it → field_ms − field_gpu_ms is
		# the CPU-tail cost. Splits the ~69ms field step into GPU/readback vs the scene tails.
		LASimReport.gauge("field_gpu_ms", float(Time.get_ticks_usec() - _fstep_t0) / 1000.0)
		if _wind_sim != null:
			_wind_sim.recompute_avg_from_field()
		# GEOLOGICAL/biological CPU processes are SLOW by nature (erosion carving rock, snowpack, magma boring
		# conduits, fungus rotting matter) — running each dense full-grid pass EVERY frame was ~80ms/frame for
		# no visible gain. Stagger them one-per-frame on a 4-cycle (perf > parity, per CLAUDE.md): each still
		# advances, just at a cadence matched to how slowly it actually changes. (Until they are GPU-ported.)
		_slow_tick = (_slow_tick + 1) % 4
		# CPU-oracle field processes on the fresh GPU readback (their edits round-trip to the GPU next frame).
		# Geological CORES ran on-GPU (erosion deposit/advect, snow accrete/melt, magma buoyant up-flow) inside
		# _gpu.step() and susp/snow/sediment/lava came back in the readback — so each runs ONLY its CPU tail
		# here: the SDF/solid-mask stamps (erosion CARVE, snow FREEZE/THAW, magma PRESSURE-MELT + source feed).
		# These SDF stamps are the frame's HEAVIEST CPU cost (magma ~13ms) AND each edit forces godot_voxel to
		# re-mesh the touched chunks — so running all three EVERY 10 Hz step frame was ~130ms/s of carving for
		# a GLACIAL process. Stagger them across the 4-cycle (one per step frame, each 4× less often): rock
		# melts/freezes/erodes over seconds, so a 0.4 s stamp interval is imperceptible, and the worst-case
		# step frame now carries at most ONE geological tail instead of all three. (The GPU cores still evolve
		# every step; only the SDF stamp + its remesh is throttled.)
		if _erosion_sim != null and _slow_tick == 0:
			_erosion_sim.step_scene_only()
			_prof_mark("erosion", _prof_on)
		if _snowice_sim != null and _slow_tick == 1:
			_snowice_sim.step_scene_only()
			_prof_mark("snowice", _prof_on)
		if _magma_sim != null and _slow_tick == 2:
			var _mt0: int = Time.get_ticks_usec()
			_magma_sim.step_scene_only()
			LASimReport.gauge("tail_magma_ms", float(Time.get_ticks_usec() - _mt0) / 1000.0)
			_prof_mark("magma", _prof_on)
		# Emergent dust: the loft/advect/settle CORE ran on-GPU (dust_*3d kernels) and dust/sediment came back in
		# the readback — so here we run ONLY the CPU tail (refresh the dust_cells/dust_peak diagnostics).
		if _dust_sim != null:
			_dust_sim.step_scene_only()
		# Emergent fire: the ember/phase CORE ran on-GPU (fire3d.glsl) and fuel/fire came back in the readback
		# above — so here we run ONLY the CPU scene tail (fuel seed/scan, ash marking, ash->plant regrowth).
		if _combustion != null:
			var _ft0: int = Time.get_ticks_usec()
			_combustion.step_scene_only()
			LASimReport.gauge("tail_fire_ms", float(Time.get_ticks_usec() - _ft0) / 1000.0)
			_prof_mark("fire_tail", _prof_on)
		# Emergent oxygen/CO₂: the fire kernel consumed O₂ / emitted CO₂ on-GPU AND the CONTINUOUS transport
		# (diffuse + advect on the fresh wind + sky exchange/vent) now runs on-GPU too (o2_transport3d /
		# co2_transport3d / gas_sky3d inside _gpu.step()) — the drawn-down + transported fields came back in the
		# readback above. So here the gas channel runs ONLY the diagnostics scan (SMOKE_SUMMARY/HUD), and even
		# that is STAGGERED on the 4-cycle — o2/co2 min/avg/peak change slowly, so the cached values (≤3 frames
		# fresh) are plenty for a HUD/smoke readout and the full-grid scan no longer costs every frame.
		if _gas_sim != null and _slow_tick == 0:
			_gas_sim.refresh_diagnostics_from_field()
			_prof_mark("gas", _prof_on)
		# Scent/waste stigmergy advects on the fresh wind; shock radiates the latest stimuli. Charge's ACCUMULATE
		# ran on-GPU (charge_accum3d) and _charge came back above — so charge runs ONLY its CPU tail here (the
		# per-column BREAKDOWN reduction + bolt spawn + column reset). All CPU oracle otherwise.
		# Scent airborne transport + fertility blur/leach ran ON-GPU (scent_wind3d/scent_transport3d/
		# scent_fert3d) and came back above — so scent runs ONLY its CPU tail here (emit from creatures/
		# carcasses into the fresh _scent/_fert, then budgeted plant-seeding from the richest soil).
		if _scent_sim != null:
			var _st0: int = Time.get_ticks_usec()
			_scent_sim.step_scene_only()
			LASimReport.gauge("tail_scent_ms", float(Time.get_ticks_usec() - _st0) / 1000.0)
			_prof_mark("scent", _prof_on)
		# Emergent decomposer: the grow/decompose/spread CA + the rot->fertility reduce ran ON-GPU (fungus3d/
		# fungus_fert3d) and fungus/detritus (and drawn-down O2 / emitted CO2 / soil fertility) came back above.
		# So fungus runs ONLY its diagnostics refresh here, staggered on the 4-cycle (slow biological process).
		if _fungus_sim != null and _slow_tick == 3:
			_fungus_sim.refresh_diagnostics_from_field()
			_prof_mark("fungus", _prof_on)
		# The charge tail (per-column dielectric BREAKDOWN + bolt spawn + column reset) runs EVERY frame on the
		# fresh every-frame _charge readback, so a column that crosses the breakdown threshold fires its bolt
		# without a cadence delay (cadencing this halved charge_peak and staggered strikes).
		if _charge_sim != null:
			var _ct0: int = Time.get_ticks_usec()
			_charge_sim.step_scene_only()
			LASimReport.gauge("tail_charge_ms", float(Time.get_ticks_usec() - _ct0) / 1000.0)
		# Shock radiated + decayed ON-GPU (shock3d) and _shock came back above — refresh its diagnostics only,
		# staggered on the 4-cycle (peak/audible-cell count change slowly).
		if _shock_sim != null and _slow_tick == 1:
			_shock_sim.refresh_diagnostics_from_field()
			_prof_mark("shock", _prof_on)
		if _prof_on:
			_prof_cpu += Time.get_ticks_usec() - _pc0
			_prof_n += 1
			if _prof_n % 120 == 0:
				print("PROF gpu=%dus cpu=%dus mods=%s" % [_prof_gpu / 120, _prof_cpu / 120, str(_prof_mod_avg(120))])
				_prof_gpu = 0
				_prof_cpu = 0
				_prof_mod = {}
	else:
		for i in range(steps):
			# Springs feed the surface (rivers emerge as this water flows downhill in 3D).
			for src in _sources:
				add_water_world(src["pos"], float(src["rate"]) * STEP_DT)
			step_water()
			# Hydraulic erosion reads the fresh water flow, carving rock into sediment (slump then piles it).
			if _erosion_sim != null:
				_erosion_sim.step()
			if _heat != null:
				_heat.step()
			# Wind steps after heat (reads post-heat temp for pressure), before the atmosphere.
			if _wind_sim != null:
				_wind_sim.step()
			if _atmosphere != null:
				_atmosphere.step()
			# Snow/ice phase reads fresh temp + precipitation: snowpack accretes cold, melts warm (→ meltwater),
			# standing water freezes below 0°C. Before lava/slump so fire reads the freshly wet/frozen cells.
			if _snowice_sim != null:
				_snowice_sim.step()
			if _lava_sim != null:
				_lava_sim.step()
			# Magma pressure bores conduits + drives eruptions from the deep hot source (after the lava CA).
			if _magma_sim != null:
				_magma_sim.step()
			if _slump_sim != null:
				_slump_sim.step()
			# Dust lofts dry loose sediment on strong wind (after wind + slump); dunes migrate downwind.
			if _dust_sim != null:
				_dust_sim.step()
			# Oxygen transports (diffuse + advect on the fresh wind) + replenishes at the sky surface BEFORE
			# combustion reads it, so a sealed cave's trapped O₂ draws down and its fire suffocates.
			if _gas_sim != null:
				_gas_sim.step()
			# Fire runs after: fuel ignites from lava/lightning/meteor heat, burns + spreads downwind, leaves ash.
			if _combustion != null:
				_combustion.step()
			# Scent/waste stigmergy: emit from creatures/carcasses, advect on wind, decay, seed plants.
			if _scent_sim != null:
				_scent_sim.step()
			# Emergent decomposer: fungus rots the detritus carcasses/ash deposited (→ CO2/O2/fertility) on
			# the fresh post-readback CO2/O2. CPU-oracle; its edits round-trip to the GPU next frame.
			if _fungus_sim != null:
				_fungus_sim.step()
			# Charge accumulates in convective updrafts → lightning; shock radiates the latest violent stimuli.
			if _charge_sim != null:
				_charge_sim.step()
			if _shock_sim != null:
				_shock_sim.step()
	# Granular slump settles into permanent terrain on BOTH paths (a CPU-only SDF stamp, throttled).
	if _slump_sim != null:
		_slump_sim.settle()
	var _rb_t0: int = Time.get_ticks_usec()
	rebuild_surface()
	LASimReport.gauge("field_rebuild_ms", float(Time.get_ticks_usec() - _rb_t0) / 1000.0)
	# Heat-glow texture drives only the terrain incandescence shader and changes slowly (lava/fire
	# heat diffuses over seconds), so refresh it on a cadence instead of every frame's full-grid scan.
	if _heat_tex_tick == 0:
		_heat_texture.update()
	_heat_tex_tick = (_heat_tex_tick + 1) % HEAT_TEX_EVERY
	# Coarse per-step-frame field cost → SimReport (max = the step-frame spike). Compare to the physics_ms
	# gauge: physics_ms − field_ms is the NON-field "other" (terrain remesh / actor bodies / godot_voxel).
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - _fstep_t0) / 1000.0)


## Temperature °C at a world point (0 outside the grid). The consumer query the 2.5D field also exposes.
func temp_at(x: float, z: float, y: float = NAN) -> float:
	return _queries.temp_at(x, z, y)


# Topmost non-solid cell of a column (its sky-exposed surface), or -1 if the column is solid to the top.
func _surface_iy(ix: int, iz: int) -> int:
	for iy in range(_dim_y - 1, -1, -1):
		if _solid[(iy * _dim_z + iz) * _dim_x + ix] == 0:
			return iy
	return -1


# --- Consumer-facing API (matches the 2.5D LAMaterialField so this is a drop-in on the swap) --------

## True where the ground is below sea level (open ocean under the plane).
func is_ocean_at(x: float, z: float) -> bool:
	return _queries.is_ocean_at(x, z)


## Salinity 0 (fresh inland water) .. brackish shallows .. 1 (deep salt ocean); NAN if dry.
func salinity_at(x: float, z: float) -> float:
	return _queries.salinity_at(x, z)


# Atmosphere delegators (the 3D atmosphere owns the water cycle + humidity/dewpoint).
func cloud_at(x: float, z: float) -> float:
	return _atmosphere.cloud_at(x, z) if _atmosphere != null else 0.0

func fog_at(x: float, z: float) -> float:
	return _atmosphere.fog_at(x, z) if _atmosphere != null else 0.0

func avg_cloud_cover() -> float:
	return _atmosphere.avg_cloud_cover() if _atmosphere != null else 0.0

func avg_fog_cover() -> float:
	return _atmosphere.avg_fog_cover() if _atmosphere != null else 0.0

func precipitation() -> float:
	return _atmosphere.precipitation() if _atmosphere != null else 0.0

func cloud_grid() -> PackedFloat32Array:
	return _atmosphere.cloud_grid() if _atmosphere != null else PackedFloat32Array()

func fog_grid() -> PackedFloat32Array:
	return _atmosphere.fog_grid() if _atmosphere != null else PackedFloat32Array()

func cloud_base_y() -> float:
	return _atmosphere.cloud_base_y() if _atmosphere != null else sea_level + 62.0

func fog_base_y() -> float:
	return _atmosphere.fog_base_y() if _atmosphere != null else sea_level + 6.0

func relative_humidity_at(x: float, z: float) -> float:
	return _atmosphere.relative_humidity_at(x, z) if _atmosphere != null else 0.0

func dewpoint_at(x: float, z: float) -> float:
	return _atmosphere.dewpoint_at(x, z) if _atmosphere != null else NAN

## The old global scalar wind is now only the PREVAILING (large-scale) input the emergent wind field forces
## at its edges — local circulation emerges on top from pressure + terrain. Still fed to the atmosphere as
## its legacy advection wind until stage 2 repoints that to the local field.
func set_wind(w: Vector2) -> void:
	if _wind_sim != null:
		_wind_sim.set_prevailing(w)
	if _gpu != null:
		_gpu.set_prevailing(w)
	if _atmosphere != null:
		_atmosphere.set_wind(w)

## Domain-average horizontal wind (ocean swell / HUD) — the mean of the emergent velocity field.
func wind() -> Vector2:
	if _wind_sim != null:
		return _wind_sim.avg_wind()
	return _atmosphere.wind() if _atmosphere != null else Vector2.ZERO

## LOCAL horizontal wind (world XZ) at a point — sampled a couple of cells above the column surface (the
## free-stream, clear of the ground layer). What wind-drifting consumers + the debug arrows read.
func wind_at(x: float, z: float) -> Vector2:
	if _wind_sim == null or _cell_count <= 0:
		return Vector2.ZERO
	var ix: int = _col_i(x, _origin.x)
	var iz: int = _col_i(z, _origin.z)
	var iy: int = clampi(_surface_iy(ix, iz) + 2, 0, _dim_y - 1)
	var i: int = _idx(ix, iy, iz)
	return Vector2(_vel_x[i], _vel_z[i])

## Vertical vorticity (air SPIN) at a world point — storm actors track/scale off the emergent vortex.
func vorticity_at(x: float, z: float) -> float:
	return _queries.vorticity_at(x, z)

## Vertical updraft (+Y wind) at a column — the convective lift a thunderstorm/tornado feeds on.
func updraft_at(x: float, z: float) -> float:
	return _queries.updraft_at(x, z)

## Full LOCAL 3D wind velocity at a world point — the authoritative per-cell wind fire/scent ride.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	if _wind_sim == null or _cell_count <= 0:
		return Vector3.ZERO
	var ix: int = _col_i(x, _origin.x)
	var iy: int = clampi(int(round((y - _origin.y) / _cell_size)), 0, _dim_y - 1)
	var iz: int = _col_i(z, _origin.z)
	var i: int = _idx(ix, iy, iz)
	return Vector3(_vel_x[i], _vel_y[i], _vel_z[i])

## The cloud/fog grids project to (dim_x × dim_z) so CloudLayer's texture maps 1:1 with the 2.5D field.
func grid_dim() -> int:
	return _dim_x

func grid_half_extent() -> float:
	return _half_extent


# Heat + lava injection (disasters call these) + diagnostics.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _heat != null:
		_heat.add_heat(world_pos, amount, maxf(0.0, radius))

func add_lava(world_pos: Vector3, amount: float) -> void:
	if _lava_sim != null and _lava_sim.has_method("add_lava"):
		_lava_sim.add_lava(world_pos, amount)
		_lava_dirty = true                                  # CPU edited _lava → GPU path re-uploads it next frame

## Inject airborne water vapor (humidity) over a disc/column at a world point — a storm's LOCAL moisture
## source. With a little aloft cooling the existing condense→rain rules build a dense cloud → heavy local
## rain there. Folded into the resident GPU vapor buffer each frame (like lava). Emergent, not scripted.
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _atmosphere != null and _atmosphere.has_method("add_vapor"):
		_atmosphere.add_vapor(world_pos, amount, radius)
		_vapor_dirty = true                                 # GPU path re-uploads vapor only when injected

## Cool a volume (negative heat) — a storm's cold aloft that pushes rising humid air past its dewpoint so
## it condenses. Thin helper over add_heat so storms read as "cool the air here" rather than negative heat.
func add_cooling(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	add_heat(world_pos, -absf(amount), maxf(0.0, radius))

func lava_cell_count() -> int:
	return _lava_sim.lava_cell_count() if _lava_sim != null and _lava_sim.has_method("lava_cell_count") else 0

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


func cloud_cell_count(min_density: float = 0.05) -> int:
	return _atmosphere.cloud_cell_count(min_density) if _atmosphere != null and _atmosphere.has_method("cloud_cell_count") else 0


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
	if _slump_sim != null:
		_slump_sim.disturb(world_pos, radius, strength)

## Cells of loose sediment actively slumping (> 0 while a landslide is live; decays to 0 as it comes to rest).
func slump_count() -> int:
	return _slump_sim.active_count() if _slump_sim != null else 0

# --- Fire / combustion (emergent, LAMaterialCombustion3D) — real values now. --------------------------

## Light the cell under a node on fire (disaster/scripted ignition; vegetation also self-ignites from heat).
func ignite(node) -> void:
	if _combustion != null:
		_combustion.ignite_node(node)

## Is the cell under this node currently burning?
func is_burning(node) -> bool:
	return _combustion.is_burning_node(node) if _combustion != null else false

## Number of cells currently on fire (SMOKE_SUMMARY `fires`).
func active_fire_count() -> int:
	return _combustion.active_fire_count() if _combustion != null else 0


# --- Scent / waste / fertility (emergent stigmergy, LAMaterialScent3D) -------------------------------

## Drop feces/urine at a world point: diet-flavored soil fertility + a FOOD dab + the depositor's musk.
func deposit_waste(world_pos: Vector3, creature, kind: String) -> void:
	if _scent_sim != null:
		_scent_sim.deposit_waste(world_pos, creature, kind)

## A fresh burst of BLOOD scent (a wound or a kill).
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	if _scent_sim != null:
		_scent_sim.deposit_blood(world_pos, amount)

## A carcass advertising FOOD (the decaying-corpse cue scavengers follow).
func deposit_food(world_pos: Vector3, amount: float) -> void:
	if _scent_sim != null:
		_scent_sim.deposit_food(world_pos, amount)

## Scent density of a channel (LAMaterialScent3D.PREY/PREDATOR/BLOOD/FOOD/ALARM) at a world point.
func scent_at(world_pos: Vector3, channel: int) -> float:
	return _scent_sim.scent_at(world_pos, channel) if _scent_sim != null else 0.0

## Normalized XZ direction UP a scent channel's gradient (predator tracking, prey avoidance).
func scent_gradient(world_pos: Vector3, channel: int) -> Vector3:
	return _scent_sim.scent_gradient(world_pos, channel) if _scent_sim != null else Vector3.ZERO

## Soil nutrient at a world point (plants grow faster on rich ground).
func fertility_at(world_pos: Vector3) -> float:
	return _scent_sim.fertility_at(world_pos) if _scent_sim != null else 0.0

## Columns carrying meaningful airborne scent (SMOKE_SUMMARY `scent_cells`).
func scent_cell_count() -> int:
	return _scent_sim.scent_cell_count() if _scent_sim != null else 0

## Peak soil nutrient (SMOKE_SUMMARY `fertility_peak`).
func fertility_peak() -> float:
	return _scent_sim.fertility_peak() if _scent_sim != null else 0.0


# --- Emergent-process forwarders (magma volcano / erosion / snow-ice / dust / charge lightning / shock).
# Each module owns its channel; the field just exposes the write (emitter) + read (diagnostic) entry points.
func add_magma_source(world_pos: Vector3, temp: float, rate: float) -> void:
	if _magma_sim != null: _magma_sim.add_source(world_pos, temp, rate)
func magma_cell_count() -> int:
	return _magma_sim.magma_cells() if _magma_sim != null else 0
func magma_erupting() -> bool:
	return _magma_sim.erupting() if _magma_sim != null else false
func erosion_cell_count() -> int:
	return _erosion_sim.eroding_cells() if _erosion_sim != null else 0
func snow_depth_at(x: float, z: float) -> float:
	return _snowice_sim.snow_depth_at(x, z) if _snowice_sim != null else 0.0
func snow_cell_count() -> int:
	return _snowice_sim.snow_cells() if _snowice_sim != null else 0
func ice_cell_count() -> int:
	return _snowice_sim.ice_cells() if _snowice_sim != null else 0
func dust_at(x: float, y: float, z: float) -> float:
	return _dust_sim.dust_at(x, y, z) if _dust_sim != null else 0.0
func dust_cell_count() -> int:
	return _dust_sim.dust_cells() if _dust_sim != null else 0
# Emergent atmospheric OXYGEN (LAMaterialGas3D): O₂ level at a point + depletion diagnostics.
func o2_at(x: float, y: float, z: float) -> float:
	return _gas_sim.o2_at(x, y, z) if _gas_sim != null else 0.0

## BREATHABLE oxygen at a TRUE-3D world point — the cell's O₂, but ZERO once WATER fills the cell (water
## displaces air) or the cell is rock. One 3D read that lets a lung suffocate underwater OR in O₂-depleted
## smoke, with altitude respected for free (a flying bird's head cell holds no water; a diver's does) — no
## 2.5D depth column, no can_fly special-case. Gills invert it (see is_submerged_at). Above the volume = open sky.
func breathable_o2_at(x: float, y: float, z: float) -> float:
	var ix: int = _col_i(x, _origin.x)
	var iy: int = clampi(int(round((y - _origin.y) / _cell_size)), 0, _dim_y - 1)
	var iz: int = _col_i(z, _origin.z)
	if not _in_bounds(ix, iy, iz):
		return O2_AMBIENT
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return 0.0
	if _water[i] >= MAX_MASS * 0.5:      # cell over half-full of water → air is displaced
		return 0.0
	return _o2[i]

## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	var ix: int = _col_i(x, _origin.x)
	var iy: int = clampi(int(round((y - _origin.y) / _cell_size)), 0, _dim_y - 1)
	var iz: int = _col_i(z, _origin.z)
	if not _in_bounds(ix, iy, iz):
		return false
	var i: int = _idx(ix, iy, iz)
	return _solid[i] == 0 and _water[i] >= MAX_MASS * 0.5
func o2_min_open() -> float:
	return _gas_sim.o2_min_open() if _gas_sim != null else O2_AMBIENT
func o2_avg() -> float:
	return _gas_sim.o2_avg() if _gas_sim != null else O2_AMBIENT
# Emergent CARBON DIOXIDE (LAMaterialGas3D second channel): CO₂ level at a point + build-up diagnostics.
func co2_at(x: float, y: float, z: float) -> float:
	return _gas_sim.co2_at(x, y, z) if _gas_sim != null else 0.0
func co2_peak() -> float:
	return _gas_sim.co2_peak() if _gas_sim != null else 0.0
func co2_avg() -> float:
	return _gas_sim.co2_avg() if _gas_sim != null else 0.0
# Emergent DECOMPOSER loop (LAMaterialFungus3D): dead matter (detritus) → fungus → CO₂ + soil fertility.
## Deposit dead decomposable matter at the surface cell under a world point (a rotting carcass, wildfire
## ash). Fungus grows on it + rots it back into the carbon/nutrient loop. Mirrors photosynthesize()'s lookup.
func deposit_detritus(world_pos: Vector3, amount: float) -> void:
	if _cell_count <= 0 or amount <= 0.0:
		return
	var ix: int = _col_i(world_pos.x, _origin.x)
	var iz: int = _col_i(world_pos.z, _origin.z)
	var iy: int = _surface_iy(ix, iz)
	if iy < 0:
		return
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return
	if _detritus.size() != _cell_count:
		_detritus.resize(_cell_count)
	_detritus[i] += amount
func fungus_at(x: float, y: float, z: float) -> float:
	return _fungus_sim.fungus_at(x, y, z) if _fungus_sim != null else 0.0
func fungus_peak() -> float:
	return _fungus_sim.fungus_peak() if _fungus_sim != null else 0.0
func fungus_cells() -> int:
	return _fungus_sim.fungus_cells() if _fungus_sim != null else 0
func detritus_peak() -> float:
	return _fungus_sim.detritus_peak() if _fungus_sim != null else 0.0
## Daylight factor 0..1 (the heat module's solar term) — plants read it to gate PHOTOSYNTHESIS (day only).
func solar_factor() -> float:
	return _heat._solar() if _heat != null else 0.0
## Plant PHOTOSYNTHESIS write: at the sky-surface cell of `world_pos`, FIX `amount` of carbon — subtract CO₂
## and release the same mass of O₂ (stoichiometric). The return leg of the carbon loop: fire/decay make CO₂,
## plants turn it back into O₂ + biomass. `amount` is clamped to the CO₂ actually present (no free carbon).
func photosynthesize(world_pos: Vector3, amount: float) -> void:
	if _cell_count <= 0 or amount <= 0.0:
		return
	var ix: int = _col_i(world_pos.x, _origin.x)
	var iz: int = _col_i(world_pos.z, _origin.z)
	var iy: int = _surface_iy(ix, iz)
	if iy < 0:
		return
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return
	var fixed: float = minf(amount, _co2[i])
	if fixed <= 0.0:
		return
	_co2[i] = maxf(0.0, _co2[i] - fixed)
	_o2[i] = _o2[i] + fixed
## Wire the visual-only lightning bolt (VoxelDisasters.spawn_lightning); the field's charge fires it.
func set_lightning_visual(cb: Callable) -> void:
	if _charge_sim != null: _charge_sim.on_bolt = cb
func charge_peak() -> float:
	return _charge_sim.charge_peak() if _charge_sim != null else 0.0
func bolts_fired() -> int:
	return _charge_sim.bolts_fired() if _charge_sim != null else 0
## Inject a shock/sound wave (explosion, thunder, impact, stampede) — the ONE stimulus violent events feed;
## shock_at/shock_gradient are what the camera tremor + creature panic read (replaced the seismic ring).
func emit_shock(world_pos: Vector3, magnitude: float) -> void:
	if _shock_sim != null: _shock_sim.emit(world_pos, magnitude)
func shock_at(world_pos: Vector3) -> float:
	return _shock_sim.shock_at(world_pos) if _shock_sim != null else 0.0
func shock_gradient(world_pos: Vector3) -> Vector3:
	return _shock_sim.shock_gradient(world_pos) if _shock_sim != null else Vector3.ZERO
func shock_cell_count() -> int:
	return _shock_sim.shock_cells() if _shock_sim != null else 0


# The dynamic-water surface mesh is rebuilt each frame by the render adapter (MaterialFieldRender3D).
func rebuild_surface() -> void:
	if _render != null:
		_render.rebuild_surface()


## Central-telemetry provider (registered once with LASimReport): this field's channel aggregates, in ONE
## dict, so they flow into SIM_REPORT from their owner instead of being hand-threaded into a format string.
## Polled only at snapshot time, so these (cheap forwarder) reads don't run per frame.
func report() -> Dictionary:
	return {
		"wet_cells": wet_cell_count(), "heat_peak": peak_heat(), "heat_cells": hot_cell_count(),
		"lava_cells": lava_peak(), "cloud_cells": cloud_cell_count(), "cloud_cover": avg_cloud_cover(),
		"fog_cover": avg_fog_cover(), "wind": wind().length(), "scent_cells": scent_cell_count(),
		"fertility_peak": fertility_peak(), "magma_cells": magma_cell_count(),
		"erosion_cells": erosion_cell_count(), "snow_cells": snow_cell_count(), "ice_cells": ice_cell_count(),
		"dust_cells": dust_cell_count(), "charge_peak": charge_peak(), "bolts": bolts_fired(),
		"shock_cells": shock_cell_count(), "o2_min": o2_min_open(), "o2_avg": o2_avg(),
		"co2_peak": co2_peak(), "co2_avg": co2_avg(), "fungus_cells": fungus_cells(),
		"fungus_peak": fungus_peak(), "detritus_peak": detritus_peak(),
	}
