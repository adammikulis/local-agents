class_name LAGasRecords
extends LAReactionDefs

## ATMOSPHERIC GAS exchange records (R11 O₂ sky refill, R12 CO₂ sky exchange).

# Constants inherited from the kernels that were dissolved (MaterialGas3D.gd / MaterialFungus3D.gd). They were
# "copied VERBATIM", i.e. never derived — and two of them were wrong in a way no amount of tuning could fix.
const SKY_EXCHANGE: float = 0.5
const O2_AMBIENT: float = 1.0
const CO2_SKY_VENT: float = 0.25

# --- Biomass / plant carbon exchange (Phase B3 §1 R19) ----------------------------------------------------
# Trace atmospheric CO₂ the sky maintains at every exposed surface cell (the ~400ppm baseline). Photosynthesis
# draws it DOWN locally, respiration/combustion push it UP — the sky exchange relaxes it back to this trace.
# Without it the carbon loop can't start: biomass, detritus, fungus and the combustion CO₂ all begin at ~0, so
# there is no carbon anywhere for a plant to fix (chicken-and-egg). This trace IS that ambient carbon source.
const CO2_AMBIENT_TRACE: float = 0.05


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		# R11 — Gas O₂ SKY-REFILL: relax O₂ toward ambient at sky-exposed surface cells (gas_sky_sphere3d:55).
		# RELAX_TARGET: x = SKY_EXCHANGE*(O2_AMBIENT - o2); product = O2 itself, no reactant.
		rec(RELAX_TARGET, SKY_EXCHANGE, O2, [], [[O2, 1.0, TGT_SELF]], GATE_SURFACE, O2_AMBIENT),

		# R12 — Gas CO₂ SKY-EXCHANGE: relax CO₂ toward a small ambient TRACE at sky-exposed surface cells
		# (mirrors the O₂ sky refill R11 exactly). RELAX_TARGET: x = CO2_SKY_VENT*(CO2_AMBIENT_TRACE - co2);
		# product = CO₂ itself, no reactant. Excess combustion CO₂ still vents DOWN toward the trace (x<0), and
		# clean surface air refills UP to it (x>0) — the trace is the atmosphere's baseline carbon that seeds
		# the whole loop (photosynthesis draws it below the trace locally; see R19).
		rec(RELAX_TARGET, CO2_SKY_VENT, CO2, [], [[CO2, 1.0, TGT_SELF]], GATE_SURFACE, CO2_AMBIENT_TRACE),
	]
