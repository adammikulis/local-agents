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
uniform vec3 hot_color : source_color = vec3(1.0, 0.75, 0.2);
uniform vec3 cool_color : source_color = vec3(0.6, 0.09, 0.02);
uniform float flow_speed = 0.25;
void vertex() {
	VERTEX.y += sin(VERTEX.x * 0.6 + TIME * flow_speed) * cos(VERTEX.z * 0.6 + TIME * flow_speed) * 0.06;
}
void fragment() {
	float crust = 0.5 + 0.5 * sin(VERTEX.x * 1.7 + TIME * flow_speed) * sin(VERTEX.z * 1.7 - TIME * flow_speed);
	vec3 c = mix(cool_color, hot_color, crust);
	ALBEDO = c;
	EMISSION = c * (1.5 + crust * 2.5);
	ROUGHNESS = 0.7;
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


# --- Water surface ----------------------------------------------------------

func rebuild_water() -> void:
	if _surface_mesh == null:
		return
	if _surface_mesh.get_surface_count() > 0:
		_surface_mesh.clear_surfaces()
	if not _f._mats.has(Mat.WATER):
		return
	var water: PackedFloat32Array = _f._mats[Mat.WATER]

	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var hc: float = _f._cell_size * 0.5
	var up: Vector3 = Vector3.UP
	var base: int = 0

	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0:
			continue
		var d: float = water[idx]
		if d < RENDER_THRESHOLD:
			continue
		var i: int = idx % _f._dim
		var j: int = idx / _f._dim
		var cx: float = _f._cell_x(i)
		var cz: float = _f._cell_z(j)
		var y: float = _f._terrain_h[idx] + d
		verts.push_back(Vector3(cx - hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz + hc))
		verts.push_back(Vector3(cx - hc, y, cz + hc))
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		indices.push_back(base + 0)
		indices.push_back(base + 1)
		indices.push_back(base + 2)
		indices.push_back(base + 0)
		indices.push_back(base + 2)
		indices.push_back(base + 3)
		base += 4

	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_surface_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _water_material != null:
		_surface_mesh.surface_set_material(0, _water_material)


# --- Lava surface -----------------------------------------------------------

func rebuild_lava() -> void:
	if _lava_mesh == null:
		return
	if _lava_mesh.get_surface_count() > 0:
		_lava_mesh.clear_surfaces()
	if not _f._mats.has(Mat.LAVA):
		return
	var lava: PackedFloat32Array = _f._mats[Mat.LAVA]
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var hc: float = _f._cell_size * 0.5
	var up: Vector3 = Vector3.UP
	var base: int = 0
	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0 or lava[idx] < _f.LAVA_MIN:
			continue
		var i: int = idx % _f._dim
		var j: int = idx / _f._dim
		var cx: float = _f._cell_x(i)
		var cz: float = _f._cell_z(j)
		var y: float = _f._terrain_h[idx] + lava[idx]
		verts.push_back(Vector3(cx - hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz + hc))
		verts.push_back(Vector3(cx - hc, y, cz + hc))
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		indices.push_back(base + 0)
		indices.push_back(base + 1)
		indices.push_back(base + 2)
		indices.push_back(base + 0)
		indices.push_back(base + 2)
		indices.push_back(base + 3)
		base += 4
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_lava_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _lava_material != null:
		_lava_mesh.surface_set_material(0, _lava_material)


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
