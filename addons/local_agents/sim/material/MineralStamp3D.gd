class_name LAMineralStamp3D
extends RefCounted


# The rheological lock-up the GPU's own `solid` derive uses. One declaration, so the SDF cannot disagree
# with the field about which cells are rock.
const GROW_THRESHOLD: float = LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const SHRINK_THRESHOLD: float = LAPhysical.RHEOLOGICAL_MOBILE_CRYSTAL_FRAC
const SCAN_EVERY: int = 4                # throttle: at most one crossing scan per this many active frames
const ACTIVE_WINDOW: int = 32            # frames to keep scanning after the last edit / found crossing
const STAMP_BUDGET: int = 96             # max SDF edits emitted per scan (bounds the per-frame remesh burst)

var _f = null                            # owning LAMaterialField3D (reads its mineral mirrors + geometry)
var _window: int = 0                     # frames left in the active scan window (0 = idle, no per-frame cost)
var _tick: int = 0                       # cadence counter toward SCAN_EVERY

# Telemetry / proof (read by SIM_REPORT + the --stamp-test harness).
var grows: int = 0                       # total GROW stamps emitted over the run
var shrinks: int = 0                     # total SHRINK stamps emitted over the run
var last_scan_ms: float = 0.0            # wall cost of the most recent crossing scan (ms)
var last_grow_before_solid: bool = false # terrain.is_solid at the last grow point, sampled BEFORE the stamp
var last_grow_after_solid: bool = false  # ... and immediately AFTER — the same-frame growth proof
var last_grow_pos: Vector3 = Vector3.ZERO


func setup(field) -> void:
	_f = field


## Wake the scan: called when the CPU edits the mineral field so the next scans catch the resulting
## lock-up crossings, then idle again once the flurry settles.
func arm() -> void:
	_window = ACTIVE_WINDOW


func maybe_scan() -> void:
	if _window <= 0:
		return
	_window -= 1
	_tick += 1
	if _tick < SCAN_EVERY:
		return
	_tick = 0
	_scan()


# Scan for cells whose CEMENTED mineral fraction crossed the lock-up band vs the last-stamped `_solid`
# cache and emit a GROW/SHRINK SDF edit for each, up to STAMP_BUDGET. Gated to the active window + cadence.
func _scan() -> void:
	var terrain = _f._terrain
	if terrain == null or not terrain.has_method("fill_rock") or not terrain.has_method("carve_sphere"):
		return
	var n: int = _f._cell_count
	var sil: PackedFloat32Array = _f._silicate
	var cem: PackedFloat32Array = _f._cement
	var solid: PackedByteArray = _f._solid
	if sil.size() != n or cem.size() != n or solid.size() != n:
		return
	var t0: int = Time.get_ticks_usec()
	var size: float = _f._cell_size * 0.7          # SDF edit extent ~ one cell (fill_rock scales by this)
	var budget: int = STAMP_BUDGET
	var found: int = 0
	# H₂O the solidity change has to account for (see _settle_h2o). Gathered here, queued once at the end.
	var bury_src: PackedInt32Array = PackedInt32Array()
	var bury_dst: PackedInt32Array = PackedInt32Array()
	for c in range(n):
		if budget <= 0:
			break
		var was_solid: bool = solid[c] != 0
		var rf: float = maxf(sil[c], 0.0) * clampf(cem[c], 0.0, 1.0)
		if not was_solid and rf >= GROW_THRESHOLD:
			var wp: Vector3 = _f.cell_world_pos_linear(c)
			last_grow_before_solid = terrain.is_solid(wp)
			terrain.fill_rock(wp, size, LAFieldGeometry.up(_f, c))
			last_grow_after_solid = terrain.is_solid(wp)
			last_grow_pos = wp
			solid[c] = 1
			bury_src.append(c)
			bury_dst.append(_open_neighbour(c, solid))
			grows += 1
			found += 1
			budget -= 1
		elif was_solid and rf <= SHRINK_THRESHOLD:
			terrain.carve_sphere(_f.cell_world_pos_linear(c), size)
			solid[c] = 0
			shrinks += 1
			found += 1
			budget -= 1
	_f._solid = solid                              # PackedByteArray is COW — write the updated mask back
	_settle_h2o(bury_src, bury_dst)
	last_scan_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	if found > 0:
		_window = ACTIVE_WINDOW                     # sustained activity keeps the scan awake
		# The CPU solid mask changed (land grew/shrank) → re-seed the GPU solid/static buffers next begin_frame.
		if _f._gpu != null and _f._gpu.has_method("mark_solid_dirty"):
			_f._gpu.mark_solid_dirty()
	if OS.has_environment("LA_STAMP_DEBUG"):
		print("STAMP_SCAN={ms:%.3f, found:%d, cells:%d}" % [last_scan_ms, found, n])


## Rock CLOSING over a cell has to put that cell's h2o somewhere. Rock OPENING does not: the water was
## already there, and free or in a pore is a fact about the cell, not about the water.
func _settle_h2o(bury_src: PackedInt32Array, bury_dst: PackedInt32Array) -> void:
	if _f == null or _f._inject == null or _f._gpu == null:
		return
	var q = _f._inject.queue
	if bury_src.size() > 0:
		var keep_src: PackedInt32Array = PackedInt32Array()
		var keep_dst: PackedInt32Array = PackedInt32Array()
		var lost: PackedInt32Array = PackedInt32Array()
		for i in bury_src.size():
			if bury_dst[i] >= 0:
				keep_src.append(bury_src[i])
				keep_dst.append(bury_dst[i])
			else:
				lost.append(bury_src[i])
		if keep_src.size() > 0:
			q.displace("h2o", keep_src, "h2o", keep_dst)
		if lost.size() > 0:
			q.discard("h2o", lost)


## The nearest OPEN neighbour of `c`, preferring the one UP the local vertical so displaced water rises
## rather than being pushed sideways into a hillside. -1 when the cell is fully enclosed by rock.
func _open_neighbour(c: int, solid: PackedByteArray) -> int:
	if _f._grid == null:
		return -1
	var hi: int = LAFieldGeometry.above(_f, c)
	if hi >= 0 and hi < solid.size() and solid[hi] == 0:
		return hi
	var nbr: PackedInt32Array = _f._grid.neighbours
	var down_slot: int = LAFieldGeometry.slot_toward(LAFieldGeometry.down(_f, c))
	for d in LAVoxelGrid.SLOTS:
		if d == down_slot or d == LAVoxelGrid.opposite_slot(down_slot):
			continue
		var nb: int = nbr[c * LAVoxelGrid.SLOTS + d]
		if nb >= 0 and nb < solid.size() and solid[nb] == 0:
			return nb
	var lo: int = LAFieldGeometry.below(_f, c)
	return lo if lo >= 0 and lo < solid.size() and solid[lo] == 0 else -1


## TEST HOOK (--stamp-test): raise a void cell's mineral to `amount` as consolidated rock, so the next scan
## fires a GROW stamp. The gain is a sourceless add and is booked as mineral_minted. Not used in normal play.
func debug_deposit(world_pos: Vector3, amount: float) -> void:
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count or _f._silicate.size() != _f._cell_count:
		return
	var want: float = clampf(amount, 0.0, 1.0)
	var gain: float = want - _f._silicate[c]
	_f._silicate[c] = maxf(_f._silicate[c], want)
	if gain > 0.0 and _f._inject != null:
		_f._inject.queue.add("silicate", PackedInt32Array([c]), PackedFloat32Array([gain]), want)
		if _f._gpu != null:
			_f._gpu.add_field_sparse("cement", PackedInt32Array([c]), PackedFloat32Array([1.0]), 1.0)
	arm()
