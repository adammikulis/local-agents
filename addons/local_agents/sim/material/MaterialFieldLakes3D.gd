class_name LAMaterialFieldLakes3D
extends RefCounted

## Runs a PRIORITY-FLOOD depression fill (Barnes et al.) over the surface columns: starting from the sea, it

## Fill the field's enclosed land basins with static lake water. Reads/writes the field's packed arrays directly
## (the same access the query/inject/step sibling modules use).
func seed(field) -> void:
	var grid: RefCounted = field._sphere
	if grid == null or field._solid.size() != field._cell_count:
		return
	if field._terrain == null or not field._terrain.has_method("sea_radius"):
		return
	var sea_r: float = field._terrain.sea_radius()
	if sea_r <= 0.0:
		return
	var sc: int = int(grid.surf_count)
	var depth: int = int(grid.depth)
	var mid: PackedFloat32Array = grid.shell_mid
	var face: PackedFloat32Array = grid.shell_face
	var surf_nbr: PackedInt32Array = grid.surf_nbr
	var solid: PackedByteArray = field._solid

	# Ground shell per column: eground = the shell index of the ground SURFACE (top of the outermost solid cell).
	# surfr = that outermost solid r (-1 = an all-open column, i.e. deep ocean over no floor → treat as outlet).
	var eground: PackedInt32Array = PackedInt32Array()
	eground.resize(sc)
	var surfr: PackedInt32Array = PackedInt32Array()
	surfr.resize(sc)
	for s in range(sc):
		var base: int = s * depth
		var sr: int = -1
		for r in range(depth - 1, -1, -1):
			if solid[base + r] != 0:
				sr = r
				break
		surfr[s] = sr
		eground[s] = (sr + 1) if sr >= 0 else 0
	var sea_shell: int = clampi(grid.face_of(sea_r), 0, depth)

	# PRIORITY-FLOOD (integer buckets). W[s] = the water level (spill shell) of s's basin; INF = unreached.
	var inf: int = depth + 2
	var w: PackedInt32Array = PackedInt32Array()
	w.resize(sc)
	w.fill(inf)
	var done: PackedByteArray = PackedByteArray()
	done.resize(sc)
	done.fill(0)
	var buckets: Array = []
	for i in range(depth + 2):
		buckets.append(PackedInt32Array())
	# Outlets: every ocean column (ground at/below sea) holds water at sea level and drains freely.
	for s in range(sc):
		if eground[s] <= sea_shell:
			w[s] = sea_shell
			buckets[sea_shell].push_back(s)
	# Process buckets low→high; a cell finalises at its spill level, then raises its neighbours to at least that.
	for level in range(0, depth + 1):
		var qi: int = 0
		while qi < buckets[level].size():
			var c: int = buckets[level][qi]
			qi += 1
			if done[c] != 0:
				continue
			done[c] = 1
			for slot in range(4):
				var n: int = surf_nbr[c * 4 + slot]
				if n < 0 or done[n] != 0:
					continue
				var neww: int = maxi(eground[n], level)      # to leave the basin, water must climb to `level`
				if neww < w[n]:
					w[n] = neww
					buckets[neww].push_back(n)

	# Fill: a land column whose basin spill level rose above its own ground is underwater up to that level.
	var lake_cells: int = 0
	for s in range(sc):
		if surfr[s] < 0 or eground[s] <= sea_shell:
			continue                                          # ocean / already static sea
		var wsurf: int = w[s]
		if wsurf >= inf or wsurf <= eground[s]:
			continue                                          # drains to the sea → no standing lake
		var base2: int = s * depth
		for r in range(surfr[s] + 1, mini(wsurf, depth)):     # open cells between ground and the water surface
			var c2: int = base2 + r
			if field._solid[c2] == 0 and field._water[c2] <= 0.0:
				field._water[c2] = 1.0
				lake_cells += 1
	var river_cells: int = _seed_rivers(field, grid, sea_r, sc, depth, surf_nbr)
	if OS.has_environment("LA_WATER_DEBUG"):
		print("LAKES_SEEDED={cells:%d, rivers:%d}" % [lake_cells, river_cells])


const RIVER_ACCUM_MIN: int = 6           # upstream cells before a channel carries a visible river
const RIVER_MAX_DEPTH_CELLS: int = 2     # deepest a big trunk river incises (cells below the valley floor)
const RIVER_CARVE_MAX: int = 6000        # safety cap on channel carves (bounds the one-time world-gen cost)

func _seed_rivers(field, grid: RefCounted, sea_r: float, sc: int, depth: int,
		surf_nbr: PackedInt32Array) -> int:
	var terrain = field._terrain
	if terrain == null or not terrain.has_method("sdf_at"):
		return 0
	var center: Vector3 = grid.center
	var solid: PackedByteArray = field._solid
	var mid: PackedFloat32Array = grid.shell_mid
	var face: PackedFloat32Array = grid.shell_face
	# CONTINUOUS surface elevation + ground shell per column.
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
		var r_lo: float = mid[sr]
		var r_hi: float = mid[mini(sr + 1, depth - 1)]
		var d_lo: float = terrain.sdf_at(center + dir * r_lo)
		var d_hi: float = terrain.sdf_at(center + dir * r_hi)
		var e: float = face[sr + 1]
		if d_hi > d_lo:
			e = clampf(r_lo + (-d_lo) / (d_hi - d_lo) * (r_hi - r_lo), r_lo, r_hi)
		elev[s] = e
		is_land[s] = 1 if e > sea_r else 0
	# Steepest descent + upstream-area accumulation (process high→low).
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
			if n >= 0 and elev[n] < lowest_e:
				lowest_e = elev[n]
				lowest = n
		downstream[s] = lowest
		order.append(s)
	order.sort_custom(func(a: int, b: int) -> bool: return elev[a] > elev[b])
	var accum: PackedInt32Array = PackedInt32Array()
	accum.resize(sc)
	accum.fill(0)
	for s in order:
		accum[s] += 1
		var d: int = downstream[s]
		if d >= 0 and is_land[d] == 1:
			accum[d] += accum[s]
	var can_carve: bool = terrain.has_method("carve_sphere") and not OS.has_environment("LA_NO_RIVER_CARVE")
	var center2: Vector3 = grid.center
	var count: int = 0
	var carved: int = 0
	for s in order:
		if accum[s] < RIVER_ACCUM_MIN:
			continue
		var mag: int = clampi(int(log(float(accum[s])) / log(4.0)), 1, RIVER_MAX_DEPTH_CELLS)
		var base2: int = s * depth
		var top: int = eground[s] - 1                            # shell of the top solid cell (the valley floor)
		if top < 0:
			continue
		if can_carve and carved < RIVER_CARVE_MAX:
			# Bite the top `mag` shells out of the ground with a small sphere at the surface point; overlapping
			# spheres down the channel trace one continuous incised valley. Radius grows with the incision depth.
			var cdir: Vector3 = grid.surf_dir(s)
			var dr_top: float = grid.shell_dr[top]
			terrain.carve_sphere(center2 + cdir * elev[s], dr_top * (0.5 + 0.7 * float(mag)))
			carved += 1
			for j in range(mag):                                 # keep the field's solidity consistent with the carve
				var rc: int = top - j
				if rc >= 0:
					field._solid[base2 + rc] = 0
		# Fill: the carved notch (cells eground-mag .. eground-1), or — carving off — a thin ribbon above the floor.
		var lo: int = maxi(0, eground[s] - mag) if can_carve else eground[s]
		var hi: int = eground[s] if can_carve else (eground[s] + mag)
		for r in range(lo, mini(hi, depth)):
			var c: int = base2 + r
			if field._solid[c] == 0 and field._water[c] <= 0.0:
				field._water[c] = 1.0
				count += 1
	if OS.has_environment("LA_WATER_DEBUG"):
		print("RIVER_CARVE={filled:%d, carved:%d, cap:%d}" % [count, carved, RIVER_CARVE_MAX])
	return count
