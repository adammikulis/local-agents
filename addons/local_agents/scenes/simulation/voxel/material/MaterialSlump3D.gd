class_name LAMaterialSlump3D
extends RefCounted

## LAMaterialSlump3D — the 3D GRANULAR-SLUMP (landslide) step of the dense LAMaterialField3D. Sediment is
## LOOSE, COLD granular mass (rock shaken free of the terrain, impact debris, crater-rim spoil) that lives
## as a per-cell amount in the shared `_f._sediment` array. It runs the SAME finite-volume cellular flow
## the water + lava CAs use (LAMaterialField3D.step_water / MaterialLava3D._flow via `_f._stable_below`) —
## gravity DOWN, then a LATERAL level-out, then UP under pressure — with ONE change that makes it granular
## instead of liquid: the lateral pass is gated by the ANGLE OF REPOSE. Sediment only creeps sideways to a
## lower neighbour when the per-cell mass (height) difference EXCEEDS the repose threshold REPOSE_TAN; below
## that the slope is stable and nothing moves, so a heap settles into a CONE at the repose angle instead of
## flattening like a fluid. Oversteep crater walls therefore slump inward, and impact debris piles at the
## base — all emergent from this one local rule (no per-crater / per-slide code).
##
## Two other responsibilities, both CPU-only (they touch the terrain SDF, which the GPU kernel can't):
##   disturb(world_pos, radius, strength): carve a chunk of SOLID terrain into loose sediment — carve the
##     SDF once, resample the rock mask, then seed the removed rock volume as `_sediment` so it flows + repiles.
##   settle(): sediment that has come to REST (can't fall, no lateral repose-flow pending) re-solidifies back
##     into the terrain SDF (throttled), so a slump leaves permanent NEW ground — not a floating pile.
##
## The flow math is mirrored EXACTLY by kernels3d/slump3d.glsl (parity mandate — constants duplicated there
## with "must match" comments). The CPU loop stays the correctness oracle + the headless/no-GPU path.
## It holds NO grid state of its own beyond a scratch double-buffer + a settle cursor; everything else is
## reached through the owning field (`_f`).
## (Explicit types only — no ':=' inferred typing.)

# --- Granular 3D flow tuning. Mirrors the water/lava CA (shares `_f._stable_below`, MAX_MASS, MAX_COMPRESS)
# but the lateral pass carries a REPOSE gate instead of a pure viscosity cap. --------------------------
const MAX_MASS: float = 1.0               # a cell is "full" of sediment at this mass (must match MaterialField3D)
const SLUMP_MAX_FLOW: float = 0.5         # max mass moved out of a cell per step (water 1.0, lava 0.25)
const SLUMP_MIN_MASS: float = 0.0001      # below this a cell holds no sediment
const SLUMP_MIN_FLOW: float = 0.01        # ignore dribbles smaller than this
const SLUMP_LATERAL_FRACTION: float = 0.25 # share of the OVER-repose excess sent to each lateral neighbour
# Angle of repose expressed as a per-cell mass-height difference: a full cell (mass 1) is one cell_size tall,
# so a mass difference d between neighbours == a surface slope of atan(d) over one cell. REPOSE_TAN = tan(θ):
# 0.70 ≈ 35° (a natural repose angle for loose rock/gravel). Sediment creeps laterally ONLY when the mass
# difference EXCEEDS this, and only the EXCESS moves — so a pile relaxes exactly to the repose slope, then stops.
const REPOSE_TAN: float = 0.70

# --- disturb() + settle() (terrain-SDF touches, CPU only) --------------------
const DISTURB_YIELD: float = 1.0          # loose sediment seeded per cell of solid rock the disturbance frees
const SETTLE_STAMP_MIN: float = 0.15      # at-rest sediment at/above this re-solidifies into terrain
const SETTLE_FULL_EPS: float = 0.01       # the cell below counts as "full" (blocks further fall) within this of MAX_MASS
const SETTLE_MAX_EDITS: int = 48          # cap terrain re-solidify stamps per step (cursor-rotated, like lava)
const SDF_STAMP_SCALE: float = 0.62       # stamp radius as a fraction of cell size (must match MaterialLava3D)

var _f = null                             # back-reference to the owning LAMaterialField3D
var _scratch: PackedFloat32Array = PackedFloat32Array()   # sediment double buffer (mass-conserving flow)
var _settle_cursor: int = 0               # rotating scan cursor for capped settle stamps
var _moving_last: int = 0                 # diagnostic: cells that sent sediment on the last flow step


func setup(field) -> void:
	_f = field
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## One granular-slump step: viscous 3D redistribution (down / lateral-gated-by-repose / up), mass-conserving
## via the `_scratch` double buffer (every transfer edits `_scratch` while reads stay on the stable
## `_f._sediment` snapshot, then the buffers swap). Settling back into terrain is SEPARATE (settle(), called
## by the field on both the CPU and GPU paths) so the flow stays a pure, GPU-mirrorable per-cell rule.
func step() -> void:
	if _f == null:
		return
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	_flow()


# --- Granular 3D flow (mirrored by slump3d.glsl) ----------------------------

## Redistribute sediment one step with the finite-volume rule: gravity DOWN (fill bottom-up via
## `_stable_below`), a LATERAL level-out GATED by the angle of repose (only the mass-height excess over
## REPOSE_TAN creeps to a lower neighbour), then UP overflow under pressure. Heat does NOT ride with it
## (sediment is cold — this is the one thing that differs from lava's `_flow`, besides the repose gate).
func _flow() -> void:
	var sed: PackedFloat32Array = _f._sediment
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var full: float = MAX_MASS
	var moving: int = 0

	for i in range(_f._cell_count):
		_scratch[i] = sed[i]

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var remaining: float = sed[i]
				if remaining < SLUMP_MIN_MASS:
					continue
				var sent_any: bool = false

				# 1) DOWN — gravity. Pour toward the stable split with the (non-solid) cell below. Debris
				# falls straight down a crater wall / cliff into the void until it hits solid ground or a
				# full sediment stack, so a pile grows bottom-up at the base of the slope.
				if iy > 0:
					var ib: int = i - layer
					if solid[ib] == 0:
						var dflow: float = _f._stable_below(remaining + sed[ib]) - sed[ib]
						dflow = clampf(dflow, 0.0, minf(SLUMP_MAX_FLOW, remaining))
						if dflow > SLUMP_MIN_FLOW:
							_scratch[i] -= dflow
							_scratch[ib] += dflow
							remaining -= dflow
							sent_any = true
				if remaining < SLUMP_MIN_MASS:
					if sent_any:
						moving += 1
					continue

				# 2) LATERAL — REPOSE-GATED level-out with the 4 side neighbours. Only push to a lower
				# neighbour, and only the mass EXCESS over the repose threshold: (diff - REPOSE_TAN). Below
				# the threshold the local slope is at/under the angle of repose and the grain stack is stable,
				# so nothing moves — that is what freezes a heap into a cone instead of a puddle.
				var lat: Array = [
					[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1]
				]
				for pr in lat:
					if remaining < SLUMP_MIN_MASS:
						break
					var nx: int = pr[0]
					var nz: int = pr[1]
					if nx < 0 or nx >= dx or nz < 0 or nz >= dz:
						continue
					var inb: int = (iy * dz + nz) * dx + nx
					if solid[inb] != 0:
						continue
					var diff: float = remaining - sed[inb]
					if diff > REPOSE_TAN:
						var excess: float = diff - REPOSE_TAN
						var lflow: float = clampf(excess * SLUMP_LATERAL_FRACTION, 0.0, minf(SLUMP_MAX_FLOW, remaining))
						if lflow > SLUMP_MIN_FLOW:
							_scratch[i] -= lflow
							_scratch[inb] += lflow
							remaining -= lflow
							sent_any = true

				# 3) UP — only overflow (compressed above a full cell) presses into the cell above, so a
				# sediment column that over-filled a pocket rises and connected fill finds a level.
				if remaining > full and iy < dy - 1:
					var iu: int = i + layer
					if solid[iu] == 0:
						var uflow: float = remaining - _f._stable_below(remaining + sed[iu])
						uflow = clampf(uflow, 0.0, minf(SLUMP_MAX_FLOW, remaining))
						if uflow > SLUMP_MIN_FLOW:
							_scratch[i] -= uflow
							_scratch[iu] += uflow
							remaining -= uflow
							sent_any = true

				if sent_any:
					moving += 1

	# Commit: swap the buffers (the old sediment array becomes next step's scratch).
	var tmp: PackedFloat32Array = _f._sediment
	_f._sediment = _scratch
	_scratch = tmp
	_moving_last = moving


# --- disturb(): carve solid terrain into loose sediment (CPU only) ----------

## Shake a chunk of ground loose: carve the terrain SDF once over the disturbance sphere, resample the rock
## mask so the field sees the new void, then seed the FREED rock volume as loose `_sediment` in exactly the
## cells that went solid->void — mass in ≈ rock removed. That sediment then flows + repiles under the rule
## above (crater walls slump inward, debris cones at the base). `strength` scales nothing here — the caller
## bakes intensity into `radius`; a no-op without a carvable terrain (mass has nowhere to come from).
func disturb(world_pos: Vector3, radius: float, _strength: float) -> void:
	if _f == null or _f._terrain == null:
		return
	if not _f._terrain.has_method("carve_sphere"):
		return
	var cs: float = _f._cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var ci: int = _f._col_i(world_pos.x, _f._origin.x)
	var cj: int = clampi(int(round((world_pos.y - _f._origin.y) / cs)), 0, _f._dim_y - 1)
	var ck: int = _f._col_i(world_pos.z, _f._origin.z)
	var r2: float = radius * radius

	# 1) Snapshot which cells in the region are SOLID right now (before the carve).
	var was_solid: Dictionary = {}
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _f._dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _f._dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _f._dim_x:
					continue
				var i: int = _f._idx(ix, iy, iz)
				if _f._solid[i] != 0:
					was_solid[i] = true

	# 2) Carve the SDF once + resync the rock mask over the region.
	_f._terrain.carve_sphere(world_pos, radius)
	_f.resample_terrain(world_pos, radius)

	# 3) Seed the removed rock volume as loose sediment (cells that were solid and are now void, in radius).
	for dj in range(-cells, cells + 1):
		var iy2: int = cj + dj
		if iy2 < 0 or iy2 >= _f._dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz2: int = ck + dk
			if iz2 < 0 or iz2 >= _f._dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix2: int = ci + di
				if ix2 < 0 or ix2 >= _f._dim_x:
					continue
				var i2: int = _f._idx(ix2, iy2, iz2)
				if not was_solid.has(i2):
					continue
				if _f._solid[i2] != 0:
					continue                          # still solid (outside the carve sphere)
				if _f.cell_world_pos(ix2, iy2, iz2).distance_squared_to(world_pos) > r2:
					continue
				_f._sediment[i2] = _f._sediment[i2] + DISTURB_YIELD


# --- settle(): at-rest sediment re-solidifies into terrain (CPU only) -------

## Sediment that has come to REST re-integrates into the terrain SDF so a slump leaves permanent new ground.
## A cell is at rest when it can neither FALL (the cell below is solid or a full sediment stack) nor creep
## LATERALLY (no side neighbour is low enough to exceed the repose threshold). Such a cell is stamped into the
## terrain (a small SDF sphere, like cooled lava becoming basalt), marked solid, and its sediment zeroed.
## Throttled + cursor-rotated (SETTLE_MAX_EDITS/step) so it never edits the whole map in one frame; when the
## GPU path is live and any cell solidified, the (now-changed) rock mask is re-pushed to the resident buffers.
func settle() -> void:
	if _f == null:
		return
	var can_stamp: bool = _f._terrain != null and _f._terrain.has_method("fill_sphere")
	if not can_stamp:
		return
	var sed: PackedFloat32Array = _f._sediment
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var dy: int = _f._dim_y
	var layer: int = dx * dz
	var edits: int = 0
	var scanned: int = 0
	var stamped: int = 0
	while scanned < _f._cell_count and edits < SETTLE_MAX_EDITS:
		var i: int = _settle_cursor
		_settle_cursor += 1
		if _settle_cursor >= _f._cell_count:
			_settle_cursor = 0
		scanned += 1
		if solid[i] != 0:
			continue
		var m: float = sed[i]
		if m < SLUMP_MIN_MASS:
			continue
		var iy: int = i / layer
		var rem_i: int = i - iy * layer
		var iz: int = rem_i / dx
		var ix: int = rem_i - iz * dx
		# Still able to FALL? (below is void and not a full stack) — not at rest.
		if iy > 0:
			var ib: int = i - layer
			if solid[ib] == 0 and sed[ib] < MAX_MASS - SETTLE_FULL_EPS:
				continue
		# Still a lateral REPOSE-flow pending toward a lower neighbour? — not at rest.
		var pending: bool = false
		if ix - 1 >= 0 and solid[i - 1] == 0 and m - sed[i - 1] > REPOSE_TAN:
			pending = true
		elif ix + 1 < dx and solid[i + 1] == 0 and m - sed[i + 1] > REPOSE_TAN:
			pending = true
		elif iz - 1 >= 0 and solid[i - dx] == 0 and m - sed[i - dx] > REPOSE_TAN:
			pending = true
		elif iz + 1 < dz and solid[i + dx] == 0 and m - sed[i + dx] > REPOSE_TAN:
			pending = true
		if pending:
			continue
		# At rest. A meaningful pile (>= SETTLE_STAMP_MIN) re-solidifies into new terrain; a negligible thin
		# scatter below that is simply absorbed (dropped) so the loose-sediment count decays cleanly to 0
		# instead of leaving a permanent sub-cell fringe — cheaper than stamping a tiny SDF blob for each grain.
		if m >= SETTLE_STAMP_MIN:
			solid[i] = 1
			sed[i] = 0.0
			_f._terrain.fill_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
			stamped += 1
		else:
			sed[i] = 0.0
		edits += 1
	if stamped > 0 and _f._use_gpu and _f._gpu != null:
		# The rock mask changed — re-push it so the resident GPU buffers block fluid/sediment in the new rock.
		_f._gpu.upload_static_state(_f._solid, _f._static)


# --- Diagnostics ------------------------------------------------------------

## Cells holding loose sediment actively slumping this step (a landslide is live while this is > 0; it decays
## to 0 as the debris comes to rest and settle() re-solidifies it into permanent ground). Works on both the
## CPU and GPU paths (reads the shared `_f._sediment`, which the GPU path reads back each frame).
func active_count() -> int:
	if _f == null:
		return 0
	var n: int = 0
	var sed: PackedFloat32Array = _f._sediment
	for i in range(_f._cell_count):
		if sed[i] >= SLUMP_MIN_MASS:
			n += 1
	return n


func total_sediment() -> float:
	if _f == null:
		return 0.0
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _f._sediment[i]
	return s
