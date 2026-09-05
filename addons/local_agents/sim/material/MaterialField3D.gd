class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D: the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).

const FieldCacheScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCache3D.gd")
const GravityScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldGravity3D.gd")
const MineralStampScript: GDScript = preload("res://addons/local_agents/sim/material/MineralStamp3D.gd")

# A cell is "full" of water at this amount, mol/m^3: liquid water's density over its molar mass.
const MAX_MASS: float = LAPhysical.WATER_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
const MIN_MASS: float = 0.0001 * MAX_MASS # below this a cell is considered dry

var _terrain = null
## The terrain definition PlanetBody.setup() was given; the solid-mask cache's key.
var _terrain_opts: Dictionary = {}
var _cell_size: float = 5.0
var _origin: Vector3 = Vector3.ZERO       # world position of cell (0,0,0) centre
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0

var _solid: PackedByteArray = PackedByteArray()          # 1 = rock (holds no fluid), 0 = void (air/water)
var _rock_fraction: PackedFloat32Array = PackedFloat32Array()   # share of the cell's volume inside the terrain
var _surface_depth: PackedFloat32Array = PackedFloat32Array()   # m below the local ground, negative above it
var _water_fraction: PackedFloat32Array = PackedFloat32Array()  # share of the cell's volume under the sea shell and over its ground
var _ground_d: PackedFloat32Array = PackedFloat32Array()        # depth of the ground under the cell's fluid below its centre, m
## THE ONE CPU-SIDE DECLARATION of every per-cell channel: LAFieldMirrors, native storage the drain
## lands the device's channels in. Nothing here holds a cell-sized array.
var _mirrors: LAFieldMirrors = null

const INITIAL_TEMP: float = 15.0
# Gas channel seeds, mol/m^3.
const O2_AMBIENT: float = 0.0
const SNOW_PRESENT: float = 1.9e-4 * MAX_MASS
const ICE_DEPTH: float = 0.5 * MAX_MASS
const FOG_MAX_TEMP: float = 12.0
# Condensate at which a cell counts as covered, mol/m^3.
const CONDENSE_COVER_MIN: float = 5.0e-5 / LAPhysical.MOLAR_MASS_WATER_KG_MOL
var _t_rock: PackedFloat32Array = PackedFloat32Array()   # the geotherm's mean over each cell's rock, C, at the seed
var _sun_light = null                                    # DirectionalLight3D — solar forcing (top cells)

var _ecology = null                                      # LAEcologyService back-ref (ash regrowth / actor coupling)
const SphereGPUScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSphereGPU3D.gd")
const QueriesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldQueries3D.gd")
const InjectScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInject3D.gd")
const SphereStepScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd")
const OrganicScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldOrganic3D.gd")
var _gpu = null                                          # LAMaterialSphereGPU3D or null
var _use_gpu: bool = false
var _queries = null                                      # LAMaterialFieldQueries3D
var _inject = null                                       # LAMaterialFieldInject3D (write-side injection + FX)
var _stamp = null                                        # LAMineralStamp3D — solid-flag -> SDF growth stamp
var _sphere_step = null                                  # LAMaterialFieldSphereStep3D — the per-frame step loop
var _organic = null                                      # LAMaterialFieldOrganic3D — the dead pool's C:H:O gauge
# Substrate-foundation primitive modules (the field only delegates; all logic lives in these). Seams the
# per-actor dissolution agents fill: charge→bolt (Thunderstorm), ejecta (bombs/debris).
var _charge_mod = null                                   # LAMaterialCharge3D — charge readback + breakdown→bolt
var _ejecta = null                                       # LAMaterialEjecta3D — momentum/ejecta parcels (Node3D child)
var _pending_lightning_cb: Callable = Callable()         # lightning visual callback (registered pre-activate)
const ChargeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialCharge3D.gd")
const EjectaScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialEjecta3D.gd")
var _atmos = null                                     # LAMaterialFieldAtmos3D
var _ledger = null                                       # LAMaterialFieldLedger3D
var _channels = null                                     # LAMaterialFieldChannels3D
var _report_mod = null                                   # LAMaterialFieldReport3D
var _biota = null                                        # LAMaterialFieldBiota3D
const BoundaryScript: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundary3D.gd")
var _boundary = null                                     # LAFieldBoundary3D — the box-face boundary provider
const CaptureScript: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundaryCapture3D.gd")
var _capture = null                                      # LAFieldBoundaryCapture3D — face-state record/replay
var _slice = null                                        # LAFieldSlice3D — set when this field is a slice
var _pivot = null                                        # Vector3 body centre when the box is not centred on it
const AtmosScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldAtmos3D.gd")
const LedgerScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldLedger3D.gd")
const ChannelsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldChannels3D.gd")
const ReportScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldReport3D.gd")
const BiotaScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldBiota3D.gd")


func _init() -> void:
	_atmos = AtmosScript.new()
	_atmos.setup(self)
	_ledger = LedgerScript.new()
	_ledger.setup(self)
	_channels = ChannelsScript.new()
	_channels.setup(self)
	_report_mod = ReportScript.new()
	_report_mod.setup(self)
	_biota = BiotaScript.new()
	_biota.setup(self)


## Wire the real scene sun (DirectionalLight3D); the heat module reads its energy + angle for solar input.
func set_sun(light) -> void:
	_sun_light = light


var _body = null                                         # LAPlanetBody
## Which row of LABodySeeds this field's matter was seeded from. One field, one body.
var _body_key: String = "planet"
var _body_measure: LABodyMeasure = null
var _body_basis: Basis = Basis.IDENTITY                  # body->world rotation, refreshed once per step
var _body_basis_inv: Basis = Basis.IDENTITY


## Wire the planet body whose rotation this grid rides.
func set_body(body) -> void:
	_body = body


## Bulk properties measured off the seeded matter: mass, surface radius, inertia, the air's gas
## constant. Null until the field is seeded, and every reader takes that as unmeasured.
func body_measure() -> LABodyMeasure:
	return _body_measure


## Refresh the cached body rotation. Called once per field step, before anything converts a position.
func sync_body_frame() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	_body_basis = (_body as Node3D).global_transform.basis.orthonormalized()
	_body_basis_inv = _body_basis.inverse()


## A world DIRECTION expressed in the field's (body-local) frame — sun_dir and any other bare direction.
func dir_to_field(world_dir: Vector3) -> Vector3:
	return _body_basis_inv * world_dir


## A world POINT in the field's frame.
func point_to_field(world_pos: Vector3) -> Vector3:
	var pivot: Vector3 = centre()
	return pivot + _body_basis_inv * (world_pos - pivot)


## Radius of the sea shell, model units, measured from `centre()`.
func sea_radius() -> float:
	if _terrain != null and _terrain.has_method("sea_radius"):
		return float(_terrain.sea_radius())
	return 0.0


var _ready_sim: bool = false
var _seal = null


## THE ONE GRID: a Cartesian box with axis-aligned refinement. No second index layout anywhere.
var _grid: LAVoxelGrid = null
## Gravity, SOLVED from the mass that is there. There is no gravity constant anywhere in this tree.
var _gravity = null                                      # LAMaterialFieldGravity3D

## THE ONE CONSTRUCTION PATH: `dims` cells of `cell_size` from `origin`, refined where `refine` says.
## A slice, a sandbox and a whole planet differ in their arguments, never in their code.
func setup_box(origin: Vector3, dims: Vector3i, cell_size: float, terrain = null,
		body_centre: Vector3 = Vector3.ZERO, refine_below_m: float = 0.0,
		refine_above_m: float = 0.0, target_edge_m: float = 0.0, body_radius: float = 0.0) -> void:
	if terrain != null:
		_terrain = terrain
		if terrain.has_method("generator_options"):
			_terrain_opts = terrain.generator_options()   # the solid-mask cache's key
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(dims.x, dims.y, dims.z, maxf(cell_size, 1.0e-6), origin)
	# WHERE THE GRID IS FINE: the shell around the terrain surface, to the scale height's edge, under budget.
	if target_edge_m > 0.0 and (refine_below_m > 0.0 or refine_above_m > 0.0):
		LAFieldGridBudget.refine_to_budget(grid, body_centre, terrain, refine_below_m,
			refine_above_m, target_edge_m, body_radius)
	_adopt(grid)

## ONE lifecycle.
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

## Allocate every per-cell channel mirror for the current `_cell_count`, in native storage.
func _alloc_channels() -> void:
	_solid = PackedByteArray()
	_solid.resize(_cell_count)
	# The channel table plus the buffers a pass recomputes each step. `regolith` is a CPU byte mask, not
	# a mirror, so it is not one here.
	var names: PackedStringArray = PackedStringArray()
	for name in LAChannels.channels():
		if String(name) != "regolith":
			names.append(String(name))
	for name in LAChannels.derived_buffers():
		if not names.has(String(name)):
			names.append(String(name))
	_mirrors = LAFieldMirrors.new()
	_mirrors.alloc(names, _cell_count)
	_mirrors.fill("temp", INITIAL_TEMP)
	_mirrors.fill("temp_lith", INITIAL_TEMP)
	# Read-only query accessors bind to this field now; the mirrors they read exist from here on.
	_queries = QueriesScript.new()
	_queries.setup(self)


func cell_world_pos(ix: int, iy: int, iz: int) -> Vector3:
	return _grid.cell_world_pos(_grid.leaf_at(ix, iy, iz))



## World centre of a linear cell index.
func cell_world_pos_linear(c: int) -> Vector3:
	var pivot: Vector3 = centre()
	return pivot + _body_basis * (_grid.cell_world_pos(c) - pivot)

func cell_size() -> float:
	return _cell_size


## World position → linear cell index, -1 outside the box.
func world_to_cell(world_pos: Vector3) -> int:
	return _grid.cell_at(point_to_field(world_pos)) if _grid != null else -1



func total_water() -> float:
	return _queries.total_water()




# Water in the point's own cell, or the sea/lake shell over the ground beneath it.
func is_water_at(pos: Vector3) -> bool:
	return _queries.is_water_at(pos)


# World-space WATER CURRENT (sweep) force at a point — downhill × depth × slope; ZERO in still/dry ground.
func water_force_at(pos: Vector3) -> Vector3:
	return _queries.water_force_at(pos)





## Begin simulating + rendering (called after setup + sample_solidity + seed_sea).
func activate() -> void:
	_boundary = BoundaryScript.new()
	_boundary.setup(self)                 # appends ghost rows before the driver reads grid.ghost_rows
	if _grid != null and SphereGPUScript.available():
		# The GPU driver runs the kernels over the grid's neighbour SSBO.
		_gpu = SphereGPUScript.new()
		_gpu.setup(self)
		_use_gpu = true
	_boundary.attach(_gpu)                # uploads the redirect table + supplied ghost tails
	_inject = InjectScript.new()
	_inject.setup(self)
	_organic = OrganicScript.new()
	_organic.setup(self)
	# The sparse, event-driven solid-flag crossing -> SDF terrain-growth stamp (idle until armed).
	_stamp = MineralStampScript.new()
	_stamp.setup(self)
	# Substrate-foundation primitives (thin delegates; the field only forwards to them).
	_charge_mod = ChargeScript.new()
	_charge_mod.setup(self)
	if _pending_lightning_cb.is_valid():
		_charge_mod.set_visual(_pending_lightning_cb)
	_ejecta = EjectaScript.new()
	_ejecta.setup(self)
	add_child(_ejecta)                            # Node3D: integrates ballistic parcels + owns the GPU ejecta particles
	_capture = CaptureScript.maybe_make(self)
	_ready_sim = true


## Rock fraction per cell from the terrain's signed distance; the solid flag is the half-full cell.
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid") or _grid == null:
		return
	var k: String = "" if _terrain_opts.is_empty() else FieldCacheScript.key(_terrain_opts, _grid)
	var fr: Dictionary = FieldCacheScript.load_fractions(k, _cell_count)
	if fr.is_empty():
		fr = LAPlanetComposition.surface_fractions(_grid, _terrain, centre(), sea_radius())
		fr["surface_depth"] = LAPlanetComposition.surface_depth(_grid, _terrain, centre())
		LAFieldStateCache.save_blob(k, fr)
	_rock_fraction = fr.get("rock_fraction", PackedFloat32Array())
	_water_fraction = fr.get("water_fraction", PackedFloat32Array())
	_ground_d = fr.get("ground_d", PackedFloat32Array())
	_surface_depth = fr.get("surface_depth", PackedFloat32Array())
	_solid = LAPlanetComposition.solid_of(_rock_fraction)
	_seed_silicate()

## Mineral amounts mirror the sampled mask: consolidated bedrock layered as LAPlanetComposition derives.
func _seed_silicate() -> void:
	if _mirrors == null or not _mirrors.has("silicate") or _solid.size() != _cell_count:
		return
	var r_body: float = LABodySeeds.seed_radius_m(_body_key)
	_t_rock = LAFieldCellMass3D.rock_temperature(self, _grid, LAFieldGeothermSeed.profile_k(r_body, INITIAL_TEMP), r_body, INITIAL_TEMP, _surface_depth)
	LAPlanetComposition.seed(self, INITIAL_TEMP, _t_rock)
	_body_measure = LABodyMeasure.new()
	_body_measure.measure(self, LABodySeeds.spin_axis_of(_body_key))


# 1 where the rock is loose enough to hold pore water; its pore fraction and grain size are mirrors.
var _regolith: PackedByteArray = PackedByteArray()



## Release the GPU driver's local RenderingDevice while the tree is still up, so every RID is freed cleanly.
func _exit_tree() -> void:
	if _gpu != null and _gpu.has_method("dispose"):
		_gpu.dispose()


## The step driver LASimLoop calls: `seed_tick()` while seeding, `step()` once per simulated step.
func step_driver():
	return _sphere_step


## Temperature °C at a true-3D world point (a mild default outside the shell). Sphere-native single read.
func temp_at(pos: Vector3) -> float:
	return _queries.temp_at(pos)


## Pressure Pa at a true-3D world point; NAN outside the box or before the first readback.
func pressure_at(pos: Vector3) -> float:
	return _queries.pressure_at(pos)



## True where the ground beneath a world point is below the sea shell (open salt ocean / a sea basin).
func is_ocean_at(pos: Vector3) -> bool:
	return _queries.is_ocean_at(pos)


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

func avg_airborne_mineral() -> float:
	return _queries.avg_airborne_mineral()

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

## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's moisture would saturate.
func dewpoint_at(x: float, z: float) -> float:
	return _atmos.dewpoint_at(x, z)

## The fastest air in the box, m/s. A direction is a local question; wind3_at is where it is asked.
func wind_speed_max() -> float:
	return _queries.wind_speed_max()

## Radial vorticity (air spin about local up) at a world point, 1/s.
func vorticity_at(pos: Vector3) -> float:
	return _queries.vorticity_at(pos)

## Vertical updraft (outward radial wind) at a world point, m/s.
func updraft_at(pos: Vector3) -> float:
	return _queries.updraft_at(pos)

## Full local 3D wind velocity at a world point, m/s.
func wind3_at(x: float, y: float, z: float) -> Vector3:
	return _queries.wind3_at(x, y, z)


## Hand JOULES to the matter at a world point (and within `radius`).
func add_heat_energy(world_pos: Vector3, joules: float, radius: float = 0.0) -> float:
	return _inject.add_heat_energy(world_pos, joules, radius) if _inject != null else 0.0

## Launch ejected matter (mass + heat) from a world point.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _ejecta != null:
		_ejecta.eject(world_pos, mass, energy, dir_bias)

## Cells holding melt that has reached open ground.
func lava_cell_count() -> int:
	return _queries.lava_cell_count() if _queries != null else 0

func wet_cell_count() -> int:
	return _queries.wet_cell_count()



## Flood pool-fill: add water only where the ground is at or below the centre column's ground.
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	if _inject != null:
		_inject.add_water_pooled(center, amount, radius)   # queued as a sparse LIVE device add — no channel-wide


## Re-sample rock/void from the terrain SDF in a region after an edit.
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _inject != null:
		_inject.resample_terrain(world_pos, radius)
		if _gpu != null: _gpu.mark_solid_dirty()   # the solid mask changed → re-seed the GPU solid/static buffers


## Count of open cells whose derived condensate is at or above CONDENSE_COVER_MIN.
func cloud_cell_count(min_density: float = 0.05) -> int:
	return _atmos.cloud_cell_count()



func peak_heat() -> float:
	return _queries.peak_heat()

func hot_cell_count(threshold: float = 60.0) -> int:
	return _queries.hot_cell_count(threshold)

## A few short-lived rigidbody droplets flung from a world point.
func splash(world_pos: Vector3, strength: float) -> void:
	if _inject != null:
		_inject.splash(world_pos, strength)


func set_ecology(e) -> void:
	_ecology = e


## Is the cell under this node currently burning?
func is_burning(node) -> bool:
	return _queries.is_burning(node) if _queries != null else false

## Number of cells currently on fire.
func active_fire_count() -> int:
	return _queries.fire_cells() if _queries != null else 0



## Deposit blood at `pos`: water plus organic solids.
func deposit_blood(world_pos: Vector3, amount: float) -> void:
	deposit_detritus(world_pos, amount)

## Soil nutrient at a world point.
func fertility_at(world_pos: Vector3) -> float:
	return _queries.fertility_at(world_pos) if _queries != null else 0.0

## Peak soil nutrient over the grid.
func fertility_peak() -> float:
	return _queries.fertility_peak() if _queries != null else 0.0


## Cells holding melt still confined by rock.
func magma_cell_count() -> int:
	return _queries.magma_cell_count() if _queries != null else 0
## Molten rock standing in open cells.
func magma_erupting() -> bool:
	return _queries.magma_erupting() if _queries != null else false
## Open cells currently carrying a suspended mineral load.
func erosion_cell_count() -> int:
	return _queries.suspended_cell_count()
## Snow depth at a world point, in channel units. Body in LAMaterialFieldChannels3D.
func snow_depth_at(pos: Vector3) -> float:
	return _channels.snow_depth_at(pos)
## The planet's conserved H₂O budget, m^3.
func h2o_total() -> float:
	return _ledger.total("h2o_total")
## Airborne mineral at a world point, as a volume fraction of the cell.
func airborne_mineral_at(x: float, y: float, z: float) -> float:
	return _channels.airborne_mineral_at(x, y, z)
#  counts the same cells with the same threshold inside a pass it already makes. Reason in MaterialFieldQueries3D.)

func o2_at(x: float, y: float, z: float) -> float:
	return _channels.o2_at(x, y, z)
## Breathable oxygen at a true-3D world point; zero once water fills the cell or the point is inside rock.
func breathable_o2_at(x: float, y: float, z: float) -> float:
	return _channels.breathable_o2_at(x, y, z)
## Is the cell at this world point over half full of water?
func is_submerged_at(x: float, y: float, z: float) -> bool:
	return _channels.is_submerged_at(x, y, z)
func o2_min_open() -> float:
	return _channels.o2_min_open()
func o2_avg() -> float:
	return _channels.o2_avg()
func co2_at(x: float, y: float, z: float) -> float:
	return _channels.co2_at(x, y, z)
func co2_peak() -> float:
	return _channels.co2_peak()
func co2_avg() -> float:
	return _channels.co2_avg()
func biomass_at(x: float, y: float, z: float) -> float:
	return _channels.biomass_at(x, y, z)
## Total living biomass over every open cell.
func biomass_total() -> float:
	return _channels.biomass_total()
func melt_at(x: float, y: float, z: float) -> float:
	return _channels.melt_at(x, y, z)
func silicate_at(x: float, y: float, z: float) -> float:
	return _channels.silicate_at(x, y, z)
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
## Peak space-charge density in the open air, C/m^3, off the row that folded it.
func charge_peak() -> float:
	var v: float = _queries.row_f("charge_peak")
	return 0.0 if is_nan(v) else v
func bolts_fired() -> int:
	return _charge_mod.bolts_fired() if _charge_mod != null else 0




func report() -> Dictionary:
	return _report_mod.report()


## Take up to `want` of the standing crop under `pos`; returns what was there.
func graze_biomass(pos: Vector3, want: float) -> float:
	return _biota.graze(pos, want) if _biota != null else 0.0
## Take up to `want` H₂O out of the world at `pos`.
func drink_water(pos: Vector3, want: float) -> float:
	return _biota.drink(pos, want) if _biota != null else 0.0
## Oxidise `mass` of body tissue at `pos`: debits O₂, credits CO₂ one for one, and warms the cell.
func respire_at(pos: Vector3, mass: float) -> float:
	return _biota.respire(pos, mass) if _biota != null else 0.0
## Return `mass` of body tissue to the soil as litter.
func deposit_detritus(pos: Vector3, mass: float) -> void:
	if _biota != null:
		_biota.litter(pos, mass)
## Body water leaving as vapour into the air at `pos`.
func transpire_at(pos: Vector3, mass: float) -> void:
	if _biota != null:
		_biota.transpire(pos, mass)
## A body appeared with `mass`: seeded matter before the seal, a booked stand-in's after it.
func note_biota_spawn(mass: float) -> void:
	if _biota != null:
		_biota.note_body(mass)
