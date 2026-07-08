class_name LAMaterialSnowIce3D
extends RefCounted

## LAMaterialSnowIce3D — the SNOW / ICE PHASE step of the dense LAMaterialField3D. Mirrors the shape of
## LAMaterialLava3D / LAMaterialCombustion3D: it holds only its OWN two channels (a per-COLUMN snowpack
## depth `_snow` and a per-cell frozen-water mask `_ice` + the water it locked up) and reaches into the
## owning field (`_f`) for the shared arrays (`_temp`, `_water`, `_solid`), the geometry (`_dim_*`,
## `_cell_size`, `_origin`, `_cell_count`), the index/position helpers (`_idx`, `cell_world_pos`,
## `_col_i`), the global precipitation signal (`_f.precipitation()`) and the terrain SDF
## (`_terrain.fill_sphere` / `carve_sphere`), exactly like lava's solidify/melt.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted winter, no season timeline, no snow-line
## constant painted onto the map. A seasonal snowpack, a spring-melt river swell and frozen ponds all fall
## out of three local rules driven ONLY by the live TEMPERATURE field + precipitation:
##   SNOWFALL/PACK — where it is precipitating and the surface cell is at/below freezing (temp < SNOW_T),
##     the falling precipitation lands as SNOW (accumulates in the per-column `_snow` depth) instead of
##     liquid water. Because temp is driven by the sun/altitude, only the cold columns (high ground, the
##     cold side of the day/year) build a pack — the snow LINE emerges from the temperature field, not a
##     hardcoded height. When those columns warm the pack recedes: an emergent seasonal cover.
##   MELT — where the surface warms past MELT_T, snowpack melts at a rate proportional to how far over the
##     melt point it is, and the meltwater is injected into `_f._water` at the surface cell. The water CA
##     then carries it downhill, so a warming spell swells the rivers below a melting snowfield — spring
##     melt with no scripting.
##   WATER FREEZE/THAW — standing surface water in a cell colder than FREEZE_T freezes to solid ice (the
##     water skin at the top of a pond/lake), which BLOCKS the flow like any rock, so a pond ices over.
##     Ice thaws back to the exact water it locked up once its cell warms past THAW_T. Frozen ice is
##     stamped into / carved out of the terrain SDF the same capped, cursor-rotated way cooled lava turns
##     to basalt — so the freeze is real geometry the renderer + collision see, not just a flag.
##
## The CPU loop here is the correctness ORACLE + the headless/no-GPU path (no GLSL kernel yet). Gather
## form: each column/cell reads the shared fields and writes only its OWN channel, so it is order-
## independent and a future GPU port would be bit-for-bit. (Explicit types only — no ':=' inferred typing.)

# --- Phase thresholds (°C; the field runs in real Celsius — 0 freezes water). A small THAW_T > FREEZE_T /
# MELT_T > SNOW_T hysteresis stops a cell hovering at 0° from flickering frozen<->thawed every step. -----
const SNOW_T: float = 0.0                 # surface at/below this: precipitation lands as snow, not water
const MELT_T: float = 2.0                 # snowpack above this melts (rate ∝ temp − MELT_T)
const FREEZE_T: float = 0.0               # standing surface water below this freezes to ice
const THAW_T: float = 1.0                 # ice above this thaws back to water (hysteresis vs FREEZE_T)

# --- Snow accumulation / melt tuning ----------------------------------------
const SNOW_FALL_RATE: float = 0.03        # snowpack depth added per step per unit precipitation, in a cold column
const SNOW_MIN: float = 0.001             # below this a column holds no meaningful snow (counts as bare)
const MELT_RATE: float = 0.02             # snow depth melted per step per °C over MELT_T
const MELT_MAX_PER_STEP: float = 0.15     # cap on snow melted from one column per step (a thaw is gradual)
const SNOW_WATER_YIELD: float = 0.3       # water mass produced per unit of melted snow (snow is fluffy: density ~0.3)

# --- Ice freeze/thaw (terrain-SDF touches; capped + cursor-rotated exactly like lava solidify/melt) -----
const ICE_WATER_MIN: float = 0.2          # a cell needs at least this much water to freeze into ice (a real pool, not a film)
const FREEZE_MAX_EDITS: int = 32          # cap freeze conversions per step (cursor-rotated)
const THAW_MAX_EDITS: int = 32            # cap thaw conversions per step (cursor-rotated)
const FREEZE_SCAN_BUDGET: int = 20000     # max cells scanned per GPU-tail freeze/thaw call (perf bound; edits still capped)
const SDF_STAMP_SCALE: float = 0.62       # stamp/carve radius as a fraction of cell size (must match MaterialLava3D / MaterialSlump3D)

var _f = null                             # back-reference to the owning LAMaterialField3D
var _snow: PackedFloat32Array = PackedFloat32Array()      # OWNED: per-COLUMN snowpack depth (size _dim_x*_dim_z)
var _ice: PackedByteArray = PackedByteArray()             # OWNED: per-cell, 1 = a water cell this module froze to ice
var _ice_mass: PackedFloat32Array = PackedFloat32Array()  # OWNED: water mass a frozen cell locked up (restored on thaw)
var _freeze_cursor: int = 0               # rotating scan cursor for capped freeze edits
var _thaw_cursor: int = 0                 # rotating scan cursor for capped thaw edits
var _snow_cells_last: int = 0             # diagnostic: snow-covered columns after the last step
var _ice_cells_last: int = 0              # diagnostic: frozen ice cells after the last step
var _snow_peak: float = 0.0               # diagnostic: deepest snowpack ever reached in any column


func setup(field) -> void:
	_f = field
	_snow = PackedFloat32Array()
	_snow.resize(_f._dim_x * _f._dim_z)
	_ice = PackedByteArray()
	_ice.resize(_f._cell_count)
	_ice_mass = PackedFloat32Array()
	_ice_mass.resize(_f._cell_count)


## One snow/ice step, ordered so a fresh temperature + precipitation drive everything:
##   1) SNOW  — accumulate snowpack in cold precipitating columns; melt it (→ meltwater into _water) in warm ones.
##   2) FREEZE — standing surface water in a below-freezing cell turns to solid ice (capped + cursor-rotated).
##   3) THAW  — ice that has warmed past THAW_T turns back into the water it locked up (capped + cursor-rotated).
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _snow.size() != _f._dim_x * _f._dim_z:
		_snow.resize(_f._dim_x * _f._dim_z)
	if _ice.size() != _f._cell_count:
		_ice.resize(_f._cell_count)
	if _ice_mass.size() != _f._cell_count:
		_ice_mass.resize(_f._cell_count)
	_step_snow()
	var solid_changed: bool = false
	if _freeze():
		solid_changed = true
	if _thaw():
		solid_changed = true
	# The rock/solid mask changed → re-push it so the resident GPU buffers block fluid through the new ice
	# (and let water flow through thawed cells again). Mirrors MaterialSlump3D.settle(). No-op headless.
	if solid_changed and _f._use_gpu and _f._gpu != null and _f._gpu.has_method("upload_static_state"):
		_f._gpu.upload_static_state(_f._solid, _f._static)
	_snow_cells_last = snow_cells()
	_ice_cells_last = ice_cells()


## GPU-path TAIL — runs ONLY the water FREEZE/THAW phase (water <-> ice: SDF fill/carve + the solid-mask edit +
## its re-upload) + diagnostics, because on the GPU-resident path snowice3d already ran the per-column snowpack
## accrete/melt core on-device (snow depth + meltwater into _f._water came back from the readback). Mirrors how
## lava keeps its solidify/melt SDF stamps a CPU tail off the GPU flow. Freeze/thaw are scan-bounded (perf).
## Ice count is tracked incrementally (freeze +1 / thaw -1) so the tail skips the full-grid ice_cells() scan.
func step_scene_only() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _snow.size() != _f._dim_x * _f._dim_z:
		_snow.resize(_f._dim_x * _f._dim_z)
	if _ice.size() != _f._cell_count:
		_ice.resize(_f._cell_count)
	if _ice_mass.size() != _f._cell_count:
		_ice_mass.resize(_f._cell_count)
	var solid_changed: bool = false
	if _freeze():
		solid_changed = true
	if _thaw():
		solid_changed = true
	if solid_changed and _f._use_gpu and _f._gpu != null and _f._gpu.has_method("upload_static_state"):
		_f._gpu.upload_static_state(_f._solid, _f._static)
	_snow_cells_last = snow_cells()


# --- 1) Snowfall / pack / melt (per COLUMN) ---------------------------------

## Per column: read the surface cell's fresh temperature. If it is precipitating and that cell is at/below
## SNOW_T, the precipitation lands as SNOW (grow the pack). If the surface is above MELT_T, melt the pack
## proportionally and pour the meltwater into the surface water cell (the CA carries it downhill). A column
## that is neither snowing nor melting just holds its pack — so cover persists through a cold dry spell.
func _step_snow() -> void:
	var precip: float = _f.precipitation()
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var falling: float = precip * SNOW_FALL_RATE
	for iz in range(dz):
		for ix in range(dx):
			var giy: int = _ground_iy(ix, iz)
			if giy < 0 or giy >= _f._dim_y - 1:
				continue                                     # no ground, or no surface air cell above it
			var si: int = ((giy + 1) * dz + iz) * dx + ix
			if _f._solid[si] != 0:
				continue
			var col: int = iz * dx + ix
			var st: float = temp[si]
			var depth: float = _snow[col]
			if falling > 0.0 and st < SNOW_T:
				depth += falling                             # cold + precipitating → precip becomes snowpack
			elif st > MELT_T and depth > 0.0:
				var melted: float = minf(depth, minf(MELT_MAX_PER_STEP, (st - MELT_T) * MELT_RATE))
				if melted > 0.0:
					depth -= melted
					water[si] += melted * SNOW_WATER_YIELD   # meltwater feeds the river CA at the surface cell
			if depth < SNOW_MIN:
				depth = 0.0
			_snow[col] = depth
			if depth > _snow_peak:
				_snow_peak = depth


# --- 2) Water freeze → ice (cooled standing water → solid; capped + cursor-rotated like lava solidify) --

## Freeze the exposed top of standing water where the cell has cooled below FREEZE_T: the water mass is
## locked into `_ice_mass`, the cell is marked solid ice (blocking the flow so the pond ices over) and a
## small SDF sphere is stamped so the freeze is real geometry. Only the WATER SURFACE freezes — a cell whose
## cell above is open (not a full water column) — so a lake grows an ice skin instead of freezing solid to
## the bed in one step. Capped + cursor-rotated so a single step never edits the whole map. Returns true if
## any cell froze (so the caller re-pushes the changed solid mask to the GPU).
func _freeze() -> bool:
	var water: PackedFloat32Array = _f._water
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var can_stamp: bool = _f._terrain != null and _f._terrain.has_method("fill_sphere")
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var edits: int = 0
	var scanned: int = 0
	var froze: bool = false
	while scanned < mini(FREEZE_SCAN_BUDGET, _f._cell_count) and edits < FREEZE_MAX_EDITS:
		var i: int = _freeze_cursor
		_freeze_cursor += 1
		if _freeze_cursor >= _f._cell_count:
			_freeze_cursor = 0
		scanned += 1
		if solid[i] != 0:
			continue
		if water[i] < ICE_WATER_MIN:
			continue
		if temp[i] >= FREEZE_T:
			continue
		# Only freeze the EXPOSED water surface: the cell above must be open (off-grid top or a non-solid,
		# not-full-of-water cell). This grows an ice skin on top of ponds/lakes rather than freezing a whole
		# water column solid at once.
		var iy: int = i / layer
		if iy < _f._dim_y - 1:
			var iu: int = i + layer
			if solid[iu] == 0 and water[iu] >= ICE_WATER_MIN:
				continue                                     # water above us — we're mid-column, not the surface
		# Cooled below freezing at a standing-water surface → it freezes to solid ice.
		_ice_mass[i] = water[i]
		water[i] = 0.0
		solid[i] = 1
		_ice[i] = 1
		if can_stamp:
			var rem: int = i - iy * layer
			var iz: int = rem / dx
			var ix: int = rem % dx
			_f._terrain.fill_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
		edits += 1
		froze = true
		_ice_cells_last += 1
	return froze


# --- 3) Ice thaw → water (warmed ice → the water it locked up; capped + cursor-rotated like lava melt) --

## Thaw ice that has warmed past THAW_T: open the cell back up, restore exactly the water mass it locked
## when it froze (mass-conserving), clear the ice flag and carve the stamped ice sphere out of the terrain
## SDF. Capped + cursor-rotated. Only touches cells this module itself froze (`_ice[i] == 1`), so it never
## carves natural rock. Returns true if any cell thawed (so the caller re-pushes the changed solid mask).
func _thaw() -> bool:
	var water: PackedFloat32Array = _f._water
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var can_carve: bool = _f._terrain != null and _f._terrain.has_method("carve_sphere")
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var edits: int = 0
	var scanned: int = 0
	var thawed: bool = false
	while scanned < mini(FREEZE_SCAN_BUDGET, _f._cell_count) and edits < THAW_MAX_EDITS:
		var i: int = _thaw_cursor
		_thaw_cursor += 1
		if _thaw_cursor >= _f._cell_count:
			_thaw_cursor = 0
		scanned += 1
		if _ice[i] == 0:
			continue
		if temp[i] <= THAW_T:
			continue
		# Warmed past the thaw point → back to the water it locked up.
		solid[i] = 0
		_ice[i] = 0
		water[i] += _ice_mass[i]
		_ice_mass[i] = 0.0
		if can_carve:
			var iy: int = i / layer
			var rem: int = i - iy * layer
			var iz: int = rem / dx
			var ix: int = rem % dx
			_f._terrain.carve_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
		edits += 1
		thawed = true
		_ice_cells_last -= 1
	return thawed


# --- Column helpers ---------------------------------------------------------

## Topmost SOLID (ground) cell index-y of a column scanning down from the top, or -1 if the column is all
## void. Matches LAMaterialCombustion3D._ground_iy so snow sits on the same surface fire/fuel does.
func _ground_iy(ix: int, iz: int) -> int:
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * dz + iz) * dx + ix] != 0:
			return iy
	return -1


# --- Read queries + diagnostics ---------------------------------------------

## Snowpack depth at a world point (0 outside the grid, or on a bare/warm column). A future terrain shader
## reads this to paint a snow cover, and creatures read it (deep snow slows them / hides forage).
func snow_depth_at(x: float, z: float) -> float:
	if _f == null or _snow.size() == 0:
		return 0.0
	var ix: int = _f._col_i(x, _f._origin.x)
	var iz: int = _f._col_i(z, _f._origin.z)
	return _snow[iz * _f._dim_x + ix]


## Number of columns currently holding snow (diagnostic / HUD / SMOKE_SUMMARY `snow_cells`).
func snow_cells() -> int:
	var n: int = 0
	for c in range(_snow.size()):
		if _snow[c] >= SNOW_MIN:
			n += 1
	return n


## Deepest snowpack ever reached in any column (diagnostic).
func snow_peak() -> float:
	return _snow_peak


## Number of cells currently frozen to ice (diagnostic / HUD / SMOKE_SUMMARY `ice_cells`).
func ice_cells() -> int:
	var n: int = 0
	for i in range(_ice.size()):
		if _ice[i] != 0:
			n += 1
	return n


## Total snowpack mass across all columns (mass-readout / debugging).
func total_snow() -> float:
	var s: float = 0.0
	for c in range(_snow.size()):
		s += _snow[c]
	return s
