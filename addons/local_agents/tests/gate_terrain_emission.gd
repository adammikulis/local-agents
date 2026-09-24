extends SceneTree

## THE GROUND'S OWN LIGHT, READ OFF THE TERRAIN SHADER: the planet's material fed by LAHeatFieldTexture, lit
## by nothing, tonemapped linearly into a float target. --arm=glow holds black-body and deep-ice leaves to
## Planck x (1 - albedo) in the sunlit unit; --arm=field reads a graded grid through a turned, moved body.

const MATERIAL_PATH: String = "res://addons/local_agents/game/render/VoxelTerrainMaterial.tres"
const ARG_ARM: String = "--arm="
const PX_PER_M: float = 4.0
const EYE_M: float = 20.0
const CONTROL_EMISSION: Vector3 = Vector3(0.25, 1.5, 3.0)
# Error of the float32 shader sum over 10 nm bands, read back through a half-float target, as a share of
# the channel's magnitude: the sum of its terms before the primaries' negative lobes cancel them.
const REL_TOL: float = 0.005
# Radiance below this, in the sunlit unit, is compared absolutely: the half-float target's resolution.
const ABS_TOL: float = 2.0e-4
# Frames the upload and a visibility change are given before a frame is read.
const SETTLE_FRAMES: int = 6

const GLOW_TEMPS_C: Array[float] = [15.0, 700.0, 900.0, 1000.0, 1100.0, 1200.0, 1300.0, 1400.0]
const GLOW_EDGE_M: float = 4.0
const FIELD_DIMS: Vector3i = Vector3i(4, 2, 2)
const FIELD_EDGE_M: float = 8.0
const FIELD_SPLIT: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(2, 1, 0), Vector3i(3, 0, 1)]
const FIELD_T0_C: float = 950.0
const FIELD_DT_C: float = 23.0
# The body's pose in the world, and where the field box stands in the body, m.
const BODY_AXIS: Vector3 = Vector3(1.0, 2.0, 3.0)
const BODY_ANGLE_RAD: float = 0.7
const BODY_AT: Vector3 = Vector3(3000.5, -1200.25, 770.75)
const BOX_MIN_BODY: Vector3 = Vector3(100.0, 200.0, 300.0)
const BLOCK_AT: Vector3i = Vector3i(96, 192, 288)


class FieldStandIn extends RefCounted:
	var _grid: LAVoxelGrid = null
	var _star: LAStar = null
	var _mirrors: LAFieldMirrors = null
	var _pivot: Vector3 = Vector3.ZERO

	func centre() -> Vector3:
		return _pivot


class TerrainStandIn extends RefCounted:
	var _node: VoxelLodTerrain = null

	func terrain_node() -> Node:
		return _node


var _arm: String = ""
var _vp: SubViewport = null
var _cam: Camera3D = null
var _voxel: VoxelLodTerrain = null
var _field: FieldStandIn = null
var _heat: LAHeatFieldTexture = null
var _control: MeshInstance3D = null
var _quads: Array[MeshInstance3D] = []
var _planes_z: Array[float] = []
var _box_size: Vector2 = Vector2.ZERO
var _pivot: Vector3 = Vector3.ZERO
var _temps: PackedFloat32Array = PackedFloat32Array()
var _snow: PackedByteArray = PackedByteArray()
var _stage: int = 0
var _wait: int = 0
var _frames: Array[Image] = []


func _initialize() -> void:
	LAQuietWindow.apply_if_automated()
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(ARG_ARM):
			_arm = String(a).substr(ARG_ARM.length())
	if _arm != "glow" and _arm != "field":
		_abort("give --arm=glow or --arm=field")


## Built on the first frame, once the root is inside the tree and a node can say where it stands.
func _build() -> void:
	_build_view()
	if _arm == "glow":
		_build_glow()
	else:
		_build_field()
	_wait = SETTLE_FRAMES


func _process(_delta: float) -> bool:
	if _arm != "glow" and _arm != "field":
		return false
	if _vp == null:
		_build()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _stage > _quads.size():
		return false
	_frames.append(_vp.get_texture().get_image())
	_control.visible = false
	for q in _quads:
		q.visible = false
	if _stage < _quads.size():
		_quads[_stage].visible = true
		_stage += 1
		_wait = SETTLE_FRAMES
		return false
	_stage += 1
	_verdict()
	return false


func _abort(why: String) -> void:
	print('TERRAIN_EMISSION={"arm":"%s","error":"%s"}' % [_arm, why])
	LocalAgentDemoHarness.print_complete(2)
	quit(2)


## A float target, lit by nothing and tonemapped linearly: what the pixel holds is what the fragment emits.
func _build_view() -> void:
	_vp = SubViewport.new()
	_vp.use_hdr_2d = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.environment = env
	_cam.near = 0.05
	_cam.far = 4.0 * EYE_M
	_vp.add_child(_cam)
	_cam.current = true
	_voxel = VoxelLodTerrain.new()
	_vp.add_child(_voxel)


## Uniform leaves, bare on one row and under deep ice on the next, over a straight body at the origin. The
## bare ground is drawn black, so its emission is Planck's own and no presentation mottle enters it.
func _build_glow() -> void:
	var n: int = GLOW_TEMPS_C.size()
	var grid: LAVoxelGrid = _grid_in(Transform3D(), Vector3i(n, 2, 1), GLOW_EDGE_M, [])
	for c in grid.cell_count:
		var at: Vector3i = grid.coords(c)
		_temps.append(GLOW_TEMPS_C[at.x])
		_snow.append(1 if at.y == 1 else 0)
	_dress(grid, [0.5 * GLOW_EDGE_M])


## A graded grid in a body turned and carried away from the world origin: a world point is not a body
## point, and a base cell's leaves tile it in Morton order.
func _build_field() -> void:
	var body: Transform3D = Transform3D(Basis(BODY_AXIS.normalized(), BODY_ANGLE_RAD), BODY_AT)
	var grid: LAVoxelGrid = _grid_in(body, FIELD_DIMS, FIELD_EDGE_M, FIELD_SPLIT)
	if grid.cell_count == grid.nx * grid.ny * grid.nz:
		_abort("the grid did not grade, so a leaf-count comparison would pass it")
		return
	for c in grid.cell_count:
		_temps.append(FIELD_T0_C + FIELD_DT_C * float((c * 7) % grid.cell_count))
		_snow.append(0)
	_dress(grid, [0.3 * FIELD_EDGE_M, 0.6 * FIELD_EDGE_M, 1.3 * FIELD_EDGE_M])


## `dims` base cells of `edge_m`, the `split` ones refined once, boxed at BOX_MIN_BODY in a body at
## `body`. The field's frame turns about its pivot by the body's rotation, so the grid's origin stands off
## the pivot by the box's half-extent.
func _grid_in(body: Transform3D, dims: Vector3i, edge_m: float, split: Array) -> LAVoxelGrid:
	_voxel.transform = body
	var size: Vector3 = Vector3(dims) * edge_m
	_pivot = _voxel.to_global(BOX_MIN_BODY + 0.5 * size)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(dims.x, dims.y, dims.z, edge_m, _pivot - 0.5 * size)
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(dims.x * dims.y * dims.z)
	for b in split:
		mask[grid.index(b.x, b.y, b.z)] = 1
	grid.refine(mask)
	return grid


## The planet's material through LATerrainLook and LAHeatFieldTexture as the render layer dresses it,
## and one quad per body-frame plane `planes` metres into the box.
func _dress(grid: LAVoxelGrid, planes: Array) -> void:
	var size: Vector3 = Vector3(grid.nx, grid.ny, grid.nz) * grid.cell_size
	LATerrainLook.dress(_voxel, (load(MATERIAL_PATH) as ShaderMaterial).duplicate())
	var star: LAStar = LAStar.new()
	_vp.add_child(star)
	star.setup({"seed_key": "star"})
	var mirrors: LAFieldMirrors = LAFieldMirrors.new()
	mirrors.alloc(PackedStringArray(["temp", "h2o", "h2o_solid"]), grid.cell_count)
	mirrors.set_array("temp", _temps)
	var ice: PackedFloat32Array = PackedFloat32Array()
	for c in grid.cell_count:
		ice.append(float(_snow[c]) * 2.0 * LAMaterialField3D.ICE_DEPTH)
	mirrors.set_array("h2o", ice)
	mirrors.set_array("h2o_solid", ice)
	_field = FieldStandIn.new()
	_field._grid = grid
	_field._star = star
	_field._mirrors = mirrors
	_field._pivot = _pivot
	var terrain: TerrainStandIn = TerrainStandIn.new()
	terrain._node = _voxel
	_heat = LAHeatFieldTexture.new()
	_vp.add_child(_heat)
	_heat.setup(_field, terrain)
	_box_size = Vector2(size.x, size.y)
	for z in planes:
		_planes_z.append(float(z))
		_quads.append(_quad(float(z)))
	var eye: Vector3 = BOX_MIN_BODY + Vector3(0.5 * size.x, 0.5 * size.y, size.z + EYE_M)
	_cam.global_transform = Transform3D(_voxel.global_basis, _voxel.to_global(eye))
	_cam.size = size.y
	_vp.size = Vector2i(roundi(size.x * PX_PER_M), roundi(size.y * PX_PER_M))
	_control = _control_quad(size)


## One block of the terrain: its mesh in whole-voxel offsets from its origin, as the mesher writes them.
func _quad(z_m: float) -> MeshInstance3D:
	var arrays: Array = QuadMesh.new().get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var origin: Vector3 = Vector3(BLOCK_AT)
	for i in verts.size():
		var v: Vector3 = verts[i]
		verts[i] = BOX_MIN_BODY + Vector3((v.x + 0.5) * _box_size.x, (v.y + 0.5) * _box_size.y, z_m) - origin
	arrays[Mesh.ARRAY_VERTEX] = verts
	var custom: PackedFloat32Array = PackedFloat32Array()
	custom.resize(verts.size() * 4)
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	var mat: ShaderMaterial = (_voxel.material as ShaderMaterial).duplicate() as ShaderMaterial
	mat.set_shader_parameter("u_block_local_transform", Transform3D(Basis(), origin))
	mat.set_shader_parameter("albedo_bare_ground", 0.0)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = origin
	mi.visible = false
	_voxel.add_child(mi)
	return mi


## The positive control: a surface emitting a known radiance, which the target must return unchanged.
func _control_quad(size: Vector3) -> MeshInstance3D:
	var sh: Shader = Shader.new()
	sh.code = ("shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.0); EMISSION = vec3(%f, %f, %f); }\n"
		% [CONTROL_EMISSION.x, CONTROL_EMISSION.y, CONTROL_EMISSION.z])
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = sh
	var q: QuadMesh = QuadMesh.new()
	q.size = Vector2(size.x, size.y) * 2.0
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	mi.position = BOX_MIN_BODY + Vector3(0.5 * size.x, 0.5 * size.y, size.z)
	_voxel.add_child(mi)
	return mi


## Linear-sRGB radiance of a Planck emitter at `t_k` through the CIE 1931 observer, W m^-2 sr^-1, summed
## at 1 nm over the band the observer is tabulated on; `magnitude` sums every term's absolute value.
static func planck_rgb(t_k: float, magnitude: bool = false) -> PackedFloat64Array:
	var h: float = LAPhysical.PLANCK_J_S
	var c: float = LAPhysical.SPEED_OF_LIGHT_M_S
	var k: float = LAPhysical.BOLTZMANN_J_K
	var m: Basis = LAHeatFieldTexture.XYZ_TO_SRGB
	if magnitude:
		m = Basis(m.x.abs(), m.y.abs(), m.z.abs())
	var out: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0])
	var lo: float = LAHeatFieldTexture.VISIBLE_NM.x
	var hi: float = LAHeatFieldTexture.VISIBLE_NM.y
	for i in int(hi - lo):
		var nm: float = lo + float(i) + 0.5
		var lam: float = nm * 1.0e-9
		var b: float = 2.0 * h * c * c / pow(lam, 5.0) / (exp(h * c / (lam * k * t_k)) - 1.0) * 1.0e-9
		var xyz: Vector3 = LAHeatFieldTexture.cie1931(nm)
		out[0] += b * (m.x.x * xyz.x + m.y.x * xyz.y + m.z.x * xyz.z)
		out[1] += b * (m.x.y * xyz.x + m.y.y * xyz.y + m.z.y * xyz.z)
		out[2] += b * (m.x.z * xyz.x + m.y.z * xyz.y + m.z.z * xyz.z)
	return out


## The white Lambertian surface under the star's full beam: the photosphere's Planck radiance at the
## Stefan-Boltzmann temperature of its luminosity over its surface, times the sine squared of its radius.
func _sunlit_unit() -> PackedFloat64Array:
	var star: LAStar = _field._star
	var r_m: float = float(star.seed_row()["radius_m"])
	var d_m: float = star.global_position.distance_to(_field._pivot)
	var t_k: float = pow(star.luminosity_w() / (4.0 * PI * r_m * r_m * LAPhysical.STEFAN_BOLTZMANN), 0.25)
	var p: PackedFloat64Array = planck_rgb(t_k)
	for i in 3:
		p[i] *= (r_m / d_m) * (r_m / d_m)
	return p


## Kirchhoff: an opaque surface emits (1 - albedo) of a black body, and the display none of a negative
## primary. Deep ice reflects its own albedo; the bare ground here is drawn black.
func _expected(t_c: float, snow: bool, unit: PackedFloat64Array) -> Array:
	var p: PackedFloat64Array = planck_rgb(t_c + LAPhysical.KELVIN_OFFSET)
	var mag: PackedFloat64Array = planck_rgb(t_c + LAPhysical.KELVIN_OFFSET, true)
	var albedo: float = LAPhysical.ALBEDO_SNOW_ICE if snow else 0.0
	var lo: Vector3 = Vector3.ZERO
	var hi: Vector3 = Vector3.ZERO
	for i in 3:
		var e: float = maxf(p[i] / unit[i] * (1.0 - albedo), 0.0)
		var tol: float = REL_TOL * mag[i] / unit[i] * (1.0 - albedo) + ABS_TOL
		lo[i] = e - tol
		hi[i] = e + tol
	return [lo, hi]


## The body point a pixel centre of frame `f` stands on, m in the terrain's own frame.
func _body_point(px: float, py: float, f: int) -> Vector3:
	var s: float = 1.0 / PX_PER_M
	return BOX_MIN_BODY + Vector3(px * s, _box_size.y - py * s, _planes_z[f])


func _verdict() -> void:
	var control: Color = _frames[0].get_pixel(_frames[0].get_width() / 2, _frames[0].get_height() / 2)
	var got: Vector3 = Vector3(control.r, control.g, control.b)
	if (got - CONTROL_EMISSION).length() > 1.0e-3 * CONTROL_EMISSION.length():
		_abort("the target returned %s for an emission of %s, so it does not read radiance" % [got, CONTROL_EMISSION])
		return
	var unit: PackedFloat64Array = _sunlit_unit()
	var grid: LAVoxelGrid = _field._grid
	var expect: Array = []
	for c in grid.cell_count:
		expect.append(_expected(_temps[c], _snow[c] == 1, unit))
	var checked: int = 0
	var edge: int = 0
	var wrong: int = 0
	var worst: String = ""
	for f in range(1, _frames.size()):
		var img: Image = _frames[f]
		for py in img.get_height():
			for px in img.get_width():
				var c: int = _leaf_under(float(px) + 0.5, float(py) + 0.5, f - 1)
				if c == -2:
					edge += 1
					continue
				var col: Color = img.get_pixel(px, py)
				var v: Vector3 = Vector3(col.r, col.g, col.b)
				checked += 1
				var lo: Vector3 = expect[c][0]
				var hi: Vector3 = expect[c][1]
				if v.x < lo.x or v.y < lo.y or v.z < lo.z or v.x > hi.x or v.y > hi.y or v.z > hi.z:
					wrong += 1
					if worst == "":
						worst = "leaf %d at %.0f C read %s, wanted %s..%s" % [c, _temps[c], v, lo, hi]
	if checked < grid.cell_count * 16:
		_abort("only %d pixels stood inside one leaf, so the leaves were not all read" % checked)
		return
	if worst != "":
		printerr("TERRAIN_EMISSION: " + worst)
	print('TERRAIN_EMISSION={"arm":"%s","leaves":%d,"graded":%s,"pixels":%d,"edge_pixels":%d,"wrong":%d,"failures":%d}'
		% [_arm, grid.cell_count, str(grid.cell_count != grid.nx * grid.ny * grid.nz).to_lower(), checked, edge,
			wrong, 1 if wrong > 0 else 0])
	LocalAgentDemoHarness.print_complete(1 if wrong > 0 else 0)
	quit(1 if wrong > 0 else 0)


## The leaf holding the pixel's body point, found by LAGridGeometry; -2 where the pixel's own footprint
## spans two leaves or leaves the box.
func _leaf_under(px: float, py: float, f: int) -> int:
	var grid: LAVoxelGrid = _field._grid
	var at: PackedInt32Array = PackedInt32Array()
	for o in [Vector2(0.0, 0.0), Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)]:
		var p: Vector3 = _body_point(px + o.x, py + o.y, f)
		at.append(LAGridGeometry.cell_at(grid, grid.origin + (p - BOX_MIN_BODY)))
	for c in at:
		if c < 0 or c != at[0]:
			return -2
	return at[0]
