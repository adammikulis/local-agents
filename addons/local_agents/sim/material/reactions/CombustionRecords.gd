class_name LACombustionRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## COMBUSTION — the one record (R26) that replaces fire_sphere3d.glsl and its state machine.
##
## ===== A SOLID FUEL HAS NO IGNITION POINT ===================================================================
##
## Water has a freezing point. Wood does not have an ignition point. It PYROLYSES: heat drives combustible
## volatiles out of the solid at a rate that rises exponentially with temperature, and "ignition" is the name
## for the moment that release outruns the losses. The threshold every handbook quotes — 300 C piloted,
## 400-500 C unpiloted — is an artefact of the apparatus it was measured in, and it moves with moisture
## content, particle size, oxygen concentration and exposure time. One constant cannot carry any of that.
##
## What IS a property of the material is the ACTIVATION ENERGY, and it is in the substance table as
## `cellulose.pyrolysis_ea_over_r_k` (230 kJ/mol over R; Antal & Varhegyi 1995, the mid of a measured
## 200-250 kJ/mol). So combustion is an ARRHENIUS record, and everything the old kernel spelled out falls
## out of the exponential instead:
##   * IGNITION is a runaway, not a branch. At 27 C the rate is 1e-21 of its reference and nothing happens;
##     at 227 C it smoulders; at 427 C it consumes everything available in one step. No IGNITE_TEMP anywhere.
##   * SPREAD is the heat, and nothing else. A burning cell releases its enthalpy into `temp`; conduction,
##     radiation and buoyancy carry it to the neighbours; their rate rises. The old EMBER_HEAT / EMBER_UP /
##     EMBER_WIND_GAIN / EMBER_MAX gather is gone and is not replaced.
##   * A DAMP FUEL RESISTS LIGHTING because the water is in the cell's heat capacity (reactions_sphere3d's
##     rc_of), so the same reaction warms it a hundredfold less. There is no WET_MAX gate.
##   * EXTINCTION when the fuel runs out needs no FIRE_MIN: the rate is first order in the fuel.
##
## ===== AND IT IS UNDER THE CONSERVATION GATE, WHICH THE KERNEL COULD NOT BE ================================
##
## `scripts/check_reaction_balance.sh` validates LAReactionDefs records. Combustion was a standalone kernel
## that no record described, so no gate could see it, and it showed: for as long as it shipped it DESTROYED
## the hydrogen, the oxygen and the nitrogen of everything it burned (only the carbon arrived), and when the
## water leg was finally added by hand it was wrong by 6484x because a gas channel unit is not a water
## channel unit. Both were found by a person reading the file. As a record neither is writable.
##
## ===== THE REACTION IS R15's, RUN HOT =======================================================================
##
##     CH2O + O2 -> CO2 + H2O + N
##
## Rotting and burning oxidise the same carbon out of the same matter, so this is literally the reaction
## LABioRecords R15 already runs for decomposition — same reactants, same products, a different rate law. The
## coefficients are not chosen here either: every cross-substance one is `unit_ratio(a, FUEL)`, so the record
## reads as the 1:1:1:1 stoichiometry a chemist writes and the conversion cannot be mistyped.
##
## THE NITROGEN IS A LUMPED APPROXIMATION and the old kernel's account of it stands: a real wildfire
## VOLATILISES most fuel nitrogen (to N2, NO/NO2, NH3) and leaves the rest as mineral N in the ash. This
## substrate has no NOx or N2 channel and `fert` is its only plant-available mineral nitrogen, so all of the
## fuel's N is credited there. That gets the conservation and the post-fire flush of growth right, and
## OVERSTATES post-fire soil nitrogen while understating the atmospheric loss. The alternative available today
## was to keep deleting it, which is not an approximation.
##
## THE WATER IS VAPOUR. Combustion water leaves a flame far above its boiling point, so it is credited to
## `moisture` (the air's suspended H2O) and not to `water` (liquid standing in the cell). It costs no extra
## latent heat: HEAT_PER_KG_OXYGEN_J is measured on the NET heat of combustion, which already counts the
## product water as vapour, so charging a latent heat here would subtract the same energy twice. Once that
## vapour drifts into cold air the atmosphere pass condenses it like any other water in the sky.
##
## ===== WHAT THIS RECORD DOES NOT MODEL ======================================================================
##
## Stated so the omissions are not read as claims:
##   * NO SMOKE, NO CHAR, NO ASH MINERAL. Everything oxidises completely to CO2 and H2O in one step. Real
##     flaming combustion leaves char that smoulders for far longer, and soot that darkens the sky.
##   * THE OXYGEN ORDER IS A LUMP. Pyrolysis itself does not involve oxygen; the volatiles it releases then
##     burn, fast, in the gas phase. Writing the overall rate as first order in BOTH the solid and the oxygen
##     says "at ambient oxygen the rate is the pyrolysis rate, and half the oxygen halves it", which is the
##     right limit at both ends and an interpolation in between.
##   * NO BUOYANT PLUME. A real flame entrains fresh air AND loses its hot products upward, which is most of
##     why a measured wildfire (1100-1500 K) sits far below its adiabatic flame temperature. Here a cell
##     entrains (GasWind refills its oxygen) and cannot exhaust, so a fuelled cell can ratchet hotter than a
##     real fire. That is thermal transport, not combustion stoichiometry, and it is where to look if flame
##     temperatures come out high.
##
## ===== MEASURED, 2026-08-09 =================================================================================
##
## NOTHING IGNITES, AND THAT IS THE EXPECTED RESULT rather than evidence against the record. Six 600-frame runs
## at seed 4242, --fast=8, field_step 590: three --planet-only and one each of --no-fauna, --no-fauna
## --auto-lightning and --no-fauna --auto-volcano. Every one reports `fires` 0 / `fire_cells` 0 /
## `fire_peak` 0.0, and `fuel_total` 151.2-152.0 against a `fuel_seeded` of 216 in all of them — the shortfall
## is BURIAL under growing terrain, not burning. The hottest open cell any arm reached was 360 C, where the
## rate law consumes about a hundred-thousandth of a cell's fuel per step; nothing on this planet is hot enough
## for long enough beside fuel. `--auto-volcano` drew `lava_cells` 0, so that arm never had an ignition source
## at all. The reason no heat ever reaches fuel is upstream and unrelated: `MaterialField3D.ignite()` and
## `EcologyService.ignite_area()` are both deliberate no-ops.
##
## THE PLANET IS UNMOVED, which is the other half of the claim. Three --planet-only runs against the parent
## commit's one: temp_ground_p50 26.34 / 26.24 / 26.15 (26.30), temp_mean 34.97 / 34.94 / 34.90 (~35),
## energy_imbalance_cool -1.286 / -1.284 / -1.283 (-1.3), h2o_total 4330 / 4317 / 4282 (4287), soil_total
## 2833 / 2839 / 2822 (2809), snow_cells 1153 / 1158 / 1161 (1145), element_C 1.091e7 / 1.091e7 / 1.090e7
## (1.09e7), energy_run_drift_per_step -1.496e13 / -1.505e13 / -1.504e13 (-1.51e13).
##
## AND THE RECORD DEMONSTRABLY RUNS ON THE GPU, which those two paragraphs cannot show on their own — a record
## that never executes produces the same numbers. Negative control: PYROLYSIS_K_PER_S raised by 1e18 (nothing
## else changed, then reverted byte-identical). Matched --planet-only runs at 120 frames: `fuel_total`
## 215.64 -> 215.43 and `temp_max` 108.5 -> 237.9 C; at 200 frames with --no-fauna, `fuel_total` 205.0 against
## ~215.6. Combustion is the only sink `fuel` has anywhere in the tree and this record is the only thing that
## writes the reaction engine's enthalpy, so both the FUEL `add_ch` branch and the enthalpy term execute.
##
## WHAT STILL CANNOT BE READ, and it is not this record's to fix: `fire_cells` / `fire_peak` / `is_burning`
## read a CPU mirror that is DEMAND-GATED (LAMaterialSphereGPU3D.SITUATIONAL_CHANNELS). The only caller of
## `request_channel("fire")` is `MaterialFieldInject3D.add_heat`, and the ignition paths never reach it because
## `ignite()` / `ignite_area()` are no-ops — so the gauge answers 0 whether or not anything is alight. That
## chain was true of the deleted kernel too; LAMaterialFieldQueries3D's own docstring states it.

# --- THE RATE CONSTANT ---------------------------------------------------------------------------------------
# ARRHENIUS needs the activation energy (a measured property of cellulose, LAPhysical) and ONE rate constant
# with the temperature it is quoted at. Both of those are here, and the pair is checkable rather than fitted.
#
# 600 K IS A CHOICE OF PRESENTATION, NOT OF PHYSICS. `exp(-(Ea/R)(1/T - 1/T_ref))` is 1 at the reference, so
# moving T_ref only moves `rate_k` by the same factor and the LAW is identical. It is quoted at 600 K rather
# than at the 298 K the weathering record uses because it keeps the exponent small at both ends: at 298 K the
# prefactor would be 6e-22 per step and the exponential would reach 1e38 in a lava-adjacent cell, which is the
# edge of what a float32 holds. At 600 K nothing in the expression leaves 1e-21 .. 1e18 anywhere on this
# planet, including inside a meteor impact.
const PYROLYSIS_REF_TEMP_K: float = 600.0

# The first-order rate constant of cellulose pyrolysis at that temperature: 2.5e-3 per second, a half-life of
# 4.6 minutes at 327 C. That is what thermogravimetry measures through the main decomposition peak, which sits
# at 320-350 C on a slow ramp.
#
# IT IS CONSISTENT WITH THE ACTIVATION ENERGY RATHER THAN INDEPENDENT OF IT, and that is the check worth
# writing down: an Arrhenius pair is correlated (the kinetic compensation effect), so a rate constant quoted
# with the wrong prefactor is not a measurement of anything. Back out the prefactor this pair implies —
#     A = k(T_ref) * exp(Ea / (R T_ref)) = 2.5e-3 * exp(230000 / (8.3145 * 600)) = 2.6e17 per second
# — and log10 A = 17.4, inside the 17-18 that cellulose primary pyrolysis is measured at. If the activation
# energy in LAPhysical ever moves, this number must move with it or the pair stops describing cellulose.
const PYROLYSIS_K_PER_S: float = 2.5e-3

# --- THE OXYGEN A FLAME NEEDS --------------------------------------------------------------------------------
# A measured property of the fuel and the oxidiser, not a difficulty setting: below the LIMITING OXYGEN
# CONCENTRATION a flame goes out however hot it is, which is why a fire in a sealed room self-extinguishes
# with most of the oxygen still in it, and why an anoxic planet cannot burn. It is a QUENCH and not a reactant
# cap for exactly that reason — the cap says an extent cannot outrun its supply, this says the flame dies
# before the supply is gone, so the oxygen below this level is oxygen no fire in this substrate can reach.
#
# The measured value is a MOLE FRACTION (LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC = 0.15); the `o2`
# channel is denominated in modern ambient air, so it is divided by air's own mole fraction to become a
# channel value. 0.15 / 0.20946 = 0.716.
#
# IT IS ALSO THE LEG THAT SETS THE FLAME TEMPERATURE. One charge of ambient air holds enough oxygen to raise a
# dry cell 3016 K if it can all burn (the constant-cp adiabatic stoichiometric rise, itself ~35 % above a real
# wood/air flame because cp climbs with temperature and the products dissociate). With the quench, only
# (1 - 0.716) of it can, so a charge delivers 857 K — which lands a flame at a real wildfire's temperature
# instead of at twice it. The kernel this replaces reached the same arithmetic and shipped 0.35, half the
# measured threshold, with its own comment saying so.
const OXYGEN_QUENCH: float = LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC / LAPhysical.AIR_MOLE_FRAC_O2


## Per-step extent per unit of (fuel x oxygen) at the reference temperature. Derived from the substrate's own
## clock, so it tracks a changed day length instead of going stale — the pattern LAPhaseRecords._evap_k uses.
static func _rate_k() -> float:
	return PYROLYSIS_K_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step()


## Heat released per unit of extent, in joules per cubic metre of cell — the record's `enthalpy_j_m3`.
##
## ANCHORED ON THE OXYGEN, which is deliberate and is what makes it measurable here. Huggett (1980) measured
## that burning almost any organic fuel releases 13.1 MJ per KILOGRAM OF OXYGEN CONSUMED, within about 5 %
## across wood, cellulose, plastics and hydrocarbons, because the energy comes out of the O=O bond rather than
## the fuel's. So the heat is (the oxygen THIS RECORD's own stoichiometry consumes) x (that figure), and the
## coefficient doing the work is the same one the balance gate checks. Nothing is typed and nothing is fitted.
##
## `o2_per_fuel` is in channel units; LAPhysical.AMBIENT_O2_DENSITY_KG_M3 is what one of those units weighs.
static func _enthalpy_j_m3(o2_per_fuel: float) -> float:
	return o2_per_fuel * LAPhysical.AMBIENT_O2_DENSITY_KG_M3 * LAPhysical.HEAT_PER_KG_OXYGEN_J


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	# Denominated in FUEL, because that is what the rate is expressed in. Every cross-substance coefficient is
	# `unit_ratio(slot, FUEL)` — how many units of `slot` hold the moles one unit of fuel holds — so the record
	# reads as the mole-for-mole reaction it is. A unit of fuel is a cell full of dry wood (16652 mol/m3) and a
	# unit of o2 is the oxygen in a cell of ambient air (8.535 mol/m3), so `o2_per_fuel` comes out near 1951:
	# burning a whole cell of solid wood would take two thousand cells' worth of air, which is why in practice
	# the extent is always oxygen-limited and a fire is a slow siege on its own atmosphere.
	var o2_per_fuel: float = LAReactionBalance.unit_ratio(O2, FUEL)
	var co2_per_fuel: float = LAReactionBalance.unit_ratio(CO2, FUEL)
	var w_per_fuel: float = LAReactionBalance.unit_ratio(MOISTURE, FUEL)
	var fert_per_fuel: float = LAReactionBalance.unit_ratio(FERT, FUEL)
	# Nitrogen per mole of CH2O, read off the composition table rather than restated, so this record cannot
	# disagree with the gate about what litter is made of. It is MOLAR: LITTER_C_TO_N is a ratio of MASSES, and
	# spending it directly as a mole count is a 16 % overstatement the old kernel had to be corrected for.
	var organic_n: float = float(LAReactionBalance.composition()[FUEL]["N"])
	return [
		# R26 — COMBUSTION: fuel + O2 -> CO2 + water vapour + mineral nitrogen, plus the reaction's own heat.
		# ARRHENIUS on cellulose's pyrolysis activation energy, first order in the FUEL (the driver) and in the
		# O2 (driver2), quenched below the limiting oxygen concentration, with NO temperature ceiling — a solid
		# fuel has no solvent whose boiling ends the reaction.
		#
		# GATE_NOT_STATIC only. The sea/lake reservoir is an unsimulated abstraction and per-cell chemistry
		# there is meaningless; everywhere else combustion is allowed to evaluate, and the exponential decides.
		# In particular there is no near-ground gate: a canopy or a lofted ember burns if it is hot and has
		# fuel and oxygen, which is what the physics says and not something this record has an opinion about.
		rec(ARRHENIUS, _rate_k(), FUEL,
			[[FUEL, 1.0], [O2, o2_per_fuel]],
			[[CO2, co2_per_fuel, TGT_SELF],
				[MOISTURE, w_per_fuel, TGT_SELF],
				[FERT, organic_n * fert_per_fuel, TGT_SELF]],
			GATE_NOT_STATIC, LAPhysical.CELLULOSE_PYROLYSIS_EA_OVER_R_K, O2, PYROLYSIS_REF_TEMP_K,
			-1, 0.0, 0.0, _enthalpy_j_m3(o2_per_fuel), O2, OXYGEN_QUENCH),
	]
