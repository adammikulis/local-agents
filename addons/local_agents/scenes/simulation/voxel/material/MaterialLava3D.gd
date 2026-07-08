class_name LAMaterialLava3D
extends RefCounted

## LAMaterialLava3D — the 3D lava step of the dense LAMaterialField3D (generalises the 2.5D lava in
## LAMaterialLiquid to a real volume). Lava is a hot, viscous LIQUID that lives as a per-cell mass in
## the shared `_f._lava` array and runs the SAME finite-volume cellular flow the water CA uses
## (LAMaterialField3D.step_water / _stable_below), only with a much smaller flow cap (viscous → moves
## less per step). Because it flows in a real 3D volume, lava over a cave mouth pours DOWN through the
## void into the tube/cavern below and POOLS there — the 3D payoff the 2.5D field could never do.
##
## It holds NO grid state of its own beyond a scratch double-buffer + edit cursors; it reaches into the
## owning field (`_f`) for the shared arrays (`_lava`, `_temp`, `_solid`, `_water`), the geometry
## (`_dim_*`, `_cell_size`, `_origin`, `_cell_count`), the index/position helpers (`_idx`,
## `cell_world_pos`, `_col_i`), the pressure model (`_stable_below`, `MAX_MASS`) and the terrain SDF
## (`_terrain.fill_sphere` / `carve_sphere`). Nothing about glowing, crusting, quenching, or building a
## delta is scripted per-case: lava sustains its own molten heat, the heat module conducts it into the
## surrounding rock, and where a flow COOLS below SOLIDIFY_TEMP (a fringe crusting, a tongue meeting the
## sea) it FREEZES to solid rock and stamps that rock into the terrain — a hardened flow BUILDS terrain.
## (Explicit types only — no ':=' inferred typing.)

# --- Phase thresholds (shared with the 2.5D LAMaterialLiquid so the two lava sims read identically) --
const LAVA_EMPLACE_TEMP: float = 1150.0   # temperature fresh/thick lava carries (capped below MELT_TEMP)
const MOLTEN_FLOOR: float = 950.0         # any cell holding lava is kept at least this hot (glows + flows)
const SOLIDIFY_TEMP: float = 800.0        # lava whose cell has cooled below this freezes to rock
const MELT_TEMP: float = 1200.0           # rock this hot (a meteor / vent super-heat) melts back to lava

# --- Viscous 3D flow tuning. Mirrors the water CA (LAMaterialField3D.MAX_MASS / MAX_COMPRESS via the
# field's _stable_below) but with a SMALLER flow cap and lateral share so lava creeps instead of
# sloshing. Down-flow into non-solid cells below is what makes lava drain through a shaft into a cave.
const LAVA_MAX_FLOW: float = 0.25         # max mass moved out of a cell per step (water is 1.0 — lava is slow)
const LAVA_MIN_MASS: float = 0.0001       # below this a cell holds no lava
const LAVA_MIN_FLOW: float = 0.01         # ignore dribbles smaller than this
const LAVA_LATERAL_FRACTION: float = 0.25 # share of the level-out flow to each lateral neighbour (water 0.5)

# --- Heat sustain / phase-edit caps -----------------------------------------
const EMPLACE_DEPTH: float = 1.0          # lava mass at which a cell reaches LAVA_EMPLACE_TEMP
const SOLIDIFY_MAX_EDITS: int = 48        # cap solidify SDF stamps per step (cursor-rotated)
const MELT_MAX_EDITS: int = 24            # cap melt SDF carves per step (cursor-rotated)
const SDF_STAMP_SCALE: float = 0.9        # stamp/carve radius vs cell size — ≥ half the cell's 3D diagonal
                                          # (0.87) so adjacent per-cell sphere stamps fully UNION into a smooth
                                          # flow/dome instead of a lumpy "string of spheres" (was 0.62 → gaps).
const MELT_LAVA_YIELD: float = 0.7        # lava mass produced when a rock cell melts

var _f = null                             # back-reference to the owning LAMaterialField3D
var _scratch: PackedFloat32Array = PackedFloat32Array()   # lava double buffer (mass-conserving flow)
var _solidify_cursor: int = 0             # rotating scan cursor for capped solidify edits
var _melt_cursor: int = 0                 # rotating scan cursor for capped melt edits
var _lava_cells_last: int = 0             # diagnostic: lava cells after the last step
var _lava_peak: int = 0                   # diagnostic: most lava cells ever live at once


func setup(field) -> void:
	_f = field
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## One lava step, ordered so a flowing tongue never freezes on cold contact yet a genuinely COOLED cell
## still turns to rock:
##   1) FLOW — viscous 3D redistribution (down / lateral / up), carrying molten heat WITH the mass so a
##      leading tongue stays hot as it spreads onto cold ground (and drains DOWN into caves).
##   2) SOLIDIFY — any cell still holding lava but sitting below SOLIDIFY_TEMP (nothing kept it hot: a
##      crusting fringe, a tongue quenched where it met water, a force-cooled cell) freezes to rock.
##   3) SUSTAIN — the lava that remains is kept molten (depth-scaled), so pools glow and keep flowing.
##   4) MELT — rock super-heated past MELT_TEMP (a meteor/vent, NOT lava's own capped heat) gives way to
##      fresh lava. Capped + cursor-rotated so a step never edits the whole map.
func step() -> void:
	if _f == null:
		return
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	_flow()
	_solidify()
	_sustain_heat()
	_melt()
	_lava_cells_last = lava_cell_count()
	if _lava_cells_last > _lava_peak:
		_lava_peak = _lava_cells_last


# --- 1) Viscous 3D flow -----------------------------------------------------

## Redistribute lava one step with the water CA's finite-volume rule (gravity down, lateral level-out,
## up under pressure) but a viscous flow cap. Mass-conserving via the `_scratch` double buffer: every
## transfer edits `_scratch` while reads stay on the stable `_f._lava` snapshot, then the buffers swap.
## Heat travels WITH the mass — any cell that RECEIVES lava is pulled to at least MOLTEN_FLOOR so a
## tongue crossing cold rock does not freeze on contact (solidify below only bites cells nothing warms).
func _flow() -> void:
	var lava: PackedFloat32Array = _f._lava
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var full: float = _f.MAX_MASS

	for i in range(_f._cell_count):
		_scratch[i] = lava[i]

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var remaining: float = lava[i]
				if remaining < LAVA_MIN_MASS:
					continue

				# 1) DOWN — gravity. Pour toward the stable split with the (non-solid) cell below. This is
				# the 3D drain: a cave mouth under the flow is just a non-solid cell below, so lava falls
				# through the void into the tube/cavern and pools there.
				if iy > 0:
					var ib: int = i - layer
					if solid[ib] == 0:
						var dflow: float = _f._stable_below(remaining + lava[ib]) - lava[ib]
						dflow = clampf(dflow, 0.0, minf(LAVA_MAX_FLOW, remaining))
						if dflow > LAVA_MIN_FLOW:
							_scratch[i] -= dflow
							_scratch[ib] += dflow
							remaining -= dflow
							_carry_heat(ib)
				if remaining < LAVA_MIN_MASS:
					continue

				# 2) LATERAL — level out with the 4 side neighbours (only push to lower ones).
				var lat: Array = [
					[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1]
				]
				for pr in lat:
					if remaining < LAVA_MIN_MASS:
						break
					var nx: int = pr[0]
					var nz: int = pr[1]
					if nx < 0 or nx >= dx or nz < 0 or nz >= dz:
						continue
					var inb: int = (iy * dz + nz) * dx + nx
					if solid[inb] != 0:
						continue
					var diff: float = remaining - lava[inb]
					if diff > LAVA_MIN_FLOW:
						var lflow: float = clampf(diff * LAVA_LATERAL_FRACTION, 0.0, minf(LAVA_MAX_FLOW, remaining))
						if lflow > LAVA_MIN_FLOW:
							_scratch[i] -= lflow
							_scratch[inb] += lflow
							remaining -= lflow
							_carry_heat(inb)

				# 3) UP — only overflow (compressed above a full cell) presses into the cell above, so a
				# filling cavern rises bottom-up and connected pools find a level.
				if remaining > full and iy < dy - 1:
					var iu: int = i + layer
					if solid[iu] == 0:
						var uflow: float = remaining - _f._stable_below(remaining + lava[iu])
						uflow = clampf(uflow, 0.0, minf(LAVA_MAX_FLOW, remaining))
						if uflow > LAVA_MIN_FLOW:
							_scratch[i] -= uflow
							_scratch[iu] += uflow
							remaining -= uflow
							_carry_heat(iu)

	# Commit: swap the buffers (the old lava array becomes next step's scratch).
	var tmp: PackedFloat32Array = _f._lava
	_f._lava = _scratch
	_scratch = tmp


## Molten heat rides with a lava transfer: a cell that just received lava is pulled up to at least
## MOLTEN_FLOOR so the advancing front stays liquid instead of freezing the instant it touches cold rock.
func _carry_heat(dst: int) -> void:
	if _f._temp[dst] < MOLTEN_FLOOR:
		_f._temp[dst] = MOLTEN_FLOOR


# --- 2) Solidify (cooled lava → rock) ---------------------------------------

## Freeze cells that STILL hold lava but have cooled below SOLIDIFY_TEMP. Under normal flow the sustain
## pass keeps lava >= MOLTEN_FLOOR (> SOLIDIFY_TEMP), so nothing here fires — solidification only bites a
## cell that something actively COOLED past the point flow could reheat it: a stagnant fringe conducting
## into cold rock, a tongue quenched where it poured into water (the heat module drives wet cells toward
## WATER_TEMP), or a force-cooled cell. Such a cell becomes solid rock, its lava is zeroed, and the rock
## is stamped into the terrain SDF so a hardened flow BUILDS real terrain (a tube lining, a delta lobe).
## Capped + cursor-rotated so a single step never edits the whole map.
func _solidify() -> void:
	var lava: PackedFloat32Array = _f._lava
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var can_stamp: bool = _f._terrain != null and _f._terrain.has_method("fill_sphere")
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var edits: int = 0
	var scanned: int = 0
	while scanned < _f._cell_count and edits < SOLIDIFY_MAX_EDITS:
		var i: int = _solidify_cursor
		_solidify_cursor += 1
		if _solidify_cursor >= _f._cell_count:
			_solidify_cursor = 0
		scanned += 1
		if solid[i] != 0:
			continue
		if lava[i] < LAVA_MIN_MASS:
			continue
		if temp[i] >= SOLIDIFY_TEMP:
			continue
		# Cooled below the solidus while still holding lava → it has frozen to rock.
		solid[i] = 1
		lava[i] = 0.0
		if can_stamp:
			var ix: int = i % dx
			var rem: int = i / dx
			var iz: int = rem % dz
			var iy: int = rem / dz
			_f._terrain.fill_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
		edits += 1


# --- 3) Sustain molten heat -------------------------------------------------

## Keep every lava-bearing cell hot: molten scales with lava DEPTH (thick lava stays hotter), floored at
## MOLTEN_FLOOR and capped at LAVA_EMPLACE_TEMP. Uses max() so it only RAISES temperature — it never
## fights the heat module's conduction/evaporative cooling downward, it just refuses to let lava go cold.
## This is what makes lava glow and, via the heat module's conduction, bakes the surrounding rock.
func _sustain_heat() -> void:
	var lava: PackedFloat32Array = _f._lava
	var temp: PackedFloat32Array = _f._temp
	var span: float = LAVA_EMPLACE_TEMP - MOLTEN_FLOOR
	for i in range(_f._cell_count):
		var d: float = lava[i]
		if d < LAVA_MIN_MASS:
			continue
		var molten: float = MOLTEN_FLOOR + span * clampf(d / EMPLACE_DEPTH, 0.0, 1.0)
		if temp[i] < molten:
			temp[i] = molten


# --- 4) Melt (rock → lava, external super-heat only) ------------------------

## Rock super-heated past MELT_TEMP gives way to molten lava: the cell turns to void, gains lava, and the
## rock is carved from the terrain SDF. Because LAVA_EMPLACE_TEMP (1150) < MELT_TEMP (1200), lava's own
## sustained heat can never (via conduction, which only relaxes toward the mean) push adjacent rock over
## the melt point — so there is NO runaway; only a genuine external source (a meteor/vent adding heat
## above 1200) melts rock. Capped + cursor-rotated. No-op when the terrain can't be carved (headless).
func _melt() -> void:
	if _f._terrain == null or not _f._terrain.has_method("carve_sphere"):
		return
	var lava: PackedFloat32Array = _f._lava
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var edits: int = 0
	var scanned: int = 0
	while scanned < _f._cell_count and edits < MELT_MAX_EDITS:
		var i: int = _melt_cursor
		_melt_cursor += 1
		if _melt_cursor >= _f._cell_count:
			_melt_cursor = 0
		scanned += 1
		if solid[i] == 0:
			continue
		if temp[i] < MELT_TEMP:
			continue
		if water[i] > 0.05:
			continue                                    # water quenches — no melting where it's wet
		# Rock this hot melts to lava: open the cell and emplace molten material.
		solid[i] = 0
		lava[i] = lava[i] + MELT_LAVA_YIELD
		if temp[i] > LAVA_EMPLACE_TEMP:
			temp[i] = LAVA_EMPLACE_TEMP
		var ix: int = i % dx
		var rem: int = i / dx
		var iz: int = rem % dz
		var iy: int = rem / dz
		_f._terrain.carve_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
		edits += 1


# --- Sources + diagnostics --------------------------------------------------

## Inject a lava source at a world point (a volcano vent, a meteor impact melt). Adds molten mass to the
## target VOID cell and sets it to emplace temperature so the fresh lava is immediately liquid and hot.
## No-op outside the grid or into solid rock (a vent feeds the open air/void above the ground).
func add_lava(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _f == null:
		return
	var ix: int = _f._col_i(world_pos.x, _f._origin.x)
	var iz: int = _f._col_i(world_pos.z, _f._origin.z)
	var iy: int = clampi(int(round((world_pos.y - _f._origin.y) / _f._cell_size)), 0, _f._dim_y - 1)
	var i: int = _f._idx(ix, iy, iz)
	if _f._solid[i] != 0:
		return
	_f._lava[i] = _f._lava[i] + amount
	if _f._temp[i] < LAVA_EMPLACE_TEMP:
		_f._temp[i] = LAVA_EMPLACE_TEMP


## Total lava mass across the field (mass-conservation checks + volume readouts).
func total_lava() -> float:
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _f._lava[i]
	return s


## Number of cells currently holding lava (diagnostic / HUD).
func lava_cell_count() -> int:
	var n: int = 0
	for i in range(_f._cell_count):
		if _f._lava[i] >= LAVA_MIN_MASS:
			n += 1
	return n


func lava_peak() -> int:
	return _lava_peak
