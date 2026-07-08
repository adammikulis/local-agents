class_name LAMaterialMagma3D
extends RefCounted

## LAMaterialMagma3D — the 3D MAGMA / VOLCANO step of the dense LAMaterialField3D (TODO #23). Where
## LAMaterialLava3D is the SURFACE lava CA (a viscous liquid that flows, pools, crusts, and — past
## MELT_TEMP — melts rock back to lava), LAMaterialMagma3D is the DEEP driver BELOW it: a hot, buoyant,
## OVER-PRESSURED source of lava that bores its own conduit UPWARD through solid rock until it breaks the
## surface and ERUPTS. It runs each step AFTER `_lava_sim.step()`, composing with it: the lava CA owns the
## flow/crust/melt of lava that is already exposed; this module owns the pressure that pushes new lava up.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted eruption cycle, no timer, no per-volcano
## state machine. An eruption FALLS OUT of three purely LOCAL rules over the shared `_f._lava`/`_f._temp`/
## `_f._solid` channels, driven by ONE thing the Volcano actor registers — a deep hot source:
##   1) DEEP HOT-SOURCE — a registered chamber cell is pinned hot (>= chamber temp, ~1300°C, the ONLY thing
##      the whole field keeps above MELT_TEMP) and fed lava at a steady rate. That is the entire external
##      drive: add_source(deep_pos, temp, rate). Everything below emerges from the lava + heat it deposits.
##   2) BUOYANT OVERPRESSURE UP-FLOW — a cell holding more lava than MAX_MASS has overpressure op; that
##      op pushes an EXTRA up-transfer into the open cell above (beyond the lava CA's own overflow), so a
##      fed, rock-walled column climbs its conduit and stays full + hot as it rises. Gather-form + mass-
##      conserving via a scratch double buffer (each cell writes only itself), so a future GPU port matches.
##   3) DIRECTIONAL-UP PRESSURE-MELT — a SOLID cell whose cell directly BELOW holds hot pressurized lava
##      melts at a REDUCED threshold MELT_TEMP - K_MELT_P*op_below. Un-pressurized rock still needs the full
##      MELT_TEMP (carried lava heat is capped BELOW MELT_TEMP, exactly like the lava CA), so there is NO
##      runaway — only a genuinely PRESSURIZED column punches upward. The bore opens the cell, adds a lava
##      yield, and carries heat up, advancing the conduit one cell toward the surface → an eruption.
##
## Episodic eruptions emerge for free: when the conduit breaks the surface, lava drains out and downhill via
## the lava CA, overpressure at the chamber bleeds off, pressure-melt stalls, and the conduit tip cools and
## re-solidifies under LAMaterialLava3D._solidify (re-capping it). The persistent source then rebuilds
## pressure behind the fresh cap until it bores through again — a natural eruption/repose cycle, unscripted.
##
## Holds NO authoritative grid state of its own beyond the source registry, a lava scratch double-buffer,
## and a melt cursor: lava/temp/solid all live on the owning field (`_f`). SDF terrain carves are CPU-only
## (guarded), so the CPU loop is the correctness oracle + the headless/no-GPU path.
## (Explicit types only — no ':=' inferred typing.)

# --- Borrowed phase constants (MUST MATCH MaterialLava3D / MaterialField3D) ---
const MAX_MASS: float = 1.0               # a cell is "full" of lava at this mass (must match MaterialField3D)
const MELT_TEMP: float = 1200.0           # rock this hot melts back to lava (must match MaterialLava3D)
const MOLTEN_FLOOR: float = 950.0         # a lava cell is kept at least this hot (must match MaterialLava3D)
const LAVA_EMPLACE_TEMP: float = 1150.0   # cap on lava's own carried heat, < MELT_TEMP → no melt runaway (must match MaterialLava3D)
const LAVA_MIN: float = 0.0001            # below this a cell holds no lava (must match MaterialLava3D LAVA_MIN_MASS)
const SDF_STAMP_SCALE: float = 0.9        # carve radius vs cell size (must match MaterialLava3D) — ≥ half the
                                          # cell's 3D diagonal (0.87) so per-cell sphere stamps UNION smoothly
                                          # instead of a lumpy "string of spheres" (was 0.62 → diagonal gaps).

# --- Rule 2: buoyant overpressure up-flow -----------------------------------
const BUOY_FRAC: float = 0.55             # base fraction of overpressure buoyed upward per step
const K_P: float = 0.6                    # extra up-push per unit overpressure (pressure accelerates the rise)
const MAX_UP_FLOW: float = 0.4            # cap on a single buoyant up-transfer per step (stability)
const MIN_OP: float = 0.0001              # ignore negligible overpressure

# --- Rule 3: directional-up pressure-melt (CPU-only SDF carve) ---------------
const K_MELT_P: float = 200.0             # °C the melt threshold drops per unit overpressure below (op≈0.25 → -50°C)
const MELT_THRESHOLD_FLOOR: float = 950.0 # the reduced melt threshold never goes below this (== MOLTEN_FLOOR; anti-runaway)
const MELT_YIELD: float = 0.9             # lava mass emplaced when a pressurized roof cell is bored open
const MELT_MAX_EDITS: int = 12            # cap pressure-melt SDF carves per step (cursor-rotated, like lava)
const WET_MAX: float = 0.05               # water mass above which a cell won't melt (steam-quenched, must match lava _melt 0.05)

# --- Source feed -------------------------------------------------------------
const CHAMBER_TEMP_MIN: float = 1300.0    # sources are expected hotter than MELT_TEMP; this documents the intent
const CHAMBER_LAVA_CAP: float = 4.0       # clamp chamber lava so pressure builds but numbers stay bounded (op ≤ 3)
const VENT_MIN_CLIMB: int = 2             # open conduit cells above a chamber before it counts as "venting" (erupting)

var _f = null                             # back-reference to the owning LAMaterialField3D
var _sources: Array = []                  # [{cell:int, temp:float, rate:float}] — deep hot magma chambers
var _scratch: PackedFloat32Array = PackedFloat32Array()   # lava double buffer for the buoyant up-flow
var _melt_cursor: int = 0                 # rotating scan cursor for capped pressure-melt carves
var _magma_cells_last: int = 0            # diagnostic: overpressured lava cells after the last step
var _erupting_last: bool = false          # diagnostic: any source venting lava up its conduit last step


func setup(field) -> void:
	_f = field
	_sources = []
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)
	_melt_cursor = 0


## One magma step (runs AFTER LAMaterialLava3D.step() each frame): re-feed + pin the deep chambers, buoy the
## over-pressured lava up its conduit (gather-form, mass-conserving), then bore any pressurized rock roof
## upward. Order: feed → buoy → melt, so injected lava rises this step and the pressurized tip melts the roof
## for next step's rise. Skips everything if there are no sources (idle cost is one branch).
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _sources.is_empty():
		_magma_cells_last = 0
		_erupting_last = false
		return
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	_feed_sources()
	_buoy_flow()
	_pressure_melt()
	_magma_cells_last = _count_magma()
	_erupting_last = _compute_erupting()


## GPU-path TAIL — runs ONLY the SDF/solid-mask concerns (deep-source FEED + conduit PRESSURE-MELT) + diagnostics,
## because on the GPU-resident path magma_buoy3d already ran the buoyant overpressure up-flow core on-device and
## _f._lava/_f._temp came back from the readback. Mirrors how lava keeps its melt SDF carve a CPU tail. Order:
## feed (inject into the readback lava, pin chamber hot) -> pressure-melt (bore the rock roof upward: SDF carve +
## solid-mask edit + lava emplace). Both round-trip to the GPU next frame. Called ONCE per frame on the readback.
func step_scene_only() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _sources.is_empty():
		_magma_cells_last = 0
		_erupting_last = false
		return
	_feed_sources()
	_pressure_melt()
	# The feed/bore just wrote _f._lava on the CPU (deep-source injection + conduit emplacement), so the GPU
	# path must re-upload it next frame — otherwise its dirty-gated upload would skip and the eruption's lava
	# would never reach the resident buffer. (A live volcano dirties this every frame, so lava round-trips.)
	_f._lava_dirty = true
	_magma_cells_last = _count_magma()
	_erupting_last = _compute_erupting()


# --- Rule 1: deep hot-source registry ---------------------------------------

## Register a persistent deep magma chamber at a world point (the Volcano actor's ONE drive). Opens the
## chamber cell so the injected lava has a home (a one-time emplacement — a single cell, not a scripted
## conduit; everything above bores emergently), then records it for per-step feeding. `temp` should exceed
## MELT_TEMP (~1300°C) so the chamber roof melts and the conduit can start; `rate` is lava mass per second.
func add_source(world_pos: Vector3, temp: float, rate: float) -> void:
	if _f == null or _f._cell_count <= 0 or rate <= 0.0:
		return
	var i: int = _cell_at(world_pos)
	if i < 0:
		return
	# Open the chamber cell (one-time), carving the SDF where possible so the field + terrain agree.
	if _f._solid[i] != 0:
		var ix: int = i % _f._dim_x
		var rem: int = i / _f._dim_x
		var iz: int = rem % _f._dim_z
		var iy: int = rem / _f._dim_z
		if _f._terrain != null and _f._terrain.has_method("carve_sphere"):
			_f._terrain.carve_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
			if _f.has_method("resample_terrain"):
				_f.resample_terrain(_f.cell_world_pos(ix, iy, iz), _f._cell_size)
		_f._solid[i] = 0
		if _f._use_gpu and _f._gpu != null and _f._gpu.has_method("upload_static_state"):
			_f._gpu.upload_static_state(_f._solid, _f._static)
	if _f._temp[i] < temp:
		_f._temp[i] = temp
	_sources.append({"cell": i, "temp": temp, "rate": rate})


## Pin each chamber cell hot and inject its lava rate. Temperature is pinned even if the cell somehow
## re-solidified (so the lava CA's own _melt can re-open it); lava is injected only into an OPEN chamber,
## clamped to CHAMBER_LAVA_CAP so overpressure builds toward the bore threshold without unbounded growth.
func _feed_sources() -> void:
	var lava: PackedFloat32Array = _f._lava
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var dt: float = _f.STEP_DT
	for s in _sources:
		var i: int = int(s["cell"])
		var t: float = float(s["temp"])
		if temp[i] < t:
			temp[i] = t
		if solid[i] == 0:
			var inj: float = float(s["rate"]) * dt
			lava[i] = minf(lava[i] + inj, CHAMBER_LAVA_CAP)


# --- Rule 2: buoyant overpressure up-flow (gather form, mass-conserving) -----

## Push over-pressured lava UP its conduit. GATHER form: for each open cell i,
##   scratch[i] = lava[i] - (buoyant outflow to the open cell ABOVE) + (buoyant inflow from the open cell BELOW).
## Both endpoints of an edge evaluate the SAME `_buoy_up(lava[source])` on the stable `_f._lava` snapshot, so
## mass is exactly conserved and the pass is order-independent (a future GPU kernel is bit-for-bit). Heat
## rides UP with received lava (capped at LAVA_EMPLACE_TEMP < MELT_TEMP — so carried heat alone never melts
## rock; only heat+overpressure does), keeping the climbing column molten. Buffers swap at the end.
func _buoy_flow() -> void:
	var lava: PackedFloat32Array = _f._lava
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz

	for i in range(_f._cell_count):
		_scratch[i] = lava[i]

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var out_up: float = 0.0
				var in_below: float = 0.0
				# Outflow: buoyant push into the open cell directly ABOVE.
				if iy < dy - 1:
					var iu: int = i + layer
					if solid[iu] == 0:
						out_up = _buoy_up(lava[i])
				# Inflow: the open cell directly BELOW pushes its buoyant share up into us.
				if iy > 0:
					var ib: int = i - layer
					if solid[ib] == 0:
						in_below = _buoy_up(lava[ib])
				if out_up == 0.0 and in_below == 0.0:
					continue
				_scratch[i] = _scratch[i] - out_up + in_below
				# Molten heat rides up with received lava so the front stays liquid + hot (bounded < MELT_TEMP).
				if in_below > 0.0 and iy > 0:
					var src: int = i - layer
					var carried: float = minf(temp[src], LAVA_EMPLACE_TEMP)
					if carried < MOLTEN_FLOOR:
						carried = MOLTEN_FLOOR
					if temp[i] < carried:
						temp[i] = carried

	# Commit: swap the buffers (the old lava array becomes next step's scratch).
	var tmp: PackedFloat32Array = _f._lava
	_f._lava = _scratch
	_scratch = tmp


## Buoyant up-transfer a cell contributes given its lava mass: only the OVERPRESSURE (mass beyond MAX_MASS)
## is buoyed, scaled by (BUOY_FRAC + K_P*op) and capped at both `op` (so the cell never falls below full via
## buoyancy — the column stays full as it climbs) and MAX_UP_FLOW (stability). Duplicated math for a GPU port.
func _buoy_up(mass: float) -> float:
	var op: float = mass - MAX_MASS
	if op < MIN_OP:
		return 0.0
	var flow: float = op * (BUOY_FRAC + K_P * op)
	return clampf(flow, 0.0, minf(MAX_UP_FLOW, op))


# --- Rule 3: directional-up pressure-melt (bore the conduit upward, CPU-only) -

## Bore the conduit UPWARD: a SOLID cell whose cell directly BELOW holds hot, over-pressured lava melts at a
## threshold REDUCED by that overpressure (MELT_TEMP - K_MELT_P*op_below, floored at MELT_THRESHOLD_FLOOR).
## Because the lava CA + this module cap carried lava heat at LAVA_EMPLACE_TEMP (< MELT_TEMP), an
## UN-pressurized hot lava cell can never melt its roof (op≈0 → full MELT_TEMP needed) — only a genuinely
## PRESSURIZED column does, so there is no runaway; a chamber cell pinned above MELT_TEMP bootstraps the first
## bore. On melt the roof cell opens, gains a lava yield, and inherits the carried heat, advancing the conduit
## one cell toward the surface. SDF carve is CPU-only.
##
## PERF: overpressure buoys STRICTLY UP (Rule 2 only ever pushes into the cell ABOVE, and lava is injected only
## at the registered chamber cell), so the ONLY cells that can ever satisfy the melt condition are the SOLID
## roof cells directly above each source's vertical conduit tip. So instead of scanning the whole ~127K-cell
## grid every call (the old full-sweep cursor cost ~13.7 ms even at rest), we walk each source column to its
## growing frontier — O(sources × conduit-height), a handful of cells — and bore only there. This visits the
## exact same cells the full scan would have found (no off-column cell is ever overpressured), so the emergent
## bore/eruption is unchanged; it is just found directly instead of searched for.
func _pressure_melt() -> void:
	var lava: PackedFloat32Array = _f._lava
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var dy: int = _f._dim_y
	var layer: int = dx * dz
	var can_carve: bool = _f._terrain != null and _f._terrain.has_method("carve_sphere")
	var opened_any: bool = false
	var edits: int = 0
	for s in _sources:
		if edits >= MELT_MAX_EDITS:
			break
		var base: int = int(s["cell"])
		if solid[base] != 0:
			continue                                     # chamber not open yet (lava CA _melt will reopen it)
		# Climb the OPEN conduit from the chamber to its tip (topmost open cell in this column).
		var tip: int = base
		while true:
			if tip / layer >= dy - 1:
				break                                    # tip is at the ceiling — no roof cell above
			var up: int = tip + layer
			if solid[up] != 0:
				break                                    # hit the solid roof / re-solidified cap
			tip = up
		if tip / layer >= dy - 1:
			continue                                     # conduit already reached the top layer
		var ib: int = tip                                # the OPEN, lava-bearing cell directly BELOW the roof
		var i: int = tip + layer                         # the SOLID roof cell to bore
		if solid[i] == 0:
			continue                                     # already open (broken through / venting)
		if water[i] > WET_MAX:
			continue                                     # steam-quenched — no melting where it's wet
		if lava[ib] < LAVA_MIN:
			continue                                     # tip holds no lava to push up
		var op_below: float = maxf(0.0, lava[ib] - MAX_MASS)
		var threshold: float = maxf(MELT_THRESHOLD_FLOOR, MELT_TEMP - K_MELT_P * op_below)
		if temp[ib] < threshold:
			continue                                     # not hot/pressurized enough to punch through
		# Bore the roof cell open, emplace lava, and carry the molten heat up so it can melt the NEXT cell.
		solid[i] = 0
		lava[i] = lava[i] + MELT_YIELD
		var carried: float = minf(temp[ib], LAVA_EMPLACE_TEMP)
		if temp[i] < carried:
			temp[i] = carried
		if can_carve:
			var ix: int = i % dx
			var rem: int = i / dx
			var iz: int = rem % dz
			var iy: int = rem / dz
			_f._terrain.carve_sphere(_f.cell_world_pos(ix, iy, iz), _f._cell_size * SDF_STAMP_SCALE)
			if _f.has_method("resample_terrain"):
				_f.resample_terrain(_f.cell_world_pos(ix, iy, iz), _f._cell_size)
			solid[i] = 0                                 # force-open (resample re-reads the SDF)
		opened_any = true
		edits += 1
	if opened_any and _f._use_gpu and _f._gpu != null and _f._gpu.has_method("upload_static_state"):
		# The rock mask changed — re-push it so the resident GPU buffers see the newly bored conduit.
		_f._gpu.upload_static_state(_f._solid, _f._static)


# --- Diagnostics ------------------------------------------------------------

## Number of registered deep magma chambers.
func source_count() -> int:
	return _sources.size()


## Cells holding OVER-PRESSURED lava (mass > MAX_MASS) — the active pressurized magma in the chamber +
## conduit. A distinct signal from the lava CA's lava_cell_count() (which counts ALL exposed lava, most of
## it un-pressurized surface flow). SMOKE_SUMMARY `magma_cells`.
func magma_cells() -> int:
	return _magma_cells_last


## Overpressured lava (mass > MAX_MASS) lives ONLY in the fed chamber + its buoyed vertical conduit (Rule 2
## pushes strictly up, lava is injected only at the chamber), so count along each source's OPEN column instead
## of scanning the whole grid — the same cheap frontier walk _pressure_melt uses. O(sources × conduit-height).
func _count_magma() -> int:
	if _f == null:
		return 0
	var lava: PackedFloat32Array = _f._lava
	var solid: PackedByteArray = _f._solid
	var layer: int = _f._dim_x * _f._dim_z
	var dy: int = _f._dim_y
	var n: int = 0
	for s in _sources:
		var c: int = int(s["cell"])
		while true:
			if solid[c] == 0 and lava[c] > MAX_MASS + MIN_OP:
				n += 1
			if c / layer >= dy - 1:
				break
			var up: int = c + layer
			if solid[up] != 0:
				break                                    # top of the OPEN column (solid cap / roof)
			c = up
	return n


## Is any source currently venting lava up its conduit? True when a source's contiguous OPEN column above
## the chamber has climbed at least VENT_MIN_CLIMB cells and its top open cell holds lava — i.e. the bore has
## broken upward and lava is climbing it (drops back to false when the conduit re-caps between eruptions).
func erupting() -> bool:
	return _erupting_last


func _compute_erupting() -> bool:
	for s in _sources:
		if _source_venting(int(s["cell"])):
			return true
	return false


func _source_venting(cell: int) -> bool:
	var layer: int = _f._dim_x * _f._dim_z
	var dy: int = _f._dim_y
	var solid: PackedByteArray = _f._solid
	var c: int = cell
	var climbed: int = 0
	while true:
		var iy: int = c / layer
		if iy >= dy - 1:
			break
		var above: int = c + layer
		if solid[above] != 0:
			break                                        # capped by rock → conduit plugged
		c = above
		climbed += 1
	if climbed < VENT_MIN_CLIMB:
		return false
	return _f._lava[c] >= LAVA_MIN                        # top open cell holds lava → lava is venting up the conduit


# --- Helpers ----------------------------------------------------------------

## Grid cell index for a world position (clamped into the volume), or -1 if the field has no cells.
func _cell_at(world_pos: Vector3) -> int:
	if _f._cell_count <= 0:
		return -1
	var ix: int = _f._col_i(world_pos.x, _f._origin.x)
	var iz: int = _f._col_i(world_pos.z, _f._origin.z)
	var iy: int = clampi(int(round((world_pos.y - _f._origin.y) / _f._cell_size)), 0, _f._dim_y - 1)
	return _f._idx(ix, iy, iz)
