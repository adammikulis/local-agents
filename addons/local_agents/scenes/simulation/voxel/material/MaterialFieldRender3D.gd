class_name LAMaterialFieldRender3D
extends RefCounted

## LAMaterialFieldRender3D — the DYNAMIC-WATER SURFACE render adapter of the dense 3D MaterialField3D,
## factored out so the field node stays a thin simulation core (and under the file-size gate). It owns
## the water MeshInstance3D (parented under the field) and rebuilds it each frame from the field's water
## column tops as ONE smooth welded heightfield. Holds only the render node/mesh/material; it reaches
## into the owning LAMaterialField3D (`_f`) for the per-cell arrays + geometry, exactly as the concern
## modules do. (Explicit types only — no ':=' inferred typing.)

const WATER_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelWater.gdshader"

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _surface_mi: MeshInstance3D = null
var _surface_mesh: ArrayMesh = null
var _water_mat: Material = null


func setup(field) -> void:
	_f = field


## Build the water surface MeshInstance3D under the field node (idempotent).
func build() -> void:
	if _surface_mi != null:
		return
	if _water_mat == null:
		# The proper freshwater surface shader (waves/depth/foam/fresnel) — not a flat plain-blue material.
		var sh: Shader = load(WATER_SHADER_PATH) as Shader
		if sh != null:
			var sm: ShaderMaterial = ShaderMaterial.new()
			sm.shader = sh
			_water_mat = sm
		else:
			var m: StandardMaterial3D = StandardMaterial3D.new()
			m.albedo_color = Color(0.12, 0.42, 0.62, 0.72)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			_water_mat = m
	_surface_mesh = ArrayMesh.new()
	_surface_mi = MeshInstance3D.new()
	_surface_mi.name = "Water3DSurface"
	_surface_mi.mesh = _surface_mesh
	_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_f.add_child(_surface_mi)


## Rebuild the dynamic-water surface as ONE smooth WELDED heightfield. For each XZ column take the top
## DYNAMIC water cell's surface height, then weld: each grid corner's height is the average of the wet
## cells touching it, so adjacent cells share corners and the surface blends smoothly and fades at the
## shoreline. Calm static sea is left to the ocean plane.
func rebuild_surface() -> void:
	if _surface_mesh == null:
		return
	var dx: int = _f._dim_x
	var dz: int = _f._dim_z
	var cs: float = _f._cell_size
	var render_min: float = _f.RENDER_MIN
	var max_mass: float = _f.MAX_MASS
	var sea_wave_eps: float = _f.SEA_WAVE_EPS
	var sea_level: float = _f.sea_level
	var origin: Vector3 = _f._origin

	# 1) Per column, the world Y of the top dynamic-water surface (NAN = nothing to mesh here).
	var col_surf: PackedFloat32Array = PackedFloat32Array()
	col_surf.resize(dx * dz)
	var any: bool = false
	for iz in range(dz):
		for ix in range(dx):
			var found: float = NAN
			for iy in range(_f._dim_y - 1, -1, -1):
				var i: int = (iy * dz + iz) * dx + ix
				if _f._solid[i] != 0 or _f._static[i] != 0:
					continue
				var m: float = _f._water[i]
				if m < render_min:
					continue
				var wy: float = origin.y + float(iy) * cs + (clampf(m, 0.0, max_mass) - 0.5) * cs
				# A sub-sea cell sitting at ~sea level is calm sea → the plane draws it.
				if origin.y + float(iy) * cs < sea_level and absf(wy - sea_level) < sea_wave_eps:
					continue
				found = wy
				break
			col_surf[iz * dx + ix] = found
			if not is_nan(found):
				any = true

	if not any:
		if _surface_mesh.get_surface_count() > 0:
			_surface_mesh.clear_surfaces()
		return

	# 2) Accumulate each wet column's surface into its 4 shared corners ((dx+1)×(dz+1) corner grid).
	var cw: int = dx + 1
	var ccount: int = cw * (dz + 1)
	var ch: PackedFloat32Array = PackedFloat32Array()
	ch.resize(ccount)
	var cn: PackedInt32Array = PackedInt32Array()
	cn.resize(ccount)
	var half: float = cs * 0.5
	var ox: float = origin.x - half
	var oz: float = origin.z - half
	for iz in range(dz):
		for ix in range(dx):
			var surf: float = col_surf[iz * dx + ix]
			if is_nan(surf):
				continue
			var c0: int = iz * cw + ix
			var c1: int = c0 + 1
			var c2: int = c0 + cw
			var c3: int = c2 + 1
			ch[c0] += surf; cn[c0] += 1
			ch[c1] += surf; cn[c1] += 1
			ch[c2] += surf; cn[c2] += 1
			ch[c3] += surf; cn[c3] += 1
	for c in range(ccount):
		if cn[c] != 0:
			ch[c] = ch[c] / float(cn[c])

	# 3) Vertex per active corner + a smooth normal from the corner-height gradient.
	var vmap: PackedInt32Array = PackedInt32Array()
	vmap.resize(ccount)
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	for cj in range(dz + 1):
		for ci in range(cw):
			var c: int = cj * cw + ci
			if cn[c] == 0:
				vmap[c] = -1
				continue
			var hh: float = ch[c]
			vmap[c] = verts.size()
			verts.push_back(Vector3(ox + float(ci) * cs, hh, oz + float(cj) * cs))
			var hl: float = ch[c - 1] if (ci > 0 and cn[c - 1] != 0) else hh
			var hr: float = ch[c + 1] if (ci < cw - 1 and cn[c + 1] != 0) else hh
			var hd: float = ch[c - cw] if (cj > 0 and cn[c - cw] != 0) else hh
			var hu: float = ch[c + cw] if (cj < dz and cn[c + cw] != 0) else hh
			normals.push_back(Vector3(hl - hr, 2.0 * cs, hd - hu).normalized())

	# 4) Two triangles per wet column referencing its 4 shared corners.
	var indices: PackedInt32Array = PackedInt32Array()
	for iz in range(dz):
		for ix in range(dx):
			if is_nan(col_surf[iz * dx + ix]):
				continue
			var b0: int = iz * cw + ix
			var v0: int = vmap[b0]
			var v1: int = vmap[b0 + 1]
			var v2: int = vmap[b0 + cw + 1]
			var v3: int = vmap[b0 + cw]
			if v0 < 0 or v1 < 0 or v2 < 0 or v3 < 0:
				continue
			indices.push_back(v0); indices.push_back(v1); indices.push_back(v2)
			indices.push_back(v0); indices.push_back(v2); indices.push_back(v3)

	if _surface_mesh.get_surface_count() > 0:
		_surface_mesh.clear_surfaces()
	if verts.is_empty() or indices.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_surface_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _water_mat != null:
		_surface_mesh.surface_set_material(0, _water_mat)
