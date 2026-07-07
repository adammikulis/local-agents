class_name LAMaterialFungus3D
extends RefCounted

## LAMaterialFungus3D — the emergent DECOMPOSER step of the dense LAMaterialField3D, and the piece that
## CLOSES the carbon/nutrient loop. It owns the dynamics of two field-resident channels (`_f._detritus`,
## `_f._fungus`, per-cell PackedFloat32Arrays): dead organic matter (detritus) is colonised by fungus,
## which rots it back into CO₂ + soil FERTILITY while drawing down O₂ (aerobic decay). It holds NO
## authoritative grid state of its own (like MaterialGas3D / MaterialCombustion3D) — detritus + fungus live
## in the field so any source (a rotting carcass, wildfire ash) can DEPOSIT detritus and the ecology can
## read fungus for mushrooms — and it reaches into `_f` for the shared arrays (`_detritus`, `_fungus`,
## `_co2`, `_o2`, `_temp`, `_water`, `_vapor`, `_fire`, `_solid`) + geometry (`_dim_*`, `_cell_count`).
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted "spawn a mushroom on this corpse". Rot
## falls out of four local rules over the shared substrate:
##   GROWTH — a cell grows fungus where it has DETRITUS (food), MOISTURE (fungus loves damp: humidity/rain,
##     and rotting matter is itself wet) and SHADE/COOL (below a warm cap, not frozen, not on fire). Growth
##     is ∝ detritus × moisture, capped. So mushrooms bloom in the damp shade of a carcass, never on a
##     sun-baked or burning cell — no per-case code.
##   DECOMPOSITION (the loop-closer) — where fungus AND detritus coexist, fungus consumes detritus ∝
##     fungus × detritus and, conserved, deposits the freed carbon as CO₂ (`_f._co2`), adds soil FERTILITY
##     (via the scent module's `_fert`) and consumes O₂ (`_f._o2`, aerobic). This is the DEATH→SOIL leg: the
##     CO₂ feeds plant photosynthesis, the fertility seeds new plants — rot literally feeds regrowth.
##   SPREAD — spores: fungus colonises neighbouring cells that themselves hold detritus (gather form).
##   DEATH/DECAY — fungus dies back where its detritus is exhausted, or the cell gets too hot (fire/sun),
##     freezes, or dries out — so a bloom fades once the corpse is eaten or a wildfire sweeps through.
##
## CPU-ORACLE REFERENCE: fungus is a SLOW, sparse biological process (not a per-frame hot path), so the CPU
## module is the first-class, authoritative implementation (a genuine reference oracle, per CLAUDE.md — not
## debt). It steps on BOTH the headless and GPU-resident paths, AFTER combustion/gas (so it reads the fresh
## CO₂/O₂) and near scent (so its fertility composes with the soil channel). A fungus3d.glsl parity port is a
## legitimate follow-on if profiling ever wants it. (Explicit types only — no ':=' inferred typing.)

# --- Substrate thresholds --------------------------------------------------------------------------------
const DETRITUS_MIN: float = 0.05          # below this a cell holds no meaningful dead matter (diagnostics floor)
const FUNGUS_MIN: float = 0.02            # below this _fungus counts as none (no visible mushroom)
const FUNGUS_MAX: float = 3.0             # cap on fungal biomass per cell (high = a dense mushroom patch)

# --- Moisture (fungus loves damp). Combined from air humidity, active rain, and the dampness of the rotting
# matter itself (decomposing organic mass holds water), so a carcass stays a damp microclimate even in dry
# air — which is exactly where real fungus fruits. Below MOIST_MIN a cell reads as too dry to grow/sustain.
const MOIST_MIN: float = 0.02
const MOIST_REF: float = 0.06             # moisture at which the growth-rate factor saturates (damp = fast)
const VAPOR_MOIST: float = 1.0            # weight of local humidity (`_vapor`) in the moisture signal
const RAIN_MOIST: float = 0.5            # weight of active precipitation (a downpour damps everything)
const DETRITUS_DAMP: float = 0.15        # dampness contributed by the rotting matter itself (× clamped detritus)

# --- Temperature window. Fungus grows in cool shade; it dies scorched (fire/sun-baked) or frozen. ---------
const TEMP_WARM: float = 42.0             # °C above which a cell is too hot for fungus (sun-baked / near fire)
const TEMP_COLD: float = 0.0             # °C below which fungus freezes and dies
const FIRE_MIN: float = 0.02             # _fire above this is an actively burning cell (fungus can't live in fire)

# --- Rates (per step; kept slow — decomposition is geological/biological, not per-frame). -----------------
const GROW_RATE: float = 0.06            # fungal biomass grown per step ∝ detritus × moisture
const SPREAD: float = 0.02               # share of a neighbour's fungus that seeds spores onto this cell's detritus
const DECOMPOSE_RATE: float = 0.05       # detritus rotted per step ∝ fungus × detritus (the loop-closer)
const CO2_PER_DECOMPOSE: float = 1.0     # CO₂ released per unit detritus decomposed (freed carbon → carbon loop)
const O2_PER_DECOMPOSE: float = 0.8      # O₂ consumed per unit detritus decomposed (decay is aerobic)
const FERT_PER_DECOMPOSE: float = 1.5    # soil FERTILITY added per unit detritus decomposed (→ seeds new plants)
const DECAY: float = 0.02                # baseline fungus turnover per step where conditions hold
const DRY_DECAY: float = 0.06            # extra decay per step where the cell is too hot/frozen/dry or food is gone

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _scratch: PackedFloat32Array = PackedFloat32Array()  # fungus double buffer (gather writes here, then swap)
var _fungus_peak_last: float = 0.0                       # diagnostic: densest fungus after the last step
var _fungus_cells_last: int = 0                          # diagnostic: cells carrying meaningful fungus
var _detritus_peak_last: float = 0.0                     # diagnostic: most dead matter in any cell


func setup(field) -> void:
	_f = field
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## One fungus step (gather form; order-independent). Per non-solid cell:
##   1) GROW fungus where there is detritus + moisture + cool shade, plus spores gathered from neighbours,
##   2) DECOMPOSE detritus where fungus + detritus coexist → emit CO₂, draw O₂, deposit soil fertility,
##   3) DECAY the fungus (baseline, or faster where hot/frozen/dry/food-gone),
## writing the new fungus to a scratch buffer, then swapping it in. Runs AFTER combustion/gas so it reads the
## fresh CO₂/O₂ the fire kernel produced.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _f._detritus.size() != _f._cell_count:
		_f._detritus.resize(_f._cell_count)
	if _f._fungus.size() != _f._cell_count:
		_f._fungus.resize(_f._cell_count)
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)

	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var detritus: PackedFloat32Array = _f._detritus
	var fungus: PackedFloat32Array = _f._fungus
	var co2: PackedFloat32Array = _f._co2
	var o2: PackedFloat32Array = _f._o2
	var temp: PackedFloat32Array = _f._temp
	var vapor: PackedFloat32Array = _f._vapor
	var fire: PackedFloat32Array = _f._fire
	var solid: PackedByteArray = _f._solid
	var rain: float = _f.precipitation() if _f.has_method("precipitation") else 0.0
	var scent = _f._scent_sim
	var can_fert: bool = scent != null and scent.has_method("deposit_fertility")

	var peak_g: float = 0.0
	var n_g: int = 0
	var peak_d: float = 0.0

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_scratch[i] = 0.0
					continue
				var d: float = detritus[i]
				var g: float = fungus[i]
				# Moisture: air humidity + active rain + the dampness of the rotting matter itself.
				var moist: float = VAPOR_MOIST * vapor[i] + RAIN_MOIST * rain + DETRITUS_DAMP * clampf(d, 0.0, 1.0)
				var t: float = temp[i]
				var scorched: bool = t > TEMP_WARM or fire[i] > FIRE_MIN
				var frozen: bool = t < TEMP_COLD
				var dry: bool = moist < MOIST_MIN
				var favourable: bool = d > DETRITUS_MIN and not scorched and not frozen and not dry
				var gnew: float = g
				# 1) GROWTH + SPREAD — only on damp, cool, detritus-bearing cells.
				if favourable:
					var mfac: float = clampf(moist / MOIST_REF, 0.0, 1.0)
					gnew += GROW_RATE * d * mfac
					# Spores: gather a share of each open neighbour's fungus onto this cell's dead matter.
					var spore: float = 0.0
					if ix > 0 and solid[i - 1] == 0:
						spore += fungus[i - 1]
					if ix < dx - 1 and solid[i + 1] == 0:
						spore += fungus[i + 1]
					if iz > 0 and solid[i - dx] == 0:
						spore += fungus[i - dx]
					if iz < dz - 1 and solid[i + dx] == 0:
						spore += fungus[i + dx]
					if iy > 0 and solid[i - layer] == 0:
						spore += fungus[i - layer]
					if iy < dy - 1 and solid[i + layer] == 0:
						spore += fungus[i + layer]
					gnew += SPREAD * spore
				if gnew > FUNGUS_MAX:
					gnew = FUNGUS_MAX
				# 2) DECOMPOSITION (the loop-closer) — fungus rots detritus into CO₂ + fertility, drawing O₂.
				if g > FUNGUS_MIN and d > DETRITUS_MIN:
					var consumed: float = DECOMPOSE_RATE * g * d
					if consumed > d:
						consumed = d
					# Aerobic: never rot more than the available O₂ supports.
					if O2_PER_DECOMPOSE > 0.0:
						var o2_cap: float = o2[i] / O2_PER_DECOMPOSE
						if consumed > o2_cap:
							consumed = o2_cap
					if consumed > 0.0:
						detritus[i] = d - consumed
						d = detritus[i]
						co2[i] += CO2_PER_DECOMPOSE * consumed
						o2[i] = maxf(0.0, o2[i] - O2_PER_DECOMPOSE * consumed)
						if can_fert:
							scent.deposit_fertility(_f.cell_world_pos(ix, iy, iz), FERT_PER_DECOMPOSE * consumed)
				# 3) DEATH / DECAY — dies back fast where hot/frozen/dry or the food is exhausted.
				if scorched or frozen or dry or d <= DETRITUS_MIN:
					gnew -= DRY_DECAY * gnew
				else:
					gnew -= DECAY * gnew
				gnew = maxf(0.0, gnew)
				_scratch[i] = gnew
				if gnew > peak_g:
					peak_g = gnew
				if gnew > FUNGUS_MIN:
					n_g += 1
				if d > peak_d:
					peak_d = d

	var tmp: PackedFloat32Array = _f._fungus
	_f._fungus = _scratch
	_scratch = tmp
	_fungus_peak_last = peak_g
	_fungus_cells_last = n_g
	_detritus_peak_last = peak_d


## GPU-PATH TAIL: the grow/decompose/spread/decay CA now runs on the GPU (fungus3d.glsl + the per-column
## fertility reduce fungus_fert3d.glsl inside LAMaterialGPU3D.step()); the field uploads _fungus/_detritus into
## the resident buffers and reads them back (co2/o2 round-trip too). So on the GPU path step() is replaced by
## this diagnostics-only refresh over the fresh post-readback _fungus/_detritus (SMOKE_SUMMARY/HUD). Staggered
## by the field (fungus is a slow biological process), so it need not scan every frame.
func refresh_diagnostics_from_field() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _f._fungus.size() != _f._cell_count or _f._detritus.size() != _f._cell_count:
		return
	var fungus: PackedFloat32Array = _f._fungus
	var detritus: PackedFloat32Array = _f._detritus
	var peak_g: float = 0.0
	var n_g: int = 0
	var peak_d: float = 0.0
	for i in range(_f._cell_count):
		var g: float = fungus[i]
		if g > peak_g:
			peak_g = g
		if g > FUNGUS_MIN:
			n_g += 1
		var d: float = detritus[i]
		if d > peak_d:
			peak_d = d
	_fungus_peak_last = peak_g
	_fungus_cells_last = n_g
	_detritus_peak_last = peak_d


# --- Read API + diagnostics ------------------------------------------------------------------------------

## Fungal biomass at a world point (0 off-grid or inside rock) — the ecology reads this to fruit mushrooms.
func fungus_at(x: float, y: float, z: float) -> float:
	if _f == null or _f._cell_count <= 0:
		return 0.0
	var ix: int = _f._col_i(x, _f._origin.x)
	var iy: int = clampi(int(round((y - _f._origin.y) / _f._cell_size)), 0, _f._dim_y - 1)
	var iz: int = _f._col_i(z, _f._origin.z)
	if not _f._in_bounds(ix, iy, iz):
		return 0.0
	var i: int = _f._idx(ix, iy, iz)
	if _f._solid[i] != 0:
		return 0.0
	return _f._fungus[i]


## Densest fungus in any cell after the last step (SMOKE_SUMMARY `fungus_peak`; >0 wherever rot has bloomed).
func fungus_peak() -> float:
	return _fungus_peak_last


## Cells carrying meaningful fungus (SMOKE_SUMMARY `fungus_cells`; proof the decomposer is live).
func fungus_cells() -> int:
	return _fungus_cells_last


## Most dead organic matter in any cell (SMOKE_SUMMARY `detritus_peak`; >0 wherever a carcass/ash deposited it).
func detritus_peak() -> float:
	return _detritus_peak_last
