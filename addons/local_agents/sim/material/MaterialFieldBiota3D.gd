class_name LAMaterialFieldBiota3D
extends RefCounted

## LAMaterialFieldBiota3D — THE ONE SEAM THROUGH WHICH A LIVING BODY EXCHANGES MATTER WITH THE FIELD.
##
## Before this module existed, animals were outside physics. Every one of these was live in the shipped tree
## and every one of them created or destroyed matter:
##   * a herbivore standing on warm ground was handed 5 biomass/second out of nothing. The only field read was
##     `temp_at` — a thermometer, not a stock — and nothing anywhere was decremented. The header comment said
##     so: "never depletes, can't be crashed".
##   * every joule an animal burned VANISHED. Nothing consumed oxygen, nothing produced carbon dioxide, and no
##     body heat reached the temperature field. Breathing was a boolean threshold test on the O₂ a creature
##     never took.
##   * drinking refilled hydration with no water cell debited, and the sweat/urine side drained hydration into
##     nowhere. H₂O is the substance this project holds up as its worked example of a closed ledger.
##   * a carcass's decomposition and an animal's feces called `deposit_detritus`, which wrote the CPU MIRROR
##     `_f._detritus[c] += amount` — a mirror uploaded to the device exactly ONCE (`_detritus_seed_dirty`, at
##     seed) and OVERWRITTEN by the readback on every drain that requests it. So the return leg of the whole
##     death→soil loop was silently discarded. That deposit now runs through the device queue here, which is
##     the only reason the loop closes at all.
##
## WHAT THIS MODULE IS, MECHANICALLY. It plans each exchange against the CPU mirrors (cheap, one cell read) and
## parks it on LAMaterialFieldInject3D's queue, which LAMaterialFieldSphereStep3D flushes onto the LIVE device
## buffers at the one point in the frame where the GPU is idle. Nothing here uploads a whole channel and
## nothing here calls `buffer_get_data` — both of those change the simulation (see the `request_channel` and
## `request_probe` notes in LAMaterialSphereGPU3D). A debit is resolved on device against the live value, so it
## can never drive a cell negative and never takes grass that is not there, however stale the mirror it was
## planned against. What the ground could not supply comes back as `biota_graze_short`.
##
## THE MIRROR IS DECREMENTED LOCALLY THE INSTANT AN ANIMAL BITES, and that is not bookkeeping — it is the
## competition. `biomass` rides the SLOW readback set (every 4th drain), so without the local decrement every
## grazer on a cell would plan against the same stale standing crop for four drains and they would all be
## credited the same blade of grass. The device would then clamp the aggregate and the shortfall would show up
## as a huge `biota_graze_short` instead of as animals competing for a finite pasture.
##
## THE CARBON BOUNDARY, stated because a conserved quantity is only as meaningful as its boundary.
## LAMaterialFieldMassBudget3D defines `carbon_total = co2 + biomass + detritus`. Living bodies are a FOURTH
## carbon pool that budget cannot see, so this module publishes it: `biota_carbon` is the running sum of
## everything bodies have taken out of the field minus everything they have put back. Read the two together and
## the biosphere's books close; read `carbon_total` alone and a herd eating grass looks like a leak.
##   `biota_carbon` going NEGATIVE is meaningful, not a bug: it means bodies are exporting into the field more
##   carbon than they took from it, which happens because animals also eat PLANT NODES and each other, and a
##   plant node's mass never came out of a field channel. `biota_node_intake` counts that separately so the two
##   sources are never silently merged. (`LAPlant.FOOD_REGROW` regrows a plant's reserve from nothing at 8/sec,
##   which is a real violation in `sim/actors/Plant.gd` — a file another track owns concurrently, reported and
##   not touched here.)
##
## OXYGEN'S CONVENTION is the budget's: FREE molecular O₂ only. An animal's aerobic respiration debits `o2` and
## credits `co2` ONE FOR ONE, which is the identity `LABioRecords` already enforces on the substrate's own
## respiration record R20 ("RESP_O2_COST MUST EQUAL RESP_CO2_YIELD — one O₂ consumed per CO₂ produced"). The
## carbon in that CO₂ comes out of the body, not out of the air, so `biota_carbon` falls by exactly what `co2`
## rises by.
##
## (Explicit types only, no ':=' inferred typing.)

## A grazer may not strip a cell bare in one bite — that is what makes a pasture recover rather than being
## mined out. Real grazing systems leave residual leaf area because the animal physically cannot get its mouth
## below it, and the residual is what regrows. `BITE_TAKE_FRAC` is the share of the standing crop above the
## residual one bite may remove.
const GRAZE_RESIDUAL: float = 0.02       # standing crop per cell a mouth cannot reach (regrowth stays possible)
const BITE_TAKE_FRAC: float = 0.35       # share of the reachable crop one animal's bite may take in a frame

## Metabolic heat: how many °C one unit of respired tissue raises its cell. This is a UNIT CONVERSION between
## the sim's mass/energy unit and the field's temperature channel, not a property of matter — the sim's "energy
## unit" has no joule value, so there is nothing to derive it from. It is deliberately small: an animal is a
## rounding error against a cell of rock or air, and the point of wiring it at all is that the heat has to go
## SOMEWHERE rather than vanish. A herd sheltering together should warm its hollow, not the planet.
const HEAT_C_PER_MASS: float = 0.02
const HEAT_RADIUS: float = 0.0           # the animal's own cell only; body heat does not teleport

## THE CONTROL. `LA_NO_BIOTA_DEBIT=1` turns every debit in this module into a free hand-out: grazing returns
## what was asked without touching the pasture, drinking refills without a puddle, respiration takes no oxygen.
## That is EXACTLY the pre-fix behaviour, and it exists so the acceptance measurement can be a real experiment
## rather than an assertion — a gate that passes with the feature switched off is not a gate. The credits
## (litter, transpire, CO₂) are switched off with it, because in the world this reproduces they did not run
## either. Gated on a NON-EMPTY value, not on `has_environment`: `env FOO= …` counts as set and has silently
## armed a diagnostic here before.
static func disabled() -> bool:
	return OS.get_environment("LA_NO_BIOTA_DEBIT") != ""

var _f = null                            # back-reference to the owning LAMaterialField3D

# --- the biotic ledger (published into SIM_REPORT through the LASimReport.register seam) --------------------
var graze_asked: float = 0.0             # standing crop animals bit at
var graze_taken: float = 0.0             # ...of which the local mirror agreed was there (the gut credit)
var node_intake: float = 0.0             # body mass taken from plant/carcass NODES, which are not field channels
var o2_in: float = 0.0                   # free O₂ animals drew out of their head cells
var co2_out: float = 0.0                 # CO₂ their respiration put back (== o2_in, one for one)
var detritus_out: float = 0.0            # body mass returned to the soil as litter (feces, carcass, carrion)
var water_in: float = 0.0                # H₂O drunk out of the field
var water_out: float = 0.0               # H₂O breathed/sweated/passed back into it
var heat_out: float = 0.0                # °C·cells of metabolic heat handed to the temperature field
var spawn_mass: float = 0.0              # body mass that entered the world by SPAWNING rather than by eating
var spawn_founder: float = 0.0           # ...of which the founding population (an initial condition)
var spawn_runtime: float = 0.0           # ...of which spawned after the founding wave — matter made at runtime
var exchanges: int = 0                   # per-cell edits queued, so a dead seam is distinguishable from a calm one


func setup(field) -> void:
	_f = field
	LASimReport.register(report)


## The queue every exchange parks on. Null (and every method below a no-op) on a field with no GPU driver —
## a bare box-mode field or a headless test — because nothing would ever flush it and the ops would pile up
## forever. A creature simply cannot eat or breathe the world in that configuration, which is honest: there is
## no world to eat.
func _queue():
	if _f == null or _f._inject == null:
		return null
	if _f._gpu == null or not _f._gpu.has_method("move_field_sparse"):
		return null
	return _f._inject.queue


## The GROUND-HUGGING open cell under a world point — the cell photosynthesis actually grows grass in.
## R19 is gated `GATE_NEAR_GROUND` (see LABioRecords), i.e. the open cell whose inward neighbour is rock, so
## this is where the standing crop is and where a mouth reaches. Returns -1 outside the shell.
##
## *(This corrects a claim that justified the free-food hack. `LACreatureDigestion.ambient_graze`'s comment
## said photosynthesis "deposits its biomass in the sky-exposed TOP-of-column cell, dozens of cells ABOVE the
## grazer — so a ground-level biomass read was always 0". That was true of an older photosynthesis record and
## is not true now; R19 was moved to the ground cell, and LABioRecords:50 says so. The stale comment was the
## stated reason for handing herbivores food out of nothing.)*
func ground_cell(world_pos: Vector3) -> int:
	if _f == null or _f._cell_count <= 0:
		return -1
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return -1
	if _f._sphere == null:
		return c if _f._solid[c] == 0 else -1
	# Walk radially until we are in open air with rock (or the shell floor) beneath — at most a few steps,
	# because a standing animal is by construction within a cell or two of the ground.
	var steps: int = 0
	while _f._solid[c] != 0 and steps < 6:
		var up_c: int = _f._sphere.neighbours[c * 6 + 1]     # N_OUT = 1 (radially outward)
		if up_c < 0:
			return -1
		c = up_c
		steps += 1
	if _f._solid[c] != 0:
		return -1
	steps = 0
	while steps < 6:
		var in_c: int = _f._sphere.neighbours[c * 6 + 0]     # N_IN = 0 (radially inward)
		if in_c < 0 or _f._solid[in_c] != 0:
			return c                                          # rock (or the floor) beneath: this is the ground cell
		c = in_c
		steps += 1
	return c


# --- INTAKE: matter leaving the field and entering a body -------------------------------------------------

## GRAZE. Take up to `want` of the standing crop in the ground cell under `world_pos` and return what the
## animal actually got. Debits the field's real `biomass` channel; a bare, frozen or flooded cell yields
## exactly nothing, which is what makes starvation reachable.
##
## The debit's destination is -1 — the mass leaves the field entirely, because the body it enters is not a
## field channel. That is not a loss: `biota_carbon` rises by the same number, and falls again when the animal
## respires it, excretes it, or dies and rots.
func graze(world_pos: Vector3, want: float) -> float:
	if want <= 0.0:
		return 0.0
	if disabled():
		graze_asked += want
		graze_taken += want              # the control arm: food out of nothing, exactly as it used to be
		return want
	var q = _queue()
	if q == null:
		return 0.0
	if _f._biomass.size() != _f._cell_count:
		return 0.0
	var c: int = ground_cell(world_pos)
	if c < 0:
		return 0.0
	var standing: float = _f._biomass[c]
	var reachable: float = maxf(0.0, standing - GRAZE_RESIDUAL)
	if reachable <= 0.0:
		return 0.0
	var take: float = minf(want, reachable * BITE_TAKE_FRAC)
	if take <= 0.0:
		return 0.0
	# Decrement the mirror NOW so the next grazer this frame sees a thinner pasture (see the header note).
	_f._biomass[c] = maxf(0.0, standing - take)
	var cells: PackedInt32Array = PackedInt32Array([c])
	var amounts: PackedFloat32Array = PackedFloat32Array([take])
	var sink: PackedInt32Array = PackedInt32Array([-1])
	q.transfer("biomass", cells, amounts, "biomass", sink)
	graze_asked += want
	graze_taken += take
	exchanges += 1
	return take


## DRINK. Take up to `want` of H₂O out of the world at `world_pos` and return what was there. Liquid surface
## water first (a lake, a river, the sea); failing that the groundwater the animal is standing on, which is
## what a real animal at a seep or a dug well gets. Returns 0 on dry ground, so thirst is a real pressure.
func drink(world_pos: Vector3, want: float) -> float:
	if want <= 0.0:
		return 0.0
	if disabled():
		water_in += want                 # the control arm: water the lake never lost
		return want
	var q = _queue()
	if q == null:
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return 0.0
	var took: float = _draw(q, "water", _f._water, c, want)
	if took < want and _f._soil.size() == _f._cell_count and _f._sphere != null:
		# Groundwater: the permeable shell immediately under the animal's feet.
		var g: int = ground_cell(world_pos)
		if g >= 0:
			var below: int = _f._sphere.neighbours[g * 6 + 0]
			if below >= 0:
				took += _draw(q, "soil", _f._soil, below, want - took)
	if took > 0.0:
		water_in += took
	return took


## One channel, one cell, up to `want`, planned against `mirror` and resolved on device. The mirror is
## decremented for the same reason grazing decrements it: several animals may drink the same puddle in one
## frame, and the second one must see what the first one left.
func _draw(q, channel: String, mirror: PackedFloat32Array, c: int, want: float) -> float:
	if want <= 0.0 or mirror.size() != _f._cell_count or c < 0:
		return 0.0
	var have: float = mirror[c]
	if have <= 0.0:
		return 0.0
	var take: float = minf(want, have)
	mirror[c] = have - take
	q.transfer(channel, PackedInt32Array([c]), PackedFloat32Array([take]), channel, PackedInt32Array([-1]))
	exchanges += 1
	return take


# --- OUTPUT: matter leaving a body and entering the field -------------------------------------------------

## RESPIRE. An animal oxidises `mass` of its own tissue at `head_pos`: it draws that much free O₂ out of the
## cell it is breathing and returns the same amount as CO₂, one for one — the identity LABioRecords enforces on
## the substrate's own respiration record. The metabolic heat goes into the temperature field.
##
## Returns the O₂ the cell could actually supply. A creature in air the substrate has drawn down gets less than
## it asked for, and its caller can act on that; nothing here silently invents the difference.
func respire(head_pos: Vector3, mass: float) -> float:
	if mass <= 0.0:
		return 0.0
	if disabled():
		return mass                      # the control arm: energy burned into nowhere, no O₂, no CO₂, no heat
	var q = _queue()
	if q == null:
		return 0.0
	if _f._o2.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(head_pos)
	if c < 0 or _f._solid[c] != 0:
		return 0.0
	var have: float = _f._o2[c]
	var got: float = minf(mass, maxf(0.0, have))
	if got <= 0.0:
		return 0.0
	_f._o2[c] = have - got
	# O₂ is DEBITED (dst -1: the substrate's oxygen convention counts free molecular O₂ only, and the oxygen
	# bound into the CO₂ below is deliberately not tracked — see LAMaterialFieldMassBudget3D's convention note).
	q.transfer("o2", PackedInt32Array([c]), PackedFloat32Array([got]), "o2", PackedInt32Array([-1]))
	# CO₂ is CREDITED with no field debit, because its carbon came out of the body. `biota_carbon` falls by the
	# same number, which is what keeps the carbon books closed across the body/field boundary.
	q.add("co2", PackedInt32Array([c]), PackedFloat32Array([got]))
	o2_in += got
	co2_out += got
	exchanges += 2
	if HEAT_C_PER_MASS > 0.0 and _f.has_method("add_heat"):
		_f.add_heat(head_pos, got * HEAT_C_PER_MASS, HEAT_RADIUS)
		heat_out += got * HEAT_C_PER_MASS
	return got


## LITTER. Return `mass` of body tissue to the soil as detritus at `world_pos` — a carcass rotting, an animal
## passing the indigestible residue of a meal, a fish sinking. The substrate's decomposer loop (R15) then rots
## it into CO₂ and soil fertility.
##
## This is the leg that was DEAD. `LAMaterialFieldChannels3D.deposit_detritus` writes `_f._detritus[c] +=
## amount`, and the detritus mirror reaches the device exactly once (the one-shot `_detritus_seed_dirty` upload
## in LAMaterialFieldSphereStep3D) and is overwritten by the readback thereafter. Every carcass and every
## dropping since that channel was wired went nowhere.
func litter(world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or disabled():
		return                           # the control arm: the body's mass simply disappears, as it used to
	var q = _queue()
	if q == null:
		return
	var c: int = ground_cell(world_pos)
	if c < 0:
		return
	q.add("detritus", PackedInt32Array([c]), PackedFloat32Array([mass]))
	if _f._detritus.size() == _f._cell_count:
		_f._detritus[c] += mass          # keep the mirror in step until the next readback
	detritus_out += mass
	exchanges += 1


## TRANSPIRE. Body water leaving as vapour — breath, sweat, the water in urine. Credited to `moisture` (the
## atmosphere's conserved airborne H₂O) at the animal's own cell, out of the body's own hydration. The animal
## drank it from the field through `drink`, so over a life the two legs close.
func transpire(world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or disabled():
		return                           # the control arm: sweat that never reaches the air
	var q = _queue()
	if q == null:
		return
	if _f._moisture.size() != _f._cell_count:
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or _f._solid[c] != 0:
		return
	q.add("moisture", PackedInt32Array([c]), PackedFloat32Array([mass]))
	water_out += mass
	exchanges += 1


## Body mass taken from a NODE rather than from a field channel (a plant eaten, a carcass bitten, a kill). Pure
## accounting: the mass moves node → body without touching the substrate, and counting it here is what lets a
## reader tell a biosphere feeding on field grass apart from one feeding on actor nodes.
func note_node_intake(mass: float) -> void:
	if mass > 0.0:
		node_intake += mass


## A BODY APPEARED. Every creature spawned by the ecology arrives with a full structural mass and a full
## reserve that came from nowhere in the substrate, and the honest thing is to SAY SO rather than let it show
## up later as a mysterious carbon surplus when the animal dies and rots.
##
## Two cases, and they are physically different:
##   * the FOUNDING population is an initial condition — a planet that starts with a biosphere is a premise,
##     not a violation, in the same way the ocean starts full of water;
##   * every later spawn is matter created at runtime. A BIRTH is not one of these: the mother is debited the
##     newborn's whole mass in LACreatureReproduction, so a birth moves mass rather than making it. Anything
##     else reaching this counter after the founding wave is a top-up spawner minting animals, and
##     `biota_spawn_runtime` is the number that makes that visible.
func note_spawn(mass: float, founder: bool) -> void:
	if mass <= 0.0:
		return
	spawn_mass += mass
	if founder:
		spawn_founder += mass
	else:
		spawn_runtime += mass


## Carbon standing in living bodies and undecomposed carcasses right now: what spawned into the world, plus
## everything bodies have taken out of the field and off nodes, less everything they have put back. Add it to
## `carbon_total` and the biosphere's books close across the body/field boundary.
func biota_carbon() -> float:
	return spawn_mass + graze_taken + node_intake - co2_out - detritus_out


func report() -> Dictionary:
	return {
		"biota_carbon": snappedf(biota_carbon(), 0.01),
		"biota_graze_asked": snappedf(graze_asked, 0.01),
		"biota_graze_taken": snappedf(graze_taken, 0.01),
		# What the pasture could not supply. A large figure beside a small `biota_graze_taken` is the honest
		# statement "the planet has no standing crop", NOT a broken debit.
		"biota_graze_short": snappedf(maxf(0.0, graze_asked - graze_taken), 0.01),
		"biota_node_intake": snappedf(node_intake, 0.01),
		# Body mass that arrived by SPAWNING. The founding split is an initial condition; anything in
		# `biota_spawn_runtime` after the founding wave is animals being made out of nothing at runtime (a
		# birth is NOT counted there — the mother pays for it).
		"biota_spawn_mass": snappedf(spawn_mass, 0.01),
		"biota_spawn_founder": snappedf(spawn_founder, 0.01),
		"biota_spawn_runtime": snappedf(spawn_runtime, 0.01),
		"biota_o2_in": snappedf(o2_in, 0.01),
		"biota_co2_out": snappedf(co2_out, 0.01),
		"biota_detritus_out": snappedf(detritus_out, 0.01),
		"biota_water_in": snappedf(water_in, 0.01),
		"biota_water_out": snappedf(water_out, 0.01),
		"biota_heat": snappedf(heat_out, 0.01),
		# Per-cell device edits this seam queued. Zero with animals alive means the seam is DEAD — which is the
		# state this module was written to end, and the control the acceptance gate disables to prove it.
		"biota_exchanges": exchanges,
		"biota_enabled": 0.0 if disabled() else 1.0,
	}
