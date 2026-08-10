class_name LAMaterialFieldConservation3D
extends RefCounted

## THE LAW, ENFORCED. Once the world is sealed, atoms are not created and not destroyed — and a run that
## breaks that is a FAILED RUN, not a run with an interesting number in it.
##
## WHY THIS IS A GATE AND NOT A GAUGE. Every substance here already had a gauge, and the gauges did not
## prevent anything. The project's own history is the argument: a carbon shortage was read off one of them
## and the plan produced was TO ADD ANOTHER SOURCE. CLAUDE.md records that as the worst framing failure in
## the repository. A number in a report is an invitation to interpret; a run that goes red is not. The
## maintainer's directive is that once a planet is seeded there is no more creating or destroying carbon
## atoms, and the only version of that which survives contact with a future agent in a hurry is one where
## the build stops.
##
## THE LAW IS "NO UNBOOKED CHANGE", NOT "NOTHING EVER CHANGES", and the difference is not pedantry.
## Element counts DO change in reality — radioactive decay transmutes atoms, and it is where a planet's
## radiogenic heat comes from in the first place, so a rule of "carbon moles are frozen forever" would be
## forbidding real physics the moment anyone modelled it. What is forbidden is ARTIFICIAL change: matter
## appearing because a record credits a product with no reactant, or vanishing because a kernel debits one
## side of a transfer and never credits the other.
##
## SO THE GATE HOLDS TOTALS EXACTLY *BECAUSE* NO NUCLEAR PROCESS IS MODELLED HERE, not as a statement about
## the universe. `LASubstances` declares h2o, o2, co2, cellulose, silicate, silica, carbonate and fixed_n —
## no radionuclides — and the geotherm is a heat RESERVOIR rather than a decay chain, so the legitimate
## transmutation rate for every element gated below is exactly zero today. If a decay chain is ever added it
## gets the same treatment a meteor gets: a named, booked source, subtracted here before the comparison.
## That is the identical shape to the energy law two paragraphs down — energy is not closed either, and the
## quantity that must go to zero is the UNBOOKED remainder, not the change.
##
## WHAT IS AND IS NOT A VIOLATION, because getting this wrong makes the gate useless in the other direction:
##   * MATTER IS CLOSED APART FROM BOOKED SOURCES. A meteor is real mass arriving from off-world; a decay
##     chain, if one is ever built, is real transmutation. Both are booked and subtracted. An unbooked
##     change is a bug, in either direction, with no third category.
##   * ENERGY IS NOT CLOSED AND MUST NOT BE. Sunlight enters and longwave leaves every step. The law for
##     energy is that every joule is BOOKED to a named source or sink, so the quantity that must go to zero
##     is `energy_residual`, NOT `energy_run_drift`. A gate demanding a constant energy stock would be
##     demanding a planet with no sun, and would be "fixed" by deleting the star.
##   * BURIAL IS NOT LOSS. Every total here is the MASK-FREE one. A substance that stops being counted
##     because it went under the solid mask has not gone anywhere, and a gate reading the open-cell total
##     would fire on ordinary sedimentation.
##   * A RAW CHANNEL SUM IS NOT A QUANTITY unless every channel in it holds one substance in one unit.
##     `carbon_total` summed CO2 units + biomass units + detritus units and read +1261% while the mole count
##     read -10.7%; the sign was different. Everything gated here is either in moles or is a single-substance
##     sum (h2o, mineral), and nothing else is admissible.
##
## IT IS A RATCHET, NOT A TOLERANCE, AND THAT IS DELIBERATE. Every substance is in violation TODAY — over a
## 600-frame run, carbon -26.7%, water -19.5%, oxygen -90.3%. A tolerance loose enough to pass now would be a tolerance
## that permits the thing the rule forbids, and a tolerance tight enough to be honest would fail every run
## until the last leak is closed, which trains people to ignore it. So the gate carries the CURRENT measured
## violation as recorded debt and fails when a substance gets WORSE than its recorded figure. The target is
## and remains zero; the recorded numbers are what must come down, and lowering one means lowering the
## number written here in the same commit. A substance that reaches zero gets its entry set to zero and can
## never drift again.
## (Explicit types only, no ':=' inferred typing.)

## THE DEBT IS CUMULATIVE DRIFT AT A FIXED REFERENCE HORIZON, and arriving at that took two wrong answers
## that are worth recording, because both look right until they are run.
##
##   1. CUMULATIVE SINCE THE SEAL, evaluated whenever. Horizon-dependent, so not a property of the physics
##      at all: carbon reads -10.7% at 300 frames and -26.7% at 600. A threshold tuned on a short run fails
##      a long one for no reason, and Stage 3 wants 4000+ frames.
##   2. PER STEP, to remove the horizon. A rate is unstable at small N — the first armed run fired at steps
##      5, 20 and 30, where a settling transient is divided by almost nothing and water read +3.96e-4/step
##      against a settled -2.55e-4, the wrong SIGN as well as the wrong size. A warm-up fixed that and
##      exposed the deeper problem: THE LOSS IS FRONT-LOADED. Water is already down 11.7% by step 100 and
##      only reaches 19.5% by step 760, so the per-step rate is high early and decays, and no single
##      threshold fits both ends. That is not noise — it is a real fast leak at startup, and a statistic
##      that averages it away would hide the largest thing here.
##
## So: ONE evaluation, at the first sample at or after REFERENCE_STEPS past the seal. Reproducible, immune
## to both problems, and the same shape the project already measures in (fixed-length arms compared at equal
## `field_sim_s`). A run shorter than the horizon publishes `conservation_audited: false` and gates nothing,
## which is honest — a 120-frame smoke test has no opinion about conservation and should not pretend to.
## *(Corrected 2026-08-09: this said such a run "reports `too_short`". No such string is ever emitted; the
## only signal is the boolean, and a reader grepping the name this header gave them finds nothing. Naming a
## marker that does not exist is the same defect class as a gauge that cannot fail.)*
##
## The worst excursion is still tracked and published (`conservation_worst`), because the gate found on its
## first run that water breaches at -20.5% and RECOVERS to -17.8% — a total read only at the finish line
## understates the violation, and one end of a run is no more trustworthy than the other.
##
## Measured 2026-08-09, seed 4242, `--sandbox --planet-only --no-fauna --run-frames=600 --fast=8`, from the
## world seal at field_step 9. EVERY ONE OF THESE IS A BUG, and the list is the work queue for closing them.
##
## Lowering one of these means editing this table DOWN in the same commit that earns it. Raising one is not
## a thing that happens: if a change makes a substance worse, the change is wrong.
##
##   element_C_total  the only dimensionally honest carbon number — moles, both books, via mol_per_unit
##   h2o_closed_total water + moisture + snow + soil, all one substance in water-equivalent units
##   mineral_total    the five silicate phases, which trade 1:1 — the ONLY one anywhere near closed, and the
##                    only substance with a per-pass probe. That is not a coincidence; it is the argument for
##                    building the same instrument for the others.
const DEBT: Dictionary = {
	# |relative drift| at REFERENCE_STEPS past the seal, with headroom over the measured figure so ordinary
	# run-to-run spread (impacts, eruptions) does not fire it.
	#
	# RETIGHTENED 2026-08-10, after the biological rates stopped being fitted (see the note below). Four of
	# the six moved by factors of 3-5x, and the rule is that a table entry comes DOWN in the commit that
	# earns it. The headroom here is ~15% rather than the ~5% these started at, ON PURPOSE: the new figures
	# are ONE run each, and this project's residual spread is discrete and disaster-driven rather than
	# Gaussian. Retighten toward 5% once three runs per arm confirm them.
	"element_C_total": 0.29,      # measured -0.286 — NOT LOWERED, AND NOT RAISED. See CARBON GOT WORSE below.
	"h2o_closed_total": 0.21,     # measured -0.192 (was -0.195; the 0.1pp is inside the noise, so unchanged)
	"o2_total": 0.29,             # measured -0.248 (was -0.903)
	"oxidant_total": 0.12,        # measured -0.104 (was -0.562)
	"nitrogen_all": 0.0075,       # measured -0.0062 (was -0.0214)
	"mineral_total": 0.0001,      # measured -0.000061 (was -0.00027) — still the bar for everything else
}

## CARBON GOT WORSE AND THE TABLE DOES NOT HIDE IT: -0.267 -> -0.286, against an allowance of 0.29 that is
## deliberately NOT being raised. There is 0.42 percentage points of headroom left, so the next change that
## touches the carbon path very likely trips this gate, and that is the gate doing its job.
##
## THE RULE SAYS A CHANGE THAT MAKES A SUBSTANCE WORSE IS WRONG, AND THIS CHANGE WAS TAKEN ANYWAY — by the
## maintainer, explicitly, on 2026-08-10. Recorded here rather than in a commit message alone because a
## future reader finding carbon 1.9pp worse deserves to know it was a decision and not an accident. The
## reasoning: the rates it replaced were FITTED — each picked by running the sim and keeping the value whose
## `biomass_total` looked best, which is the one thing CLAUDE.md's physical-constant rule forbids outright —
## and Rule Zero outranks this ratchet. Four substances improved 3-5x in the same change.
##
## WHAT IS NOT KNOWN, STATED PLAINLY: nobody has measured WHY carbon got worse. The plausible story is that
## it is redistribution rather than new destruction — field `biomass_total` falls 6.27 -> 0.0028 when
## photosynthesis stops running ~3000x too fast, so carbon that sat inert in a biomass pool now moves
## through CO2 and detritus where the pre-existing leak can reach it. THAT IS A GUESS. It is exactly the
## question per-pass matter attribution exists to answer, and it is the next job.

## Steps past the seal at which the books are audited, once. 600 is the project's standard verification
## horizon (a 600-frame run at --fast=8 is ~760 steps, so this lands comfortably inside one).
const REFERENCE_STEPS: int = 600

## Baseline key for each gated total. A substance with no sealed baseline is NOT gated — it is reported as
## unmeasurable, which is the honest answer and is itself worth seeing in a run.
const BASELINE: Dictionary = {
	"element_C_total": "element_C_total_first",
	"h2o_closed_total": "h2o_first",
	"o2_total": "o2_first",
	"oxidant_total": "oxidant_first",
	"nitrogen_all": "nitrogen_first",
	"mineral_total": "mineral_first",
}

var _f = null
var _worst: Dictionary = {}          # substance -> worst relative drift seen this run
var _violations: PackedStringArray = PackedStringArray()
## The audit happens once, at REFERENCE_STEPS. Without this the same breach re-reports every sample and a
## reader cannot tell one violation from forty.
var _audited: bool = false


func setup(field) -> void:
	_f = field


## Check every gated substance against its sealed baseline. Returns the report block; prints a marker when a
## substance exceeds its recorded debt, in the same shape as STALE_SHADERS so a run can be checked
## mechanically by grepping one string rather than by a human reading a table.
func check(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._seal == null or not _f._seal.sealed():
		out["conservation"] = "seeding"
		return out
	# ONE EVALUATION, AT THE REFERENCE HORIZON. See the header for the two statistics this replaced and why
	# each failed. The worst excursion is still accumulated every sample below; only the VERDICT waits.
	var elapsed: int = _steps_since_seal()
	var rows: Dictionary = {}
	var fresh: PackedStringArray = PackedStringArray()
	for key in DEBT:
		var first_key: String = String(BASELINE.get(key, ""))
		var now = d.get(key)
		var first = d.get(first_key)
		if not (now is float or now is int) or not (first is float or first is int):
			rows[key] = "unmeasured"
			continue
		var f: float = float(first)
		if f == 0.0:
			rows[key] = "unmeasured"
			continue
		var rel: float = (float(now) - f) / f
		var mag: float = absf(rel)
		if mag > float(_worst.get(key, 0.0)):
			_worst[key] = mag
		rows[key] = snappedf(rel, 1e-6)
		# The verdict only at the horizon; before it the run is still accumulating, after it the same
		# breach would be re-reported every sample.
		if elapsed < REFERENCE_STEPS or _audited:
			continue
		if mag > float(DEBT[key]) and not _violations.has(key):
			_violations.append(key)
			fresh.append(key)
			# One line per substance, the first time it breaches. A marker rather than a push_error so the
			# offscreen wrapper and CI can both find it without parsing Godot's error stream.
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "first": f, "now": float(now),
				"rel_drift": snappedf(rel, 1e-6), "allowed": float(DEBT[key]), "at_steps": elapsed,
				"seal_step": _f._seal.seal_step(),
			}))
	if elapsed >= REFERENCE_STEPS:
		_audited = true
	out["conservation"] = rows
	out["conservation_audited"] = _audited
	out["conservation_steps"] = elapsed
	out["conservation_worst"] = _worst
	out["conservation_violations"] = _violations
	# The single boolean a harness can gate on. It is FALSE on a healthy run and there is no third state:
	# "seeding" above is the only way to avoid answering, and it stops being available once the world seals.
	out["conservation_failed"] = not _violations.is_empty()
	return out


## Steps elapsed since the books closed. The denominator that makes every figure above a RATE rather than a
## number that grows with the length of the run.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
