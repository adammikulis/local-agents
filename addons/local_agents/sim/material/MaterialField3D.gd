class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D: the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).

const SolidCacheScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSolidCache3D.gd")
const GravityScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldGravity3D.gd")
const MineralStampScript: GDScript = preload("res://addons/local_agents/sim/material/MineralStamp3D.gd")

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
## The dictionary PlanetBody.setup() was given — the full definition of this world's terrain, and the key
## the solid-mask cache is hashed from.
var _terrain_opts: Dictionary = {}
var _cell_size: float = 5.0
var _origin: Vector3 = Vector3.ZERO       # world position of cell (0,0,0) centre
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0

var _solid: PackedByteArray = PackedByteArray()          # 1 = rock (holds no fluid), 0 = void (air/water)
# ONE H2O CHANNEL, every phase. Volume fraction of the cell. Which phase it is in is DERIVED per cell from
# its enthalpy by state_derive.glsl and mirrored back into the three share arrays below.
var _h2o: PackedFloat32Array = PackedFloat32Array()
var _h2o_solid: PackedFloat32Array = PackedFloat32Array()    # share of _h2o that is ice
var _h2o_liquid: PackedFloat32Array = PackedFloat32Array()   # share that is liquid, free or in pores
var _h2o_vapour: PackedFloat32Array = PackedFloat32Array()   # share that is vapour

# --- Shared 3D field state used by the concern modules (heat / atmosphere / lava). Every cell (rock OR
const INITIAL_TEMP: float = 15.0
# Gas channel seeds, mol/m^3: air's molar density times each gas's mole fraction.
# FREE OXYGEN IS A PRODUCT OF LIFE. It starts at zero and has to be earned.
const O2_AMBIENT: float = 0.0
const CO2_AMBIENT: float = LAPhysical.AIR_MOLAR_DENSITY_MOL_M3 * LAPhysical.AIR_MOLE_FRAC_CO2
const N2_AMBIENT: float = LAPhysical.AIR_MOLAR_DENSITY_MOL_M3 * LAPhysical.AIR_MOLE_FRAC_N2
# ICE_DEPTH = a thick pack that reads as glacial ice (the deep end of the same channel — no separate ice buffer).
const SNOW_PRESENT: float = 1.9e-4
const ICE_DEPTH: float = 0.5              # ~8 m water equivalent = a real glacial thickness, not a snowfall
const FOG_MAX_TEMP: float = 12.0
# Condensate at which a cell counts as covered, mol/m^3: 5e-5 kg/m^3 of condensed H2O over its molar mass.
const CONDENSE_COVER_MIN: float = 5.0e-5 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
var _h: PackedFloat32Array = PackedFloat32Array()        # THE STATE: enthalpy J/m^3 per cell
var _temp: PackedFloat32Array = PackedFloat32Array()     # DERIVED °C, rewritten by StateDerivePass each step
# Fractional BEDROCK mineral mass per cell (Stage B). `solid` is DERIVED from it on the GPU (solid iff >= 0.5).
# GPU-owned + GPU-evolved (M5/M6 records).
var _rock_fill: PackedFloat32Array = PackedFloat32Array()
var _lava: PackedFloat32Array = PackedFloat32Array()     # lava mass per cell (a hot, viscous liquid)
# --- Emergent FIRE / COMBUSTION (LAMaterialCombustion3D): a FUEL channel (flammable vegetation mass seeded
var _fuel: PackedFloat32Array = PackedFloat32Array()     # flammable fuel mass per cell (vegetation)
var _fire: PackedFloat32Array = PackedFloat32Array()     # burning intensity per cell (0 = not burning)
var _o2: PackedFloat32Array = PackedFloat32Array()       # atmospheric O₂ per cell, mol/m^3
var _co2: PackedFloat32Array = PackedFloat32Array()      # atmospheric CO₂ per cell, mol/m^3
var _n2: PackedFloat32Array = PackedFloat32Array()       # atmospheric N₂ per cell, mol/m^3
# --- Emergent DECOMPOSER loop (the decompose and die-back records in LABioRecords)
var _detritus: PackedFloat32Array = PackedFloat32Array() # dead decomposable organic matter per cell (0 = none)
# The hydrogen and oxygen bound in the dead organic pool (detritus + fuel). org_h/(detritus+fuel) is the cell's
# molar H:C, org_o/(...) its O:C — GPU-owned, seeded here at fresh CH2O and driven down by coalification.
var _org_h: PackedFloat32Array = PackedFloat32Array()
var _org_o: PackedFloat32Array = PackedFloat32Array()
var _fungus: PackedFloat32Array = PackedFloat32Array()   # fungal biomass density per cell (0 = none; high = mushrooms)
# Soil FERTILITY per cell — the decomposer loop's output (detritus → fungus → CO₂ + fertility). GPU-owned PAIR
# channel (scent_fert blur/leach + fungus_fert deposit); read back each frame for fertility_at/fertility_peak.
var _fert: PackedFloat32Array = PackedFloat32Array()     # soil nutrient density per cell (0 = barren)
# --- Emergent LIVING BIOMASS (MaterialReactions3D R19/R20 — the plant carbon-fix leg dissolved into the field).
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
var _sun_light = null                                    # DirectionalLight3D — solar forcing (top cells)

var _ecology = null                                      # LAEcologyService back-ref (ash regrowth / actor coupling)
const SphereGPUScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSphereGPU3D.gd")
const QueriesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldQueries3D.gd")
const InjectScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInject3D.gd")
const SphereStepScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd")
const SurfaceSeedScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd")
const OrganicScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldOrganic3D.gd")
var _gpu = null                                          # LAMaterialSphereGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false
var _geotherm = null                                     # LAMaterialFieldGeotherm3D — radiogenic heat in the rock
# Read-only query accessors + the write-side injection facade (factored out; see those files).
var _queries = null                                      # LAMaterialFieldQueries3D
var _inject = null                                       # LAMaterialFieldInject3D (write-side injection + FX)
var _stamp = null                                        # LAMineralStamp3D — Stage C rock_fill->SDF growth stamp
var _sphere_step = null                                  # LAMaterialFieldSphereStep3D — the per-frame step loop
var _surface_seed = null                                 # LAMaterialSurfaceSeed3D — ground-surface fuel + soil detritus seed/refill
var _organic = null                                      # LAMaterialFieldOrganic3D — the dead pool's C:H:O gauge
# Substrate-foundation primitive modules (the field only delegates; all logic lives in these). Seams the
# per-actor dissolution agents fill: shock (Earthquake/Meteor), charge→bolt (Thunderstorm), ejecta (bombs/debris).
var _shock_mod = null                                    # LAMaterialShock3D — shock channel + emit/readback
var _charge_mod = null                                   # LAMaterialCharge3D — charge readback + breakdown→bolt
var _ejecta = null                                       # LAMaterialEjecta3D — momentum/ejecta parcels (Node3D child)
var _pending_lightning_cb: Callable = Callable()         # lightning visual callback (registered pre-activate)
const ShockScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialShock3D.gd")
const ChargeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialCharge3D.gd")
const EjectaScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialEjecta3D.gd")
# they hold no per-cell state (every one reaches back into this field's arrays), so the field stays the thin
# facade + step orchestration and each family is independently ownable.
var _atmos = null                                     # LAMaterialFieldAtmos3D — condensate derivation + aggregates
var _ledger = null                                       # LAMaterialFieldLedger3D — conserved H₂O ledger + snow/ice
var _channels = null                                     # LAMaterialFieldChannels3D — per-cell gas/biomass/phase reads
var _report_mod = null                                   # LAMaterialFieldReport3D — SIM_REPORT telemetry snapshot
var _regolith_mod = null                                 # LAMaterialFieldRegolith3D — aquifer rock: mask, grain size, porosity
var _biota = null                                        # LAMaterialFieldBiota3D — the living-body <-> field matter seam
const AtmosScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldAtmos3D.gd")
const LedgerScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldLedger3D.gd")
const ChannelsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldChannels3D.gd")
const ReportScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldReport3D.gd")
const GeothermScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldGeotherm3D.gd")
const RegolithScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldRegolith3D.gd")
const BiotaScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldBiota3D.gd")


func _init() -> void:
	_atmos = AtmosScript.new()
	_atmos.setup(self)
	_geotherm = GeothermScript.new()
	_geotherm.setup(self)
	_ledger = LedgerScript.new()
	_ledger.setup(self)
	_channels = ChannelsScript.new()
	_channels.setup(self)
	_report_mod = ReportScript.new()
	_report_mod.setup(self)
	_regolith_mod = RegolithScript.new()
	_regolith_mod.setup(self)
	_biota = BiotaScript.new()
	_biota.setup(self)


## Wire the real scene sun (DirectionalLight3D); the heat module reads its energy + angle for solar input.
func set_sun(light) -> void:
	_sun_light = light


var _body = null                                         # LAPlanetBody — the frame this grid rides
var _body_basis: Basis = Basis.IDENTITY                  # body->world rotation, refreshed once per step
var _body_basis_inv: Basis = Basis.IDENTITY


## Wire the planet body whose rotation this grid rides. Null (a flat world, a bare field test) leaves the
## basis identity, so every conversion below is a no-op and the field behaves exactly as it did before.
func set_body(body) -> void:
	_body = body


## Refresh the cached body rotation. Called once per field step, before anything converts a position.
func sync_body_frame() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	_body_basis = (_body as Node3D).global_transform.basis.orthonormalized()
	_body_basis_inv = _body_basis.inverse()


## A world DIRECTION expressed in the field's (body-local) frame — sun_dir and any other bare direction.
func dir_to_field(world_dir: Vector3) -> Vector3:
	return _body_basis_inv * world_dir


## A world POINT in the field's frame. Rotation is about the body centre, so that offset comes out first —
## that is the part a basis-only transform gets wrong.
func point_to_field(world_pos: Vector3) -> Vector3:
	var pivot: Vector3 = centre()
	return pivot + _body_basis_inv * (world_pos - pivot)


## Radius of the sea shell, model units, measured from `centre()`.
func sea_radius() -> float:
	if _terrain != null and _terrain.has_method("sea_radius"):
		return float(_terrain.sea_radius())
	return 0.0


# --- Frame loop + rendering -------------------------------------------------
const STEP_HZ: float = 10.0
const STEP_DT: float = 1.0 / STEP_HZ
const MAX_STEPS_PER_FRAME: int = 2
const RENDER_MIN: float = 0.08            # min water mass in a cell for its top face to render
const SEA_WAVE_EPS: float = 0.6           # calm-sea top faces within this of the sea shell are left to the ocean plane
var _step_accum: float = 0.0
var _ready_sim: bool = false
var _seal = null
# --- Per-frame CPU-cost throttles (the field is CPU-bound; these cut redundant full-grid work while
const HEAT_TEX_EVERY: int = 3            # terrain-glow heat texture refresh cadence (full-grid column scan)
const SLOW_READ_EVERY: int = 3           # render-only GPU readback cadence for vapor/cloud/fog
var _heat_tex_tick: int = 0
var _slow_read_tick: int = 0
var _charge_woke: bool = false           # a charge injection woke the breakdown scan
var _fuel_dirty: bool = false            # fuel seeded on the CPU → seed the GPU fuel buffer before step 0
var _detritus_seed_dirty: bool = false   # one-shot: initial soil detritus seeded → upload once before the first step
var _organic_seed_dirty: bool = false    # one-shot: the seeded litter's C:H:O pushed once, with the detritus seed
# Lazy solidity sampling: the field is created before the terrain has finished streaming, so it samples
# rock/void a budget of columns per frame and self-activates (seed sea + build modules) once complete —
# exactly how the old field lazily sampled heights. No blocking, no external init calls.
const SAMPLE_COLS_PER_FRAME: int = 700
var _sampling_done: bool = false
var _sample_cursor: int = 0
# Persistent water sources (springs) injected each step: [{pos, rate}].
var _sources: Array = []


# --- Setup ------------------------------------------------------------------

## THE ONE GRID: a uniform Cartesian box. Nothing here holds a second index layout.
var _grid: LAVoxelGrid = null
## Gravity, SOLVED from the mass that is there. There is no gravity constant anywhere in this tree.
var _gravity = null                                      # LAMaterialFieldGravity3D

## Lay the field over a box centred on a body of `radius`, at `cell_size` resolution.
func setup_body(centre_pos: Vector3, radius: float, cell_size: float, terrain = null) -> void:
	if terrain != null:
		_terrain = terrain
		if terrain.has_method("generator_options"):
			_terrain_opts = terrain.generator_options()   # the solid-mask cache's key
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build_centred(centre_pos, radius, maxf(0.5, cell_size))
	_adopt(grid)

## Lay the field over an explicit box. Same grid, same lifecycle: an extent is not a second kind of world.
func setup_dims(dim_x: int, dim_y: int, dim_z: int, cell_size: float, origin: Vector3) -> void:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(dim_x, dim_y, dim_z, cell_size, origin)
	_adopt(grid)

## ONE lifecycle. A box and a body differ in extent and in nothing else: both step, both solve gravity,
## both run the kernels. A field that adopts a grid without a step module never advances.
func _adopt(grid: LAVoxelGrid) -> void:
	_grid = grid
	_dim_x = grid.nx
	_dim_y = grid.ny
	_dim_z = grid.nz
	_cell_size = grid.cell_size
	_origin = grid.origin
	_cell_count = grid.cell_count
	_alloc_channels()
	_gravity = GravityScript.new()
	_gravity.setup(self)
	# Per-frame step orchestration (begin/step/end + readback). Without it the field never advances.
	_sphere_step = SphereStepScript.new()
	_sphere_step.setup(self)

## The body centre — the pivot the grid's rotation turns about, and the origin `sea_radius` is measured from.
func centre() -> Vector3:
	return LAFieldGeometry.centre(self)

## Re-solve gravity from the mass that is there. Returns true when a solve actually ran.
func solve_gravity() -> bool:
	return _gravity.step() if _gravity != null else false

## Allocate + seed every per-cell channel for the current `_cell_count`.
func _alloc_channels() -> void:
	_solid = PackedByteArray()
	_solid.resize(_cell_count)
	_h2o = PackedFloat32Array()
	_h2o.resize(_cell_count)
	_h2o_solid = PackedFloat32Array()
	_h2o_solid.resize(_cell_count)
	_h2o_liquid = PackedFloat32Array()
	_h2o_liquid.resize(_cell_count)
	_h2o_vapour = PackedFloat32Array()
	_h2o_vapour.resize(_cell_count)
	_h = PackedFloat32Array()
	_h.resize(_cell_count)
	_temp = PackedFloat32Array()
	_temp.resize(_cell_count)
	_temp.fill(INITIAL_TEMP)
	_lava = PackedFloat32Array()
	_lava.resize(_cell_count)
	# Bedrock mineral fraction: seeded from the solid mask on activate (mirrors _solid), GPU-owned thereafter.
	_rock_fill = PackedFloat32Array()
	_rock_fill.resize(_cell_count)
	_fuel = PackedFloat32Array()
	_fuel.resize(_cell_count)
	_fire = PackedFloat32Array()
	_fire.resize(_cell_count)
	# THE AIR, seeded once and finite thereafter, in mol/m^3.
	_o2 = PackedFloat32Array()
	_o2.resize(_cell_count)
	_o2.fill(O2_AMBIENT)
	_co2 = PackedFloat32Array()
	_co2.resize(_cell_count)
	_co2.fill(CO2_AMBIENT)
	_n2 = PackedFloat32Array()
	_n2.resize(_cell_count)
	_n2.fill(N2_AMBIENT)
	# Detritus + fungus start empty; carcasses/ash deposit detritus, fungus grows on it (decomposer loop).
	_detritus = PackedFloat32Array()
	_detritus.resize(_cell_count)
	_org_h = PackedFloat32Array()
	_org_h.resize(_cell_count)
	_org_o = PackedFloat32Array()
	_org_o.resize(_cell_count)
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
	# Read-only query accessors bind to this field now; the arrays they read exist from here on.
	_queries = QueriesScript.new()
	_queries.setup(self)


# --- Index helpers ----------------------------------------------------------

func _idx(ix: int, iy: int, iz: int) -> int:
	return _grid.index(ix, iy, iz)


func _in_bounds(ix: int, iy: int, iz: int) -> bool:
	return _grid.in_bounds(ix, iy, iz)


func cell_world_pos(ix: int, iy: int, iz: int) -> Vector3:
	return _grid.cell_world_pos(_grid.index(ix, iy, iz))


# --- The world↔cell seam ---------------------------------------------------------------------------------

## World centre of a linear cell index. Body-local -> world: the grid rides the body, so a cell's WORLD
## position turns with it.
func cell_world_pos_linear(c: int) -> Vector3:
	var pivot: Vector3 = centre()
	return pivot + _body_basis * (_grid.cell_world_pos(c) - pivot)

func cell_size() -> float:
	return _cell_size


## World position → linear cell index, -1 outside the box. Every actor hands us a world position (actors are
## children of the spinning body), so this is where their frame and the grid's are reconciled.
func world_to_cell(world_pos: Vector3) -> int:
	return _grid.cell_at(point_to_field(world_pos)) if _grid != null else -1


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
	_h2o[i] = maxf(0.0, _h2o[i] + amount)
	if _gpu != null: _gpu.mark_water_dirty()   # CPU h2o edit → re-upload it next begin_frame


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	return _queries.water_at_cell(ix, iy, iz)


func total_water() -> float:
	return _queries.total_water()


# --- The 3D water CA --------------------------------------------------------

# Stable amount for the LOWER of two stacked water cells given their combined mass: the excess over
# MAX_MASS compresses upward, so water in a connected cavern finds a common level.
func _stable_below(total_mass: float) -> float:
	if total_mass <= MAX_MASS:
		return total_mass
	if total_mass < 2.0 * MAX_MASS + MAX_COMPRESS:
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS)
	return (total_mass + MAX_COMPRESS) * 0.5


# --- World-space queries (delegated to _queries; the 2.5D-compatible API consumers call) --------

# Water in the point's own cell, or the sea/lake shell over the ground beneath it.
func is_water_at(pos: Vector3) -> bool:
	return _queries.is_water_at(pos)


# World-space WATER CURRENT (sweep) force at a point — downhill × depth × slope; ZERO in still/dry ground.
# The seam creatures (mass-scaled drag) and plants (uproot vs root strength) read to be swept by moving water.
func water_force_at(pos: Vector3) -> Vector3:
	return _queries.water_force_at(pos)




# --- Live frame loop + fluid-surface rendering ------------------------------

## Begin simulating + rendering (called after setup + sample_solidity + seed_sea). Builds the render
## node and starts the throttled step in _physics_process.
func activate() -> void:
	# The state the device is seeded FROM, so it is filled before the driver reads it.
	LAFieldEnthalpySeed.seed(self, INITIAL_TEMP)
	if _grid != null and SphereGPUScript.available() and not OS.has_environment("LA_FORCE_CPU"):
		# The GPU driver runs the kernels over the grid's neighbour SSBO.
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
	_organic = OrganicScript.new()
	_organic.setup(self)
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
	_ejecta = EjectaScript.new()
	_ejecta.setup(self)
	add_child(_ejecta)                            # Node3D: integrates ballistic parcels + owns the GPU ejecta particles
	_ready_sim = true


## Solid mask: sample the terrain SDF per cell (world pos from the grid). One-time at activation.
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid") or _grid == null:
		return
	var k: String = ""
	if not _terrain_opts.is_empty():
		k = SolidCacheScript.key(_terrain_opts, _grid)
		var cached: PackedByteArray = SolidCacheScript.load_mask(k, _cell_count, self)
		if cached.size() == _cell_count:
			_solid = cached
			_seed_rock_fill()
			return
	for c in _cell_count:
		_solid[c] = 1 if _terrain.is_solid(cell_world_pos_linear(c)) else 0
	if k != "":
		SolidCacheScript.save_mask(k, _solid)
	_seed_rock_fill()

## Bedrock fraction mirrors the sampled mask, so the gravity solve has mass to read before the first step.
func _seed_rock_fill() -> void:
	if _rock_fill.size() != _cell_count or _solid.size() != _cell_count:
		return
	for c in _cell_count:
		_rock_fill[c] = 1.0 if _solid[c] != 0 else 0.0

func _seed_sea() -> void:
	if _grid == null or _terrain == null or not _terrain.has_method("sea_radius"):
		return
	var sea_r: float = _terrain.sea_radius()
	if sea_r <= 0.0:
		return
	var sea_sq: float = sea_r * sea_r
	var pivot: Vector3 = centre()
	for c in _cell_count:
		if _solid[c] != 0:
			continue
		if (_grid.cell_world_pos(c) - pivot).length_squared() <= sea_sq:
			_h2o[c] = 1.0

const REGOLITH_CELLS: int = LAMaterialFieldRegolith3D.REGOLITH_CELLS
# Athy pore fraction per cell (0 outside regolith), GPU-written and read back on the slow cadence.
var _porosity: PackedFloat32Array = PackedFloat32Array()
var _regolith: PackedByteArray = PackedByteArray()
var _grain: PackedFloat32Array = PackedFloat32Array()    # representative grain diameter (m) per regolith cell

func _compute_regolith() -> void:
	_regolith_mod.compute()


## Release the GPU driver's local RenderingDevice while the tree is still up, so every RID is freed cleanly.
func _exit_tree() -> void:
	if _gpu != null and _gpu.has_method("dispose"):
		_gpu.dispose()


func _physics_process(delta: float) -> void:
	if _sphere_step != null:
		_sphere_step.process(delta)


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
var _atmos_dirty: bool = true
var _cloud_cover_c: float = 0.0
var _fog_cover_c: float = 0.0
var _cloud_cells_c: int = 0
var _precip_c: float = 0.0
var _vapour_total_c: float = 0.0

## Cloud density at a world XZ column (0 if unresolved). Cloud = the condensate that is NOT ground fog.
func cloud_at(x: float, z: float) -> float:
	return _atmos.cloud_at(x, z)

## Fog density at a world XZ column (0 if unresolved). Fog = cool near-ground condensate.
func fog_at(x: float, z: float) -> float:
	return _atmos.fog_at(x, z)

## Read-only CLIMATE snapshot — the live per-cell moisture/temp/snow/solid readback the biome surface baker
## reduces into a terrain-colour texture. Empty dict until the field is active.
func climate_snapshot() -> Dictionary:
	return _atmos.climate_snapshot()

## The atmosphere band radii, measured from `centre()`, that the water-particle renderer places against.
func atmos_cloud_base_r() -> float:
	return _atmos.atmos_cloud_base_r()

func atmos_fog_top_r() -> float:
	return _atmos.atmos_fog_top_r()

func atmos_fog_lo_r() -> float:
	return _atmos.atmos_fog_lo_r()

func atmos_outer_r() -> float:
	return _atmos.atmos_outer_r()

func avg_cloud_cover() -> float:
	return _atmos.avg_cloud_cover()

func avg_atmos_dust() -> float:
	return _queries.avg_atmos_dust()

func avg_fog_cover() -> float:
	return _atmos.avg_fog_cover()

## Domain precipitation proxy 0..1 — fraction of open cells whose condensate is over the rain threshold.
func precipitation() -> float:
	return _atmos.precipitation()

## Total suspended atmospheric water mass (mass-conservation spot check; used by the SIM_REPORT).
func vapour_total() -> float:
	return _atmos.vapour_total()


## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(moisture, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	return _atmos.relative_humidity_at(x, z)

## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's moisture would
## saturate (invert sat(T)). NAN if unresolved or bone dry.
func dewpoint_at(x: float, z: float) -> float:
	return _atmos.dewpoint_at(x, z)

## Domain-average horizontal wind (ocean swell / HUD) — a coarse mean of the read-back GPU velocity field.
func wind() -> Vector2:
	return _queries.wind()

## LOCAL horizontal wind at a world POINT, as the tangential drift in world XZ — the emergent GPU velocity
## read back into `_vel_*`.
func wind_at(world_pos: Vector3) -> Vector2:
	return _queries.wind_at(world_pos)

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

# Local injection writes the GPU field buffers via the injection module; the field only forwards.

## Hand JOULES to the matter at a world point (and within `radius`). Returns the J/m^3 it raised the
## enthalpy by; what temperature that is depends on what is there, which is the ladder's business.
func add_heat_energy(world_pos: Vector3, joules: float, radius: float = 0.0) -> float:
	return _inject.add_heat_energy(world_pos, joules, radius) if _inject != null else 0.0

## Inject airborne water vapor (humidity) at a world point (+`radius`) — a storm's moisture source. Real (module).
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_vapor(world_pos, amount, radius)


## Launch ejected matter (mass + heat) from a world point — the shared momentum/ejecta primitive (volcano
## bombs, meteor debris, geyser blasts). Arcs under radial gravity + re-deposits on landing. See the module.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _ejecta != null:
		_ejecta.eject(world_pos, mass, energy, dir_bias)

## Cells holding melt that has reached OPEN ground — lava. Thin forwarder; the walk (and the magma/lava
## distinction it rests on) lives in LAMaterialFieldQueries3D.molten_counts.
func lava_cell_count() -> int:
	return _queries.lava_cell_count() if _queries != null else 0

func wet_cell_count() -> int:
	return _queries.wet_cell_count()


# --- Injection API (the impact actor calls these; bodies live in LAMaterialFieldInject3D) ---------

## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside).
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	if _inject != null:
		_inject.add_water_pooled(center, amount, radius)   # queued as a sparse LIVE device add — no channel-wide
		                                                   # re-upload of the stale mirror (see the module)


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _inject != null:
		_inject.resample_terrain(world_pos, radius)
		if _gpu != null: _gpu.mark_solid_dirty()   # the solid mask changed → re-seed the GPU solid/static buffers


## Count of OPEN cells carrying derived condensate (moisture over saturation) at/above CONDENSE_COVER_MIN.
## Cached with the other atmosphere aggregates (recomputed once per field readback, not per call).
func cloud_cell_count(min_density: float = 0.05) -> int:
	return _atmos.cloud_cell_count()


# --- Heat diagnostics -------------------------------------------------------

func peak_heat() -> float:
	return _queries.peak_heat()

func hot_cell_count(threshold: float = 60.0) -> int:
	return _queries.hot_cell_count(threshold)

# --- Physical splash droplets (FX; body lives in LAMaterialFieldInject3D) ----
## A few short-lived rigidbody droplets flung from a world point — the splash accent an impact calls.
func splash(world_pos: Vector3, strength: float) -> void:
	if _inject != null:
		_inject.splash(world_pos, strength)


# --- Ecology back-ref: fire ash regrowth + actor coupling.
func set_ecology(e) -> void:
	_ecology = e

# --- Fire / combustion — thin forwarders to LAMaterialFieldQueries3D, which walks the `fire` channel. -------

## Is the cell under this node currently burning?
func is_burning(node) -> bool:
	return _queries.is_burning(node) if _queries != null else false

## Number of cells currently on fire (SMOKE_SUMMARY `fires`) — the same walk `fire_cells` publishes.
func active_fire_count() -> int:
	return _queries.fire_cells() if _queries != null else 0


# --- Organic deposits. There is no scent channel: dung, blood and a carcass land as `detritus`, the
# decomposer record eats them, and the CO2 rides the same gas transport as every other gas. -----------------

## A wound or a kill: blood is water plus organic solids, and the solids are what rots.
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	deposit_detritus(world_pos, amount)

## Soil nutrient at a world point (plants grow faster on rich ground) — the read-back GPU fertility channel.
func fertility_at(world_pos: Vector3) -> float:
	return _queries.fertility_at(world_pos) if _queries != null else 0.0

## Peak soil nutrient (SMOKE_SUMMARY `fertility_peak`) — the read-back GPU fertility channel.
func fertility_peak() -> float:
	return _queries.fertility_peak() if _queries != null else 0.0


# --- Emergent-process forwarders (magma volcano / erosion / snow-ice / dust / charge lightning / shock).
# CPU oracles retired; these channels are not yet read back from the sphere GPU driver, so the emitters are
func _step_geotherm() -> void:
	_geotherm.step()


## Radiogenic power and the observed gradient, merged into the field report by LAMaterialFieldReport3D.
func geotherm_report() -> Dictionary:
	return _geotherm.report()


## Cells holding melt still CONFINED by rock — magma, as against the lava_cell_count above. Thin forwarders;
## both, and the eruption test, come from the single walk in LAMaterialFieldQueries3D.molten_counts.
func magma_cell_count() -> int:
	return _queries.magma_cell_count() if _queries != null else 0
## Molten rock standing in open cells: magma has reached the surface, which is what an eruption IS.
func magma_erupting() -> bool:
	return _queries.magma_erupting() if _queries != null else false
## Open cells currently carrying a suspended mineral load — the `erosion_cells` gauge in SIM_REPORT. Thin
## forwarder; the count lives in LAMaterialFieldMineralProfile3D (static, so no diagnostic instance is needed).
func erosion_cell_count() -> int:
	return LAMaterialFieldMineralProfile3D.suspended_cell_count(_susp, _solid)
## Snow depth at a world point, in channel units. Body in LAMaterialFieldChannels3D.
func snow_depth_at(pos: Vector3) -> float:
	return _channels.snow_depth_at(pos)
## The planet's whole conserved H₂O budget in cubic metres, as LAMaterialFieldLedger3D last measured it.
func h2o_total() -> float:
	return _ledger.total("h2o_total")
## Airborne dust at a world point. Forwards to the channel module; self-wakes the demand-gated `dust`
## readback the way co2_at does.
func dust_at(x: float, y: float, z: float) -> float:
	return _channels.dust_at(x, y, z)
#  counts the same cells with the same threshold inside a pass it already makes. Reason in MaterialFieldQueries3D.)

# --- Per-cell CHANNEL point reads (atmospheric O₂/CO₂, living biomass, the decomposer deposit, and the
# phase-channel debug readers) — bodies live in LAMaterialFieldChannels3D. -------------------------------
func o2_at(x: float, y: float, z: float) -> float:
	return _channels.o2_at(x, y, z)
## BREATHABLE oxygen at a TRUE-3D world point — the cell's O₂, but ZERO once WATER fills the cell (water
## displaces air) or the creature is truly encased in rock. One 3D read that lets a lung suffocate underwater
## OR in O₂-depleted smoke, with altitude respected for free — no 2.5D depth column, no can_fly special-case.
func breathable_o2_at(x: float, y: float, z: float) -> float:
	return _channels.breathable_o2_at(x, y, z)
## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	return _channels.is_submerged_at(x, y, z)
# Open-cell O₂ min / mean over the GPU readback (_o2). Proves the sky-refill + transport keep the open air
# oxygenated and expose sealed-cavity draw-down. Falls back to ambient when no field is resident.
func o2_min_open() -> float:
	return _channels.o2_min_open()
func o2_avg() -> float:
	return _channels.o2_avg()
# Emergent CARBON DIOXIDE (second gas channel): CO₂ level at a point + build-up diagnostics.
func co2_at(x: float, y: float, z: float) -> float:
	return _channels.co2_at(x, y, z)
func co2_peak() -> float:
	return _channels.co2_peak()
func co2_avg() -> float:
	return _channels.co2_avg()
# Emergent LIVING BIOMASS (MaterialReactions3D R19/R20): CO₂ fixed into plant matter on the GPU + queried here.
func biomass_at(x: float, y: float, z: float) -> float:
	return _channels.biomass_at(x, y, z)
## Total living biomass over every open cell — the emergent-growth spot check (should rise then plateau, not
## explode; bounded by the CO₂ budget + respiration). Fed into SIM_REPORT.
func biomass_total() -> float:
	return _channels.biomass_total()
func lava_at(x: float, y: float, z: float) -> float:
	return _channels.lava_at(x, y, z)
func rock_fill_at(x: float, y: float, z: float) -> float:
	return _channels.rock_fill_at(x, y, z)
func charge_at(x: float, y: float, z: float) -> float:
	return _channels.charge_at(x, y, z)
func fungus_at(x: float, y: float, z: float) -> float:
	return _channels.fungus_at(x, y, z)
func decomposer_stats() -> Dictionary:
	return _channels.decomposer_stats()
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


# `rebuild_surface()` IS DELETED. Its own comment already said "box dynamic-water surface mesh render adapter
# retired" and its body was `pass`; the cubed sphere renders water through the ocean shell.


func report() -> Dictionary:
	return _report_mod.report()


# --- LIVING BODIES <-> FIELD (LAMaterialFieldBiota3D) ---------------------------------------------------
# detritus return wrote a mirror the device never sees. The bodies live in the biota module.
## Take up to `want` of the standing crop under `pos`; returns what the pasture actually had.
func graze_biomass(pos: Vector3, want: float) -> float:
	return _biota.graze(pos, want) if _biota != null else 0.0
## Take up to `want` H₂O out of the world at `pos` (surface water, then the groundwater underfoot).
func drink_water(pos: Vector3, want: float) -> float:
	return _biota.drink(pos, want) if _biota != null else 0.0
## Oxidise `mass` of body tissue at `pos`: debits O₂, credits CO₂ one for one, and warms the cell.
func respire_at(pos: Vector3, mass: float) -> float:
	return _biota.respire(pos, mass) if _biota != null else 0.0
## Return `mass` of body tissue to the soil as litter (a carcass, a dropping, a sunken fish).
func deposit_detritus(pos: Vector3, mass: float) -> void:
	if _biota != null:
		_biota.litter(pos, mass)
## Body water leaving as vapour (breath, sweat, urine) into the air at `pos`.
func transpire_at(pos: Vector3, mass: float) -> void:
	if _biota != null:
		_biota.transpire(pos, mass)
## Accounting only: body mass taken from a NODE (a plant, a carcass) rather than from a field channel.
func note_biota_node_intake(mass: float) -> void:
	if _biota != null:
		_biota.note_node_intake(mass)
## Accounting only: a body appeared with `mass` that no field channel paid for (see the biota module's note on
## founders versus runtime spawns — a BIRTH is not one of these, the mother is debited for it).
func note_biota_spawn(mass: float, founder: bool) -> void:
	if _biota != null:
		_biota.note_spawn(mass, founder)
