class_name LAMaterialFieldBiota3D
extends RefCounted


# Standing crop per cell a mouth cannot reach (regrowth stays possible), mol/m^3 of biomass.
const GRAZE_RESIDUAL: float = 0.02 * LAPhysical.DRY_WOOD_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CH2O_UNIT_KG_MOL

const HEAT_RADIUS: float = 0.0           # the animal's own cell only; body heat does not teleport

var _f = null                            # back-reference to the owning LAMaterialField3D
static var _resp_j_per_unit: float = -1.0   # cached: J released per channel unit of O2 respired


## Joules of oxidation heat per MOLE of O2 consumed, from the substance table's formation enthalpies. A
## channel amount is moles, so no unit bridge stands between the mole and the channel.
static func _respiration_j_per_o2_unit() -> float:
	if _resp_j_per_unit >= 0.0:
		return _resp_j_per_unit
	var tbl: Dictionary = LASubstances.table()
	var c_h: float = float(tbl.get("organic_c", {}).get("formation_enthalpy_j_mol", 0.0))
	var o2_h: float = float(tbl.get("o2", {}).get("formation_enthalpy_j_mol", 0.0))
	var co2_h: float = float(tbl.get("co2", {}).get("formation_enthalpy_j_mol", 0.0))
	_resp_j_per_unit = maxf(0.0, -(co2_h - c_h - o2_h))
	return _resp_j_per_unit


# --- THE BODY STOCK. Matter crosses between the sealed field and a body only here, so the field plus this
# book is closed. Matter a stand-in made is held apart and never handed to the field.
var _stock: Dictionary = {}              # element -> mol taken out of the sealed field
var _stood_in: Dictionary = {}           # fake name -> {element -> mol} a stand-in made


## Fresh litter: the dead pool's carbon channel plus the hydrogen and oxygen the inject queue credits
## with it. A body is made of what it becomes; this is the only organic composition the table declares.
static func litter_comp() -> Dictionary:
	var out: Dictionary = LAReactionBalance.channel_elements("detritus").duplicate()
	out["H"] = float(out.get("H", 0.0)) + LASubstances.fresh_litter_per_carbon("H")
	out["O"] = float(out.get("O", 0.0)) + LASubstances.fresh_litter_per_carbon("O")
	return out


## Largest amount of `comp` a pool of element moles can serve, in units of `comp`.
static func _room(pool: Dictionary, comp: Dictionary, amount: float) -> float:
	var out: float = amount
	for el in comp:
		if float(comp[el]) > 0.0:
			out = minf(out, float(pool.get(el, 0.0)) / float(comp[el]))
	return maxf(out, 0.0)


static func _shift(pool: Dictionary, comp: Dictionary, amount: float, sign: float) -> void:
	for el in comp:
		pool[el] = float(pool.get(el, 0.0)) + sign * amount * float(comp[el])


## Body -> field. Returns what the field-backed book carries, which is all the caller may hand to the
## device; the rest came from a stand-in, so it goes home to one instead of into the sealed field.
func _give(comp: Dictionary, amount: float, fallback: String) -> float:
	var real: float = _room(_stock, comp, amount)
	_shift(_stock, comp, real, -1.0)
	var left: float = amount - real
	for fake in _stood_in:
		if left <= 0.0:
			break
		var can: float = _room(_stood_in[fake], comp, left)
		if can <= 0.0:
			continue
		_shift(_stood_in[fake], comp, can, -1.0)
		LAFakes.give_back(String(fake), can)
		left -= can
	if left > 0.0:
		LAFakes.give_back(fallback, left)
	return real


# --- the biotic ledger (published into SIM_REPORT through the LASimReport.register seam) --------------------
var graze_taken: float = 0.0             # standing crop that left the field and entered a gut
var co2_out: float = 0.0                 # body carbon respiration turned the head cell's O₂ into
var detritus_out: float = 0.0            # body mass returned to the soil as litter (feces, carcass, carrion)
var water_in: float = 0.0                # H₂O drunk out of the field
var water_out: float = 0.0               # H₂O breathed/sweated/passed back into it
var exchanges: int = 0                   # per-cell edits queued, so a dead seam is distinguishable from a calm one


func setup(field) -> void:
	_f = field
	LASimReport.register(report)


func _queue():
	if _f == null or _f._inject == null:
		return null
	if _f._gpu == null or not _f._gpu.has_method("queue_sparse"):
		return null
	return _f._inject.queue


## Steps a foot-level march may take before it is no longer a march to the ground under an animal.
const GROUND_SEARCH: int = 6


## The open cell resting on rock under `world_pos`.
func ground_cell(world_pos: Vector3) -> int:
	if _f == null or _f._cell_count <= 0:
		return -1
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return -1
	return LAFieldGeometry.ground(_f, c, GROUND_SEARCH)


# --- INTAKE: matter leaving the field and entering a body -------------------------------------------------

func graze(world_pos: Vector3, want: float) -> float:
	if want <= 0.0:
		return 0.0
	var q = _queue()
	if q == null:
		return 0.0
	if _f._biomass.size() != _f._cell_count:
		return 0.0
	var c: int = ground_cell(world_pos)
	if c < 0:
		return 0.0
	var standing: float = _f._biomass[c]
	# What a mouth can reach: the crop standing above the grazing horizon. Nothing else bounds a bite;
	# the animal already asked for what its jaw takes in this step.
	var take: float = minf(want, maxf(0.0, standing - GRAZE_RESIDUAL))
	if take <= 0.0:
		return 0.0
	# Decrement the mirror NOW so the next grazer this frame sees a thinner pasture (see the header note).
	_f._biomass[c] = maxf(0.0, standing - take)
	q.transfer("biomass", PackedInt32Array([c]), PackedFloat32Array([take]),
		"biomass", PackedInt32Array([-1]))
	_shift(_stock, LAReactionBalance.channel_elements("biomass"), take, 1.0)
	graze_taken += take
	exchanges += 1
	return take


## Take up to `want` H2O out of the world at `world_pos`, surface water first.
func drink(world_pos: Vector3, want: float) -> float:
	if want <= 0.0:
		return 0.0
	var q = _queue()
	if q == null:
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return 0.0
	var took: float = _draw(q, "h2o", c, want)
	if took < want and _f._grid != null:
		# Groundwater: the permeable ground immediately under the animal's feet.
		var g: int = ground_cell(world_pos)
		if g >= 0:
			var below: int = LAFieldGeometry.below(_f, g)
			if below >= 0:
				took += _draw(q, "h2o", below, want - took)
	if took > 0.0:
		water_in += took
	return took


## One channel, one cell, up to `want`. Decrements the LIVE mirror as graze() does.
func _draw(q, channel: String, c: int, want: float) -> float:
	if want <= 0.0 or c < 0 or _f._h2o.size() != _f._cell_count:
		return 0.0
	var have: float = _f._queries.liquid_at(c)
	if have <= 0.0:
		return 0.0
	var take: float = minf(want, have)
	_f._h2o[c] = maxf(0.0, _f._h2o[c] - take)
	q.transfer(channel, PackedInt32Array([c]), PackedFloat32Array([take]), channel, PackedInt32Array([-1]))
	_shift(_stock, LAReactionBalance.channel_elements(channel), take, 1.0)
	exchanges += 1
	return take


# --- OUTPUT: matter leaving a body and entering the field -------------------------------------------------

## Oxidise body carbon in the O2 of the head cell. One mole of the cell's O2 becomes one mole of CO2 in
## place, so its oxygen is transformed rather than destroyed; the carbon comes out of the body.
func respire(head_pos: Vector3, mass: float) -> float:
	if mass <= 0.0:
		return 0.0
	var q = _queue()
	if q == null:
		return 0.0
	if _f._o2.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(head_pos)
	if c < 0 or _f._solid[c] != 0:
		return 0.0
	# Oxidation heat is part of the exchange, not an extra. With no cell volume the joules cannot be sized,
	# so the whole exchange is refused rather than booked with its heat silently zero.
	var m3: float = _f._grid.cell_volume(c) if _f._grid != null else -1.0
	if m3 <= 0.0:
		push_error("LAMaterialFieldBiota3D.respire: no cell volume, so respiration heat cannot be sized.")
		return 0.0
	var have: float = _f._o2[c]
	var want: float = minf(mass, maxf(0.0, have))
	if want <= 0.0:
		return 0.0
	var got: float = _give({"C": float(LAReactionBalance.channel_elements("co2")["C"])}, want, "plant_carbon")
	if got <= 0.0:
		return 0.0
	_f._o2[c] = have - got
	q.transfer("o2", PackedInt32Array([c]), PackedFloat32Array([got]), "co2", PackedInt32Array([c]))
	co2_out += got
	exchanges += 1
	# Respiration heat, by Hess's law over the same formation enthalpies the reaction table uses.
	var j: float = got * _respiration_j_per_o2_unit() * m3
	if j > 0.0 and _f.has_method("add_heat_energy"):
		_f.add_heat_energy(head_pos, j, HEAT_RADIUS)
	return got


func litter(world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0:
		return
	var q = _queue()
	if q == null:
		return
	var c: int = ground_cell(world_pos)
	if c < 0:
		return
	var got: float = _give(litter_comp(), mass, "plant_carbon")
	if got <= 0.0:
		return
	q.add("detritus", PackedInt32Array([c]), PackedFloat32Array([got]))
	if _f._detritus.size() == _f._cell_count:
		_f._detritus[c] += got          # keep the mirror in step until the next readback
	detritus_out += got
	exchanges += 1


## TRANSPIRE. Body water leaving as vapour — breath, sweat, the water in urine.
func transpire(world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0:
		return
	var q = _queue()
	if q == null:
		return
	if _f._h2o.size() != _f._cell_count:
		return
	# Breath and sweat go into the air around the animal. Its own cell is rock when it is standing on the
	# ground, so the open cell resting on that ground is where the vapour is.
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or _f._solid[c] != 0:
		c = ground_cell(world_pos)
	if c < 0:
		return
	var got: float = _give(LAReactionBalance.channel_elements("h2o"), mass, "drinking_water")
	if got <= 0.0:
		return
	q.add("h2o", PackedInt32Array([c]), PackedFloat32Array([got]))
	water_out += got
	exchanges += 1


## A body appeared. While the world is still seeding it is matter the planet is handed, declared at the
## seal; after the seal nothing sources it, so a stand-in makes it and books what it made.
func note_body(mass: float) -> void:
	if mass <= 0.0 or _f == null or _f._seal == null:
		return
	var comp: Dictionary = litter_comp()
	if not _f._seal.sealed():
		_f._seal.note_creation("biota_body", mass)
		_shift(_stock, comp, mass, 1.0)
		return
	var got: float = LAFakes.draw("founding_stock", mass)
	if got > 0.0:
		_shift(_stood_in.get_or_add("founding_stock", {}), comp, got, 1.0)


func report() -> Dictionary:
	# `biota_exchanges` is the per-cell device edits this seam queued: zero with animals alive is a dead seam.
	var out: Dictionary = {"biota_graze_taken": graze_taken, "biota_co2_out": co2_out,
		"biota_detritus_out": detritus_out, "biota_water_in": water_in,
		"biota_water_out": water_out, "biota_exchanges": exchanges}
	for el in _stock:
		out["biota_stock_" + String(el)] = float(_stock[el])
	return out
