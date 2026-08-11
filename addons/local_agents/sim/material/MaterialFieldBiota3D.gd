class_name LAMaterialFieldBiota3D
extends RefCounted


const GRAZE_RESIDUAL: float = 0.02       # standing crop per cell a mouth cannot reach (regrowth stays possible)
const BITE_TAKE_FRAC: float = 0.35       # share of the reachable crop one animal's bite may take in a frame

const HEAT_C_PER_MASS: float = 0.02
const HEAT_RADIUS: float = 0.0           # the animal's own cell only; body heat does not teleport

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


func _queue():
	if _f == null or _f._inject == null:
		return null
	if _f._gpu == null or not _f._gpu.has_method("move_field_sparse"):
		return null
	return _f._inject.queue


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

func graze(world_pos: Vector3, want: float) -> float:
	if want <= 0.0:
		return 0.0
	if disabled():
		graze_asked += want
		graze_taken += want              # the control arm: food out of nothing
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
	# bound into the CO₂ below is deliberately not tracked — see LAMaterialFieldElementInventory3D's convention note).
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


func litter(world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or disabled():
		return                           # the control arm: the body's mass simply disappears
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
		"biota_exchanges": exchanges,
		"biota_enabled": 0.0 if disabled() else 1.0,
	}
