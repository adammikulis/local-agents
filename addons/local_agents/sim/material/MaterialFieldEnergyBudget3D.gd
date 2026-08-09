class_name LAMaterialFieldEnergyBudget3D
extends RefCounted

## LAMaterialFieldEnergyBudget3D — THE PLANET'S ENERGY BOOKS. Absorbed shortwave in, emitted longwave out,
## and the difference, summed over the same surface cells the solar kernel acts on.
##
## WHY IT EXISTS. `feature/energy-balance` replaced a relax-to-target thermostat with a real radiative sink
## (`dT = (absorbed - sigma*eps*T^4) * dt / C`), and NOTHING IN THIS REPOSITORY MEASURED ENERGY. A grep for
## energy_in / energy_out / radiated / absorbed returned zero hits outside the kernels themselves. Every
## climate claim was therefore argued from temperature — a state variable, which tells you where the planet
## HAS got to and never why, nor which way it is heading. A sink you cannot measure is a sink you cannot
## verify, and the last time this project reasoned about climate from an unmeasured quantity it moved water's
## freezing point to 12.5 C in five files.
##
## WHAT IT IS, EXACTLY: a CPU REFERENCE COMPUTATION OF A GPU KERNEL'S OWN ARITHMETIC. Every expression below
## is transcribed from `kernels3d/heat3d_solar_sphere3d.glsl` (line citations inline), evaluated on the CPU
## mirrors of the same channels, over the same surface set. It computes NOTHING the kernel does not, and it
## writes NOTHING back — it is a voltmeter across the circuit, not part of it.
##   * IF THE TWO EVER DISAGREE, THE KERNEL IS AUTHORITATIVE. It is what actually moves the temperature; this
##     is a restatement of it in another language, one commit away from drifting. A mismatch is a bug HERE
##     until proven otherwise, and the fix is to re-read the kernel and correct this file — never to "fix"
##     the kernel so it agrees with the instrument.
##   * The CPU mirrors it reads are one GPU drain behind the kernel's own view, so a fast transient is
##     smoothed. That is a resolution limit, not an error, and it does not affect the running totals.
##
## THE UNITS. *(Corrected 2026-08-03. This paragraph used to say `SOLAR_CONSTANT` in the kernel is 600.0
## rather than the measured 1361, "sized to this world's cell scale". That stopped being true when the
## kernel was reconciled to the real value, and this file went on mirroring 600 — under-reporting absorbed
## shortwave by 2.27x in every energy number it published.)* The irradiance and the Stefan-Boltzmann
## constant are now the measured ones, so a per-cell flux really is in W/m^2. The TOTALS are still sums
## over cells rather than an integral over area, so they are not watts; the MEANS
## (`energy_absorbed_mean`, `energy_emitted_mean`) are the numbers that compare against real physics —
## an Earth-like planet sits near 240 W/m^2 absorbed on the global mean.
##
## THE ONE THING THIS MEASURES THAT TEMPERATURE CANNOT: `energy_net` is the planet's instantaneous heating
## rate. Positive means it is still warming toward equilibrium, negative that it is shedding. At equilibrium
## it is small against `energy_absorbed`, which is what `energy_imbalance` reports. A planet whose temperature
## has stopped moving and whose imbalance is 40% is not in equilibrium — it is being held by something else
## (conduction from the pinned geothermal core, lava, a clamp), and only the books show that.
##
## READ `*_cool` FOR THE CLIMATE. THE GLOBAL TOTALS ARE A LAVA THERMOMETER. Emission goes as T⁴, so one cell
## of erupting basalt at 1573 K radiates about 900 times what a 288 K surface does, and a few hundred of them
## swamp every other cell on the planet. Measured on the first run of this instrument, seed 4242, 600 frames:
## 8923 surface cells, `energy_emitted_mean` 10223 against a mean surface temperature of 88 °C — a temperature
## whose OWN blackbody flux is 756. The gap is entirely the tail; the T⁴-weighted mean temperature was 420 °C
## while the arithmetic mean was 88 °C. The instrument was arithmetically correct and told you almost nothing,
## which is the failure mode this whole lane exists to avoid. So every total is ALSO reported over the
## sub-solidus surface only (`< LAPhysical.BASALT_SOLIDUS_C` — a real material property, not a fitted cut),
## and that is the pair to read for anything about climate. `energy_cells_magma` says how many cells the split
## moved, so nobody mistakes a quiet planet's numbers for a suppressed one.
##
## AND `energy_clamped_cells` IS THE INSTRUMENT'S OWN INTEGRITY CHECK. The kernel guards one step's dT with
## `clamp(dT, -MAX_DT_PER_STEP, MAX_DT_PER_STEP)` and calls it "numerical guard ONLY (not a physics clamp)"
## (heat3d_solar_sphere3d.glsl:507-521). That claim is true only while the guard never binds. This counts the
## cells where it does. A non-zero count means energy is being silently discarded and the books below do NOT
## describe what the field actually did.
##
## COST. One O(open cells) scan. The CALLER gates it (LAMaterialFieldReport3D._heavy_block), because the
## report provider turns out to be polled every rendered frame rather than "at snapshot time" — see that
## function for the measurement. `energy_scan_ms` reports what one sweep actually costs, so the cadence can be
## re-argued from a number. The per-column insolation is hoisted out of the inner loop (radial is per-column,
## `SphereGrid.cell_radial` is `_dir[c / depth]`), so the Vector3 work is O(columns), not O(cells).
## (Explicit types only, no ':=' inferred typing.)

# --- CONSTANTS FROM LAPhysical -----------------------------------------------------------------------------
# These are properties of matter, so they live in one place and are read, never re-typed. Each is equal to the
# kernel's own copy (the kernel must declare its own because GLSL cannot read GDScript):
#   LAPhysical.STEFAN_BOLTZMANN 5.670374419e-8  vs  glsl:118 STEFAN         5.670374419e-8  (equal)
#   LAPhysical.KELVIN_OFFSET    273.15          vs  glsl:120 KELVIN         273.15
#   LAPhysical.ALBEDO_BARE_GROUND 0.15          vs  glsl:134 ALBEDO_GROUND  0.15
#   LAPhysical.ALBEDO_OCEAN       0.06          vs  glsl:135 ALBEDO_WATER   0.06
#   LAPhysical.ALBEDO_SNOW_ICE    0.65          vs  glsl:136 ALBEDO_ICE     0.65
#   LAPhysical.DRY_WOOD_DENSITY_KG_M3 500.0     vs  glsl:163 RHO_CELLULOSE  500.0
#   LAPhysical.ALBEDO_VEGETATION  0.12          vs  glsl:164 ALBEDO_VEG     0.12
#   LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS 0.03 vs glsl:165 FOLIAGE_FRACTION 0.03
#   LAPhysical.LEAF_MASS_PER_AREA_KG_M2 0.080   vs  glsl:166 LEAF_MASS_PER_AREA 0.080
#   LAPhysical.CANOPY_EXTINCTION_COEFF 0.5      vs  glsl:167 CANOPY_EXTINCTION 0.5
#   LAPhysical.ATMOS_OPTICAL_DEPTH 0.835        vs  glsl:245 TAU_SEA        0.835
#   LAPhysical.TWO_STREAM_COEFF    0.75         vs  glsl:246 TAU_TWO_STREAM 0.75
#   LAPhysical.ATMOS_SW_OPTICAL_DEPTH 0.2597    vs  glsl:271 TAU_SW         0.2597
#   LAPhysical.AIR_MASS_HORIZON   38.0          vs  glsl:275 AIR_MASS_HORIZON 38.0
#   LAPhysical.VOL_HEAT_CAP_{AIR,ROCK,WATER,SNOW} vs glsl:193-196 RC_{AIR,ROCK,WATER,SNOW}
# *(Every glsl line number in this file was stale by 20-50 lines before 2026-08-03. The VALUES still matched,
# which is why nobody noticed: a citation that points at the wrong line is only found when someone follows it.
# IT HAPPENED AGAIN, and this is the follow: at 50e71a3 every number in this block was stale by 6-16 lines —
# STEFAN was cited at 108 and sat at 114, TAU_SW at 221 and sat at 237 — because the kernel grew comment
# blocks above them. All of them are re-derived here against the kernel as it stands on 2026-08-09. That two
# rounds of hand-transcribed line numbers have now both rotted is the argument for citing the CONSTANT NAME,
# which cannot move; the line number is a convenience and should be read as one.)*

# --- CONSTANTS MIRRORED FROM THE KERNEL --------------------------------------------------------------------
# These are MODEL parameters of this world (cell scale, step size, thresholds), not properties of matter, so
# they are NOT in LAPhysical and are transcribed here with their kernel line. If you change one in the kernel,
# change it here in the same edit — nothing else keeps them equal.
# CORRECTED 2026-08-03. This read 600.0, described as "this world's solar constant, NOT LAPhysical's 1361".
# The kernel had already been reconciled to the measured 1361 (heat3d_solar_sphere3d.glsl:119,
# `// LAPhysical.SOLAR_CONSTANT_W_M2`) and nobody updated the instrument, so for as long as that gap
# existed this file under-reported absorbed shortwave by 2.27x — and with it energy_net, energy_net_cool,
# energy_imbalance and energy_imbalance_cool, which are the numbers every climate argument is made from.
# It is read from the authority now rather than transcribed, so it cannot drift again.
const K_SOLAR_CONSTANT: float = LAPhysical.SOLAR_CONSTANT_W_M2   # glsl:119
const K_ICE_ALBEDO_GAIN: float = 40.0      # glsl:137 — snow mass -> reflectivity; a dusting already whitens
# THE FOUR AREAL HEAT CAPACITIES ARE GONE, from the kernel and from here. They were K_HEAT_CAP_AIR 345600 /
# ROCK 604800 / WATER 3888000 / SNOW 1080000 J/m^2/K, and against rho*c*cell_size for the very cell the
# conduction kernel was stepping they were wrong by 18.2x (air, too large), 64.4x (rock), 17.2x (water) and
# 9.3x (snow). The kernel derives the capacity per cell now — LAPhysical's real volumetric values times the
# cell's own depth — so this file reads the same authority instead of transcribing four literals.
const K_P_REF: float = 100.0               # glsl:244 P_REF — sea-level column pressure in this world's units
const K_MAX_DT_PER_STEP: float = 5.0       # glsl:132 MAX_DT_PER_STEP — the guard whose binding this file counts
const K_WATER_SURFACE_MIN: float = 0.5     # glsl:279 WATER_SURFACE_MIN — water fraction that makes a cell a sea surface

var _f = null                                # back-reference to the owning LAMaterialField3D
var _samples: int = 0                        # recomputes so far

# Running integrals. Integrated against `field_sim_s` — the FIELD's own simulated clock — because the kernel
# applies its flux over STEP_DT per field step. Integrating against wall time or render frames would make the
# totals track framerate and `--fast`, which is the error the physics-clock rule in CLAUDE.md exists to stop.
var _cum_absorbed: float = 0.0
var _cum_emitted: float = 0.0
var _last_sim_s: float = -1.0


func setup(field) -> void:
	_f = field


## The books. THE CALLER OWNS THE CADENCE — LAMaterialFieldReport3D._heavy_block() gates and caches this, so
## every call here does the full scan. One owner for the gate, on purpose: two gates at the same period beat
## against each other the moment one of the two constants is edited, which is the same failure shape as two
## owners of one global.
func report() -> Dictionary:
	return _compute()


## World-space unit vector toward the sun, magnitude carrying insolation, ROTATED INTO THE FIELD'S FRAME.
##
## The frame conversion is the whole point and is easy to get wrong: the grid is body-local (it rides the
## spinning planet), so `LAMaterialField3D.cell_radial` returns a BODY-LOCAL vector, while the sun node lives
## in the system frame. LAMaterialFieldSphereStep3D.gd:158 hands the kernel `dir_to_field(basis.z * insol)`
## for exactly this reason, and this mirrors it so the insolation measured here is the insolation the kernel
## computed. Dotting a world-frame sun against a body-local radial gives a number that is right only at the
## instant the body's rotation happens to be identity.
func sun_field_dir() -> Vector3:
	if _f == null or _f._sun_light == null:
		return Vector3.ZERO
	var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
	return _f.dir_to_field(_f._sun_light.global_transform.basis.z * insol)


func _compute() -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._sphere == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var depth: int = int(_f._sphere.depth)
	if depth <= 0:
		return out
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var snow: PackedFloat32Array = _f._snow
	# `pressure` and `rock_fill` are GPU-owned and demand-gated (MaterialSphereGPU3D.SITUATIONAL_CHANNELS), so
	# take them from the read-only drain probe rather than asking for their mirrors to be kept hot. *(Changed
	# 2026-08-03: this used to call `request_channel("pressure")` here. A gauge must not decide readback
	# residency — the simulation's own write paths read those mirrors, so requesting one changes the run. See
	# the `request_channel` docstring in LAMaterialSphereGPU3D.)* If a leg does not come back the mirror stands
	# in, and for pressure the all-zero mirror means the kernel's own step-0 fallback (glsl:427-430) applies:
	# p_col <= 0 -> P_REF, a uniform sea-level emissivity with no altitude structure. `energy_pressure_live`
	# reports which of the two the numbers below were built from, so nobody reads a flat profile as a result.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		# The capacity mix needs every carrier, and five of them are demand-gated or mirror-less. Probe names
		# UNION across callers (see request_probe), so asking for the same legs the energy ledger asks for
		# costs one shared sample, and both instruments then read the SAME instant — which is the inclusion
		# rule they both depend on.
		var want: PackedStringArray = PackedStringArray(["pressure"])
		want.append_array(LAHeatCapacity.channels())
		_f._gpu.request_probe(want)
	var pressure: PackedFloat32Array = legs.get("pressure", _f._pressure)
	var rock_fill: PackedFloat32Array = legs.get("rock_fill", _f._rock_fill)
	# ONE capacity model, shared with the stock this module's output is differenced against. See the note at
	# the `rc` assignment below for what the two-copy version cost.
	var _rc_channels: Dictionary = {
		"rock_fill": rock_fill, "lava": legs.get("lava", _f._lava),
		"sediment": _f._sediment, "susp": _f._susp, "dust": legs.get("dust", PackedFloat32Array()),
		"carbonate": legs.get("carbonate", PackedFloat32Array()),
		"silica": legs.get("silica", PackedFloat32Array()),
		"water": _f._water, "soil": _f._soil, "snow": _f._snow, "moisture": _f._moisture,
		"fuel": legs.get("fuel", _f._fuel), "biomass": _f._biomass,
		"detritus": legs.get("detritus", _f._detritus),
		"fungus": legs.get("fungus", PackedFloat32Array()),
	}
	if solid.size() != cc or temp.size() != cc:
		return out
	var has_water: bool = water.size() == cc
	var has_snow: bool = snow.size() == cc
	var has_rock: bool = rock_fill.size() == cc
	var has_pressure: bool = pressure.size() == cc
	# The canopy leg of the albedo (glsl:396-401). Read from the CPU mirror the same way `snow` and `water`
	# above are, and NEVER by calling request_channel — a gauge that changes which channels are resident
	# changes the simulation, which is the rule this file's own header lane exists to keep.
	var biomass: PackedFloat32Array = _f._biomass
	var has_biomass: bool = biomass.size() == cc
	var pressure_live: int = 0
	var sun: Vector3 = sun_field_dir()

	var abs_toa: float = 0.0
	var abs_ground: float = 0.0
	var emit_toa: float = 0.0
	var emit_ground: float = 0.0
	var surf_toa: int = 0
	var surf_ground: int = 0
	var lit_cells: int = 0
	var emis_sum: float = 0.0
	var cap_sum: float = 0.0
	var dt_sum: float = 0.0
	var dt_abs_max: float = 0.0
	var clamped: int = 0
	var t_sum: float = 0.0
	# The sub-solidus (non-magmatic) surface, tracked in parallel — the climate half of the books. See the
	# header: T⁴ makes a few lava cells dominate every global total, so a total that mixes them answers a
	# question nobody asked.
	var abs_cool: float = 0.0
	var emit_cool: float = 0.0
	var cells_cool: int = 0
	var t_cool_sum: float = 0.0
	var emit_magma: float = 0.0
	# The column shortwave split, reported so the two halves can be read against each other. Before 2026-08-03
	# they were not halves at all: both cells absorbed the full undiminished beam.
	var sw_atm: float = 0.0
	var sw_surface: float = 0.0
	var cells_bedrock: int = 0
	var albedo_sum_surface: float = 0.0
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	var columns: int = cc / depth
	for surf in columns:
		var base: int = surf * depth
		# Per-COLUMN insolation: `SphereGrid.cell_radial(c)` is `_dir[c / depth]`, one vector per column, so the
		# only Vector3 work in this scan is O(columns). Same expression as glsl:370-373.
		var insolation: float = maxf(0.0, _f.cell_radial(base).dot(sun))
		# glsl:307-326 find_column_surface(), hoisted: the column is scanned top-down ONCE for the cell the beam
		# lands on, which is both the MATERIAL SURFACE and the overlying air mass the top-of-atmosphere cell
		# must use for its own share. Doing it per column here is the same answer as the kernel's per-TOA-cell
		# walk and costs O(depth) instead of O(depth) per candidate.
		var surf_c: int = -1
		for r in range(depth - 1, -1, -1):
			var c0: int = base + r
			if solid[c0] != 0:
				break                                       # rock: nothing below is lit through it
			if has_water and clampf(water[c0], 0.0, 1.0) >= K_WATER_SURFACE_MIN:
				surf_c = c0                                 # topmost water cell: the sea/lake surface
				break
			if r > 0 and solid[c0 - 1] != 0:
				surf_c = c0                                 # rests on rock: the ground
				break
		# The overlying air mass at the cell the beam lands on — ONE number for the whole column, so the
		# shortwave shares are complementary and the longwave exchange is symmetric by construction, not by
		# coincidence (glsl:427-443).
		var p_beam: float = 0.0
		if surf_c >= 0:
			p_beam = pressure[surf_c] if has_pressure else 0.0
			if p_beam <= 0.0:
				p_beam = K_P_REF
		var mu: float = maxf(insolation, 1.0 / LAPhysical.AIR_MASS_HORIZON)
		var trans: float = exp(-LAPhysical.ATMOS_SW_OPTICAL_DEPTH * (p_beam / K_P_REF) / mu)
		# The air column's LONGWAVE absorptivity — what it intercepts of the surface's infrared and re-emits
		# from both faces (glsl:485). The top-of-atmosphere cell of this column, needed for the exchange.
		var eps_a: float = 1.0 - 1.0 / (1.0 + LAPhysical.TWO_STREAM_COEFF * LAPhysical.ATMOS_OPTICAL_DEPTH * (p_beam / K_P_REF))
		var top_c: int = -1
		if solid[base + depth - 1] == 0:
			top_c = base + depth - 1
		var t_top_4: float = 0.0
		if top_c >= 0:
			var tt: float = maxf(temp[top_c] + LAPhysical.KELVIN_OFFSET, 1.0)
			t_top_4 = tt * tt * tt * tt
		var t_surf_4: float = 0.0
		if surf_c >= 0:
			var tsr: float = maxf(temp[surf_c] + LAPhysical.KELVIN_OFFSET, 1.0)
			t_surf_4 = tsr * tsr * tsr * tsr

		for r in depth:
			var c: int = base + r
			# glsl:333-367. Column layout is c = surf * depth + r (LAMaterialField3D._compute_regolith), so the
			# outward neighbour (nbr slot 5) is c+1 and the inward one (slot 0) is c-1; -1 means space/core.
			var up: int = c + 1 if r < depth - 1 else -1
			var down: int = c - 1 if r > 0 else -1
			var solid_here: bool = solid[c] != 0
			var faces_space: bool = up < 0
			var top_of_atm: bool = faces_space and not solid_here
			var bedrock_top: bool = faces_space and solid_here
			var mat_surface: bool = (not solid_here) and (c == surf_c)
			if not (top_of_atm or bedrock_top or mat_surface):
				continue      # roofed pockets, interior air and buried rock: conduction + buoyancy only

			var wet: float = clampf(water[c], 0.0, 1.0) if has_water else 0.0
			var snow_m: float = snow[c] if has_snow else 0.0
			var icy: float = clampf(snow_m * K_ICE_ALBEDO_GAIN, 0.0, 1.0)
			# glsl:396-401 — canopy cover by Beer-Lambert through the leaf area the cell's standing biomass
			# carries. Vegetation darkens the LAND inside the water mix, so plankton cannot brighten a sea.
			var veg: float = 0.0
			if has_biomass:
				var leaf_kg_m2: float = maxf(biomass[c], 0.0) * LAPhysical.DRY_WOOD_DENSITY_KG_M3 \
					* cell_size * LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
				veg = 1.0 - exp(-LAPhysical.CANOPY_EXTINCTION_COEFF * (leaf_kg_m2 / LAPhysical.LEAF_MASS_PER_AREA_KG_M2))
			# glsl:412-413 — ice/snow reflect, open water absorbs nearly everything, bare ground between, and a
			# canopy is darker than the ground it stands on.
			var land: float = lerpf(LAPhysical.ALBEDO_BARE_GROUND, LAPhysical.ALBEDO_VEGETATION, veg)
			var albedo: float = lerpf(lerpf(land, LAPhysical.ALBEDO_OCEAN, wet), LAPhysical.ALBEDO_SNOW_ICE, icy)
			# THIS BLOCK WAS THE PRE-UNIFICATION CAPACITY MODEL, SITTING ON THE BOOKED SIDE OF THE LEDGER'S
			# OWN SUBTRACTION. *(Replaced 2026-08-09.)* It kept the `solid` early-return that
			# rc_shared.glsli deleted — the one that made a unit of bedrock split 0.4/0.6 across two cells
			# hold 3.41e6 J/m3K while split 0.5/0.5 held 4.87e6, a 43% jump for no change of mass — and it
			# counted neither lava nor organic matter nor any of the eight carriers added with them.
			# LAMaterialFieldEnergyLedger3D differences the BOOKED terms computed here against a STOCK built
			# from the shared model, so every one of those disagreements was published as planetary energy
			# drift. Reconciling the stock's copy alone already took the measured drift from 7.4% to 12.8%;
			# this was the other half of that subtraction, and it was still on the old model afterwards.
			# Its old comment cited "glsl:201-210 rc_of_cell()", a function that no longer exists.
			var rc: float = LAHeatCapacity.cell(_rc_channels, c)
			var cap: float = maxf(rc * cell_size, 1.0)
			# Provenance only — this reports whether the greenhouse came from a live pressure readback. The
			# radiative terms below use `p_beam`, the COLUMN's value, because both cells must share it.
			var p_col: float = pressure[c] if has_pressure else 0.0
			if p_col > 0.0:
				pressure_live += 1
			var eps_cell: float = eps_a if (top_of_atm or mat_surface) else 0.0
			# glsl:445-453 — the column's beam, spent once. The top-of-atmosphere cell takes what the air
			# intercepts; the material surface takes what got through, less what it reflects. Exposed bedrock
			# faces space with no air over it at all, so nothing is intercepted above it.
			var t_k: float = maxf(temp[c] + LAPhysical.KELVIN_OFFSET, 1.0)
			var absorbed: float = 0.0
			if top_of_atm:
				var a_atm: float = K_SOLAR_CONSTANT * insolation * (1.0 - trans)
				absorbed += a_atm
				sw_atm += a_atm
			if mat_surface or bedrock_top:
				var beam: float = trans if mat_surface else 1.0
				var a_surf: float = K_SOLAR_CONSTANT * insolation * beam * (1.0 - albedo)
				absorbed += a_surf
				sw_surface += a_surf
				albedo_sum_surface += albedo
				if bedrock_top:
					cells_bedrock += 1
			# glsl:485-503 — the two-layer grey exchange. The air layer radiates eps_a from BOTH faces and
			# absorbs eps_a of the surface's flux; the surface radiates as a blackbody and receives the air's
			# downward half. `emitted` is therefore the NET longwave leaving this cell, and summed over the
			# column it is (1 - eps_a)*sigma*Ts^4 + eps_a*sigma*Ta^4 — the outgoing longwave, counted once.
			var lw_self: float = 0.0
			var lw_in: float = 0.0
			if top_of_atm:
				lw_self += 2.0 * eps_cell
				if surf_c >= 0:
					lw_in += eps_cell * LAPhysical.STEFAN_BOLTZMANN * t_surf_4
			if mat_surface or bedrock_top:
				lw_self += 1.0
				if mat_surface and top_c >= 0:
					lw_in += eps_cell * LAPhysical.STEFAN_BOLTZMANN * t_top_4
			var emitted: float = lw_self * LAPhysical.STEFAN_BOLTZMANN * t_k * t_k * t_k * t_k - lw_in
			# The step the kernel would apply, and whether its numerical guard binds. The dt is the field's ONE
			# clock, read from its owner rather than transcribed — this used to be a local K_STEP_DT of 0.1
			# mirroring a kernel constant that disagreed with the conduction kernel dispatched beside it.
			var d_t: float = (absorbed - emitted) * LAMaterialFieldSphereStep3D.real_seconds_per_step() / cap
			if absf(d_t) > K_MAX_DT_PER_STEP:
				clamped += 1
			dt_sum += d_t
			dt_abs_max = maxf(dt_abs_max, absf(d_t))
			emis_sum += eps_cell
			cap_sum += cap
			t_sum += temp[c]
			if temp[c] < LAPhysical.BASALT_SOLIDUS_C:
				cells_cool += 1
				abs_cool += absorbed
				emit_cool += emitted
				t_cool_sum += temp[c]
			else:
				emit_magma += emitted
			if insolation > 0.0:
				lit_cells += 1
			# TOP-OF-ATMOSPHERE vs MATERIAL SURFACE, kept apart. They are the kernel's two distinct roles
			# (glsl:333-367) and they behave nothing alike: the TOA set sits under almost no air, so its
			# emissivity approaches 1 and it radiates as a bare blackbody, while the surface sits under the full
			# column. Summed together they average into a number that describes neither. A cell that is BOTH (a
			# summit reaching the top of the shell) is counted under TOA, once.
			if top_of_atm:
				surf_toa += 1
				abs_toa += absorbed
				emit_toa += emitted
			else:
				surf_ground += 1
				abs_ground += absorbed
				emit_ground += emitted

	var n: int = surf_toa + surf_ground
	if n <= 0:
		return out
	var absorbed_total: float = abs_toa + abs_ground
	var emitted_total: float = emit_toa + emit_ground
	var net: float = absorbed_total - emitted_total
	var fn: float = float(n)

	# RUNNING TOTALS. Rectangle rule over the field's own simulated seconds. The global sums are smooth in time
	# (half the sphere is lit at every instant, so the planet-wide absorbed total barely breathes over a day),
	# which is what makes a coarse sample rate adequate here — unlike a single cell, which swings.
	var sim_s: float = LASimReport.gauge_cur("field_sim_s", 0.0)
	if _last_sim_s >= 0.0 and sim_s > _last_sim_s:
		var d_s: float = sim_s - _last_sim_s
		_cum_absorbed += absorbed_total * d_s
		_cum_emitted += emitted_total * d_s
	_last_sim_s = sim_s
	_samples += 1

	out["energy_absorbed"] = absorbed_total
	out["energy_emitted"] = emitted_total
	out["energy_net"] = net
	# The dimensionless read of "how far from balance". At equilibrium this is near zero; the SIGN says which
	# way the planet is going, which no temperature reading gives you.
	out["energy_imbalance"] = net / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	out["energy_absorbed_mean"] = absorbed_total / fn
	out["energy_emitted_mean"] = emitted_total / fn
	out["energy_abs_toa"] = abs_toa
	out["energy_abs_ground"] = abs_ground
	out["energy_emit_toa"] = emit_toa
	out["energy_emit_ground"] = emit_ground
	out["energy_cells_toa"] = surf_toa
	out["energy_cells_ground"] = surf_ground
	out["energy_cells"] = n
	out["energy_lit_cells"] = lit_cells
	out["energy_lit_frac"] = float(lit_cells) / fn
	# ALBEDO OVER THE CELLS THAT HAVE ONE. *(Corrected 2026-08-03. This averaged over EVERY surface cell,
	# which included the top-of-atmosphere air cell above each ocean — `wet` is 0 up there, so the air over the
	# sea was scored at ALBEDO_BARE_GROUND 0.15 and the mean was dominated by an albedo no ocean surface has.
	# It read 0.137 on a planet whose land is 0.15 and whose sea is 0.06.) The top-of-atmosphere cell has no
	# surface reflectance at all now — it takes the air column's share of the beam, which is an absorption, not
	# a (1 - albedo) — so the mean runs over material surfaces and exposed bedrock only.
	out["energy_albedo_mean"] = albedo_sum_surface / float(maxi(surf_ground + cells_bedrock, 1))
	# THE AIR COLUMN'S LONGWAVE ABSORPTIVITY — the greenhouse strength, `eps_a = 1 - 1/(1 + 0.75*tau*p/P_REF)`.
	# *(Changed 2026-08-03. This used to report the complementary quantity, the TRANSMISSION `1/(1+0.75 tau p)`,
	# computed per cell from that cell's own pressure — so the top-of-atmosphere cell contributed ~1.0 and the
	# mean described a planet with almost no greenhouse. It reads what the air INTERCEPTS now, from the
	# column's own air mass, which is the number both radiating cells actually use. 0 means a transparent
	# atmosphere, 1 an opaque one; a sea-level column here is 0.385.)*
	out["energy_emissivity_mean"] = emis_sum / fn
	out["energy_cap_mean"] = cap_sum / fn
	out["energy_surf_temp_mean"] = t_sum / fn
	out["energy_dt_mean"] = dt_sum / fn
	out["energy_dt_absmax"] = dt_abs_max
	# NON-ZERO MEANS THE BOOKS BELOW ARE FICTION for that many cells — the kernel threw the excess away.
	out["energy_clamped_cells"] = clamped
	# THE CLIMATE HALF — the same books over the sub-solidus surface only. Read these for anything about
	# whether the planet is warming, cooling or in balance; the totals above are dominated by open lava.
	var fc: float = float(maxi(cells_cool, 1))
	out["energy_abs_cool"] = abs_cool
	out["energy_emit_cool"] = emit_cool
	out["energy_net_cool"] = abs_cool - emit_cool
	out["energy_imbalance_cool"] = (abs_cool - emit_cool) / abs_cool if abs_cool > 1.0e-9 else 0.0
	out["energy_absorbed_cool_mean"] = abs_cool / fc
	out["energy_emitted_cool_mean"] = emit_cool / fc
	out["energy_temp_cool_mean"] = t_cool_sum / fc
	out["energy_cells_cool"] = cells_cool
	out["energy_cells_magma"] = n - cells_cool
	out["energy_emit_magma"] = emit_magma
	# How much of the whole planet's longwave leaves through molten rock. Near 1.0 means the global totals
	# above describe volcanism and nothing else.
	out["energy_magma_share"] = emit_magma / emitted_total if emitted_total > 1.0e-9 else 0.0
	# THE COLUMN SHORTWAVE SPLIT. `energy_sw_atm + energy_sw_surface` IS `energy_absorbed` — the two are the
	# air's share and the ground's share of one beam, not two independent absorptions. Before 2026-08-03 both
	# cells took the full undiminished beam and the sum was the solar constant counted twice per lit column;
	# `energy_sw_frac_atm` is the fraction the atmosphere intercepts, which should sit near Earth's measured
	# 0.23 wherever the column is close to sea-level pressure and the sun is high.
	out["energy_sw_atm"] = sw_atm
	out["energy_sw_surface"] = sw_surface
	out["energy_sw_frac_atm"] = sw_atm / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	# Bare rock facing space. It radiated nothing at all until 2026-08-03 (`if (solid) return`), so any column
	# capped by stone traded no radiation with the sky in either direction.
	out["energy_cells_bedrock"] = cells_bedrock
	out["energy_cum_absorbed"] = _cum_absorbed
	out["energy_cum_emitted"] = _cum_emitted
	out["energy_cum_net"] = _cum_absorbed - _cum_emitted
	out["energy_samples"] = _samples
	# Provenance, so a flat emissivity profile is never mistaken for a physical result: the share of surface
	# cells whose greenhouse came from a LIVE pressure readback rather than the kernel's sea-level fallback.
	out["energy_pressure_live"] = float(pressure_live) / fn
	out["energy_scan_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return out


func _blank() -> Dictionary:
	return {
		"energy_absorbed": 0.0, "energy_emitted": 0.0, "energy_net": 0.0, "energy_imbalance": 0.0,
		"energy_absorbed_mean": 0.0, "energy_emitted_mean": 0.0,
		"energy_abs_toa": 0.0, "energy_abs_ground": 0.0, "energy_emit_toa": 0.0, "energy_emit_ground": 0.0,
		"energy_cells_toa": 0, "energy_cells_ground": 0, "energy_cells": 0,
		"energy_lit_cells": 0, "energy_lit_frac": 0.0,
		"energy_albedo_mean": 0.0, "energy_emissivity_mean": 0.0, "energy_cap_mean": 0.0,
		"energy_surf_temp_mean": 0.0, "energy_dt_mean": 0.0, "energy_dt_absmax": 0.0,
		"energy_clamped_cells": 0,
		"energy_abs_cool": 0.0, "energy_emit_cool": 0.0, "energy_net_cool": 0.0, "energy_imbalance_cool": 0.0,
		"energy_absorbed_cool_mean": 0.0, "energy_emitted_cool_mean": 0.0, "energy_temp_cool_mean": 0.0,
		"energy_cells_cool": 0, "energy_cells_magma": 0, "energy_emit_magma": 0.0, "energy_magma_share": 0.0,
		"energy_sw_atm": 0.0, "energy_sw_surface": 0.0, "energy_sw_frac_atm": 0.0,
		"energy_cells_bedrock": 0,
		"energy_cum_absorbed": _cum_absorbed, "energy_cum_emitted": _cum_emitted,
		"energy_cum_net": _cum_absorbed - _cum_emitted, "energy_samples": _samples,
		"energy_pressure_live": 0.0, "energy_scan_ms": 0.0,
	}
