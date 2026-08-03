class_name LAGeoRecords
extends LAReactionDefs

## GEOLOGICAL mineral records (M4 dust loft, M3 susp settle, D1 weathering, D2 lithification).

# --- MINERAL phase transfers (rock unification Stage A) — same-cell, conserving, own-cell writes only -------
# LOFT (M4, replaces dust_loft_sphere3d.glsl): wind over LOFT_WIND scours dry loose SEDIMENT into the SAME
# cell's airborne DUST (the box/sphere loft kernel scattered into the cell ABOVE — a cross-cell write that
# forbade a DEFS record; re-aiming to own-cell makes it a clean record and dust_transport lofts it up next
# step, design-blessed as near-identical). Constants copied from dust_loft_sphere3d.glsl. The reactant cap on
# SEDIMENT enforces "can't loft more than present"; the LOFT_MAX per-step cap is dropped (perf-over-parity —
# it only bit at hspeed>~22, and sediment-capped extent stays bounded regardless).
const LOFT_WIND: float = 6.0             # horizontal wind speed a dry surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per unit wind OVER the threshold
# SETTLE (M3, susp→sediment): turbid water drops its load when calm. CONST_FRAC.
# (Corrected 2026-07-29: this said "susp is a DEAD phase today (no erosion source on the sphere populates it),
# so this record is a NO-OP". It is LIVE. ErosionPickupPass is registered at MaterialSphereGPU3D.gd:51,
# immediately before ReactionsPass so this record reads the freshly-scoured susp in the same step. The same
# false claim, that the erosion pickup kernel did not exist, sat in HANDOFF.md for weeks and sent work at a
# problem that was already solved.)
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles out when calm

# --- WEATHERING (Stage D, rock_fill→sediment): frost/thermal breakdown of exposed bedrock into the transportable
# loose pool. Runs in OPEN surface cells (GATE_SURFACE), where rock_fill is the partial boundary bedrock. Colder
# exposed rock breaks faster (freeze–thaw shattering), so it is DEFICIT_BELOW_THRESHOLD on TEMP: x = max(0,
# WEATHER_TEMP - temp) * WEATHER_RATE, capped by the ROCK_FILL present → a conserving rock_fill→sediment transfer.
# This gives slopes a water-INDEPENDENT talus source (weathered rock → slump → downhill) that composes with the
# river-scour pickup. WEATHER_TEMP sits at the top of this world's open-cell range (~11–21 °C) so all exposed rock
# weathers, fastest at the cold poles/night — the emergent latitudinal weathering gradient, no per-case code.
const WEATHER_TEMP: float = 20.0
const WEATHER_RATE: float = 0.004        # per-step k on x = max(0, WEATHER_TEMP - temp) * k (capped by rock_fill)
# --- LITHIFICATION (Stage D, sediment→rock_fill): deep/old sediment compacts back into bedrock. EXCESS_OVER_
# THRESHOLD on SEDIMENT: x = max(0, sediment - LITH_DEPTH) * LITH_RATE, capped by the SEDIMENT present → a
# conserving sediment→rock_fill transfer. Only the EXCESS above a deep threshold lithifies, so thin dustings stay
# loose and only genuine basins/deltas turn to stone — rock_fill crossing 0.5 there makes MineralStamp3D grow NEW
# land (a delta prograding into rock, a sediment plain becoming a coastal shelf). Closes the cycle: rock→susp→
# sediment→rock, so mineral_total is conserved end-to-end and the planet gains a real depositional history.
const LITH_DEPTH: float = 0.5            # sediment mass above which the EXCESS compacts to bedrock (deep deposits only)
const LITH_RATE: float = 0.02            # per-step k on x = max(0, sediment - LITH_DEPTH) * k (capped by sediment)


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		# M4 — DUST LOFT (loose → airborne): wind over LOFT_WIND scours dry loose SEDIMENT into the OWN cell's
		# airborne DUST. EXCESS_OVER_THRESHOLD on WINDSPEED (sqrt(vel_x²+vel_z²), the derived driver), gated
		# GATE_DRY (water<=WET_MAX_LOFT) + GATE_NOT_RAINING. Reactant cap on SEDIMENT. REPLACES + DELETES
		# dust_loft_sphere3d.glsl (the cross-cell scatter into the cell above → re-aimed own-cell; transport
		# lofts it up next step). A conserving sediment→dust transfer of the ONE mineral substance.
		rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY | GATE_NOT_RAINING, LOFT_WIND),

		# M3 — SUSP SETTLE (suspended → loose): calm turbid water drops its load. CONST_FRAC on SUSP →
		# SEDIMENT (own-cell, conserving). This record is LIVE: ErosionPickupPass (MaterialSphereGPU3D.gd:51)
		# scours rock_fill into susp immediately before ReactionsPass, so the settle reads the same step's
		# suspension and closes rock→susp→sediment→rock.
		# (Corrected 2026-07-29: said "susp is a DEAD phase until Stage D erosion populates it, so this is an
		# inert forward-looking record today". Stage D landed; the comment did not.)
		rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		# D1 — WEATHERING (bedrock → loose): exposed surface rock_fill breaks down into transportable SEDIMENT,
		# fastest where cold (freeze–thaw). DEFICIT_BELOW_THRESHOLD on TEMP: x = max(0, WEATHER_TEMP - temp) *
		# WEATHER_RATE, capped by ROCK_FILL → conserving rock_fill→sediment transfer. GATE_SURFACE = sky-exposed
		# bedrock only. Feeds the loose pool the slump CA then spreads downhill — a water-independent talus source.
		rec(DEFICIT_BELOW_THRESHOLD, WEATHER_RATE, TEMP, [[ROCK_FILL, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]],
			GATE_SURFACE, WEATHER_TEMP),

		# D2 — LITHIFICATION (loose → bedrock): deep/old SEDIMENT compacts back into ROCK_FILL under its own
		# accumulated weight. EXCESS_OVER_THRESHOLD on SEDIMENT: x = max(0, sediment - LITH_DEPTH) * LITH_RATE,
		# capped by SEDIMENT → conserving sediment→rock_fill transfer. Only deep deposits (deltas/basins) turn to
		# stone; the accreted rock_fill crossing 0.5 makes MineralStamp3D grow NEW land. Closes rock→susp→
		# sediment→rock, so mineral_total conserves and deposition builds a real geological history.
		rec(EXCESS_OVER_THRESHOLD, LITH_RATE, SEDIMENT, [[SEDIMENT, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			0, LITH_DEPTH),
	]
