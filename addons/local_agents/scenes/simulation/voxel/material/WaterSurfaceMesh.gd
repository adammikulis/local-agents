class_name LAWaterSurfaceMesh
extends RefCounted

## Pure builder for the dynamic water surface mesh — the geometry half of LAMaterialFieldRender3D, split out
## so the renderer node stays thin (and both stay under the file-size gate), exactly as CoverTextureBaker is
## split from the field. Stateless: `build()` takes the field's per-cell arrays + the cubed-sphere grid and
## returns ready-to-upload ArrayMesh surface arrays. No GPU work — the water CA already ran on the field; this
## just turns the settled `water` column heights near the camera into a welded, flowing surface sheet.
##
## Emits vertices in a LOCAL patch frame (caller's inverse transform) whose +Y is the camera radial, because
## VoxelWater.gdshader is a flat/Y-up shader (its swell + normal assume world-up = +Y). Over the near cap the
## curvature is small, so Y-up is locally correct. One vertex per surface COLUMN centre; adjacent columns weld
## into quads via the grid's seam-aware surf_nbr table (continuous across cube-face seams, no special-casing).
## Per-vertex COLOR = (flow.x, flow.z, steepness, salinity) in the [0,1] encoding the shader expects.
##
## v1 renders DYNAMIC land water only (springs/rivers/lakes/floods) and leaves the calm sea to the cheap ocean
## sphere; unifying the sea into this surface is a follow-up (A2). (Explicit types only — no ':=' .)

const N_A1: int = 1      # surf_nbr slot: +a lateral neighbour
const N_B1: int = 3      # surf_nbr slot: +b lateral neighbour
const N_A0: int = 0      # -a
const N_B0: int = 2      # -b
const SEA_BIAS: float = 0.4   # draw the dynamic near-cap sea this far OUTSIDE the ocean sphere so it occludes it (no z-fight)


## Build the water surface. Returns {"verts": PackedVector3Array, "normals": PackedVector3Array,
## "colors": PackedColorArray, "indices": PackedInt32Array, "count": int}. `count`==0 → nothing to draw.
func build(grid: RefCounted, water: PackedFloat32Array, solid: PackedByteArray, static_cells: PackedByteArray,
		inv_xform: Transform3D, cam_radial: Vector3, cap_cos: float,
		render_min: float, max_mass: float, sea_radius: float, sea_wave_eps: float) -> Dictionary:
	var depth: int = grid.depth
	var core_radius: float = grid.core_radius
	var cell_size: float = grid.cell_size
	var center: Vector3 = grid.center
	var sc: int = grid.surf_count
	var surf_nbr: PackedInt32Array = grid.surf_nbr

	# --- scratch, per surface column (only the near-cap subset is filled) ---
	var has: PackedByteArray = PackedByteArray()
	has.resize(sc)
	has.fill(0)
	var rtop: PackedFloat32Array = PackedFloat32Array()
	rtop.resize(sc)
	var sal: PackedFloat32Array = PackedFloat32Array()
	sal.resize(sc)
	var wpos: PackedVector3Array = PackedVector3Array()
	wpos.resize(sc)

	# --- PASS 1: find the free-surface cell of each near-cap column; classify SEA (salt) / LAKE+RIVER (fresh) ---
	for s in sc:
		var dir: Vector3 = grid.surf_dir(s)
		if dir.dot(cam_radial) < cap_cos:
			continue                                     # outside the visible cap → skip (relevance LOD)
		var base: int = s * depth
		var found: bool = false
		var r_top: float = 0.0
		var salinity: float = 0.0
		for r in range(depth - 1, -1, -1):
			var c: int = base + r
			if solid[c] != 0:
				break                                    # hit ground before any water → dry column
			if static_cells[c] != 0:
				# Static water body. Above sea level = a perched freshwater LAKE (its brim-full cell top is the
				# surface); at sea level = the calm SEA, drawn here across the near cap and biased just OUTWARD of
				# the cheap ocean sphere so it occludes it (waves/foam/ripples near the player, sphere far away).
				if core_radius + float(r + 1) * cell_size > sea_radius + sea_wave_eps:
					r_top = core_radius + float(r + 1) * cell_size
					salinity = 0.0
				else:
					r_top = sea_radius + SEA_BIAS
					salinity = 1.0
				found = true
				break
			if water[c] >= render_min:
				# dynamic FRESH water (river / spring / flood): sub-cell height → smooth shoreline
				r_top = core_radius + (float(r) + clampf(water[c] / max_mass, 0.0, 1.0)) * cell_size
				salinity = 0.0
				found = true
				break
		if not found:
			continue
		has[s] = 1
		rtop[s] = r_top
		sal[s] = salinity
		wpos[s] = center + dir * r_top

	# --- PASS 2: emit one vertex per surfaced column, with flow + steepness from neighbour height gradient ---
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var vidx: PackedInt32Array = PackedInt32Array()
	vidx.resize(sc)
	vidx.fill(-1)
	for s in sc:
		if has[s] == 0:
			continue
		var wp: Vector3 = wpos[s]
		var a_col: int = surf_nbr[s * 4 + N_A1]
		var b_col: int = surf_nbr[s * 4 + N_B1]
		var na_col: int = surf_nbr[s * 4 + N_A0]
		var nb_col: int = surf_nbr[s * 4 + N_B0]
		# Downhill flow = negative gradient of the water-surface radius across the ±a / ±b neighbours, in world
		# space, then rotated into the local patch frame's XZ (what the shader scrolls detail along).
		var da: float = _nbr_drop(has, rtop, a_col, na_col, rtop[s])
		var db: float = _nbr_drop(has, rtop, b_col, nb_col, rtop[s])
		var a_hat: Vector3 = _tangent(grid, s, a_col, na_col, wp, center)
		var b_hat: Vector3 = _tangent(grid, s, b_col, nb_col, wp, center)
		var flow_world: Vector3 = -(a_hat * da + b_hat * db)
		# Steepness drives the shader's whitewater foam — only meaningful for FLOWING fresh water (rivers/falls).
		# On the flat SEA the r_top step at a sea↔lake / bias boundary would spike the gradient into false foam
		# facets, so zero it for salt cells; the sea's look is swell + shoreline foam, not gradient whitewater.
		var steep: float = 0.0
		if sal[s] < 0.5:
			steep = clampf(flow_world.length() / cell_size, 0.0, 1.0)
		var flow_local: Vector3 = inv_xform.basis * flow_world
		var fl: Vector2 = Vector2(flow_local.x, flow_local.z)
		if sal[s] >= 0.5 or fl.length() <= 1.0e-4:
			fl = Vector2.ZERO                                # sea uses the shader's gentle default scroll, not mesh flow
		else:
			fl = fl.normalized()
		vidx[s] = verts.size()
		verts.push_back(inv_xform * wp)
		normals.push_back(Vector3.UP)                    # placeholder; VoxelWater.gdshader recomputes NORMAL
		colors.push_back(Color(fl.x * 0.5 + 0.5, fl.y * 0.5 + 0.5, steep, sal[s]))  # a = per-vertex salinity (0 fresh, 1 salt)

	# --- PASS 3: weld columns into quads (drop a quad if any corner is missing → natural shoreline edge) ---
	var indices: PackedInt32Array = PackedInt32Array()
	for s in sc:
		if vidx[s] < 0:
			continue
		var a_col: int = surf_nbr[s * 4 + N_A1]
		var b_col: int = surf_nbr[s * 4 + N_B1]
		if a_col < 0 or b_col < 0 or vidx[a_col] < 0 or vidx[b_col] < 0:
			continue
		var d_col: int = surf_nbr[a_col * 4 + N_B1]      # the +a,+b diagonal column
		if d_col < 0 or vidx[d_col] < 0:
			continue
		var v0: int = vidx[s]
		var va: int = vidx[a_col]
		var vb: int = vidx[b_col]
		var vd: int = vidx[d_col]
		# two triangles: (s, a, d) and (s, d, b). Winding is fixed up by the shader's cull_disabled anyway.
		indices.push_back(v0); indices.push_back(va); indices.push_back(vd)
		indices.push_back(v0); indices.push_back(vd); indices.push_back(vb)

	return {"verts": verts, "normals": normals, "colors": colors, "indices": indices, "count": verts.size()}


## Central-difference drop of the surface radius toward the +side neighbour (higher r_top on the −side, lower
## on the +side → positive da means it falls toward +). Falls back to a one-sided diff at a shoreline edge.
func _nbr_drop(has: PackedByteArray, rtop: PackedFloat32Array, plus_col: int, minus_col: int, mine: float) -> float:
	var hp: bool = plus_col >= 0 and has[plus_col] != 0
	var hm: bool = minus_col >= 0 and has[minus_col] != 0
	if hp and hm:
		return (rtop[minus_col] - rtop[plus_col]) * 0.5
	if hp:
		return mine - rtop[plus_col]
	if hm:
		return rtop[minus_col] - mine
	return 0.0


## World-space unit tangent from column `s` toward its +side neighbour (its world position minus mine),
## falling back to the −side if the + neighbour is absent.
func _tangent(grid: RefCounted, s: int, plus_col: int, minus_col: int, my_wp: Vector3, center: Vector3) -> Vector3:
	var ref_col: int = plus_col if plus_col >= 0 else minus_col
	if ref_col < 0:
		return Vector3.ZERO
	var sign: float = 1.0 if plus_col >= 0 else -1.0
	var other: Vector3 = center + grid.surf_dir(ref_col) * my_wp.distance_to(center)
	var t: Vector3 = (other - my_wp) * sign
	return t.normalized() if t.length() > 1.0e-6 else Vector3.ZERO
