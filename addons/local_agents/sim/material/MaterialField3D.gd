class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D: the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).
##
## The 2.5D field stored one column per XZ cell (a surface height + material *depths*). That could not
## represent caves: water can't pool in a cavern, lava can't drain into a tube, a plume can't rise a
## shaft. This field stores a real 3D volume (a temperature + per-material amount for every (x,y,z)
## cell), so all of that EMERGES from local rules that now include the Y axis.
##
## DENSE (not sparse bricks): at the sim's 5-unit resolution the whole volume is ~0.9M cells × a few
## float layers ≈ ~20 MB, so a flat 3D array is the simplest thing that works. Solid rock cells (from
## the terrain SDF via is_solid) hold no fluid and are skipped; an active-cell list keeps the CPU
## oracle cheap without brick machinery. The GPU kernels become a 3D dispatch over the same arrays.
##
## Index layout: idx = (iy * _dim_z + iz) * _dim_x + ix  (X contiguous, then Z, then Y). World position
## of a cell centre = _origin + Vector3(ix, iy, iz) * _cell_size.
## (Explicit types only, no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/sim/material/Materials.gd")
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
# Geothermal core: a FINITE reservoir of rock below the shell's innermost layer, at a temperature that
# FALLS as it conducts heat up into the bottom face (and rises a little from radioactive decay). No cell
# is ever held at a constant temperature. add_magma_source seeds it. Sphere-only. The model, and the
# reason a temperature boundary could never have worked, live in LAMaterialFieldGeotherm3D; this hub
# only forwards.
# THE ATMOSPHERE. Every open cell is seeded with real air, once, at world build, and nothing tops it up
# afterwards — the planet was assembled with an atmosphere and rearranges it from then on, which is what a
# planet does. One unit of a gas channel is DEFINED as the amount of O₂ in a cell of ambient air, so
# O2_AMBIENT stays 1.0 and every existing O₂ threshold (CreatureMetabolism.BREATHE_MIN_O2 0.3,
# fire_sphere3d O2_MIN 0.35) keeps meaning what it meant. Everything else in the air follows from its
# measured mole fraction, with nothing left to tune.
#
# WHAT THIS REPLACED (2026-08-03). `_co2` was `resize()`d with NO `.fill()` — a planet whose air contained no
# carbon at all — and both gases were then held near a target by reaction records R11/R12, which used a rate
# model with NO REACTANT: the kernel skipped the debit and ran only the product credit. Carbon entered this
# world at +6.5 units per field step and `carbon_total` had grown from 720 to about 5820 over 600 frames.
# Those records are deleted. Note the honest consequence: CO₂ per cell is now 0.00200 rather than the 0.05
# "ambient trace" the deleted record aimed at, because 0.05 was never a measurement of anything and
# 419 ppm / 20.946 % is.
const O2_AMBIENT: float = 1.0
const CO2_AMBIENT: float = O2_AMBIENT * (LAPhysical.AIR_MOLE_FRAC_CO2 / LAPhysical.AIR_MOLE_FRAC_O2)
# VAPOR_AMBIENT IS DELETED. It claimed to be "the ambient atmospheric humidity every OPEN cell is seeded to",
# and it seeded nothing: the fill it drove was never uploaded to the GPU (see _alloc_channels and
# MaterialSphereGPU3D's seed list), so for the whole life of this substrate the atmosphere has started dry
# and filled by evaporation. The value was also wrong by three orders of magnitude — 0.3 per cell is five
# times the planet's entire water budget in vapour — so the fill could never simply be switched on.
# (2026-08-03 merge note: the 0.4-dev hydrology branch replaced the constant with a relative-humidity seed,
# `0.80 * LAPhysical.saturation_mass_fraction(INITIAL_TEMP)`. That seed was still dead for the same reason —
# `moisture` is not in MaterialSphereGPU3D's `_seed` list on EITHER branch — so it is not carried across. The
# physically-sized starting humidity it was reaching for is recorded there, waiting on the kg-per-unit pin.)
# Frozen H₂O (snowpack/ice) — the third phase of the ONE conserved water substance (liquid `_water`, airborne
# `_moisture`, frozen `_snow`). GPU-owned: the snowice deposition kernel + freeze/melt reaction records (R21/R22)
# grow and thaw it; read back for queries/telemetry only. SNOW_PRESENT = depth that counts a cell snow-covered;
# ICE_DEPTH = a thick pack that reads as glacial ice (the deep end of the same channel — no separate ice buffer).
# Both are DEPTHS OF WATER EQUIVALENT as a fraction of a cell (16 m at the shipped grid). Ground reads as
# snow-covered once about 3 cm of snow lies on it — that is where surface albedo saturates (Wiscombe & Warren
# 1980) — which is ~3 mm water equivalent, hence 1.9e-4. It was 0.01: sixteen centimetres of water equivalent,
# about 1.6 m of snowpack, a threshold no honest snowfall rate reaches inside a run.
const SNOW_PRESENT: float = 1.9e-4
const ICE_DEPTH: float = 0.5              # ~8 m water equivalent = a real glacial thickness, not a snowfall
# The saturation curve the unified `moisture` channel is read against is LAPhysical.saturation_mass_fraction —
# Clausius-Clapeyron, one function, one owner. It used to be three constants here (SAT_BASE 0.06 /
# SAT_TEMP_GAIN 0.055 / EVAP_TEMP_REF 22.0) copied by hand into four kernels and two texture bakers, and the
# base was 3080x the real saturation mass fraction, which is single-handedly why this planet kept 30% of its
# mobile water in the sky. cloud/fog/vapor are still DERIVED from moisture vs sat(T) and never stored.
# FOG_MAX_TEMP splits the cool near-ground condensate (fog) from cloud aloft.
const FOG_MAX_TEMP: float = 12.0
# CONDENSE_COVER_MIN is the suspended condensate a cell must carry to READ as cloud cover. It is a real cloud
# liquid-water content: marine stratus and fair-weather cumulus run 0.05-0.5 g/m³ (Miles, Verlinde & Clothiaux
# 2000), and 0.05 g/m³ is the thin end at which cloud is optically visible. In the field's cell-fill unit that
# is 5e-5 kg/m³ / 997 kg/m³ = 5.0e-8. It was 0.05, a thousand times saturation itself.
const CONDENSE_COVER_MIN: float = 5.0e-8
# The precipitation threshold is Kessler autoconversion, and its one owner is LAAtmospherePass.rain_threshold().
# It used to be declared here as 0.42 under a comment saying it "matches atmos_precip_sphere3d" — where it was
# 0.14. Three times apart, in two files, each claiming to be the other.
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
# --- Emergent DECOMPOSER loop (kernels3d/fungus_sphere3d.glsl + the decompose reaction record; the old
# LAMaterialFungus3D CPU module is deleted): dead organic matter (DETRITUS) deposited by rotting
# carcasses + wildfire ash is colonised by FUNGUS, which rots it back into CO₂ + soil fertility while drawing
# O₂ (aerobic). Closes the carbon/nutrient loop (death→soil→plant). Seeded ~0; only exists where a source made it.
# --- SOIL WATER / water table (LASoilPass / soil_sphere3d): water held in the REGOLITH band, the top few
# groundwater-bearing shells of each column (`_regolith`, NOT simply "solid" — soil_sphere3d.glsl:223 keys on
# the regolith mask, so a carved or eroded cell reads open yet still holds and still simulates its soil).
# The reservoir that lets land water persist — surface water infiltrates in, the ground releases it slowly as
# baseflow (perennial rivers) + saturation overflow. GPU-owned; read back for `soil_total()` + the conserved
# h2o ledger (infiltrated water lives here, NOT in _water, so it must be counted). The SAME conserved H₂O
# substance as _water/_moisture/_snow, just the subsurface phase. (There is no per-point `soil_at()`; this
# said there was until 2026-07-30, and no such method has ever existed anywhere in the tree. The rooting-zone
# read that would use one is the kernel's derived SOIL_ROOT slot plus LAMaterialFieldPhotoStats3D's mirror.)
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
const SphereGPUScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSphereGPU3D.gd")
const QueriesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldQueries3D.gd")
const InjectScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInject3D.gd")
const SphereStepScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd")
const BoxStepScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldBoxStep3D.gd")
const SurfaceSeedScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd")
var _gpu = null                                          # LAMaterialSphereGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false
var _geotherm = null                                     # LAMaterialFieldGeotherm3D — the internal heat source
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
const ShockScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialShock3D.gd")
const ScentScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialScent3D.gd")
const ChargeScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialCharge3D.gd")
const EjectaScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialEjecta3D.gd")
# Read-only DERIVATION modules. Each owns one cohesive family of accessors whose bodies used to inline here;
# they hold no per-cell state (every one reaches back into this field's arrays), so the field stays the thin
# facade + step orchestration and each family is independently ownable. Built in _init so every accessor is
# safe to call before setup_dims/setup_sphere, exactly as the inlined bodies were.
var _atmos = null                                        # LAMaterialFieldAtmos3D — condensate derivation + aggregates
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


# THE FIELD GRID IS BODY-LOCAL. Its cells, their pos/radial buffers and the rock sampled into them are
# fixed relative to the PLANET, not to the world — which is what lets the planet turn at all.
#
# It used to be world-fixed while the body rotated, and the two drifted apart: the field's rock_fill and
# the terrain SDF stopped describing the same place, so a long accretion smeared a volcanic cone into an
# arc. The response at the time was to switch the planet's rotation OFF (it is off in every default path)
# and freeze it explicitly for the seabed-volcano demo. A world that cannot turn also cannot separate its
# day from its year, so it had no seasons either — the obliquity was there, but with no spin a surface
# point sees the sun circle once per ORBIT and the two cycles are indistinguishable.
#
# Reparenting the field node would not have fixed it: the cell<->world mapping is pure arithmetic off
# `grid.center` and never consults a transform. So the frame lives here, in the ONLY two functions that
# cross between world and cell space — all ~49 call sites go through them and need no change. Directions
# and points handed to the GPU are rotated to match where they are pushed (LAMaterialFieldSphereStep3D).
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


## A world POINT in the field's frame. Rotation is about the planet centre, so the origin offset comes out
## first — that is the part a basis-only transform gets wrong.
func point_to_field(world_pos: Vector3) -> Vector3:
	return _origin + _body_basis_inv * (world_pos - _origin)


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
# Moisture is fully GPU-resident. It used to carry a `_vapor_dirty` flag that made the step re-upload the whole
# CPU mirror whenever a storm injected — but the mirror was a readback one frame (up to two steps) old, so an
# injection frame REWOUND the channel to that snapshot and threw away everything the atmosphere kernels had done
# since. Storm injections now go through LAMaterialFieldInjectQueue3D as sparse edits applied to the LIVE device
# buffer, so there is nothing left to dirty. (Same fix removed the water channel's `mark_water_dirty` injection
# path; `_water_dirty` in the driver now only covers the one-time initial seed.)
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
	# THE `.fill(VAPOR_AMBIENT)` THAT WAS HERE WAS DEAD, AND ITS VALUE WAS WRONG BY THREE ORDERS OF MAGNITUDE.
	# Dead: `moisture` was never in MaterialSphereGPU3D's GPU seed list, so the device buffer started at zero
	# and the first readback overwrote this mirror — the fill had never once reached the simulation. Wrong:
	# 0.3 per cell over ~123,000 cells is ~37,000 units of H2O against a whole-planet `h2o_total` of ~7,000,
	# so "fixing" the dead fill by uploading it would have seeded five times the planet's entire water budget
	# as vapour. Real air at 15 C and 60% relative humidity holds about 1e-4 of a cell of liquid water. The
	# atmosphere starts dry and fills by evaporation, which is measurable within the first steps of a run.
	_moisture.fill(0.0)
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
	# THE AIR, seeded once and finite thereafter. Both gases are filled at Earth's measured composition; the
	# sky-exchange records that used to top them up from nothing are deleted. Solid cells are ignored by the
	# gas loops. (The `.fill` on `_co2` is the whole fix for "the planet had no carbon in its air": the line
	# was a bare `resize()` immediately below a `_o2.fill()`, and nobody noticed for months because a
	# reaction record was manufacturing the carbon anyway.)
	_o2 = PackedFloat32Array()
	_o2.resize(_cell_count)
	_o2.fill(O2_AMBIENT)
	_co2 = PackedFloat32Array()
	_co2.resize(_cell_count)
	_co2.fill(CO2_AMBIENT)
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
		# Body-local -> world: the grid rides the planet, so a cell's WORLD position turns with it.
		return _origin + _body_basis * (_sphere.cell_world_pos(c) - _origin)
	var layer: int = _dim_x * _dim_z
	var iy: int = c / layer
	var rem: int = c - iy * layer
	var iz: int = rem / _dim_x
	var ix: int = rem - iz * _dim_x
	return cell_world_pos(ix, iy, iz)

## The substrate's spatial RESOLUTION in world units — the edge length of one cell.
##
## Public because callers outside the field need it to know what the substrate can even represent. A world
## edit smaller than this is invisible to the physics however well it renders: the field samples cell
## CENTRES, so a carve that does not engulf one changes no cell's state. That is not hypothetical — meteor
## craters were `IMPACT_RADIUS * size` = 10 world units against a cell size of 16, so six impacts excavated
## zero cells while still denting the (much finer) SDF mesh, and `crater_mass` — the cross-check the mineral
## ledger uses to prove a strike MOVED rock rather than destroying it — read 0.0 the whole time.
func cell_size() -> float:
	return _cell_size


## World position → linear cell index (cubed-sphere: nearest gnomonic face+surf+radial layer; -1 if outside
## the shell). Box mode: clamp each axis and combine. This is the substrate-agnostic world→cell used by queries.
func world_to_cell(world_pos: Vector3) -> int:
	if _sphere != null:
		# World -> body-local. Every actor hands us a world position (actors are children of the spinning
		# body), so this is where their frame and the grid's are reconciled — once, for all ~49 call sites.
		return _sphere.world_to_cell(point_to_field(world_pos))
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
	if _gpu != null: _gpu.mark_water_dirty()   # CPU water edit → re-upload it next begin_frame


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


# `add_source(pos, rate)` IS DELETED — a scripted persistent spring, superseded by a real one. Springs are
# emergent now: soil_sphere3d exfiltrates groundwater wherever the water table meets the surface, at a rate
# the head gradient sets, and which springs run hot falls out of the geotherm rather than being placed. A
# fixed-rate injector beside that is a second, unconserved way to make water appear.


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

## The REGOLITH (aquifer) band: the top REGOLITH_CELLS solid shells of each column are PERMEABLE — groundwater
## lives + flows here; everything below is impermeable BEDROCK. This surface-following band is what lets the
## water table flow ridge→valley (through the rock) and DAYLIGHT as springs where it meets open ground, instead
## of the naive "all groundwater sinks to the core". Computed once from the solid mask (grid columns are
## contiguous: cell = surf_col*depth + r, r=depth-1 outermost). Also SEEDS an initial half-full water table so
## springs flow from the start (a planet has an existing aquifer; it then self-maintains via rain/snow recharge).
## The band depth, the initial saturation and the whole derivation now live in LAMaterialFieldRegolith3D,
## which also owns the grain-size field and the Athy porosity profile the aquifer's Kozeny-Carman
## conductivity is computed from. `SOIL_CAPACITY = 0.6` is gone with it: a cell's capacity is its POROSITY,
## which varies with burial, and a flat 0.6 was above the porosity of every real granular material.
const REGOLITH_CELLS: int = LAMaterialFieldRegolith3D.REGOLITH_CELLS
# Athy pore fraction per cell (0 outside regolith). Written on the GPU by soil_sphere3d.glsl and read back
# on the slow cadence — it is static after the first step, so a coarse mirror is exact, not approximate.
# Every CPU consumer that converts `rock_fill` from a matrix SATURATION to a mineral VOLUME FRACTION needs it.
var _porosity: PackedFloat32Array = PackedFloat32Array()
var _regolith: PackedByteArray = PackedByteArray()
var _grain: PackedFloat32Array = PackedFloat32Array()    # representative grain diameter (m) per regolith cell

func _compute_regolith() -> void:
	_regolith_mod.compute()


# `regolith_mask()` and `grain_field()` ARE DELETED. Their docstrings said "uploaded to the GPU soil pass",
# and that was not true: LAMaterialSphereGPU3D._seed_regolith reads `_field._regolith` directly. They were a
# second path to the same two arrays that nothing took, on a hub already over its size limit.



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
# cloud/fog/vapor are no longer stored; every reader recomputes them instantaneously from _moisture + _temp.
# The derivation, the cached domain aggregates and the render cover-texture bake all live in
# LAMaterialFieldAtmos3D; the field keeps only the cache SLOTS below (the step + snapshot modules invalidate
# `_atmos_dirty` and read `_moisture_total_c`) plus these forwarders, so the consumer signatures
# (WeatherSystem/Thunderstorm/CloudLayer/RainLayer) are unchanged.
var _atmos_dirty: bool = true
var _cloud_cover_c: float = 0.0
var _fog_cover_c: float = 0.0
var _cloud_cells_c: int = 0
var _precip_c: float = 0.0
var _moisture_total_c: float = 0.0

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

## The baked 6-layer RGBA cover texture (null until the first atmosphere refresh) — the water-particle
## renderer's field bridge. Plus the atmosphere shell radii it needs to place + classify particles.
func field_cover_texture() -> Texture2DArray:
	return _atmos.field_cover_texture()

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
func moisture_total() -> float:
	return _atmos.moisture_total()

# `cloud_base_y()` / `fog_base_y()` ARE DELETED. The comment here claimed they "survive as the near-ground
# radii the derived point queries sample at" — but cloud_at/fog_at call LAMaterialFieldAtmos3D directly and
# nothing anywhere called these two. They are also the wrong SHAPE for this planet: a single scalar Y is a
# flat-sheet concept, and on a sphere the height a cloud forms at is a radius that varies per column with
# temperature. The module's own methods remain for the one caller that has them.

## Relative humidity 0..1 near the ground at a world XZ column = vapor / sat(T) = min(moisture, sat)/sat.
func relative_humidity_at(x: float, z: float) -> float:
	return _atmos.relative_humidity_at(x, z)

## Dewpoint °C near the ground at a world XZ column — the temperature at which the cell's moisture would
## saturate (invert sat(T)). NAN if unresolved or bone dry.
func dewpoint_at(x: float, z: float) -> float:
	return _atmos.dewpoint_at(x, z)

## Prevailing (large-scale) wind input. The emergent wind now lives on the GPU; forward it to the driver.
func set_wind(w: Vector2) -> void:
	if _gpu != null and _gpu.has_method("set_prevailing"):
		_gpu.set_prevailing(w)

## The drifting PLATES, pushed in by LAPlateTectonics (which owns the kinematics) and consumed by the GPU
## driver's PlateAdvectPass, which carries rock_fill and sediment with the velocity they imply. Pure
## delegation, like set_wind above: the field holds no plate state and does no plate work.
func set_plate_motion(table: PackedFloat32Array) -> void:
	if _gpu != null and _gpu.has_method("set_plates"):
		_gpu.set_plates(table)

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

# `grid_dim()` IS DELETED. It existed so "CloudLayer's texture maps 1:1 with the 2.5D field" — there is no
# CloudLayer and no 2.5D field; both survive only in gravestone comments. Cloud is derived from `moisture`
# against the saturation curve now and has no grid of its own.

func grid_half_extent() -> float:
	return _half_extent


# Heat + lava injection + diagnostics. Local injection (add_heat/add_vapor/add_charge/add_lava) is REAL — it
# writes the sphere GPU field buffers via the injection module; the field only forwards.
## Raise the temperature at a world point (and within `radius`) — a meteor's molten spike, a fire's heat.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_heat(world_pos, amount, radius)

## A vent erupting: bedrock beneath it melts to lava. Conserving, and the body lives in the injection module
## because it has to be a SPARSE DEVICE transfer rather than a mirror edit — see LAMaterialFieldInject3D.add_lava.
func add_lava(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _rock_fill.size() != _cell_count or _lava.size() != _cell_count:
		return
	if _inject != null:
		_inject.add_lava(world_pos, amount)
	if _stamp != null:
		_stamp.arm()                              # wake the SDF stamp — the erupted lava will cool + cross 0.5

## Inject airborne water vapor (humidity) at a world point (+`radius`) — a storm's moisture source. Real (module).
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_vapor(world_pos, amount, radius)

# `add_cooling()` IS DELETED, and it would have been a conservation defect the moment anything called it. It
# was "a thin helper over add_heat" with a negated amount — and `add_heat` is the path that NAMES NO SOURCE
# (booked separately as `heat_unsourced_dc` precisely because it cannot say where the energy came from). A
# helper that makes heat vanish with no receiver is that same hole in the other direction.

## Inject electrification charge at a world point (+`radius`) — an explicit charge seed. Real (module, dirty-gated).
func add_charge(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _inject != null:
		_inject.add_charge(world_pos, amount, radius)

## Launch ejected matter (mass + heat) from a world point — the shared momentum/ejecta primitive (volcano
## bombs, meteor debris, geyser blasts). Arcs under radial gravity + re-deposits on landing. See the module.
func eject(world_pos: Vector3, mass: float, energy: float, dir_bias: Vector3 = Vector3.ZERO) -> void:
	if _ejecta != null:
		_ejecta.eject(world_pos, mass, energy, dir_bias)

## Cells holding melt that has reached OPEN ground — lava. Thin forwarder; the walk (and the magma/lava
## distinction it rests on) lives in LAMaterialFieldQueries3D.molten_counts.
## (Was `return 0`, a gauge that read "no lava" identically whether there was none or the reporting was dead.)
func lava_cell_count() -> int:
	return _queries.lava_cell_count() if _queries != null else 0

func wet_cell_count() -> int:
	return _queries.wet_cell_count()


# --- Injection API (disasters/flood call these; bodies live in LAMaterialFieldInject3D) ------------

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

# --- Fire / combustion — thin forwarders to LAMaterialFieldQueries3D, which walks the `fire` channel. -------
#
# THESE WERE HARDCODED `return 0` / `return false` AS "SAFE DEFAULTS UNTIL THE SPHERE FIRE READBACK LANDS".
# *(Fixed 2026-08-08.)* The readback had landed: `LAMaterialFieldQueries3D.fire_cells()` and `fire_peak()`
# walk `_f._fire` and are published in every SIM_REPORT as `fire_cells` / `fire_peak`. So the report carried
# a REAL fire count and a HARDCODED one side by side, and three consumers read the hardcoded one:
#   * `LASimReportSources.gd:27-28` publishes it as `fires`
#   * `LAEventTracker.gd:164-165` — so no wildfire phenomenon could ever be detected
#   * `LAStreamerDirector.gd:624-625` — so the streamer could never see a fire
# A zero that means "none" and a zero that means "nobody implemented this" are indistinguishable, which is
# the same defect `magma_cell_count` had above and the same one HANDOFF item 16 is about. It cost real
# evidence: `fires: 0` was quoted in this session's own commit messages as proof that no fire burned during
# a run. The conclusion happened to be right — `fuel_total` and `ext_open_hot` established it independently
# — but the number cited as evidence could not have said otherwise.

## Light the cell under a node on fire (disaster/scripted ignition).
## STILL A NO-OP, AND DELIBERATELY SO: the honest implementation injects heat, and the last version of that
## added 900 °C to every cell in a radius out of nothing (removed in 23c8f66). Ignition must come from the
## substrate reaching `VEGETATION_IGNITION_C` on its own. Named here rather than quietly wired so the
## reason survives: `EcologyService.ignite_area` is the same no-op for the same reason.
func ignite(_node) -> void:
	pass

## Is the cell under this node currently burning?
func is_burning(node) -> bool:
	return _queries.is_burning(node) if _queries != null else false

## Number of cells currently on fire (SMOKE_SUMMARY `fires`) — the same walk `fire_cells` publishes.
func active_fire_count() -> int:
	return _queries.fire_cells() if _queries != null else 0


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
	# Sphere geothermal core: SEED the interior reservoir's temperature AND the crustal geotherm above it
	# (world_pos/rate unused — the reservoir is the whole unsimulated interior, not a point). From then on the
	# temperature is a state variable that cools; nothing re-asserts it. The geotherm is an INITIAL CONDITION
	# because conduction through rock takes millennia to cross this shell — see LAMaterialFieldGeotherm3D.
	_geotherm.arm(temp)


## Advance the geothermal reservoir one field step: recompute the conductive flux across its boundary, debit
## it by exactly that, credit radiogenic decay, and publish the boundary temperature to the GPU. The model
## lives in LAMaterialFieldGeotherm3D.
func _step_geotherm() -> void:
	_geotherm.step()


## The geothermal reservoir's telemetry, merged into the field report by LAMaterialFieldReport3D.
func geotherm_report() -> Dictionary:
	return _geotherm.report()


## Cells holding melt still CONFINED by rock — magma, as against the lava_cell_count above. Thin forwarders;
## both, and the eruption test, come from the single walk in LAMaterialFieldQueries3D.molten_counts.
## (Both were hardcoded — `return 0` / `return false` — while `magma_cells` was published in every SIM_REPORT.)
func magma_cell_count() -> int:
	return _queries.magma_cell_count() if _queries != null else 0
## Molten rock standing in open cells: magma has reached the surface, which is what an eruption IS.
func magma_erupting() -> bool:
	return _queries.magma_erupting() if _queries != null else false
## Open cells currently carrying a suspended mineral load — the `erosion_cells` gauge in SIM_REPORT. Thin
## forwarder; the count lives in LAMaterialFieldMineralProfile3D (static, so no diagnostic instance is needed).
## (Was `return 0` — a hardcoded zero that read "no erosion anywhere" identically whether erosion was working
## or, as it happened, structurally unable to move anything at all. Fixed 2026-08-03 with the transport leg.)
func erosion_cell_count() -> int:
	return LAMaterialFieldMineralProfile3D.suspended_cell_count(_susp, _solid)
# --- Conserved H₂O ledger + snow/ice diagnostics — bodies live in LAMaterialFieldLedger3D. ONE water
# substance in four phase channels (liquid `_water`, airborne `_moisture`, frozen `_snow`, subsurface
# `_soil`); every transition is a transfer between them, so h2o_total must stay BOUNDED. All four legs obey
# ONE inclusion rule — a cell counts where its channel physically lives (open cells for water/moisture/snow,
# regolith cells for soil), and the static flag is a memo line, not a filter. The rule and why the four legs
# used to disagree are documented once, in LAMaterialFieldLedger3D's header. -------------------------------
## Snow depth at a world point (frozen H₂O in the cell). 2.5D-style (x,z) calls have no radial point, so they
## return the safe default 0 (matching temp_at); a full 3D call (x,z,y) reads the real cell — three-d-always.
func snow_depth_at(pos: Vector3) -> float:
	return _ledger.snow_depth_at(pos)
## Open cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	return _ledger.snow_cell_count()
## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	return _ledger.ice_cell_count()
## Total frozen H₂O over the field, over every open cell (one leg of the conserved h2o_total).
func snow_total() -> float:
	return _ledger.snow_total()
## Total liquid water over the field, over every open cell — the static sea/lake reservoir INCLUDED. Its
## subset is `_ledger.static_water_total()`; the sea-excluded figure is SIM_REPORT's `h2o_dynamic_total`.
func water_total() -> float:
	return _ledger.water_total()
## Total water stored in the SOIL, over every REGOLITH cell — the subsurface leg of the conserved h2o budget.
## Infiltrated water lives here rather than in _water, so it must be counted or conservation would appear to
## leak. Masked on regolith, not solidity: carved/eroded aquifer cells read open but still hold their soil.
func soil_total() -> float:
	return _ledger.soil_total()
## The planet's WHOLE conserved H₂O budget: liquid water (sea included) + airborne moisture + frozen snow +
## soil water. A closed sum since the four legs' inclusion rule was unified — nothing sits outside it.
func h2o_total() -> float:
	return _ledger.h2o_total()
## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	return _ledger.snow_line_temp()
## Airborne dust at a world point. Was a bare `return 0.0` with no comment — a point read that answered "how
## much debris is in the air here" with a permanent no. Forwards to the channel module like every other
## per-cell read; it self-wakes the demand-gated `dust` readback the way co2_at does.
func dust_at(x: float, y: float, z: float) -> float:
	return _channels.dust_at(x, y, z)
# (`dust_cell_count()` removed 2026-08-03 — superseded by LAMaterialFieldMineralBudget3D's `dusty_cells`, which
#  counts the same cells with the same threshold inside a pass it already makes. Reason in MaterialFieldQueries3D.)

# MINERAL conservation ledger (rock unification) lives in LAMaterialFieldQueries3D (`_queries.*_total()` etc.);
# report() reads it directly. ONE conserved mineral; mineral_total must stay BOUNDED (the unification's proof).
# --- Per-cell CHANNEL point reads (atmospheric O₂/CO₂, living biomass, the decomposer deposit, and the
# phase-channel debug readers) — bodies live in LAMaterialFieldChannels3D. -------------------------------
## Atmospheric O₂ level at a world point (ambient outside the shell / in box mode).
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
# Emergent DECOMPOSER loop (fungus_sphere3d.glsl): dead matter (detritus) → fungus → CO₂ + soil fertility.
# `deposit_detritus` MOVED to the biota block at the end of this file, because the version that lived here
# never reached the device: it wrote `_f._detritus[c] += amount`, a mirror uploaded once at seed and
# overwritten by every readback. See LAMaterialFieldBiota3D.litter. The same is true of the `respire_at` that
# lived here on the 0.4-dev side: it wrote `_f._o2` / `_f._co2` / `_f._detritus`, all three of which the next
# GPU readback overwrites wholesale (MaterialFieldSphereStep3D). The surviving `respire_at` is the biota one
# at the end of this file, which parks the debit and the credit on the device injection queue.
# Per-cell debug readers for the phase channels (mirror biomass_at/co2_at): molten mineral, bedrock
# fraction, and pre-lightning electrification. Pure reads for the DebugPanel field-view heatmaps.
func lava_at(x: float, y: float, z: float) -> float:
	return _channels.lava_at(x, y, z)
func rock_fill_at(x: float, y: float, z: float) -> float:
	return _channels.rock_fill_at(x, y, z)
func charge_at(x: float, y: float, z: float) -> float:
	return _channels.charge_at(x, y, z)
func fungus_at(x: float, y: float, z: float) -> float:
	return _channels.fungus_at(x, y, z)
## Decomposer extent + intensity for fungus AND detritus in one pass ({fungus_peak, fungus_cells,
## detritus_peak, detritus_cells}); merged into SIM_REPORT by LAMaterialFieldReport3D. Replaces the separate
## fungus_peak/fungus_cells/detritus_peak signatures, which were hardcoded zeros and would have been three
## grid sweeps for four numbers.
func decomposer_stats() -> Dictionary:
	return _channels.decomposer_stats()
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


# `rebuild_surface()` IS DELETED. Its own comment already said "box dynamic-water surface mesh render adapter
# retired" and its body was `pass`; the cubed sphere renders water through the ocean shell.


## Central-telemetry provider (registered once with LASimReport): this field's channel aggregates, in ONE
## dict, so they flow into SIM_REPORT from their owner instead of being hand-threaded into a format string.
## Built in LAMaterialFieldReport3D; polled only at snapshot time, so the O(cells) reads behind it never run
## per frame.
func report() -> Dictionary:
	return _report_mod.report()


# --- LIVING BODIES <-> FIELD (LAMaterialFieldBiota3D) ---------------------------------------------------
# Thin forwarders only. Every one of these used to be a hole in the ledger: grazing read a THERMOMETER and
# took nothing, respiration was a boolean test that consumed no oxygen, drinking emptied no puddle, and the
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
