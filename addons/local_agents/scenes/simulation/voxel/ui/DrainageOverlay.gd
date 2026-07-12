class_name LADrainageOverlay
extends MeshInstance3D

## DEBUG: highlight the DRAINAGE NETWORK — the "gouges in the ground" where rivers should run. On an
## ocean-heavy planet the channels are hard to spot, so this draws bright cyan spikes along the land's
## flow paths, computed by standard hydrology: fill the depressions (priority-flood), point every land
## column downhill (steepest descent on the filled surface), then accumulate upstream area — cells with
## a lot of upstream area are the trunk channels (taller/brighter here), the thin ones are headwater
## creeks. Static terrain → computed ONCE on first toggle, drawn through terrain/water (no depth test) so
## you can always see where the water is meant to collect. Toggle with the debug key / --debug-rivers.
## (Explicit types only — no ':=' .)

const RIVER_ACCUM_MIN: int = 5         # upstream cells before a column counts as a visible channel
const SPIKE_BASE: float = 5.0          # shortest channel spike (world units)
const SPIKE_PER_LOG: float = 6.0       # extra height per log2(accum) — trunk rivers tower over creeks
const SPIKE_MAX: float = 60.0

var _field = null
var _im: ImmediateMesh = null
var _mat: StandardMaterial3D = null
var _built: bool = false


func setup(field) -> void:
	_field = field
	_im = ImmediateMesh.new()
	mesh = _im
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.no_depth_test = true                    # draw through terrain + water so channels are always visible
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = _mat
	visible = false


func toggle() -> void:
	set_shown(not visible)


func set_shown(on: bool) -> void:
	visible = on
	if on and not _built:
		_rebuild()


# Deferred build: if shown before the field's solid mask is seeded (e.g. --debug-rivers at startup), keep
# retrying until it's ready. Cheap: only runs while visible-but-unbuilt, then stops.
func _process(_dt: float) -> void:
	if visible and not _built:
		_rebuild()


## Recompute + redraw the drainage spikes (terrain is static, so this is a one-shot on first show).
func _rebuild() -> void:
	# Wait until the field has actually SEEDED the solid mask (_ready_sim) — not just allocated it. Rebuilding
	# on the all-zero pre-seed mask would find no land and then latch _built, so the network never appears.
	if _field == null or _field._sphere == null or not _field._ready_sim or _field._solid.size() != _field._cell_count:
		return
	var grid: RefCounted = _field._sphere
	var out: Dictionary = _flow_accumulation(grid)
	var accum: PackedInt32Array = out["accum"]
	var eground: PackedInt32Array = out["eground"]
	var max_accum: int = out["max_accum"]
	_built = true                                            # computed successfully — don't retry (even if sparse)
	if OS.has_environment("LA_WATER_DEBUG"):
		print("DRAINAGE_MAXACCUM=%d" % max_accum)
	if max_accum < RIVER_ACCUM_MIN:
		return
	var depth: int = int(grid.depth)
	var core_r: float = float(grid.core_radius)
	var cs: float = float(grid.cell_size)
	var sc: int = int(grid.surf_count)
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var drawn: int = 0
	for s in range(sc):
		var a: int = accum[s]
		if a < RIVER_ACCUM_MIN:
			continue
		var dir: Vector3 = grid.surf_dir(s)
		var base_r: float = core_r + float(eground[s]) * cs      # top of the ground surface
		var base: Vector3 = dir * base_r                          # BODY-LOCAL (this node rides the planet spin)
		var mag: float = clampf(log(float(a)) / log(2.0), 1.0, 10.0)
		var h: float = minf(SPIKE_BASE + mag * SPIKE_PER_LOG, SPIKE_MAX)
		# colour: creeks cyan → trunk rivers bright white-blue; brighter + taller with upstream area.
		var f: float = clampf((mag - 1.0) / 9.0, 0.0, 1.0)
		var col: Color = Color(0.25 + 0.6 * f, 0.9, 1.0, 0.95)
		var tip: Color = Color(col.r, col.g, col.b, 0.25)        # fade toward the tip but stay visible
		# vertical spike
		_im.surface_set_color(col)
		_im.surface_add_vertex(base)
		_im.surface_set_color(tip)
		_im.surface_add_vertex(base + dir * h)
		# a small base CROSS (two tangents) so each channel reads as a bright marker even from orbit
		var t1: Vector3 = dir.cross(Vector3.UP)
		if t1.length() < 0.01:
			t1 = dir.cross(Vector3.RIGHT)
		t1 = t1.normalized()
		var t2: Vector3 = dir.cross(t1).normalized()
		var xr: float = 1.2 + 1.6 * f
		for tan in [t1, t2]:
			_im.surface_set_color(col)
			_im.surface_add_vertex(base - tan * xr)
			_im.surface_set_color(col)
			_im.surface_add_vertex(base + tan * xr)
		drawn += 1
	_im.surface_end()
	_built = true
	if OS.has_environment("LA_WATER_DEBUG"):
		print("DRAINAGE_OVERLAY={channels:%d, max_accum:%d}" % [drawn, max_accum])


## D8 flow accumulation on a CONTINUOUS (sub-shell) elevation sampled from the analytic terrain SDF — the
## sub-cell height breaks the flat cellular plateaus so flow actually concentrates into channels (the
## shell-quantised version left the plateaus tie-flat → no drainage). Returns {accum, eground, max_accum}.
func _flow_accumulation(grid: RefCounted) -> Dictionary:
	var sc: int = int(grid.surf_count)
	var depth: int = int(grid.depth)
	var core_r: float = float(grid.core_radius)
	var cs: float = float(grid.cell_size)
	var center: Vector3 = grid.center
	var surf_nbr: PackedInt32Array = grid.surf_nbr
	var solid: PackedByteArray = _field._solid
	var terrain = _field._terrain
	var has_sdf: bool = terrain != null and terrain.has_method("sdf_at")
	var sea_r: float = terrain.sea_radius() if terrain != null and terrain.has_method("sea_radius") else core_r

	# CONTINUOUS surface elevation per column (sub-shell), + the ground shell for spike placement.
	var elev: PackedFloat32Array = PackedFloat32Array()
	elev.resize(sc)
	var eground: PackedInt32Array = PackedInt32Array()
	eground.resize(sc)
	var is_land: PackedByteArray = PackedByteArray()
	is_land.resize(sc)
	for s in range(sc):
		var base: int = s * depth
		var sr: int = -1
		for r in range(depth - 1, -1, -1):
			if solid[base + r] != 0:
				sr = r
				break
		eground[s] = (sr + 1) if sr >= 0 else 0
		if sr < 0:
			is_land[s] = 0
			elev[s] = -1.0e9
			continue
		var dir: Vector3 = grid.surf_dir(s)
		var e: float = core_r + float(sr + 1) * cs               # quantised ground top (fallback)
		if has_sdf:
			# Linear-interpolate the SDF zero-crossing between the ground cell centre (solid, sdf<0) and the
			# cell-above centre (air, sdf>0) → the true sub-cell surface radius.
			var r_lo: float = core_r + (float(sr) + 0.5) * cs
			var r_hi: float = core_r + (float(sr) + 1.5) * cs
			var d_lo: float = terrain.sdf_at(center + dir * r_lo)
			var d_hi: float = terrain.sdf_at(center + dir * r_hi)
			if d_hi > d_lo:
				e = clampf(r_lo + (-d_lo) / (d_hi - d_lo) * (r_hi - r_lo), r_lo, r_hi)
		elev[s] = e
		is_land[s] = 1 if e > sea_r else 0

	# Steepest descent + accumulation on the continuous surface (process high→low). Land columns only.
	var downstream: PackedInt32Array = PackedInt32Array()
	downstream.resize(sc)
	downstream.fill(-1)
	var order: Array = []
	for s in range(sc):
		if is_land[s] == 0:
			continue
		var lowest: int = -1
		var lowest_e: float = elev[s]
		for slot in range(4):
			var n: int = surf_nbr[s * 4 + slot]
			if n < 0:
				continue
			if elev[n] < lowest_e:
				lowest_e = elev[n]
				lowest = n                                       # may be an ocean cell (a river mouth) — fine
		downstream[s] = lowest
		order.append(s)
	order.sort_custom(func(a: int, b: int) -> bool: return elev[a] > elev[b])

	var accum: PackedInt32Array = PackedInt32Array()
	accum.resize(sc)
	accum.fill(0)
	for s in order:
		accum[s] += 1
		var d: int = downstream[s]
		if d >= 0 and is_land[d] == 1:                           # only pass flow on while still on land
			accum[d] += accum[s]
	var max_accum: int = 0
	for s in order:
		if accum[s] > max_accum:
			max_accum = accum[s]
	return {"accum": accum, "eground": eground, "max_accum": max_accum}
