class_name LAMaterialGas3D
extends RefCounted

## LAMaterialGas3D — the emergent ATMOSPHERIC GAS (OXYGEN) step of the dense LAMaterialField3D, and the
## first brick of a chemistry/biosphere model. It owns the dynamics of the field-resident O₂ channel
## (`_f._o2`, a per-cell PackedFloat32Array): oxygen DIFFUSES to open neighbours, ADVECTS on the real
## per-cell wind (`_f._vel_*`), and is REPLENISHED FROM THE SKY only at each column's sky-exposed surface
## cell (`_f._surface_iy`, the topmost open cell, open to the atmosphere). It holds NO authoritative grid
## state of its own (like MaterialCombustion3D / MaterialDust3D) — O₂ lives in the field so the fire kernel
## can read/consume it — and it reaches into `_f` for the shared arrays (`_o2`, `_solid`, `_vel_x/_y/_z`),
## the geometry (`_dim_*`, `_cell_size`, `_origin`, `_cell_count`, `STEP_DT`) and `precipitation()`.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO "cave sealed?" test anywhere. Fire suffocating in a
## sealed cavern while it roars in the open falls out of TWO local rules coupling this channel to combustion:
##   1) TRANSPORT — O₂ diffuses to its 6 OPEN neighbours + rides the local wind (gather form; each cell reads
##      its neighbours and writes only itself, so it is order-independent and a future gas3d.glsl port is
##      bit-for-bit). Rock neighbours donate/receive nothing, so O₂ CANNOT route through a cave's stone shell.
##   2) SKY EXCHANGE — only the column's SKY-EXPOSED surface cell relaxes toward O2_AMBIENT (the open air
##      above breathes). A sealed cave has NO open diffusion path to any sky cell, so once combustion draws
##      its trapped O₂ down below the fire's O2_MIN gate the fire suffocates — emergent, never scripted. An
##      open/windy fire gets O₂ diffused + advected back in from the connected air column, so it roars.
##
## Combustion (LAMaterialCombustion3D + kernels3d/fire3d.glsl) is the CONSUMER: a burning cell subtracts
## BURN_O2_RATE·fire from its own `_f._o2` each step and cannot ignite / is extinguished below O2_MIN. This
## module never reads fire — it just keeps the O₂ field flowing, so the coupling composes for free.
##
## CPU-ORACLE REFERENCE: like scent/charge this steps on the CPU on BOTH the headless and GPU-resident paths
## (the combustion O₂-consume + gate is what runs on-device in fire3d.glsl; the CONTINUOUS O₂ transport is a
## future gas3d.glsl parity port). (Explicit types only — no ':=' inferred typing.)

# --- Ambient + transport tuning. Kept so a cell's TOTAL outflow share stays < 1 (stable, mass-aware gather).
const O2_AMBIENT: float = 1.0             # sky/open-air oxygen level (MUST match LAMaterialField3D.O2_AMBIENT seed)
const DIFFUSE: float = 0.12               # symmetric share sent to each OPEN 6-neighbour per step (Laplacian)
const ADVECT: float = 0.08                # extra downwind share (× clamped wind toward the neighbour)
const WIND_REF: float = 6.0               # wind speed at which the advective share saturates (== dust/scent)
const SKY_EXCHANGE: float = 0.5           # fraction the sky-exposed surface cell relaxes toward O2_AMBIENT/step
const O2_MIN_DIAG: float = 0.001          # below this an open cell reads as effectively empty (diagnostics floor)

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _scratch: PackedFloat32Array = PackedFloat32Array()  # transport double buffer (gather writes here, then swap)
var _min_open_last: float = O2_AMBIENT                   # diagnostic: lowest O₂ in any open cell after the last step
var _avg_last: float = O2_AMBIENT                        # diagnostic: mean O₂ over open cells after the last step


func setup(field) -> void:
	_f = field
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## One O₂ step. Runs AFTER the wind step (it needs the fresh per-cell velocity) and around combustion:
##   1) GATHER-transport `_f._o2` into `_scratch` (diffusion + wind advection, mass-aware pairwise shares),
##   2) swap the buffer in,
##   3) SKY EXCHANGE — relax each column's sky-exposed surface cell toward O2_AMBIENT (the atmosphere breathes),
## then refresh the min-open / average diagnostics. Order-independent (gather form), so a GPU port is exact.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _f._o2.size() != _f._cell_count:
		_f._o2.resize(_f._cell_count)
		_f._o2.fill(O2_AMBIENT)
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	_transport()
	_sky_exchange()
	_refresh_diagnostics()


# --- Rule 1: TRANSPORT — diffusion + wind advection (mass-conserving pairwise gather) ------------------

## Move `_f._o2` one step in GATHER form: each open cell keeps its un-emitted fraction, then sums the shares
## flowing in from its 6 OPEN neighbours (a symmetric diffusion share + a downwind advection share scaled by
## the neighbour's wind blowing TOWARD this cell). A rock/boundary neighbour contributes nothing AND is not
## sent to — the outflow share drops for that direction — so O₂ never crosses stone: this is what seals caves.
func _transport() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var o2: PackedFloat32Array = _f._o2
	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_scratch[i] = 0.0
					continue
				var has_e: bool = ix < dx - 1 and solid[i + 1] == 0
				var has_w: bool = ix > 0 and solid[i - 1] == 0
				var has_s: bool = iz < dz - 1 and solid[i + dx] == 0
				var has_n: bool = iz > 0 and solid[i - dx] == 0
				var has_u: bool = iy < dy - 1 and solid[i + layer] == 0
				var has_d: bool = iy > 0 and solid[i - layer] == 0
				# Outflow shares to each OPEN neighbour (diffusion + wind blowing that way).
				var out_e: float = _share(maxf(0.0, vx[i])) if has_e else 0.0
				var out_w: float = _share(maxf(0.0, -vx[i])) if has_w else 0.0
				var out_s: float = _share(maxf(0.0, vz[i])) if has_s else 0.0
				var out_n: float = _share(maxf(0.0, -vz[i])) if has_n else 0.0
				var out_u: float = _share(maxf(0.0, vy[i])) if has_u else 0.0
				var out_d: float = _share(maxf(0.0, -vy[i])) if has_d else 0.0
				var keep: float = 1.0 - (out_e + out_w + out_s + out_n + out_u + out_d)
				var acc: float = o2[i] * keep
				# Inflow: each neighbour's share flowing TOWARD this cell (its wind toward us + diffusion).
				if has_e: acc += o2[i + 1] * _share(maxf(0.0, -vx[i + 1]))
				if has_w: acc += o2[i - 1] * _share(maxf(0.0, vx[i - 1]))
				if has_s: acc += o2[i + dx] * _share(maxf(0.0, -vz[i + dx]))
				if has_n: acc += o2[i - dx] * _share(maxf(0.0, vz[i - dx]))
				if has_u: acc += o2[i + layer] * _share(maxf(0.0, -vy[i + layer]))
				if has_d: acc += o2[i - layer] * _share(maxf(0.0, vy[i - layer]))
				_scratch[i] = maxf(0.0, acc)
	var tmp: PackedFloat32Array = _f._o2
	_f._o2 = _scratch
	_scratch = tmp


# Outflow/inflow share toward a neighbour the wind blows toward at speed `away` (>=0): diffusion + advection.
func _share(away: float) -> float:
	return DIFFUSE + ADVECT * clampf(away / WIND_REF, 0.0, 1.0)


# --- Rule 2: SKY EXCHANGE — the open atmosphere replenishes O₂ at each column's sky-exposed surface cell.
## Relax the TOPMOST open cell of every column toward O2_AMBIENT. That cell is open to the atmosphere; a
## sealed cave's cells are never a surface cell, so they get NO replenishment — the emergent suffocation seal.
func _sky_exchange() -> void:
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var o2: PackedFloat32Array = _f._o2
	for iz in range(dz):
		for ix in range(dx):
			var siy: int = _f._surface_iy(ix, iz)
			if siy < 0:
				continue
			var si: int = (siy * dz + iz) * dx + ix
			o2[si] += SKY_EXCHANGE * (O2_AMBIENT - o2[si])


# --- Diagnostics (SMOKE_SUMMARY) -----------------------------------------------------------------------

func _refresh_diagnostics() -> void:
	var o2: PackedFloat32Array = _f._o2
	var solid: PackedByteArray = _f._solid
	var mn: float = O2_AMBIENT
	var sum: float = 0.0
	var n: int = 0
	for i in range(_f._cell_count):
		if solid[i] != 0:
			continue
		var v: float = o2[i]
		if v < mn:
			mn = v
		sum += v
		n += 1
	_min_open_last = mn
	_avg_last = (sum / float(n)) if n > 0 else O2_AMBIENT


## Lowest O₂ in any OPEN cell after the last step — proof O₂ depletes where fire consumes it (SMOKE_SUMMARY
## `o2_min`; well below O2_AMBIENT in a burning/sealed pocket, ~O2_AMBIENT in fresh open air).
func o2_min_open() -> float:
	return _min_open_last


## Mean O₂ over all open cells (mass-audit / HUD diagnostic; sits near O2_AMBIENT while the sky replenishes).
func o2_avg() -> float:
	return _avg_last


## O₂ level at a world point (0 outside the grid or inside rock) — for creatures breathing / future chemistry.
func o2_at(x: float, y: float, z: float) -> float:
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
	return _f._o2[i]
