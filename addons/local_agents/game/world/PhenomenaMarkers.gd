class_name LAPhenomenaMarkers
extends Node3D

## Presentation for what LAFieldPhenomena observed. Places a marker where the field already shows an
## eruption or a cyclone and retires it when the reading stops. It reads the detector and nothing else.

const LightningScript: GDScript = preload("res://addons/local_agents/sim/actors/LightningStrike.gd")

## Seconds between marker refreshes. A display cadence, not a physical rate: the detector's own reading is
## cached per field step and the markers only redraw it.
const REFRESH_PERIOD: float = 0.5

## Spiral marker radii in grid cells: a low is resolved at cell scale, so its drawing is sized in cells.
const SPIRAL_INNER_CELLS: float = 1.0
const SPIRAL_OUTER_CELLS: float = 4.0
const SPIRAL_ALOFT_CELLS: float = 6.0

var _field = null
var _audio = null
var _detector: LAFieldPhenomena = null
var _cd: float = 0.0
var _marks: Dictionary = {}                # snapped cell key -> marker Node3D


func setup(field) -> void:
	_field = field
	_detector = LAFieldPhenomena.new()
	_detector.setup(field)


## Audio is presentation and stays null without --ui.
func set_presentation(audio) -> void:
	_audio = audio


## The bolt the charge-breakdown kernel published. Nothing else may call this: a bolt with no discharge
## behind it is a picture of an event that did not happen.
func show_bolt(point: Vector3) -> void:
	var b: Node = LightningScript.new()
	add_child(b)
	b.strike(point)
	if _audio != null:
		_audio.play_sfx("thunder", point)


func _physics_process(delta: float) -> void:
	if _field == null or _detector == null:
		return
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = REFRESH_PERIOD
	var obs: Dictionary = _detector.observe()
	var seen: Dictionary = {}
	if bool(obs.get("eruptions_live", false)):
		for e in obs["eruptions"]:
			seen[_reconcile(e["pos"], "eruption")] = true
	if bool(obs.get("cyclones_live", false)):
		for cy in obs["cyclones"]:
			seen[_reconcile(cy["pos"], "cyclone")] = true
	for key in _marks.keys():
		if seen.has(key):
			continue
		var m: Node = _marks[key]
		_marks.erase(key)
		if is_instance_valid(m):
			m.queue_free()


## Key a site by the cell it sits in, so one site keeps one marker across refreshes.
func _reconcile(pos: Vector3, kind: String) -> String:
	var cs: float = _cell_size()
	var key: String = "%s:%d,%d,%d" % [kind, int(floor(pos.x / cs)), int(floor(pos.y / cs)), int(floor(pos.z / cs))]
	if _marks.has(key) and is_instance_valid(_marks[key]):
		(_marks[key] as Node3D).global_position = pos
		return key
	var m: Node3D = _build_eruption(cs) if kind == "eruption" else _build_cyclone(cs)
	add_child(m)
	m.global_position = pos
	_marks[key] = m
	return key


func _cell_size() -> float:
	var cs: float = float(_field.cell_size()) if _field != null and _field.has_method("cell_size") else 0.0
	return cs if cs > 0.0 else 1.0


# Molten rock glows: an emissive point where the field says melt is standing in the open.
func _build_eruption(cs: float) -> Node3D:
	var n: Node3D = Node3D.new()
	var glow: OmniLight3D = OmniLight3D.new()
	glow.light_color = Color(1.0, 0.5, 0.15)
	glow.light_energy = 18.0
	glow.omni_range = cs * 5.0
	n.add_child(glow)
	return n


# A rotating cloud disc over the low, cleared at the centre so the eye reads.
func _build_cyclone(cs: float) -> Node3D:
	var n: Node3D = Node3D.new()
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = 660
	p.lifetime = 9.0
	p.emitting = true
	p.local_coords = false
	p.position = Vector3(0.0, cs * SPIRAL_ALOFT_CELLS, 0.0)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(cs * 1.5, cs * 1.5)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = mat
	p.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0.0, 1.0, 0.0)
	pm.emission_ring_radius = cs * SPIRAL_OUTER_CELLS
	pm.emission_ring_inner_radius = cs * SPIRAL_INNER_CELLS
	pm.emission_ring_height = cs * 0.5
	pm.spread = 10.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 2.0
	pm.gravity = Vector3.ZERO
	pm.tangential_accel_min = 10.0
	pm.tangential_accel_max = 20.0
	pm.radial_accel_min = -3.0
	pm.radial_accel_max = -1.0
	pm.color_ramp = _spiral_ramp()
	p.process_material = pm
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(p)
	return n


func _spiral_ramp() -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color(0.66, 0.69, 0.74, 0.0),
		Color(0.70, 0.73, 0.78, 0.62),
		Color(0.40, 0.43, 0.50, 0.46),
		Color(0.30, 0.33, 0.40, 0.0),
	])
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


## What the detector last read, for the harness/report. Empty when it has not run.
func observation() -> Dictionary:
	return _detector.observe() if _detector != null else {}
