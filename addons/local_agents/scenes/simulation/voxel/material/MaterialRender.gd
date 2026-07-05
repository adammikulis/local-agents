class_name LAMaterialRender
extends RefCounted

## LAMaterialRender — the RENDERING/presentation half of the material field.
##
## Split out of LAMaterialField: this module owns everything VISUAL — the animated water + lava
## surface meshes, the temperature (heat) texture the terrain shader samples, and the transient FX
## (steam puffs, physical splash droplets). It holds NO simulation state of its own; it reaches back
## into the owning LAMaterialField (`_f`) for the shared grid state (`_mats`, `_sampled`, `_terrain_h`,
## `_temp`, `_dim`, `_cell_count`, `_cell_x/_cell_z`, `_half_extent`, thresholds) and only READS those
## arrays + builds meshes/textures from them. Behaviour is identical to the old inline code.
## (Explicit types only — no ':=' inferred typing.)

# Material registry (preloaded so cross-file constants resolve without an editor class-scan).
const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const RENDER_THRESHOLD: float = 0.05

const SPLASH_DROPLETS: int = 6
const SPLASH_LIFETIME: float = 2.0
const SPLASH_RADIUS: float = 0.12

const WATER_SHADER: String = """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.16, 0.46, 0.68, 0.55);
uniform vec4 deep_color : source_color = vec4(0.03, 0.16, 0.36, 0.85);
uniform float wave_speed = 0.7;
uniform float wave_scale = 0.5;
uniform float wave_height = 0.12;

varying float v_wave;

void vertex() {
	float w = sin(VERTEX.x * wave_scale + TIME * wave_speed)
			* cos(VERTEX.z * wave_scale + TIME * wave_speed * 0.8);
	v_wave = w;
	VERTEX.y += w * wave_height;
}

void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec4 col = mix(shallow_color, deep_color, clamp(0.5 + v_wave * 0.5, 0.0, 1.0));
	ALBEDO = col.rgb;
	ALPHA = mix(col.a, 1.0, fres * 0.4);
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
"""

const LAVA_SHADER: String = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform vec3 hot_color : source_color = vec3(1.0, 0.62, 0.12);
uniform vec3 cool_color : source_color = vec3(0.35, 0.045, 0.01);
uniform float flow_speed = 0.25;
varying vec3 v_world;
// Cheap value noise on world XZ so the crust is CONTINUOUS across cell quads (no per-quad polka dots).
float lhash(vec2 p) { p = fract(p * vec2(127.1, 311.7)); p += dot(p, p + 34.5); return fract(p.x * p.y); }
float lnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	float a = lhash(i); float b = lhash(i + vec2(1.0, 0.0));
	float c = lhash(i + vec2(0.0, 1.0)); float d = lhash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(v_world.x * 0.5 + TIME * flow_speed) * cos(v_world.z * 0.5 + TIME * flow_speed) * 0.06;
}
void fragment() {
	// Two octaves of world-space noise drifting slowly => cracked, glowing crust with dark cooled skin
	// over bright molten veins, continuous across the whole flow rather than a grid of cells.
	vec2 wp = v_world.xz;
	float drift = TIME * flow_speed * 0.15;
	float n = lnoise(wp * 0.35 + vec2(drift, -drift)) * 0.65 + lnoise(wp * 1.1 - vec2(drift, drift)) * 0.35;
	float crust = smoothstep(0.35, 0.75, n);   // dark cooled crust (low) vs hot veins (high)
	vec3 c = mix(cool_color, hot_color, crust);
	ALBEDO = c;
	EMISSION = c * (0.8 + crust * 3.0);
	ROUGHNESS = 0.75;
	METALLIC = 0.0;
}
"""

# Back-reference to the owning LAMaterialField (set in setup); the source of all grid state.
var _f = null

# Rendered water surface (one animated translucent quad per wet cell; rebuilt each step).
var _surface_mi: MeshInstance3D = null
var _surface_mesh: ArrayMesh = null
var _water_material: ShaderMaterial = null

# Lava gets its own glowing emissive surface (same one-quad-per-cell build as water).
var _lava_mi: MeshInstance3D = null
var _lava_mesh: ArrayMesh = null
var _lava_material: ShaderMaterial = null

# Temperature baked into an R-float texture (one texel per cell) so the terrain shader can sample it
# by world position and glow incandescently where hot — and drive the temp debug view. Updated in
# place each step (same texture object) so consumers wire it once.
var _heat_img: Image = null
var _heat_tex: ImageTexture = null


# --- Setup ------------------------------------------------------------------

## Store the owning field, build the water + lava surface nodes (added as children of the field) and
## the heat texture. Called once from LAMaterialField.setup after the grid is allocated.
func setup(field) -> void:
	_f = field
	_build_surface_node()
	_build_heat_texture()


# Create the R-float temperature texture (one texel per grid cell). Seeded to INITIAL_TEMP so the
# ground doesn't read as ice-cold before the field settles.
func _build_heat_texture() -> void:
	var seed: PackedFloat32Array = PackedFloat32Array()
	seed.resize(_f._cell_count)
	seed.fill(_f.INITIAL_TEMP)
	_heat_img = Image.create_from_data(_f._dim, _f._dim, false, Image.FORMAT_RF, seed.to_byte_array())
	_heat_tex = ImageTexture.create_from_image(_heat_img)


func _build_surface_node() -> void:
	if _water_material == null:
		var shader: Shader = Shader.new()
		shader.code = WATER_SHADER
		_water_material = ShaderMaterial.new()
		_water_material.shader = shader
	if _surface_mesh == null:
		_surface_mesh = ArrayMesh.new()
	if _surface_mi == null:
		_surface_mi = MeshInstance3D.new()
		_surface_mi.name = "WaterSurface"
		_surface_mi.mesh = _surface_mesh
		_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_f.add_child(_surface_mi)
	if _lava_material == null:
		var lsh: Shader = Shader.new()
		lsh.code = LAVA_SHADER
		_lava_material = ShaderMaterial.new()
		_lava_material.shader = lsh
	if _lava_mesh == null:
		_lava_mesh = ArrayMesh.new()
	if _lava_mi == null:
		_lava_mi = MeshInstance3D.new()
		_lava_mi.name = "LavaSurface"
		_lava_mi.mesh = _lava_mesh
		_lava_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_f.add_child(_lava_mi)


# --- Heat texture -----------------------------------------------------------

# Re-upload the temperature grid into the heat texture (in place). The ground shader samples it for
# incandescent glow, and the temp debug view renders it directly.
func update_heat_texture() -> void:
	if _heat_tex == null or _heat_img == null:
		return
	_heat_img.set_data(_f._dim, _f._dim, false, Image.FORMAT_RF, _f._temp.to_byte_array())
	_heat_tex.update(_heat_img)


## The live temperature texture (R = °C per cell). Wire once into the terrain shader; it updates in
## place each step. Also drives the temperature debug view.
func heat_texture() -> Texture2D:
	return _heat_tex


## World-space XZ extent the heat texture covers: min corner and size, for the shader's UV mapping.
func heat_world_min() -> Vector2:
	return Vector2(-_f._half_extent, -_f._half_extent)


func heat_world_size() -> Vector2:
	return Vector2(2.0 * _f._half_extent, 2.0 * _f._half_extent)


# --- Liquid surfaces (smooth, welded heightfield) ---------------------------

func rebuild_water() -> void:
	if _surface_mesh == null or not _f._mats.has(Mat.WATER):
		return
	_build_liquid_surface(_f._mats[Mat.WATER], RENDER_THRESHOLD, _surface_mesh, _water_material)


func rebuild_lava() -> void:
	if _lava_mesh == null or not _f._mats.has(Mat.LAVA):
		return
	_build_liquid_surface(_f._mats[Mat.LAVA], _f.LAVA_MIN, _lava_mesh, _lava_material)


# Build ONE continuous surface for a liquid depth field, instead of an independent flat quad per cell
# (which read as a hard grid of steps). Each grid CORNER's height is the AVERAGE of the surface heights
# (terrain + depth) of the wet cells touching it, and corners are SHARED between adjacent cells (welded)
# — so the surface is a smooth heightfield that blends across cells and at the wet/dry shoreline.
# Per-vertex normals come from the corner-height gradient, giving smooth shading instead of flat facets.
func _build_liquid_surface(depth: PackedFloat32Array, threshold: float, mesh: ArrayMesh, material: ShaderMaterial) -> void:
	var dim: int = _f._dim
	var cw: int = dim + 1                       # corner grid is (dim+1) x (dim+1)
	var ccount: int = cw * cw
	var cs: float = _f._cell_size
	var hc: float = cs * 0.5
	var origin: float = -_f._half_extent - hc   # world XZ of corner (0,0)

	# 1) Accumulate each wet cell's surface height into its 4 shared corners.
	var ch: PackedFloat32Array = PackedFloat32Array()
	ch.resize(ccount)
	var cn: PackedInt32Array = PackedInt32Array()
	cn.resize(ccount)
	var any: bool = false
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _f._sampled[idx] == 0 or depth[idx] < threshold:
				continue
			any = true
			var surf: float = _f._terrain_h[idx] + depth[idx]
			var c0: int = j * cw + i
			var c1: int = c0 + 1
			var c2: int = c0 + cw
			var c3: int = c2 + 1
			ch[c0] += surf
			cn[c0] += 1
			ch[c1] += surf
			cn[c1] += 1
			ch[c2] += surf
			cn[c2] += 1
			ch[c3] += surf
			cn[c3] += 1
	if not any:
		if mesh.get_surface_count() > 0:
			mesh.clear_surfaces()
		return

	# 2a) Average every active corner FIRST (so neighbour reads below see averaged heights, not sums).
	for c in range(ccount):
		if cn[c] != 0:
			ch[c] = ch[c] / float(cn[c])

	# 2b) Assign each active corner a vertex index and derive a smooth normal from the heights of its
	# active neighbours (central differences; missing neighbours fall back to self).
	var vmap: PackedInt32Array = PackedInt32Array()
	vmap.resize(ccount)
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	for cj in range(cw):
		var crow: int = cj * cw
		for ci in range(cw):
			var c: int = crow + ci
			if cn[c] == 0:
				vmap[c] = -1
				continue
			var h: float = ch[c]
			vmap[c] = verts.size()
			verts.push_back(Vector3(origin + float(ci) * cs, h, origin + float(cj) * cs))
			var hl: float = _corner_h(ch, cn, crow + ci - 1, ci > 0, h)
			var hr: float = _corner_h(ch, cn, crow + ci + 1, ci < cw - 1, h)
			var hd: float = _corner_h(ch, cn, c - cw, cj > 0, h)
			var hu: float = _corner_h(ch, cn, c + cw, cj < cw - 1, h)
			normals.push_back(Vector3(hl - hr, 2.0 * cs, hd - hu).normalized())

	# 3) Two triangles per wet cell, referencing its 4 shared corner vertices (same winding as before).
	var indices: PackedInt32Array = PackedInt32Array()
	for j2 in range(dim):
		var row2: int = j2 * dim
		for i2 in range(dim):
			var idx2: int = row2 + i2
			if _f._sampled[idx2] == 0 or depth[idx2] < threshold:
				continue
			var b0: int = j2 * cw + i2
			var v0: int = vmap[b0]
			var v1: int = vmap[b0 + 1]
			var v2: int = vmap[b0 + cw + 1]
			var v3: int = vmap[b0 + cw]
			indices.push_back(v0)
			indices.push_back(v1)
			indices.push_back(v2)
			indices.push_back(v0)
			indices.push_back(v2)
			indices.push_back(v3)

	if mesh.get_surface_count() > 0:
		mesh.clear_surfaces()
	if verts.is_empty() or indices.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		mesh.surface_set_material(0, material)


# Height of neighbour corner `nc` if it is in-bounds (`ok`) and active, else the fallback `self_h`
# (so the normal at the wet/dry edge doesn't spike toward a phantom zero-height neighbour).
func _corner_h(ch: PackedFloat32Array, cn: PackedInt32Array, nc: int, ok: bool, self_h: float) -> float:
	if ok and cn[nc] != 0:
		return ch[nc]
	return self_h


# --- Steam puff FX ----------------------------------------------------------

func steam_puff(pos: Vector3) -> void:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 10
	p.lifetime = 1.4
	p.explosiveness = 0.4
	p.global_position = pos + Vector3(0.0, 0.2, 0.0)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.92, 0.95, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = mat
	p.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.4
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.5
	pm.gravity = Vector3(0.0, 1.2, 0.0)              # steam rises
	pm.scale_min = 0.6
	pm.scale_max = 1.8
	pm.color = Color(0.92, 0.94, 0.97, 0.4)
	p.process_material = pm
	_f.add_child(p)
	var t: SceneTreeTimer = _f.get_tree().create_timer(1.8)
	t.timeout.connect(func(): if is_instance_valid(p): p.queue_free())


# --- Splash droplets --------------------------------------------------------

## Spawn a few short-lived rigidbody droplets flung up/out from world_pos — the physical splash
## accent. Guarded so a bad call can never crash the sim; droplets auto-free after SPLASH_LIFETIME.
func splash(world_pos: Vector3, strength: float) -> void:
	if not _f.is_inside_tree():
		return
	var tree: SceneTree = _f.get_tree()
	if tree == null:
		return
	if is_nan(world_pos.x) or is_nan(world_pos.y) or is_nan(world_pos.z):
		return
	var s: float = clampf(strength, 0.1, 4.0)

	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = SPLASH_RADIUS
	mesh.height = SPLASH_RADIUS * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.6, 0.9, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.1
	mat.metallic = 0.0
	mesh.material = mat

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = SPLASH_RADIUS

	for n in range(SPLASH_DROPLETS):
		var body: RigidBody3D = RigidBody3D.new()
		body.mass = 0.05
		body.gravity_scale = 1.0
		body.collision_mask = 1
		body.collision_layer = 0
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)
		var col: CollisionShape3D = CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		_f.add_child(body)
		body.global_position = world_pos + Vector3(
			randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))
		var ang: float = randf() * TAU
		var out: float = randf_range(1.0, 2.5) * s
		var upv: float = randf_range(2.5, 4.5) * s
		body.linear_velocity = Vector3(cos(ang) * out, upv, sin(ang) * out)
		body.angular_velocity = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
		var timer: SceneTreeTimer = tree.create_timer(SPLASH_LIFETIME)
		timer.timeout.connect(_free_droplet.bind(body))


func _free_droplet(body: Node) -> void:
	if is_instance_valid(body):
		body.queue_free()
