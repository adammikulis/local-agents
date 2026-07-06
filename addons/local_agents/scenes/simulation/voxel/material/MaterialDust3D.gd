class_name LAMaterialDust3D
extends RefCounted

## LAMaterialDust3D — the 3D AIRBORNE DUST / SAND-STORM step of the dense LAMaterialField3D, and the
## engine of emergent DUNE MIGRATION. It mirrors the shape of LAMaterialCombustion3D / LAMaterialSlump3D:
## it holds NO authoritative FIELD state (the loose granular mass it lofts from / deposits back to is the
## shared `_f._sediment` channel that LAMaterialSlump3D flows to its angle of repose and re-solidifies) —
## the ONE thing it owns is the AIRBORNE dust density `_dust`, an in-module PackedFloat32Array (plus its
## advection double-buffer + a per-cell out-scale scratch), so the field file stays tiny. It reaches into
## `_f` for the shared arrays (`_sediment`, `_water`, `_solid`, `_vel_x/_vel_y/_vel_z`), the geometry
## (`_dim_*`, `_cell_size`, `_origin`, `_cell_count`, `STEP_DT`) and `precipitation()`.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there are NO scripted dust storms and NO scripted dunes. Both
## fall out of three LOCAL rules coupling the loose-sediment channel to the emergent wind:
##   1) LOFT — a surface sediment cell (loose `_sediment` present, an OPEN air cell directly above) whose
##      HORIZONTAL wind speed exceeds LOFT_WIND lifts a little sediment into the airborne `_dust` of the
##      cell above, scaled by how far the wind exceeds the threshold. The lift is gated DRY: a WET cell
##      (standing water) or ANY rain (`precipitation()`) suppresses it — so rain kills a dust storm and
##      wet sand never blows, for free. Mass is REMOVED from `_sediment` as it enters `_dust`.
##   2) ADVECT + DIFFUSE + SETTLE — `_dust` is transported by the real per-cell wind (`_vel_x/_y/_z`) with
##      a mass-conserving donor-cell flux (GATHER form: every cell reads its neighbours and writes only
##      itself, so it is order-independent and a future GPU port is bit-for-bit), spreads a little by
##      diffusion, and always feels a gentle GRAVITY settling that is STRONG in calm air and suppressed in
##      strong wind. Dust that settles onto solid ground is DEPOSITED back into `_f._sediment`. Because
##      lofting dominates where wind is strong (the windward face) and deposition dominates where wind is
##      weak (the sheltered leeward pocket), loose material walks from windward to leeward → DUNES MIGRATE
##      DOWNWIND. No per-dune / per-storm code — just erosion + transport + deposition.
##   3) DECAY / SETTLE-OUT — when the wind drops the settling fraction rises toward its calm maximum, so an
##      airborne cloud falls out of the air over a few steps and returns to the ground as sediment.
##
## Mass is conserved end to end: every gram lofted leaves `_sediment`; advection/diffusion only shuffle
## `_dust` between air cells; every gram that settles is added back to `_sediment`. No SDF edits happen
## here — this module only moves the LOOSE `_sediment` channel around; LAMaterialSlump3D owns flowing it to
## repose and re-solidifying rested piles into permanent terrain. This is the CPU-oracle REFERENCE (there
## is no GLSL kernel yet); it is the headless/no-GPU path and the parity oracle for a future dust3d.glsl.
## (Explicit types only — no ':=' inferred typing.)

# --- Lofting: wind scours DRY loose sediment off an exposed surface into the air. -----------------------
const LOFT_WIND: float = 6.0              # horizontal wind speed (field units) a surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment mass lofted per step per unit of wind OVER the threshold
const LOFT_MAX: float = 0.05             # cap on sediment lofted from one cell per step (stability)
const SED_MIN: float = 0.0005            # below this a cell holds no meaningful loose sediment to loft
const WET_MAX: float = 0.05              # water mass above which a cell is WET and can't loft (must match MaterialCombustion3D)
const RAIN_MAX: float = 0.05             # precipitation() above which rain suppresses ALL lofting (emergent firebreak-for-dust)

# --- Airborne transport: mass-conserving donor-cell advection + diffusion + gravity settling. ----------
const OUT_MAX: float = 0.55              # cap on the TOTAL fraction of a cell's dust that leaves per step (CFL stability)
const DIFFUSE_RATE: float = 0.02         # symmetric Laplacian smoothing of `_dust` per open neighbour per step
const SETTLE_BASE: float = 0.25          # gravity settling fraction per step in DEAD-CALM air (dust falls out fast)
const SETTLE_MIN_FRAC: float = 0.02      # floor settling fraction even in the strongest wind (some always falls)
const SETTLE_WIND_REF: float = 6.0       # wind speed at which settling is fully suppressed (== LOFT_WIND: aloft while blowing)
const DUST_MIN: float = 0.0002           # below this airborne density counts as clear air (diagnostics threshold)

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _dust: PackedFloat32Array = PackedFloat32Array()     # airborne dust DENSITY per cell (the ONE channel we own)
var _scratch: PackedFloat32Array = PackedFloat32Array()  # advection double buffer (gather writes here, then swap)
var _outscale: PackedFloat32Array = PackedFloat32Array() # per-cell uniform out-flux scale (min(1, OUT_MAX/raw_total))
var _active_last: int = 0                                # diagnostic: airborne cells after the last step
var _peak_last: float = 0.0                              # diagnostic: peak airborne density after the last step


func setup(field) -> void:
	_f = field
	_dust = PackedFloat32Array()
	_dust.resize(_f._cell_count)
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)
	_outscale = PackedFloat32Array()
	_outscale.resize(_f._cell_count)


## One dust step. Runs AFTER the wind step (it needs the fresh per-cell velocity) and alongside slump:
##   1) LOFT dry surface sediment into `_dust` where the wind is strong enough (in place; each cell touches
##      only its own `_sediment` and the unique air cell above it, so it stays order-independent),
##   2) precompute the per-cell out-flux scale so the gather can read a neighbour's scaled flux directly,
##   3) GATHER-advect + diffuse + gravity-settle `_dust` into `_scratch`, DEPOSITING settled dust back into
##      `_f._sediment` where it reaches solid ground, then swap the buffer in.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _dust.size() != _f._cell_count:
		_dust.resize(_f._cell_count)
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	if _outscale.size() != _f._cell_count:
		_outscale.resize(_f._cell_count)
	_loft()
	_compute_outscale()
	_transport()


# --- Rule 1: LOFT — wind lifts DRY loose sediment into the air ------------------------------------------

## Scour dry, wind-exposed loose sediment into `_dust`. A cell lofts when it holds loose `_sediment`, has an
## OPEN air cell directly above (so wind can carry it away), is DRY (little standing water AND no rain), and
## its horizontal wind speed exceeds LOFT_WIND. The lofted mass is REMOVED from `_sediment` and injected
## into the air cell above — erosion of the windward face. In-place + per-cell-local (each cell edits only
## its own sediment and the unique cell above), so it is order-independent like the gather passes.
func _loft() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var sed: PackedFloat32Array = _f._sediment
	var water: PackedFloat32Array = _f._water
	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vz: PackedFloat32Array = _f._vel_z
	var raining: bool = _f.precipitation() > RAIN_MAX

	for iy in range(dy - 1):                              # top layer can't loft (no air cell above it)
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var m: float = sed[i]
				if m < SED_MIN:
					continue
				if water[i] > WET_MAX or raining:
					continue                              # WET sand / rain never blows (rain suppresses dust)
				var iu: int = i + layer
				if solid[iu] != 0:
					continue                              # buried — no open air above to carry the dust
				var hspeed: float = sqrt(vx[i] * vx[i] + vz[i] * vz[i])
				if hspeed <= LOFT_WIND:
					continue
				var amt: float = LOFT_RATE * (hspeed - LOFT_WIND)
				amt = minf(amt, LOFT_MAX)
				amt = minf(amt, m)
				if amt <= 0.0:
					continue
				sed[i] = m - amt
				_dust[iu] += amt


# --- Rule 2 setup: per-cell out-flux scale ------------------------------------------------------------

## Precompute, for every non-solid cell, the uniform scale that keeps its TOTAL outgoing dust fraction at or
## below OUT_MAX (CFL stability). The raw fractions are the wind Courant numbers toward each OPEN neighbour
## plus a gravity-settling fraction downward; a direction blocked by rock/boundary contributes nothing. The
## gather pass reads this so a neighbour's scaled donation is one lookup + one Courant recompute (no need to
## re-total the neighbour's six directions). Depends only on velocity + solid, so loft order is irrelevant.
func _compute_outscale() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z
	var k: float = _f.STEP_DT / _f._cell_size

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_outscale[i] = 0.0
					continue
				var total: float = _raw_out_total(i, ix, iy, iz, dx, dy, dz, layer, solid, vx, vy, vz, k)
				if total > OUT_MAX and total > 0.0:
					_outscale[i] = OUT_MAX / total
				else:
					_outscale[i] = 1.0


## Sum of a cell's RAW (unscaled) out-flux fractions: horizontal + upward wind Courant fractions toward each
## OPEN neighbour, plus the always-present downward settling flux `_fall_frac` (never blocked — it deposits
## into sediment when the cell below is solid). Duplicated logic feeds both the scale here and the retained
## fraction in the gather, so keep the two in lockstep.
func _raw_out_total(i: int, ix: int, iy: int, iz: int, dx: int, dy: int, dz: int, layer: int, solid: PackedByteArray, vx: PackedFloat32Array, vy: PackedFloat32Array, vz: PackedFloat32Array, k: float) -> float:
	var t: float = 0.0
	if ix < dx - 1 and solid[i + 1] == 0:
		t += maxf(0.0, vx[i]) * k
	if ix > 0 and solid[i - 1] == 0:
		t += maxf(0.0, -vx[i]) * k
	if iz < dz - 1 and solid[i + dx] == 0:
		t += maxf(0.0, vz[i]) * k
	if iz > 0 and solid[i - dx] == 0:
		t += maxf(0.0, -vz[i]) * k
	if iy < dy - 1 and solid[i + layer] == 0:
		t += maxf(0.0, vy[i]) * k                        # upward WIND advection (blocked into rock/ceiling)
	t += _fall_frac(i, vy, k)                            # downward: wind-down + gravity settling (never blocked)
	return t


## The downward flux fraction of a cell: the downward WIND Courant part plus a gravity SETTLING fraction
## that is largest in calm air (SETTLE_BASE) and falls to SETTLE_MIN_FRAC as the wind speed approaches
## SETTLE_WIND_REF. This is what makes dust hang in the air over the windward gale and RAIN OUT in the
## sheltered lee — the deposition half of dune migration, and the "settles out when the wind drops" decay.
func _fall_frac(i: int, vy: PackedFloat32Array, k: float) -> float:
	var vxi: float = _f._vel_x[i]
	var vyi: float = vy[i]
	var vzi: float = _f._vel_z[i]
	var speed: float = sqrt(vxi * vxi + vyi * vyi + vzi * vzi)
	var calm: float = clampf(1.0 - speed / SETTLE_WIND_REF, 0.0, 1.0)
	var settle: float = SETTLE_MIN_FRAC + (SETTLE_BASE - SETTLE_MIN_FRAC) * calm
	return maxf(0.0, -vyi) * k + settle


# --- Rule 2/3: ADVECT + DIFFUSE + gravity SETTLE (mass-conserving gather) ------------------------------

## Transport `_dust` one step in GATHER form: each non-solid cell keeps its un-emitted fraction, then sums
## the scaled donations flowing in from its six neighbours (each neighbour's wind/settling flux toward this
## cell), plus a small symmetric diffusion. The cell's OWN downward settling flux, when the cell below is
## SOLID, is DEPOSITED into `_f._sediment[i]` (dust returning to the ground as loose sand) instead of
## donating to a dust cell — this is the leeward accretion. Writes only `_scratch[i]` and this cell's own
## `_sediment[i]`, so it is order-independent and mass-conserving. Then the buffers swap.
func _transport() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z
	var sed: PackedFloat32Array = _f._sediment
	var dust: PackedFloat32Array = _dust
	var k: float = _f.STEP_DT / _f._cell_size
	var active: int = 0
	var peak: float = 0.0

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_scratch[i] = 0.0
					continue

				var di: float = dust[i]
				var scale_i: float = _outscale[i]

				# Retained fraction: dust that did NOT leave this cell this step.
				var out_total: float = _raw_out_total(i, ix, iy, iz, dx, dy, dz, layer, solid, vx, vy, vz, k) * scale_i
				var value: float = di * (1.0 - out_total)

				# Inflow: each neighbour's scaled flux flowing TOWARD this cell.
				if ix > 0 and solid[i - 1] == 0:
					var n: int = i - 1                    # -X neighbour blows toward +X (us)
					value += dust[n] * maxf(0.0, vx[n]) * k * _outscale[n]
				if ix < dx - 1 and solid[i + 1] == 0:
					var n2: int = i + 1                   # +X neighbour blows toward -X
					value += dust[n2] * maxf(0.0, -vx[n2]) * k * _outscale[n2]
				if iz > 0 and solid[i - dx] == 0:
					var n3: int = i - dx                  # -Z neighbour blows toward +Z
					value += dust[n3] * maxf(0.0, vz[n3]) * k * _outscale[n3]
				if iz < dz - 1 and solid[i + dx] == 0:
					var n4: int = i + dx                  # +Z neighbour blows toward -Z
					value += dust[n4] * maxf(0.0, -vz[n4]) * k * _outscale[n4]
				if iy > 0 and solid[i - layer] == 0:
					var nd: int = i - layer               # cell BELOW blows UP toward us
					value += dust[nd] * maxf(0.0, vy[nd]) * k * _outscale[nd]
				if iy < dy - 1 and solid[i + layer] == 0:
					var nu: int = i + layer               # cell ABOVE settles/blows DOWN toward us (whole fall flux)
					value += dust[nu] * _fall_frac(nu, vy, k) * _outscale[nu]

				# Symmetric diffusion (conservative): equalise a little with open neighbours.
				var diff: float = 0.0
				if ix > 0 and solid[i - 1] == 0:
					diff += dust[i - 1] - di
				if ix < dx - 1 and solid[i + 1] == 0:
					diff += dust[i + 1] - di
				if iz > 0 and solid[i - dx] == 0:
					diff += dust[i - dx] - di
				if iz < dz - 1 and solid[i + dx] == 0:
					diff += dust[i + dx] - di
				if iy > 0 and solid[i - layer] == 0:
					diff += dust[i - layer] - di
				if iy < dy - 1 and solid[i + layer] == 0:
					diff += dust[i + layer] - di
				value += DIFFUSE_RATE * diff

				# DEPOSIT: this cell's own downward flux that hits SOLID ground (or the floor) becomes loose
				# sediment here — dust falling back to earth. (If the cell below is OPEN the same flux was
				# already donated to that cell's dust as its "cell above" inflow, so it is not double-counted.)
				if di > 0.0 and (iy == 0 or solid[i - layer] != 0):
					var deposit: float = di * _fall_frac(i, vy, k) * scale_i
					if deposit > 0.0:
						sed[i] += deposit

				if value < 0.0:
					value = 0.0
				_scratch[i] = value
				if value >= DUST_MIN:
					active += 1
					if value > peak:
						peak = value

	# Commit: swap so queries read the fresh airborne state (old buffer becomes next step's scratch).
	var tmp: PackedFloat32Array = _dust
	_dust = _scratch
	_scratch = tmp
	_active_last = active
	_peak_last = peak


# --- Read queries + diagnostics -----------------------------------------------------------------------

## Airborne dust DENSITY at a world point (0 outside the grid or inside rock) — for a future volumetric /
## particle haze visual and for creatures choking in a sand storm (a breathing/comfort drive can read this).
func dust_at(x: float, y: float, z: float) -> float:
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
	return _dust[i]


## Cells currently holding airborne dust (a dust storm is live while this is > 0; it decays to 0 as the
## wind drops and the dust settles back into sediment). SMOKE_SUMMARY `dust_cells`.
func dust_cells() -> int:
	return _active_last


## Peak airborne dust density anywhere in the field after the last step (storm intensity diagnostic / HUD).
func dust_peak() -> float:
	return _peak_last


## Total airborne dust mass across the field (mass-audit diagnostic; pairs with slump's total_sediment()).
func total_dust() -> float:
	if _f == null:
		return 0.0
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _dust[i]
	return s
