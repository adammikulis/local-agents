class_name LAMineralStamp3D
extends RefCounted


const GROW_THRESHOLD: float = 0.55       # hysteresis high: void->solid only once rock_fill rises past this
const SHRINK_THRESHOLD: float = 0.45     # hysteresis low: solid->void only once rock_fill falls below this
const SCAN_EVERY: int = 4                # throttle: at most one crossing scan per this many active frames
# Keep the active window SHORT: a CPU edit's crossing round-trips through the GPU in a few frames, and a
# still-cooling lava flow re-arms the window every time a crossing is actually found (see _scan). A long
# blind window would burn ~O(cell_count) futile scans and dent fps; this catches the edit, then sleeps.
const ACTIVE_WINDOW: int = 32            # frames to keep scanning after the last edit / found crossing
const STAMP_BUDGET: int = 96             # max SDF edits emitted per scan (bounds the per-frame remesh burst)

var _f = null                            # owning LAMaterialField3D (read its _rock_fill/_solid + geometry)
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


## Wake the scan: called when the CPU edits the mineral field (a debug deposit) so the next
## scans catch the resulting 0.5-crossings, then idle again once the flurry settles. rock_fill is
## demand-gated (SITUATIONAL_CHANNELS), so also wake ITS readback -- mirrors add_heat waking "fire".
func arm() -> void:
	_window = ACTIVE_WINDOW
	if _f != null and _f._gpu != null:
		_f._gpu.request_channel("rock_fill")


func maybe_scan() -> void:
	if _window <= 0:
		return
	if _f != null and _f._gpu != null and _f._gpu.has_method("request_channel"):
		_f._gpu.request_channel("rock_fill")
	_window -= 1
	_tick += 1
	if _tick < SCAN_EVERY:
		return
	_tick = 0
	_scan()


# Scan for rock_fill cells that crossed 0.5 (with hysteresis) vs the last-stamped `_solid` cache and emit a
# GROW/SHRINK SDF edit for each, up to STAMP_BUDGET. O(cell_count) but gated to the active window + cadence,
# so most frames pay nothing; measured cost is reported via last_scan_ms.
func _scan() -> void:
	var terrain = _f._terrain
	if terrain == null or not terrain.has_method("fill_rock") or not terrain.has_method("carve_sphere"):
		return
	var n: int = _f._cell_count
	var rock: PackedFloat32Array = _f._rock_fill
	var solid: PackedByteArray = _f._solid
	if rock.size() != n or solid.size() != n:
		return
	var t0: int = Time.get_ticks_usec()
	var size: float = _f._cell_size * 0.7          # SDF edit extent ~ one cell (fill_rock scales by this)
	var budget: int = STAMP_BUDGET
	var found: int = 0
	# H₂O the solidity change has to account for (see _settle_h2o). Gathered here, queued once at the end.
	var bury_src: PackedInt32Array = PackedInt32Array()
	var bury_dst: PackedInt32Array = PackedInt32Array()
	var free_soil: PackedInt32Array = PackedInt32Array()
	for c in range(n):
		if budget <= 0:
			break
		var was_solid: bool = solid[c] != 0
		var rf: float = rock[c]
		if not was_solid and rf >= GROW_THRESHOLD:
			var wp: Vector3 = _f.cell_world_pos_linear(c)
			last_grow_before_solid = terrain.is_solid(wp)
			terrain.fill_rock(wp, size, _f.cell_radial(c))
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
			free_soil.append(c)
			shrinks += 1
			found += 1
			budget -= 1
	_f._solid = solid                              # PackedByteArray is COW — write the updated mask back
	_settle_h2o(bury_src, bury_dst, free_soil)
	last_scan_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	if found > 0:
		_window = ACTIVE_WINDOW                     # sustained activity keeps the scan awake
		# The CPU solid mask changed (land grew/shrank) → re-seed the GPU solid/static buffers next begin_frame.
		# begin_frame no longer uploads them every step, so this is what keeps the on-device solidity in sync.
		if _f._gpu != null and _f._gpu.has_method("mark_solid_dirty"):
			_f._gpu.mark_solid_dirty()
	if OS.has_environment("LA_STAMP_DEBUG"):
		print("STAMP_SCAN={ms:%.3f, found:%d, cells:%d}" % [last_scan_ms, found, n])


func _settle_h2o(bury_src: PackedInt32Array, bury_dst: PackedInt32Array, free_soil: PackedInt32Array) -> void:
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
		for ch in ["water", "snow", "moisture"]:
			if keep_src.size() > 0:
				q.displace(ch, keep_src, ch, keep_dst)
			if lost.size() > 0:
				q.discard(ch, lost)
	if free_soil.size() > 0:
		q.displace("soil", free_soil, "water", free_soil)   # pore water of the melted rock, freed in place


## The nearest OPEN neighbour of `c`, preferring the radially OUTWARD one (slot N_OUT) so displaced water rises
## rather than being pushed sideways into a hillside. -1 when the cell is fully enclosed by rock.
func _open_neighbour(c: int, solid: PackedByteArray) -> int:
	if _f._sphere == null:
		return -1
	var nbr: PackedInt32Array = _f._sphere.neighbours
	# Slot order is LASphereGrid's: 0 = inward, 1 = outward, 2..5 = lateral. Try outward, then lateral, then in.
	for d in [1, 2, 3, 4, 5, 0]:
		var nb: int = nbr[c * 6 + d]
		if nb >= 0 and nb < solid.size() and solid[nb] == 0:
			return nb
	return -1


## TEST HOOK (--stamp-test proof): force a void cell's rock_fill fractional-solid so the next scan fires a
## GROW stamp — the deterministic proof that a rock_fill 0.5-crossing physically grows terrain. The edit is
## dirty-gated so it round-trips through the GPU. Not used in normal play.
func debug_deposit(world_pos: Vector3, amount: float) -> void:
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count or _f._rock_fill.size() != _f._cell_count:
		return
	_f._rock_fill[c] = maxf(_f._rock_fill[c], clampf(amount, 0.0, 1.0))
	_f._rock_fill_dirty = true
	arm()
