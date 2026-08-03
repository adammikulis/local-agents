class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## PHASE-CHANGE records — one substance, phase from temperature (R21 freeze, R22 melt,
## M5 lava solidify, M6 rock melt).

# --- H₂O PHASE CHANGE (freeze / melt) — one conserved substance, phase from temperature (Phase 2c) --------
# Liquid WATER, atmospheric MOISTURE and frozen SNOW are the SAME H₂O; only the PHASE differs, and the phase
# is emergent from a cell's TEMPERATURE. Freeze/melt are pure mass-conserving TRANSFERS: debit one phase by x,
# credit the other by x (coeff 1:1), so H₂O total = water + moisture + snow is conserved by every transition.
# WATER'S PHASE BOUNDARY. Ice and liquid water coexist at exactly ONE temperature, and it is 0 °C, so freeze
# and melt are the SAME number. Must match snowice_sphere3d.glsl (the sat(T)-aware kernel that freezes the
# CONDENSED atmospheric water — the primary snow source); scripts/check_physical_constants.sh gates that.
#
# THE COMMENT THAT WAS HERE IS DELETED, and what it SAID matters more than what it set: "TUNED to the sim's
# ACTUAL open-cell temperature range (~11–21 °C …) so freezing happens in the coldest ~1–2 °C cap instead of
# NEVER. A literal 0 °C freeze can never fire here … raise these with the real climate range." The planet
# could not get cold, so a previous pass moved THE FREEZING POINT OF WATER up to meet it — 12.5 here, 12.5 in
# snowice, 13.0 in charge_accum and activity, melt at 14.0. Every measurement taken against that was
# meaningless, and it left the deep ocean at 10 °C, below its own freezing point, not freezing. The comment
# OUTLIVED the value being corrected and still told the next reader to raise it again, so it goes entirely.
#
# The 1.5 °C freeze/melt hysteresis went with it. It existed to stop the snow line flickering — a NUMERICAL
# concern, which does not license separating a phase boundary that is not separated in nature. If flicker
# returns, damp FREEZE_RATE / MELT_RATE or hold a cell's state across a few steps; do not re-split these.
const FREEZE_TEMP: float = LAPhysical.WATER_FREEZE_C   # 0.0 °C — liquid WATER (and condensed MOISTURE) → SNOW
const MELT_TEMP: float = LAPhysical.WATER_MELT_C       # 0.0 °C — SNOW → liquid WATER. The same boundary.
const FREEZE_RATE: float = 0.05          # per-step k on the below-threshold liquid-freeze extent
const MELT_RATE: float = 0.05            # per-step k on the above-threshold snow-melt extent

# --- BEDROCK phase transfers (rock unification Stage B) — molten LAVA <-> fractional bedrock ROCK_FILL ------------
# ONE conserved mineral: solidify and melt are own-cell, mass-conserving transfers between the molten and bedrock
# phases (reactant-capped debit + equal credit → conserving by construction). `solid` is DERIVED (rock_fill>=0.5),
# so as lava solidifies the accreted rock_fill crosses 0.5 and the cell becomes bedrock (terrain grows); as rock
# melts it crosses back and the cell opens. The 0.5 crossing is what Stage C will stamp into the SDF mesh.
# M5 SOLIDIFY (molten -> bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. REPLACES the direct
# `solid=1; lava=0` write dissolved out of lava_phase_sphere3d.glsl (which fabricated an invisible GPU-only solid
# cell and LOST the lava mass — non-conserving); now it is a conserving lava->rock_fill transfer. lava_phase keeps
# only its SUSTAIN leg and no longer re-heats a sub-solidus cell, so this record sees the genuine post-thermal cold.
const SOLIDIFY_TEMP: float = 800.0       # lava below this (°C) has cooled through the solidus → freezes to bedrock
const SOLIDIFY_RATE: float = 0.02        # per-step k on x = max(0, SOLIDIFY_TEMP - temp) * k (capped by lava)
# M6 MELT (bedrock -> molten): rock hotter than ROCK_MELT_TEMP melts to lava. Reactions run in OPEN cells only
# (the engine skips solid cells for race-freedom), so this record melts the BOUNDARY rock — a hot open cell that
# still carries partial rock_fill (0 < rock_fill < 0.5), e.g. at a lava/bedrock interface. FULL bedrock melt of a
# deep magma-core cell (which is solid, hence skipped) stays a special case: it is driven instead by the real
# add_lava injection (converting bedrock->lava at the vent) and, later, the Stage-C hot-bore. Conserving either way.
const ROCK_MELT_TEMP: float = 1200.0     # open-cell rock hotter than this (°C, above the lava emplace temp) melts
const ROCK_MELT_RATE: float = 0.02       # per-step k on x = max(0, temp - ROCK_MELT_TEMP) * k (capped by rock_fill)


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		# R21 — FREEZE (liquid → snow): standing/melt WATER at a cell colder than FREEZE_TEMP crystallizes to
		# SNOW. DEFICIT_BELOW_THRESHOLD: x = max(0, FREEZE_TEMP - temp) * FREEZE_RATE, capped by the WATER present
		# → a pure conserving transfer (water -= x; snow += x). The PRIMARY snowfall path (freezing the CONDENSED
		# atmospheric water at cold ground, which needs sat(T)) is the snowice deposition kernel; this record is
		# the liquid leg — it refreezes meltwater/puddles/rivers so the H₂O phase tracks temperature everywhere,
		# not only in the air. It is also the exemplar of the new below-threshold rate model.
		rec(DEFICIT_BELOW_THRESHOLD, FREEZE_RATE, TEMP, [[WATER, 1.0]], [[SNOW, 1.0, TGT_SELF]], 0, FREEZE_TEMP),

		# R22 — MELT (snow → water): SNOW at a cell warmer than MELT_TEMP thaws to liquid WATER (meltwater the
		# water CA then routes downhill on the next step). EXCESS_OVER_THRESHOLD: x = max(0, temp - MELT_TEMP) *
		# MELT_RATE, capped by the SNOW present → conserving transfer (snow -= x; water += x). REPLACES the melt
		# branch of snowice_sphere3d.glsl (which is now deposition-only).
		rec(EXCESS_OVER_THRESHOLD, MELT_RATE, TEMP, [[SNOW, 1.0]], [[WATER, 1.0, TGT_SELF]], 0, MELT_TEMP),

		# M5 — LAVA SOLIDIFY (molten → bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. Runs in the open
		# cells lava occupies. DEFICIT_BELOW_THRESHOLD on the post-thermal TEMP: x = max(0, SOLIDIFY_TEMP - temp) *
		# SOLIDIFY_RATE, capped by the LAVA present → a conserving lava→rock_fill transfer. DISSOLVES the direct
		# `solid=1; lava=0` write formerly in lava_phase_sphere3d.glsl (which lost the lava mass); the accreted
		# rock_fill crossing 0.5 is what turns the cell to derived bedrock (and, in Stage C, stamps the SDF).
		rec(DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			0, SOLIDIFY_TEMP),

		# M6 — ROCK MELT (bedrock → molten): open-cell rock hotter than ROCK_MELT_TEMP melts to lava.
		# EXCESS_OVER_THRESHOLD on TEMP: x = max(0, temp - ROCK_MELT_TEMP) * ROCK_MELT_RATE, capped by ROCK_FILL →
		# conserving rock_fill→lava transfer. Only fires in OPEN cells (engine skips solid), so it melts partial
		# boundary rock; deep full-bedrock melt is driven by add_lava / the Stage-C bore (see the const note).
		rec(EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			0, ROCK_MELT_TEMP),
	]
