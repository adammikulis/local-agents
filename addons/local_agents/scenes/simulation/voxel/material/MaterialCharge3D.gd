class_name LAMaterialCharge3D
extends RefCounted

## LAMaterialCharge3D — the 3D ELECTRIFICATION / LIGHTNING step of the dense LAMaterialField3D. Mirrors the
## shape of LAMaterialCombustion3D / LAMaterialWind3D: it holds NO authoritative grid state on the field —
## it OWNS a `_charge` channel in-module (no GPU kernel reads it yet) — and reaches into `_f` for the shared
## arrays it reads (`_temp`, `_cloud`, `_vel_y`, `_solid`), the geometry (`_dim_*`, `_cell_size`, `_origin`,
## `_cell_count`) and the ecology back-reference. (Explicit types only — no ':=' inferred typing.)
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted lightning. A bolt falls out of two local
## rules over a CHARGE channel that couples the atmosphere to the ground:
##   ACCUMULATE (per open cell) — charge separates where a convective UPDRAFT lofts SUPERCOOLED CLOUD. So
##     the same signal a real thunderstorm builds on: positive vertical wind (`_vel_y`, the emergent
##     buoyancy from the wind field) × cloud density × how deep into the mixed-phase (supercooled) band the
##     cell's temperature sits (`cold` peaks just below freezing, fades out ~COLD_SPAN below). A slow LEAK
##     bleeds charge away, so only a sustained storm updraft charges a column enough to break down. No
##     per-storm code — a hurricane eyewall, a thunderstorm cell, or a lava-plume updraft all charge the
##     air the same way through the same field state.
##   BREAKDOWN — when a COLUMN's summed charge crosses the dielectric-strength threshold BREAKDOWN_Q, the
##     air ionises and a bolt fires from the most-charged cell down to the tallest ground below that column.
##     At the strike point it INJECTS a burst of intense heat into the shared field (STRIKE_HEAT, well above
##     wood's ignition) so a wildfire EMERGES via LAMaterialCombustion3D exactly as a meteor's or lava's heat
##     would — no hardcoded "lightning → fire" — and broadcasts a scare so wildlife panics. The visual/audio
##     bolt is spawned through the `on_bolt` callback the field wires to VoxelDisasters (mesh + flash +
##     thunder ONLY; all physics is here in the field). The column's charge then resets to ~0 (discharged).
##
## GATHER form: ACCUMULATE reads/writes only ITS OWN cell, so it is order-independent and a future GPU port
## is bit-for-bit. BREAKDOWN is a per-column reduction + a capped number of discrete strikes per step.
## The math here is the CPU-oracle REFERENCE (no GLSL kernel yet); it is the headless/no-GPU path.

# --- Charge separation tunables --------------------------------------------------------------------
const FREEZE_T: float = 12.0              # °C — top of the charging band (this island's cloud tops rarely go
                                          # sub-zero, so charge builds in COOL cloud, not strictly supercooled)
const COLD_SPAN: float = 30.0             # °C below FREEZE_T over which `cold` fades 1 -> 0 (mixed-phase depth)
const CHARGE_GAIN: float = 8.0            # charge separated per (updraft × cloud × cold) per second
const CHARGE_LEAK: float = 0.004          # fraction of a cell's charge that bleeds away each step (slow relax)
const CHARGE_MIN: float = 0.02            # below this a cell holds no meaningful charge (diagnostic floor)
const UPDRAFT_MIN: float = 0.0            # only POSITIVE vertical wind (rising air) separates charge

# --- Dielectric breakdown (bolt trigger) -----------------------------------------------------------
const BREAKDOWN_Q: float = 2.5            # summed column charge at which the air ionises and a bolt fires
const MAX_BOLTS_PER_STEP: int = 2         # cap discrete strikes per step (a storm flickers, not a flood)
const RESET_FRACTION: float = 0.02        # residual charge left in a column after it discharges (~0)

# --- Strike deposition (all EMERGENT downstream: fire via combustion, flee via scare). ------------
const STRIKE_HEAT: float = 1400.0         # °C injected at the strike point (>> WOOD 300°C ignite → wildfire)
const STRIKE_HEAT_RADIUS: float = 3.0     # world-radius of the heat burst (matches the old bolt's HEAT_RADIUS)
const SCARE_RADIUS: float = 34.0          # world-radius wildlife panics over (matches the old bolt's SCARE_RADIUS)

var _f = null                                            # back-reference to the owning LAMaterialField3D
# The electrification channel is FIELD-RESIDENT (`_f._charge`) so the GPU backend can own the ACCUMULATE core
# (charge_accum3d.glsl) and round-trip it each frame; this module reads/writes `_f._charge` on the CPU path
# and runs only the BREAKDOWN tail (step_scene_only) on the GPU path.
var _bolts_total: int = 0                                # running total of bolts fired (diagnostic)
var _col_cursor: int = 0                                 # rotating column start so strikes aren't corner-biased

## The field sets this so the main thread can wire the VISUAL/audio bolt (VoxelDisasters.spawn_lightning).
## Called with the strike world-position on each breakdown; all PHYSICS already happened here in the field.
var on_bolt: Callable = Callable()


func setup(field) -> void:
	_f = field
	if _f._charge.size() != _f._cell_count:
		_f._charge.resize(_f._cell_count)
	_bolts_total = 0
	_col_cursor = 0


## One electrification step. ACCUMULATE charge in every open cell from the updraft × supercooled-cloud rule
## (gather form — each cell touches only itself), then scan columns for dielectric BREAKDOWN and fire up to
## MAX_BOLTS_PER_STEP bolts (heat + scare injected into the field; the visual bolt via `on_bolt`). Runs AFTER
## the atmosphere step so it reads the fresh vertical wind, cloud, and temperature.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _f._charge.size() != _f._cell_count:
		_f._charge.resize(_f._cell_count)
	_accumulate()                                        # per-cell charge separation (the GPU port's core)
	# --- BREAKDOWN (per-column reduction → capped strikes) -----------------------------------------
	_discharge_columns(_f._dim_x, _f._dim_y, _f._dim_z, _f._solid)


## GPU-path TAIL — runs ONLY the per-column BREAKDOWN (dielectric strike) WITHOUT the per-cell ACCUMULATE
## loop, because on the GPU-resident path charge_accum3d.glsl already ran that core (updraft × supercooled
## cloud separation + slow leak) on the device and `_f._charge` came back from the readback. Called ONCE per
## frame on the fresh readback (the CPU path keeps calling the full step()). The bolt spawns heat + scare +
## the visual callback, then resets the discharged column — the reset round-trips to the GPU next frame.
func step_scene_only() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _f._charge.size() != _f._cell_count:
		return
	_discharge_columns(_f._dim_x, _f._dim_y, _f._dim_z, _f._solid)


## Per-cell ACCUMULATE (gather form; each cell touches only itself, so it is order-independent and the GPU
## port charge_accum3d.glsl is bit-for-bit). Charge separates where a convective UPDRAFT lofts SUPERCOOLED
## CLOUD; a slow LEAK bleeds it away. This is the ONLY part that runs on the GPU — kept split out so the
## CPU path (step) and the GPU port share the same math spec.
func _accumulate() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var cloud: PackedFloat32Array = _f._cloud
	var vy: PackedFloat32Array = _f._vel_y
	var charge: PackedFloat32Array = _f._charge
	var dt: float = _f.STEP_DT
	var keep: float = 1.0 - CHARGE_LEAK

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					charge[i] = 0.0
					continue
				var up: float = vy[i]
				if up > UPDRAFT_MIN and cloud[i] > 0.0:
					var cold: float = clampf((FREEZE_T - temp[i]) / COLD_SPAN, 0.0, 1.0)
					charge[i] += CHARGE_GAIN * maxf(0.0, up) * cloud[i] * cold * dt
				charge[i] *= keep                        # slow leak toward neutral
	_f._charge = charge


## Scan every column (from a rotating cursor so strikes aren't biased to one corner); where a column's summed
## charge exceeds BREAKDOWN_Q, fire a bolt from its most-charged cell to the tallest ground below it, inject
## the heat burst + scare, request the visual bolt, then reset that column's charge. Caps bolts per step.
func _discharge_columns(dx: int, dy: int, dz: int, solid: PackedByteArray) -> void:
	var cols: int = dx * dz
	var fired: int = 0
	var scanned: int = 0
	while scanned < cols and fired < MAX_BOLTS_PER_STEP:
		var c: int = _col_cursor
		_col_cursor += 1
		if _col_cursor >= cols:
			_col_cursor = 0
		scanned += 1
		var ix: int = c % dx
		var iz: int = c / dx

		# Column reduction: total charge + the most-charged open cell (the bolt's aerial origin).
		var col_q: float = 0.0
		var top_iy: int = -1
		var top_q: float = 0.0
		for iy in range(dy):
			var i: int = (iy * dz + iz) * dx + ix
			if solid[i] != 0:
				continue
			var q: float = _f._charge[i]
			col_q += q
			if q > top_q:
				top_q = q
				top_iy = iy
		if col_q < BREAKDOWN_Q or top_iy < 0:
			continue

		# Bolt lands on the tallest ground below this column; strike the surface AIR cell just above it (where
		# combustion seeds vegetation fuel) so the heat burst lights it the same emergent way lava/meteor heat does.
		var giy: int = _ground_iy(ix, iz)
		if giy < 0:
			# No ground in this column (all void) — nothing to strike; discharge harmlessly.
			_reset_column(ix, iz, dx, dy, dz, solid)
			continue
		var siy: int = mini(giy + 1, dy - 1)
		var strike: Vector3 = _f.cell_world_pos(ix, siy, iz)

		# INJECTION ONLY — fire/scorch/steam emerge from the heat; wildlife flees the scare.
		_f.add_heat(strike, STRIKE_HEAT, STRIKE_HEAT_RADIUS)
		if _f._ecology != null and _f._ecology.has_method("broadcast_scare"):
			_f._ecology.broadcast_scare(strike, SCARE_RADIUS, 1.0)
		# VISUAL/audio bolt (mesh + flash + thunder) via the field-wired callback — no physics there.
		if on_bolt.is_valid():
			on_bolt.call(strike)

		_reset_column(ix, iz, dx, dy, dz, solid)
		_bolts_total += 1
		fired += 1


# Drain a column's charge to a residual (~0) after it discharges through a bolt.
func _reset_column(ix: int, iz: int, dx: int, dy: int, dz: int, solid: PackedByteArray) -> void:
	for iy in range(dy):
		var i: int = (iy * dz + iz) * dx + ix
		if solid[i] != 0:
			continue
		_f._charge[i] *= RESET_FRACTION


# Topmost SOLID (ground) cell index-y of a column scanning down from the top, or -1 if the column is all void.
# (Copied from LAMaterialCombustion3D._ground_iy — must match: both find the tallest ground of a column.)
func _ground_iy(ix: int, iz: int) -> int:
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * dz + iz) * dx + ix] != 0:
			return iy
	return -1


# --- Diagnostics (SMOKE_SUMMARY: charge_peak / bolts) ----------------------------------------------

## Peak charge in any single cell (0 when the sky is calm; climbs under a charging storm updraft).
func charge_peak() -> float:
	if _f == null:
		return 0.0
	var m: float = 0.0
	for i in range(_f._charge.size()):
		if _f._charge[i] > m:
			m = _f._charge[i]
	return m


## Running total of bolts fired since setup (monotonic; a storm's lightning count).
func bolts_fired() -> int:
	return _bolts_total


## Number of cells currently holding meaningful charge (the electrified volume; diagnostic / HUD).
func charged_cells() -> int:
	if _f == null:
		return 0
	var n: int = 0
	for i in range(_f._charge.size()):
		if _f._charge[i] > CHARGE_MIN:
			n += 1
	return n
