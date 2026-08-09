class_name LAMaterialFieldEnergyLedger3D
extends RefCounted

## LAMaterialFieldEnergyLedger3D — THE CONSERVATION LEDGER FOR ENERGY, built to the shape
## LAMaterialFieldLedger3D proved on H₂O and LAMaterialFieldMineralBudget3D copied for rock: a STOCK, its
## per-step DRIFT, and the drift's residual against every term the books can name. The residual is the
## instrument.
##
## WHY IT EXISTS. Energy was the one substance on this project's own "locked down" bar with no conservation
## ledger. H₂O, mineral, carbon, oxygen, nitrogen and fertility all have one; the diagnosis those ledgers
## produced was that *every subsystem with a conservation ledger conserves and every subsystem without one
## mints*, and energy was simply never checked. LAMaterialFieldEnergyBudget3D is NOT this: it is a FLUX
## instrument, a CPU transcription of ONE kernel's own arithmetic (heat3d_solar_sphere3d), so it can only ever
## see the two terms that kernel computes. Nothing anywhere summed rho*c*V*T as a STOCK, so there was no
## residual and no energy_drift_per_step. The planet radiates 2.3x what it absorbs, the geotherm supplies
## ~11 W/m² of a ~150 W/m² gap, and it WARMED 15 °C → 30 °C over a run the radiative books say should have
## cooled 47 °C. About 140 W/m² enters from terms nothing books. This is the gauge that can see them.
##
## ===== THE STOCK ==========================================================================================
##
##   energy_stock = Σ over EVERY cell, rock and void, of  rc(cell) * cell_size³ * (T + 273.15)   [joules]
##
## `rc(cell)` is the kernels' own `rc_of_cell` (heat3d_solar_sphere3d.glsl:167-176, identical text in
## heat_sphere3d.glsl `rc_of` and heat3d_buoyancy_sphere3d.glsl `rc_of`): a solid cell is rock, an open cell
## is the volume-fraction mix of rock_fill / water / snow with air filling the rest. Reading the same
## expression the kernels read is the whole point — a stock computed from a different capacity model would
## measure the disagreement between two models rather than the physics.
##
## THE REFERENCE IS ABSOLUTE ZERO, NOT 0 °C, and that is not a formality. The stock is an internal energy in
## the constant-heat-capacity idealisation, so it must be referenced to the only non-arbitrary zero there is.
## A Celsius reference would make a cell's stored energy change sign at 0 °C and would make a parcel of water
## at exactly 0 °C carry no energy at all, which is false and would silently cancel real transfers.
##
## EVERY CELL, NO MASK. Rock is where most of this planet's heat actually is (the seeded geotherm runs to
## hundreds of °C below the surface), the geotherm delivers its flux INTO rock, and conduction moves heat
## across the rock/void boundary in both directions. A ledger masked on `solid` would book a conduction
## transfer as creation or destruction — the same failure the mineral ledger's header argues at length, and
## for the same reason: `solid` is re-derived from `rock_fill >= 0.5` every step, so masking on it makes the
## ledger's own membership a function of a quantity the simulation is changing underneath it.
##
## ===== THE DRIFT IS SPLIT, BECAUSE TWO DIFFERENT THINGS MOVE IT ===========================================
##
## ΔU = Σ(rc₁T₁ − rc₀T₀) = Σ rc₀ΔT  +  Σ Δrc·T₁ , exactly (the cross term lands in the second half).
##   * `energy_heat_*`     — Σ rc₀ΔT. Heat actually moving: radiation, conduction, convection, combustion.
##   * `energy_capacity_*` — Σ Δrc·T₁. The cell's HEAT CAPACITY changed under its temperature. Pure advection
##     of water or rock between cells nets this to zero globally; what does NOT net out is mass leaving the
##     capacity model altogether. `rc_of` counts rock, water, snow and air and gives WATER VAPOUR none at all,
##     so every evaporation deletes the record of that water's sensible heat and every condensation creates
##     it. Keeping this leg separate is what stops that being read as a radiative imbalance.
## The two are summed and checked against the raw stock change every sample (`energy_split_close`, ~0 or the
## decomposition is wrong).
##
## ===== WHAT IS BOOKED, AND IT IS THREE TERMS ==============================================================
##
##  1. SHORTWAVE ABSORBED and NET LONGWAVE EMITTED — heat3d_solar_sphere3d.glsl:472 is the only line in that
##     kernel that writes temp. Taken from LAMaterialFieldEnergyBudget3D's own `energy_absorbed` /
##     `energy_emitted` (its :294-321), which are sums of per-cell fluxes in W/m², so a face area of
##     cell_size² and the field's real step length turn them into joules.
##  2. THE GEOTHERM BOUNDARY — heat_sphere3d.glsl:153-157, the ghost-cell bond at r = 0. Rate read from
##     LAMaterialFieldGeotherm3D's published `core_flux_w_m2` (its :202) over the SOLID r == 0 face, counted
##     in this module's own sweep. The kernel gives an OPEN r == 0 cell an air interface (48x less), which the
##     geotherm's scalar ledger excludes and so does this booking; that unbooked sliver is ~7% of the face at
##     1/48 the conductivity.
##  3. SOURCED HEAT INJECTIONS — MaterialFieldInject3D.add_heat_energy (:177-191), booked in JOULES by
##     MaterialFieldHeatQueue3D.note_energy (:131-132). Impacts, bolts and landing ejecta.
##
## AND TWO MORE THAT NEED NO BOOKING, BECAUSE THEY CONSERVE BY CONSTRUCTION — checked, not assumed:
##   * interior conduction, heat_sphere3d.glsl:167. Both cells of a bond share one interface conductivity
##     (harmonic mean) and each divides by its OWN rc, so rc_A·ΔT_A + rc_B·ΔT_B = 0 exactly. The comment there
##     about the receiving cell's capacity "letting hot rock warm the air without cooling much" describes the
##     TEMPERATURE asymmetry, not an energy one.
##   * buoyant convection, heat3d_buoyancy_sphere3d.glsl:91,119. Same construction, and `min(rc_here, rc_nbr)`
##     is symmetric so both invocations compute the same Q. Its own header carries the proof and the
##     measurement of the degrees-based version it replaced.
##
## ===== WHAT IS *NOT* BOOKED. THIS LIST IS THE POINT, NOT A FAILURE. =======================================
##
## THIS LIST IS STAGE 1'S WORK QUEUE. The gauge reads the sum of these as `energy_residual_*` and it is
## supposed to be large; a ledger that appeared to close while they were live would be lying. Items 10 and
## 11 are the two the gauge itself found and the two worth taking first — they are not ordered by size.
## *(Preamble corrected 2026-08-09. It read "Four other tracks are closing these right now and their terms
## do not exist on this branch", which stopped being true when those tracks landed or were held back, and
## which reads to the next agent as "someone else has this".)*
##
##   1. LATENT HEAT OF BOILING — heat3d_cool_sphere3d.glsl:128 `temp[idx] = t - boiled * cost_per_frac / cap`.
##   2. LATENT HEAT OF CRYSTALLISATION — lava_phase_sphere3d.glsl:141 `temp[g] = min(temp[g], cooled)`.
##   3. COMBUSTION ENTHALPY — now a SUB-CASE OF ITEM 4 rather than its own term, and it is booked nowhere
##      either way. *(Re-cited 2026-08-09: this said "and the fire's radiant term — fire_sphere3d.glsl:190
##      and :172", and that kernel was deleted in 94538d8. The radiant term went with it. Combustion is
##      record R26 now, and its heat arrives through the record engine's enthalpy line,
##      reactions_sphere3d.glsl:640 `temp[i] += rc.enthalpy_j_m3 * x / max(rc_of(i), 1.0)`.)*
##   4. THE REACTION ENGINE'S HEAT, and it is TWO lines, not one. A record's declared enthalpy at
##      reactions_sphere3d.glsl:640 (above), and the raw TEMP slot at :434
##      `if (slot == TEMP) { temp[i] += v; }`. Either way a record adds degrees with nothing debited
##      anywhere. *(:376 before; the line moved.)*
##   5. GROUNDWATER ADVECTED HEAT — soil_sphere3d.glsl:515 `temp[g] = mix(temp[g], donor_t, frac)`. The
##      receiving cell moves toward the donor's temperature and the donor is not cooled on that line.
##   6. LAVA AND MAGMA ADVECTED HEAT — lava_flow_sphere3d.glsl:172 and magma_buoy_sphere3d.glsl:97, both
##      `temp = (MAX_MASS*temp + inflow*T_in) / (MAX_MASS + inflow)`: mass-weighted mixing against a FIXED
##      denominator rather than the two cells' own heat capacities, with no matching debit on the donor.
##   7. UNSOURCED HEAT INJECTIONS — MaterialFieldInject3D.add_heat (:200-207), the raw degrees form that names
##      no store. Published raw beside the books as `energy_unsourced_dc` (degrees x cells since the baseline)
##      rather than converted, because converting it would need each cell's rc at the instant it was hit.
##   8. WATER VAPOUR'S SENSIBLE HEAT — `moisture` appears in no `rc_of`, so the capacity model does not hold
##      it. This is the `energy_capacity_*` leg above, which is why that leg is published separately.
##   9. THE INJECTION'S OWN CAPACITY MODEL disagrees with the kernels'. MaterialFieldInject3D
##      ._cell_heat_capacity (:157-168) mixes water and air only; `rc_of` mixes rock_fill, water, snow and
##      air. So a booked joule and the stock's response to it differ for any cell holding snow or partial rock.
##  10. GROUNDWATER HAS NO HEAT CAPACITY, AND IT IS MOST OF THIS PLANET'S WATER. `rc_of` counts the `water`
##      channel and not the `soil` one, and `soil` is the aquifer — LAMaterialFieldLedger3D sums
##      water + soil + snow + moisture as h2o_total, and on the baseline run `soil_total` is 2935 against a
##      `water_total` of 1311. So more than twice as much of this world's water is thermally invisible as is
##      visible, and a unit of water that infiltrates from the surface into the aquifer deletes its own
##      thermal mass from the planet. This is not a bookkeeping nicety: an aquifer of that size is a real
##      thermal reservoir, it is why groundwater temperature is stable through a diurnal cycle, and it is the
##      medium a hot spring is made of. This gauge was built to find unbooked terms and this is the one it
##      found; see the measurement below.
##  11. `rc_of` ITSELF IS NOT A FUNCTION OF THE MATTER PRESENT, and this is a defect in the capacity model
##      rather than in any one kernel — the same expression stands in all three (heat3d_solar_sphere3d.glsl
##      :167, heat_sphere3d.glsl:126, heat3d_buoyancy_sphere3d.glsl:73). A SOLID cell returns RC_ROCK whole,
##      an open cell returns the volume-fraction mix, and `solid` is `rock_fill >= 0.5`. So one unit of
##      bedrock split 0.4/0.6 across two cells holds 0.4*RC + RC = 3.41e6 J/m³K and split 0.5/0.5 holds
##      2*RC = 4.87e6 — a 43% jump in stored heat for no change of mass, and this planet crosses that
##      threshold constantly (`rock_grows` 5611 / `rock_shrinks` 6056 / `crust_moved` 3926 on the baseline
##      run). `energy_cap_legs` is published so this is readable rather than inferred: it splits the grid's
##      total J/K by carrier, against `energy_cap_legs_first`.
##
## AND `energy_clamped_cells` CANNOT BE FOLDED IN AS A BOOKED LOSS. It was asked for and it does not fit,
## for two independent reasons. (a) It counts the wrong event: LAMaterialFieldEnergyBudget3D:326 tests the
## WHOLE-step |dT| against MAX_DT_PER_STEP, but the kernel SUB-STEPS
## (heat3d_solar_sphere3d.glsl:462, `slices = clamp(ceil(|dT|/5), 1, 8)`) and clamps each SLICE, so that
## predicate fires when sub-stepping ENGAGES — which discards nothing — while the last-resort clamp binds only
## above |dT| ≈ 40 °C. (b) A COUNT is not an energy. Booking the loss needs Σ(dT_wanted − dT_applied)·cap
## summed inside the slice loop, which only the kernel can compute. It reads 0 on the baseline in any case.
##
## ===== SAMPLING — THIS LEDGER TOUCHES NOTHING =============================================================
##
## `temp`, `water` and `snow` are always-hot channels, so their CPU mirrors are refilled at every drain and
## are read directly. `rock_fill` is demand-gated (MaterialSphereGPU3D.SITUATIONAL_CHANNELS) and is taken from
## `request_probe` / `take_probe`, which reads it INSIDE the drain where the device has just been synced, into
## a dictionary no simulation consumer sees. This ledger calls `request_channel` NOWHERE: residency is
## simulation-visible (waking `dust` switches impact winter on), and `buffer_get_data` from the report path
## with a step submit in flight is not a passive read either — it moved `h2o_total` 5062 → 9803 on otherwise
## identical runs. `energy_stock_live` says whether rock_fill arrived, so a stock built on a stale mirror is
## never mistaken for a measurement.
##
## ===== WHAT THE SPLIT CAN AND CANNOT SAY ==================================================================
##
## THE TOTAL (`energy_drift*`) IS EXACT. It is the difference of two stocks, so however coarsely this is
## sampled it measures the whole change over the window.
##
## THE SPLIT IS A DIAGNOSTIC, NOT A SECOND MEASUREMENT, and it is order-ambiguous exactly where a cell's
## composition and its temperature move together. A cell whose water drains away and which then reads the
## air's temperature contributes to `energy_heat_*` at the WET capacity it no longer has — the water carried
## its heat off with it, and a model with ONE temperature per cell has no way to say so. Read the two legs to
## localise, and quote the total for conservation.
##
## ===== MEASURED, and the A/B that proves the gauge is not reading a dead pipeline ==========================
##
## `--sandbox --planet-only --run-frames=600 --fast=8 --seed=4242 --fixed-fps 60`, field_step 590 in both,
## `energy_first_step` 29, `energy_run_steps` 760. Second column is `LA_NO_GEOTHERM=1`:
##
##   energy_stock                1.4344e17 J    1.0020e17 J     the seeded geotherm is 4.32e16 J of the planet
##   energy_stock_first          1.5488e17 J    1.0802e17 J
##   energy_run_drift           -1.1442e16 J   -7.8164e15 J
##   energy_run_drift_per_step  -1.5055e13     -1.0285e13      joules per field step
##   energy_booked              -7.2215e12 J   -4.0067e12 J    solar - longwave + geotherm + sourced injection
##   energy_book_geo_w_m2        **4.055**      **0.000**      the booking leg dies with the mechanism
##   energy_heat_w_m2          -51764         -31.99           a factor of 1618
##   energy_capacity_w_m2     -145182        -134510
##   energy_residual_w_m2     -196821        -134475
##   energy_split_close         -4.66e10 J     +9.88e10 J      4e-6 / 1.3e-5 of the drift: the split closes
##   rock_core_c                 252.7 °C       15.0 °C
##   hotspring_cells / boiling   1021 / 112     0 / 0
##
## **THE RADIATIVE BOOKS EXPLAIN 0.06% OF WHAT MOVES.** -7.22e12 J booked against a -1.14e16 J change.
##
## **AND THE DOMINANT UNBOOKED TERM IS THE AQUIFER FILLING.** `energy_cap_legs` splits the grid's heat
## capacity by carrier and the water leg falls from 5.5171e13 to 1.852e13 J/K — 66.4%, and to three figures
## the SAME in both arms, so it is structural and not geothermal. That is 2146 cell-units of water
## (1.708e10 J/K each) leaving the `water` channel for `soil`, which carries no capacity: 2146 * 4.171e6 *
## 4096 * 288 = 1.06e16 J, which is 93% of the whole drift. Multiplying the measured capacity change by the
## mean temperature reproduces `energy_capacity_w_m2` to 1% in the disarmed arm and 4% in the armed one.
##
## The residual that is left after that is `energy_heat_w_m2`, and it is 1618x larger with the geotherm armed
## — 51764 W/m², against 240 W/m² of longwave. Two unbooked sinks exist only in that arm and this gauge cannot
## separate them: the latent heat of boiling hot springs (heat3d_cool_sphere3d.glsl:128, 112 boiling cells)
## and the aquifer's temperature advection (soil_sphere3d.glsl:515, which warms the receiver toward the donor
## and does not cool the donor). A per-pass step probe on the temp channel — the shape LAMaterialFieldH2OBudget3D
## already uses for water — is what would decide it.
##
## COST: ONE O(cells) pass, on LAMaterialFieldReport3D's HEAVY cadence gate. Two full-grid float arrays are
## carried for the exact ΔU split (552 KB at the shipped 69120 cells). `energy_stock_scan_ms` is what one
## sweep costs — named that rather than `energy_scan_ms`, which the FLUX instrument already publishes and
## which merging over would have silently deleted its cost gauge. Measured 14.19 / 13.98 ms per heavy block
## against its three existing scans (clim 8.27 + energy 18.36 + mass 11.73 + mineral 13.50 = 51.9 ms), so
## +27%, or 1.8 ms amortised over the gate's 8 frames. It cannot appear in `field_ms`, which spans
## begin_frame -> step -> readback (MaterialFieldSphereStep3D.gd:260) and not the report path; three runs here
## read field_ms 4.30 / 4.48 / 5.06 against a 4.6 baseline, which is that spread and not a regression.
## (Explicit types only, no ':=' inferred typing.)

## Samples to discard before latching the run-long BASELINE. The drain probe lands one drain after it is
## armed, so the FIRST sample reads a possibly-stale rock_fill mirror; and the report path can fire before the
## field has stepped at all, which would book world-gen's settling as drift. `energy_first_step` publishes
## where the baseline was actually taken, so this is checkable rather than trusted.
const BASELINE_SKIP_SAMPLES: int = 2

## The one demand-gated channel the capacity mix needs. Read-only, at the drain.
const LEGS: PackedStringArray = ["rock_fill"]

var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample's per-cell capacity and ABSOLUTE temperature, for the exact ΔU = Σrc₀ΔT + ΣΔrc·T₁ split.
var _prev_rc: PackedFloat32Array = PackedFloat32Array()
var _prev_tk: PackedFloat32Array = PackedFloat32Array()
var _prev_stock: float = NAN
var _prev_step: int = -1

# Run-long baseline and the books accumulated against it. Everything here is zeroed at the sample the
# baseline is latched, so the cumulative terms and the stock change span exactly the same window.
var _first_stock: float = NAN
var _first_step: int = -1
var _first_inject_j: float = 0.0
var _first_unsourced_dc: float = 0.0
var _samples: int = 0
var _cum_heat: float = 0.0
var _cum_cap: float = 0.0
var _cum_solar: float = 0.0
var _cum_lw: float = 0.0
var _cum_geo: float = 0.0
# The grid's TOTAL heat capacity at the baseline, split by which substance carries it (J/K). A scalar
# `energy_capacity_*` says the capacity moved and cannot say WHICH RESERVOIR moved, which is the difference
# between "the planet is losing water" and "bedrock is crossing the solidity threshold" — opposite diagnoses.
var _first_cap: Dictionary = {}


func setup(field) -> void:
	_f = field


## The energy books, sampled in one pass. `step_index` is the field's own step counter — drift is reported PER
## FIELD STEP, never per frame. `flux` is LAMaterialFieldEnergyBudget3D's dict from the SAME heavy block, so
## the radiative terms are booked from the module that owns them rather than recomputed here (a second column
## walk that could disagree with the first is how two clocks got into one thermal pass).
func report(step_index: int, flux: Dictionary) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0 or _f._dim_y <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	if solid.size() != cc or temp.size() != cc:
		return out
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	# THE ONE DEMAND-GATED LEG, READ-ONLY. Collect the probe the previous sample armed, then arm the next.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	# LIVENESS IS PROVENANCE, NOT LENGTH. *(Fixed 2026-08-08.)* This read `has_rock = rock_fill.size() == cc`
	# after falling back to the CPU mirror, and the mirror is the same length as the probe — so the flag said
	# "live" in exactly the case it exists to warn about. `rock_fill` is demand-gated
	# (MaterialSphereGPU3D.SITUATIONAL_CHANNELS), so its mirror can be arbitrarily stale, and a stock built on
	# a stale mirror is a number with no provenance. The flag now reports whether the PROBE delivered it.
	var probe_rock: bool = legs.has("rock_fill")
	var rock_fill: PackedFloat32Array = legs.get("rock_fill", _f._rock_fill)
	var water: PackedFloat32Array = _f._water
	var snow: PackedFloat32Array = _f._snow
	var has_rock: bool = probe_rock and rock_fill.size() == cc
	var has_water: bool = water.size() == cc
	var has_snow: bool = snow.size() == cc

	var depth: int = _f._dim_y
	var have_prev: bool = _prev_rc.size() == cc and _prev_tk.size() == cc
	if not have_prev:
		_prev_rc.resize(cc)
		_prev_tk.resize(cc)
	var rc_sum_t: float = 0.0        # Σ rc*T_K, in J per m³ of cell — scaled by the cell volume below
	var d_heat: float = 0.0          # Σ rc₀ΔT
	var d_cap: float = 0.0           # Σ Δrc·T₁
	var shell_solid: int = 0         # solid cells on the r == 0 face — the geotherm's own population
	# The grid's heat capacity by carrier, so a change in the capacity term names its own substance.
	var cap_rock: float = 0.0
	var cap_water: float = 0.0
	var cap_snow: float = 0.0
	var cap_air: float = 0.0
	var rc_air: float = LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
	var rc_rock: float = LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
	var rc_water: float = LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
	var rc_snow: float = LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K
	for c in cc:
		# heat3d_solar_sphere3d.glsl:167-176 rc_of_cell(), transcribed. Fractions of the CELL VOLUME, air
		# filling whatever is left; a solid cell is rock outright.
		var rc: float = rc_rock
		if solid[c] == 0:
			var f_rock: float = clampf(rock_fill[c], 0.0, 1.0) if has_rock else 0.0
			var f_water: float = clampf(water[c], 0.0, 1.0) if has_water else 0.0
			var f_snow: float = clampf(snow[c], 0.0, 1.0) if has_snow else 0.0
			var f_air: float = maxf(0.0, 1.0 - f_rock - f_water - f_snow)
			rc = rc_air * f_air + rc_rock * f_rock + rc_water * f_water + rc_snow * f_snow
			cap_rock += rc_rock * f_rock
			cap_water += rc_water * f_water
			cap_snow += rc_snow * f_snow
			cap_air += rc_air * f_air
		else:
			# A SOLID CELL IS SCORED AS WHOLE ROCK, not by its fraction — that is `rc_of`'s own rule and it is
			# transcribed rather than corrected here. It means the planet's total heat capacity is not a
			# function of the matter present: the same bedrock mass spread as 0.4/0.6 across two cells holds
			# 3.41e6 J/m³K and as 0.5/0.5 holds 4.87e6, a 43% jump for no change of mass. See the header.
			cap_rock += rc_rock
			if c % depth == 0:
				shell_solid += 1
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		rc_sum_t += rc * tk
		if have_prev:
			d_heat += _prev_rc[c] * (tk - _prev_tk[c])
			d_cap += (rc - _prev_rc[c]) * tk
		_prev_rc[c] = rc
		_prev_tk[c] = tk

	var volume: float = cell_size * cell_size * cell_size
	var stock: float = rc_sum_t * volume
	var d_heat_j: float = d_heat * volume
	var d_cap_j: float = d_cap * volume
	var cap_legs: Dictionary = {
		"rock": snappedf(cap_rock * volume, 1.0), "water": snappedf(cap_water * volume, 1.0),
		"snow": snappedf(cap_snow * volume, 1.0), "air": snappedf(cap_air * volume, 1.0),
	}
	out["energy_stock"] = stock
	out["energy_stock_cells"] = cc
	out["energy_stock_live"] = {"rock_fill": has_rock, "water": has_water, "snow": has_snow}
	# The grid's total heat capacity, in J/K, and which substance holds it. `energy_capacity_w_m2` is the RATE
	# this moves at; these say what moved.
	out["energy_cap_j_k"] = (cap_rock + cap_water + cap_snow + cap_air) * volume
	out["energy_cap_legs"] = cap_legs

	# THE BOOKED RATES, in watts. `energy_absorbed` / `energy_emitted` are sums of per-cell fluxes in W/m², so
	# each cell's own face area (cell_size²) turns the sum into watts. The geotherm's scalar flux covers the
	# SOLID r == 0 face only (see the header).
	var face: float = cell_size * cell_size
	var solar_w: float = float(flux.get("energy_absorbed", 0.0)) * face
	var lw_w: float = float(flux.get("energy_emitted", 0.0)) * face
	var geo_flux: float = 0.0
	if _f._geotherm != null:
		geo_flux = float(_f._geotherm.report().get("core_flux_w_m2", 0.0))
	var geo_w: float = geo_flux * face * float(shell_solid)
	var inject_j: float = 0.0
	var unsourced_dc: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inject_j = float(_f._inject.queue.heat_energy_j)
		unsourced_dc = float(_f._inject.queue.heat_unsourced_dc)

	# PER-SAMPLE DRIFT, per FIELD STEP.
	var steps: int = step_index - _prev_step
	var dt_real: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	if steps > 0 and _prev_step >= 0 and not is_nan(_prev_stock):
		out["energy_drift"] = stock - _prev_stock
		out["energy_drift_per_step"] = (stock - _prev_stock) / float(steps)
		out["energy_drift_steps"] = steps
	if steps > 0 or _prev_step < 0:
		_prev_stock = stock
		_prev_step = step_index

	# RUN-LONG BOOKS. The baseline zeroes every cumulative term, so the stock change and the booked terms span
	# exactly the same window; accumulation starts at the sample AFTER the latch.
	_samples += 1
	var latched: bool = false
	if _first_step < 0 and _samples > BASELINE_SKIP_SAMPLES and have_prev:
		_first_stock = stock
		_first_step = step_index
		_first_inject_j = inject_j
		_first_unsourced_dc = unsourced_dc
		_cum_heat = 0.0
		_cum_cap = 0.0
		_cum_solar = 0.0
		_cum_lw = 0.0
		_cum_geo = 0.0
		_first_cap = cap_legs
		latched = true
	if _first_step >= 0 and not latched and steps > 0:
		# Rectangle rule over the window, at the flux sampled at its right-hand end — the same approximation
		# LAMaterialFieldEnergyBudget3D's own running totals make, integrated against the REAL seconds the
		# kernel applies (`dt_s`), not the simulated ones.
		var window_s: float = dt_real * float(steps)
		_cum_heat += d_heat_j
		_cum_cap += d_cap_j
		_cum_solar += solar_w * window_s
		_cum_lw += lw_w * window_s
		_cum_geo += geo_w * window_s
	var run_steps: int = step_index - _first_step if _first_step >= 0 else 0
	out["energy_run_steps"] = run_steps
	out["energy_stock_samples"] = _samples
	out["energy_first_step"] = _first_step
	out["energy_stock_first"] = _first_stock if not is_nan(_first_stock) else 0.0
	out["energy_cap_legs_first"] = _first_cap
	if run_steps <= 0 or is_nan(_first_stock):
		out["energy_stock_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var run_drift: float = stock - _first_stock
	var cum_inject: float = inject_j - _first_inject_j
	var booked: float = _cum_solar - _cum_lw + _cum_geo + cum_inject
	out["energy_run_drift"] = run_drift
	out["energy_run_drift_per_step"] = run_drift / float(run_steps)
	out["energy_booked"] = booked
	out["energy_residual"] = run_drift - booked
	# THE DECOMPOSITION'S OWN CHECK. Σrc₀ΔT + ΣΔrc·T₁ is the stock change identically, so this is ~0 or the
	# split is wrong — the one number here that is allowed to be a tautology, because it is testing arithmetic
	# rather than physics.
	out["energy_split_close"] = (_cum_heat + _cum_cap) - run_drift

	# THE SAME BOOKS AS A SURFACE FLUX — the shape everything else in this report is quoted in, so the
	# residual can be read straight against `energy_absorbed_cool_mean` (112.3) and `energy_emitted_cool_mean`
	# (262.3) and against the ~140 W/m² this planet gains from terms nothing books. The denominator is the
	# radiating cell set the flux instrument itself counts, times one cell face, so `energy_book_solar_w_m2`
	# is `energy_absorbed_mean` by construction and the legs stay on one footing.
	var ref_cells: int = int(flux.get("energy_cells", 0))
	var area: float = float(ref_cells) * face
	out["energy_ref_area_m2"] = area
	if area > 0.0:
		var run_s: float = dt_real * float(run_steps)
		if run_s > 0.0:
			var inv: float = 1.0 / (area * run_s)
			out["energy_drift_w_m2"] = run_drift * inv
			out["energy_heat_w_m2"] = _cum_heat * inv
			out["energy_capacity_w_m2"] = _cum_cap * inv
			out["energy_booked_w_m2"] = booked * inv
			out["energy_residual_w_m2"] = (run_drift - booked) * inv
			out["energy_book_solar_w_m2"] = _cum_solar * inv
			out["energy_book_lw_w_m2"] = _cum_lw * inv
			out["energy_book_geo_w_m2"] = _cum_geo * inv
			out["energy_book_inject_w_m2"] = cum_inject * inv
	# The one injection form that names no store it came out of. Degrees x cells, unconverted — see the
	# header's unbooked list, item 7.
	out["energy_unsourced_dc"] = unsourced_dc - _first_unsourced_dc
	out["energy_geo_shell_cells"] = shell_solid
	out["energy_stock_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


func _blank() -> Dictionary:
	return {
		"energy_stock": 0.0, "energy_stock_first": 0.0, "energy_stock_cells": 0,
		"energy_drift": 0.0, "energy_drift_per_step": 0.0, "energy_drift_steps": 0,
		"energy_run_drift": 0.0, "energy_run_drift_per_step": 0.0, "energy_run_steps": 0,
		"energy_booked": 0.0, "energy_residual": 0.0, "energy_split_close": 0.0,
		"energy_drift_w_m2": 0.0, "energy_heat_w_m2": 0.0, "energy_capacity_w_m2": 0.0,
		"energy_booked_w_m2": 0.0, "energy_residual_w_m2": 0.0,
		"energy_book_solar_w_m2": 0.0, "energy_book_lw_w_m2": 0.0,
		"energy_book_geo_w_m2": 0.0, "energy_book_inject_w_m2": 0.0,
		"energy_unsourced_dc": 0.0, "energy_geo_shell_cells": 0, "energy_ref_area_m2": 0.0,
		"energy_stock_samples": 0, "energy_first_step": -1,
		"energy_cap_j_k": 0.0, "energy_cap_legs": {}, "energy_cap_legs_first": {},
		"energy_stock_scan_ms": 0.0, "energy_stock_live": {},
	}
