class_name LAFlameFX
extends RefCounted


# One quad, one draw material and one process material serve every flame.
static var _quad: QuadMesh = null
static var _process: ParticleProcessMaterial = null


## Build the shared resources ahead of the first flame.
static func warm() -> void:
	if _quad != null:
		return
	_quad = QuadMesh.new()
	_quad.size = Vector2(0.5, 0.5)
	var fmat: StandardMaterial3D = StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.5, 0.12)
	fmat.emission_energy_multiplier = 3.0
	fmat.albedo_color = Color(1.0, 0.55, 0.15, 0.9)
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_quad.material = fmat
	_process = ParticleProcessMaterial.new()
	_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_process.emission_sphere_radius = 0.8
	_process.direction = Vector3(0.0, 1.0, 0.0)
	_process.spread = 20.0
	_process.initial_velocity_min = 2.0
	_process.initial_velocity_max = 4.5
	_process.gravity = Vector3(0.0, 2.5, 0.0)
	_process.scale_min = 0.5
	_process.scale_max = 1.4
	_process.color = Color(1.0, 0.6, 0.2)
	fmat.get_rid()
	_process.get_rid()


static func make() -> Node3D:
	warm()
	var root: Node3D = Node3D.new()
	root.name = "FlameFX"

	var particles: GPUParticles3D = GPUParticles3D.new()
	particles.amount = 24
	particles.lifetime = 0.9
	particles.one_shot = false
	particles.emitting = true
	particles.draw_pass_1 = _quad
	particles.process_material = _process
	particles.position = Vector3(0.0, 1.2, 0.0)
	root.add_child(particles)

	var light: OmniLight3D = OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 3.0
	light.omni_range = 9.0
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
	return root
