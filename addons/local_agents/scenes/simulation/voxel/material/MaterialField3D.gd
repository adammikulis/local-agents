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
# `_airwater`, frozen `_snow`). GPU-owned: the snowice deposition kernel + freeze/melt reaction records (R21/R22)
# grow and thaw it; read back for queries/telemetry only. SNOW_PRESENT = depth that counts a cell snow-covered;
# ICE_DEPTH = a thick pack that reads as glacial ice (the deep end of the same channel — no separate ice buffer).
const SNOW_PRESENT: float = 0.01
const ICE_DEPTH: float = 0.5
# Saturation curve sat(T) = SAT_BASE * exp(SAT_TEMP_GAIN * (T - EVAP_TEMP_REF)) — the dewpoint the unified
# `airwater` channel is read against. cloud/fog/vapor are DERIVED from airwater vs sat(T), never stored;
# these MUST match the kernel constants (atmos_evap/atmos_precip _sphere3d.glsl). FOG_MAX_TEMP splits the
# cool near-ground condensate (fog) from cloud aloft; CONDENSE_COVER_MIN is the density counted as cover.
const SAT_BASE: float = 0.06
const SAT_TEMP_GAIN: float = 0.055
const EVAP_TEMP_REF: float = 22.0
const FOG_MAX_TEMP: float = 12.0
const CONDENSE_COVER_MIN: float = 0.05
const RAIN_MASS_THRESHOLD: float = 0.45   # condensed mass over this sheds rain (matches atmos_precip_sphere3d)
# Scent channel indices (formerly LAMaterialScent3D.PREY/… — re-homed here after the CPU-oracle module was
# retired). External senses/cognition sites reference these via LAMaterialField3D.SCENT_*.
const SCENT_PREY: int = 0
const SCENT_PREDATOR: int = 1
const SCENT_BLOOD: int = 2
const SCENT_FOOD: int = 3
const SCENT_ALARM: int = 4
const SCENT_CHANNELS: int = 5
var _temp: PackedFloat32Array = PackedFloat32Array()     # temperature °C per cell (rock + void)
# ONE conserved atmospheric-water channel: total water suspended in a cell's air (Phase 2a — collapses the
# old vapor/cloud/fog trio). vapor = min(airwater, sat(T)); condensed = max(0, airwater − sat(T)); the
# condensed part reads as fog (cool + near ground) or cloud (else) — all DERIVED, nothing else stores it.
var _airwater: PackedFloat32Array = PackedFloat32Array()
# Frozen H₂O per cell (snowpack depth) — the SAME conserved substance as _water/_airwater, just the cold phase.
# GPU-owned (never re-uploaded); read back each frame for snow_cell_count/ice_cell_count/snow_depth_at + h2o_total.
var _snow: PackedFloat32Array = PackedFloat32Array()
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
# --- Emergent ELECTRIFICATION (LAMaterialCharge3D) + airborne DUST (LAMaterialDust3D). Field-resident so the
# GPU backend can own their per-cell compute (charge_accum3d / dust_*3d kernels) and round-trip them each
# frame like fire/fuel/sediment; the CPU modules reach into `_f._charge` / `_f._dust` (the CPU-oracle path).
var _charge: PackedFloat32Array = PackedFloat32Array()   # electrification charge per cell (updraft × supercooled cloud)
var _dust: PackedFloat32Array = PackedFloat32Array()     # airborne dust density per cell (wind-lofted sand storm)
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
const CoverBakerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/CoverTextureBaker.gd")
var _cover_baker = null                                  # LACoverTextureBaker — bakes the render cover texture
var _gpu = null                                          # LAMaterialSphereGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false
var _core_temp: float = 0.0                              # geothermal core pin temperature (0 = disarmed)
var _core_cells: PackedInt32Array = PackedInt32Array()  # static innermost-shell cell indices (built once)
# Read-only query accessors + the write-side injection facade (factored out; see those files).
var _queries = null                                      # LAMaterialFieldQueries3D
var _inject = null                                       # LAMaterialFieldInject3D (write-side injection + FX)


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
# Persistent water sources (springs) injected each step: [{pos, rate}].
var _sources: Array = []


# --- Setup ------------------------------------------------------------------

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
	_airwater = PackedFloat32Array()
	_airwater.resize(_cell_count)
	_airwater.fill(VAPOR_AMBIENT)
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

func _col_i(w: float, o: float) -> int:
	return clampi(int(round((w - o) / _cell_size)), 0, _dim_x - 1)


# 2.5D COLUMN queries — meaningless on a cubed-sphere (no vertical XZ column). Return safe defaults in sphere
# mode; radial callers use terrain.surface_radius / sea_radius / is_submerged_at instead.
func column_surface_y(ix: int, iz: int) -> float:
	if _sphere != null:
		return NAN
	return _queries.column_surface_y(ix, iz)


func surface_y_at(x: float, z: float) -> float:
	if _sphere != null:
		return NAN
	return _queries.surface_y_at(x, z)


func is_water_at(x: float, z: float) -> bool:
	if _sphere != null:
		return false
	return _queries.is_water_at(x, z)


func depth_at(x: float, z: float) -> float:
	if _sphere != null:
		return 0.0
	return _queries.depth_at(x, z)


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
	if is_sphere() and SphereGPUScript.available() and not OS.has_environment("LA_FORCE_CPU"):
		# Cubed-sphere planet: the sphere GPU driver runs the *_sphere3d kernels over the neighbour SSBO.
		_gpu = SphereGPUScript.new()
		_gpu.setup(self)
		_use_gpu = true
	_inject = InjectScript.new()
	_inject.setup(self)
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

## Release the GPU driver's local RenderingDevice while the tree is still up — deferring it to engine
## shutdown crashes (recursive_mutex under windowed metal). Covers both the box and sphere drivers.
func _exit_tree() -> void:
	if _gpu != null and _gpu.has_method("dispose"):
		_gpu.dispose()


## Cubed-sphere per-frame step (Phase B MVP): activate the sphere GPU driver once, then run the fixed-step
## begin_frame/step/end_frame loop over the *_sphere3d kernels and scatter temp/water back. No box CPU tails.
func _sphere_process(delta: float) -> void:
	if not _ready_sim:
		if _terrain == null or not _terrain.has_method("is_solid"):
			return
		_sample_solidity_sphere()
		_seed_sphere_sea()         # static field sea = the evaporation source that drives the water cycle
		activate()                 # is_sphere() → picks SphereGPUScript + sets _use_gpu
		_ready_sim = true
		return
	if not _use_gpu:
		return
	_step_accum += delta
	var steps: int = 0
	while _step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_step_accum -= STEP_DT
		steps += 1
	if steps <= 0:
		return
	var t0: int = Time.get_ticks_usec()
	# Global scalar solar term is a constant fallback; the per-cell solar terminator comes from the sphere
	# ThermalPass' set_sun_dir kernel (max(0, dot(cell_radial, sun_dir))), not this scalar.
	var solar: float = 0.6
	_pin_core_heat()                 # geothermal boundary: re-pin the hot inner shells before the upload
	_gpu.begin_frame(_temp, _water, solar, Vector2.ZERO)
	# Per-cell solar terminator + marine cooling need the world-space sun direction and the sea shell radius.
	# sun_dir points from the planet toward the star; ThermalPass' solar kernel does max(0, dot(cell_radial, sun_dir)).
	if _sun_light != null and _gpu.has_method("set_sun_dir"):
		_gpu.set_sun_dir(_sun_light.global_transform.basis.z)
	if _terrain != null and _terrain.has_method("sea_radius") and _gpu.has_method("set_sea_radius"):
		_gpu.set_sea_radius(_terrain.sea_radius())
	for i in steps:
		_gpu.step()
	var res: Dictionary = _gpu.end_frame()
	_apply_sphere_readback(res)
	LASimReport.gauge("field_ms", float(Time.get_ticks_usec() - t0) / 1000.0)


## Scatter every channel the sphere driver read back into its CPU array, so actor world-space queries
## (temp_at/o2_at/co2_at/is_submerged_at, routed through world_to_cell) and the SIM_REPORT field metrics
## see LIVE field state instead of the stale seed values. The readback cost is already paid inside
## end_frame(); assigning a PackedFloat32Array is a cheap COW reference. Guarded per channel by size.
func _apply_sphere_readback(res: Dictionary) -> void:
	if res.has("temp") and res["temp"].size() == _cell_count: _temp = res["temp"]
	if res.has("water") and res["water"].size() == _cell_count: _water = res["water"]
	if res.has("airwater") and res["airwater"].size() == _cell_count: _airwater = res["airwater"]
	_atmos_dirty = true          # new airwater/temp → invalidate the cached condensate aggregates
	if res.has("lava") and res["lava"].size() == _cell_count: _lava = res["lava"]
	if res.has("fire") and res["fire"].size() == _cell_count: _fire = res["fire"]
	if res.has("o2") and res["o2"].size() == _cell_count: _o2 = res["o2"]
	if res.has("co2") and res["co2"].size() == _cell_count: _co2 = res["co2"]
	if res.has("biomass") and res["biomass"].size() == _cell_count: _biomass = res["biomass"]
	if res.has("snow") and res["snow"].size() == _cell_count: _snow = res["snow"]
	if res.has("dust") and res["dust"].size() == _cell_count: _dust = res["dust"]


func _physics_process(delta: float) -> void:
	# The cubed-sphere is the SOLE substrate: one self-contained GPU step over the *_sphere3d kernels.
	# (The retired box grid + its CPU-oracle tails lived here; deleted with the sphere-only cleanup.)
	if is_sphere():
		_sphere_process(delta)


## Temperature °C at a world point (0 outside the grid). The consumer query the 2.5D field also exposes.
func temp_at(x: float, z: float, y: float = NAN) -> float:
	if _sphere != null:
		if is_nan(y):
			return INITIAL_TEMP           # 2.5D-style call has no radial point; safe default
		var c: int = world_to_cell(Vector3(x, y, z))
		return _temp[c] if c >= 0 else INITIAL_TEMP
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


# --- Atmosphere queries — all DERIVED from the one conserved `airwater` channel vs sat(T) (Phase 2a).
# cloud/fog/vapor are no longer stored; every reader below recomputes them instantaneously from _airwater +
# _temp. Signatures are unchanged so WeatherSystem/Thunderstorm/CloudLayer/RainLayer keep working.

## Saturation humidity at temperature `t` — the dewpoint airwater is read against. MUST match the kernel
## constants in atmos_evap/atmos_precip_sphere3d.glsl.
func _sat(t: float) -> float:
	return SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF))

## Suspended condensate (liquid/ice) at a linear cell = the airwater over saturation. 0 for solid/oob cells.
func _condensed_at(cell: int) -> float:
	if cell < 0 or cell >= _cell_count or _solid[cell] != 0:
		return 0.0
	return maxf(0.0, _airwater[cell] - _sat(_temp[cell]))

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
# ONE pass recomputes all of them together and caches, invalidated only when a new airwater/temp field is
# read back (~10Hz). Big-O: one O(cells) pass per SIM step, not per query × per frame.
var _atmos_dirty: bool = true
var _cloud_cover_c: float = 0.0
var _fog_cover_c: float = 0.0
var _cloud_cells_c: int = 0
var _precip_c: float = 0.0
var _airwater_total_c: float = 0.0

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
		var aw: float = _airwater[i]
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
	_airwater_total_c = total
	# Fold the render cover-texture bake into this same ~10Hz condensate pass (the water-particle renderer
	# samples it per particle). Cheap: one extra O(cell_count) reduction over the CPU readback we already have.
	if _sphere != null:
		_ensure_cover_baker()
		if _cover_baker != null:
			_cover_baker.bake(_airwater, _temp, _snow, _solid, _cell_count)


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
func airwater_total() -> float:
	if _atmos_dirty:
		_refresh_atmos_aggregates()
	return _airwater_total_c

# The flat cloud/fog sheet projection (cloud_grid/fog_grid) was a box-era concept, dissolved with the
# CloudLayer sheets — the water-particle renderer samples the baked cover texture instead. cloud_base_y/
# fog_base_y survive as the near-ground radii the derived point queries (cloud_at/fog_at) sample at.
func cloud_base_y() -> float:
	return sea_level + 62.0

func fog_base_y() -> float:
	return sea_level + 6.0

## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(airwater, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _solid[c] != 0:
		return 0.0
	var s: float = _sat(_temp[c])
	if s <= 0.0:
		return 0.0
	return clampf(_airwater[c] / s, 0.0, 1.0)

## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's airwater would
## saturate (invert sat(T)). NAN if unresolved or bone dry.
func dewpoint_at(x: float, z: float) -> float:
	var c: int = world_to_cell(Vector3(x, fog_base_y(), z))
	if c < 0 or _solid[c] != 0 or _airwater[c] <= 0.0:
		return NAN
	return EVAP_TEMP_REF + log(_airwater[c] / SAT_BASE) / SAT_TEMP_GAIN

## Prevailing (large-scale) wind input. The emergent wind now lives on the GPU; forward it to the driver.
func set_wind(w: Vector2) -> void:
	if _gpu != null and _gpu.has_method("set_prevailing"):
		_gpu.set_prevailing(w)

## Domain-average horizontal wind (ocean swell / HUD) — CPU wind oracle retired; safe default.
func wind() -> Vector2:
	return Vector2.ZERO

## LOCAL horizontal wind (world XZ) at a point — CPU wind oracle retired; safe default.
func wind_at(x: float, z: float) -> Vector2:
	return Vector2.ZERO

## Vertical vorticity (air SPIN) at a world point — storm actors track/scale off the emergent vortex.
func vorticity_at(x: float, z: float) -> float:
	return _queries.vorticity_at(x, z)

## Vertical updraft (+Y wind) at a column — the convective lift a thunderstorm/tornado feeds on.
func updraft_at(x: float, z: float) -> float:
	return _queries.updraft_at(x, z)

## Full LOCAL 3D wind velocity at a world point — CPU wind oracle retired; safe default.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	return Vector3.ZERO

## The cloud/fog grids project to (dim_x × dim_z) so CloudLayer's texture maps 1:1 with the 2.5D field.
func grid_dim() -> int:
	return _dim_x

func grid_half_extent() -> float:
	return _half_extent


# Heat + lava injection (disasters call these) + diagnostics. The CPU heat/lava/atmosphere oracles are
# retired and these channels are not yet wired to the sphere GPU driver's inject path, so the writes are
# no-ops (safe default) until that lands; the read diagnostic returns 0.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	pass

func add_lava(world_pos: Vector3, amount: float) -> void:
	pass

## Inject airborne water vapor (humidity) at a world point — a storm's LOCAL moisture source. No-op until
## the sphere GPU vapor inject path is wired.
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	pass

## Cool a volume (negative heat) — a storm's cold aloft. Thin helper over add_heat.
func add_cooling(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	add_heat(world_pos, -absf(amount), maxf(0.0, radius))

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


## Count of OPEN cells carrying derived condensate (airwater over saturation) at/above CONDENSE_COVER_MIN.
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


# --- Scent / waste / fertility — CPU scent oracle retired; the sphere scent readback is not yet wired, so
# deposits are no-ops and reads return safe defaults (SCENT_PREY/… channel indices live at the top). ------

## Drop feces/urine at a world point. No-op until the sphere scent path is wired.
func deposit_waste(world_pos: Vector3, creature, kind: String) -> void:
	pass

## A fresh burst of BLOOD scent (a wound or a kill).
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	pass

## A carcass advertising FOOD (the decaying-corpse cue scavengers follow).
func deposit_food(world_pos: Vector3, amount: float) -> void:
	pass

## Scent density of a channel (SCENT_PREY/PREDATOR/BLOOD/FOOD/ALARM) at a world point.
func scent_at(world_pos: Vector3, channel: int) -> float:
	return 0.0

## Normalized XZ direction UP a scent channel's gradient (predator tracking, prey avoidance).
func scent_gradient(world_pos: Vector3, channel: int) -> Vector3:
	return Vector3.ZERO

## Soil nutrient at a world point (plants grow faster on rich ground).
func fertility_at(world_pos: Vector3) -> float:
	return 0.0

## Columns carrying meaningful airborne scent (SMOKE_SUMMARY `scent_cells`).
func scent_cell_count() -> int:
	return 0

## Peak soil nutrient (SMOKE_SUMMARY `fertility_peak`).
func fertility_peak() -> float:
	return 0.0


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
func snow_depth_at(x: float, z: float, y: float = NAN) -> float:
	if _snow.size() != _cell_count:
		return 0.0
	if is_nan(y):
		return 0.0
	var c: int = world_to_cell(Vector3(x, y, z))
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
		if _solid[c] == 0:
			sum += _water[c]
	return sum
## Conserved H₂O budget of the DYNAMIC system: liquid water + airborne airwater + frozen snow. Freeze/melt/
## deposition/evap/rain are all pure transfers between these three, so this must stay BOUNDED (a slow static-sea
## source + rain-to-sea sink hold it at a steady level) — the mass-conservation spot check fed into SIM_REPORT.
func h2o_total() -> float:
	return water_total() + airwater_total() + snow_total()
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
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		if c < 0:
			return O2_AMBIENT                 # above the atmosphere shell = open sky
		if _solid[c] != 0 or _water[c] >= MAX_MASS * 0.5:
			return 0.0
		return _o2[c]
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
	if _sphere != null:
		var c: int = world_to_cell(Vector3(x, y, z))
		return c >= 0 and _solid[c] == 0 and _water[c] >= MAX_MASS * 0.5
	var ix: int = _col_i(x, _origin.x)
	var iy: int = clampi(int(round((y - _origin.y) / _cell_size)), 0, _dim_y - 1)
	var iz: int = _col_i(z, _origin.z)
	if not _in_bounds(ix, iy, iz):
		return false
	var i: int = _idx(ix, iy, iz)
	return _solid[i] == 0 and _water[i] >= MAX_MASS * 0.5
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
## Wire the visual-only lightning bolt (VoxelDisasters.spawn_lightning). No-op until sphere charge is wired.
func set_lightning_visual(cb: Callable) -> void:
	pass
func charge_peak() -> float:
	return 0.0
func bolts_fired() -> int:
	return 0
## Inject a shock/sound wave (explosion, thunder, impact, stampede). CPU shock oracle retired; no-op emitter
## + safe-default reads (camera tremor + creature panic) until the sphere shock channel is wired.
func emit_shock(world_pos: Vector3, magnitude: float) -> void:
	pass
func shock_at(world_pos: Vector3) -> float:
	return 0.0
func shock_gradient(world_pos: Vector3) -> Vector3:
	return Vector3.ZERO
func shock_cell_count() -> int:
	return 0


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
		"fog_cover": avg_fog_cover(), "airwater_total": airwater_total(),
		"wind": wind().length(), "scent_cells": scent_cell_count(),
		"fertility_peak": fertility_peak(), "magma_cells": magma_cell_count(),
		"erosion_cells": erosion_cell_count(), "snow_cells": snow_cell_count(), "ice_cells": ice_cell_count(),
		"dust_cells": dust_cell_count(), "charge_peak": charge_peak(), "bolts": bolts_fired(),
		"shock_cells": shock_cell_count(), "o2_min": o2_min_open(), "o2_avg": o2_avg(),
		"co2_peak": co2_peak(), "co2_avg": co2_avg(), "fungus_cells": fungus_cells(),
		"fungus_peak": fungus_peak(), "detritus_peak": detritus_peak(),
		"biomass_total": biomass_total(),
		"h2o_total": h2o_total(), "water_total": water_total(), "snow_total": snow_total(),
		"snow_line_temp": snow_line_temp(),
	}
	r.merge(_open_temp_stats())
	return r
