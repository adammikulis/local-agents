class_name LADebugOverlay
extends MeshInstance3D

## World-space DEBUG GIZMOS drawn as a single ImmediateMesh, redrawn each frame from live scene state
## and toggled by the DebugPanel (via VoxelWorld). It can HIGHLIGHT every instance of a type (a colored
## beam + base cross over each member of a group, drawn through terrain so they're easy to find), draw
## each creature's INTENDED PATH (a ray along its steering heading), and show the WIND as a grid of
## arrows. Purely presentational — reads groups/positions, owns no sim state. (Explicit types only.)

const BEAM_HEIGHT: float = 16.0            # tall beam so highlighted objects are visible far off
const BEAM_THICK: float = 0.09             # offset used to fake line thickness (4 parallel beams)
const RING_RADIUS: float = 1.4
const RING_SEGS: int = 20
const PATH_LEN: float = 5.0
const WIND_GRID: int = 18            # denser sampling so local funneling/fronts read clearly in the arrows

# Highlightable groups -> marker colour (mirrors the spawn-palette identity colours).
const MARKER_COLORS: Dictionary = {
	"species_rabbit": Color(0.88, 0.88, 0.86),
	"species_fox": Color(0.95, 0.5, 0.15),
	"species_bird": Color(0.30, 0.62, 0.95),
	"species_vulture": Color(0.55, 0.38, 0.26),
	"species_villager": Color(0.72, 0.42, 0.92),
	"species_fish": Color(0.35, 0.72, 0.86),
	"species_plant": Color(0.35, 0.78, 0.32),
	"nest": Color(0.92, 0.82, 0.32),
}

var _field = null
var _terrain = null                        # LAVoxelTerrainService — planet surface points for field heatmaps
var _im: ImmediateMesh = null
var _mat: StandardMaterial3D = null
var _highlight: Dictionary = {}            # group name -> true (which types are highlighted)
var _paths: bool = false
var _wind: bool = false
var _scent: bool = false
var _field_channel: String = ""           # active field-channel heatmap ("" = none). One at a time.

# Field-channel heatmap: a grid of directions over the planet, each drawn as a colored radial spike
# rising from the surface, height + colour = the sampled channel value (a channel swap on the wind/scent
# grid mechanism). Toggle-gated — nothing is sampled unless a channel view is active.
const FIELD_LAT: int = 22               # latitude rings of sample directions over the sphere
const FIELD_LON: int = 44               # longitude steps per ring
const FIELD_SPIKE_MIN: float = 1.5      # shortest visible spike (so any non-zero cell still reads)
const FIELD_SPIKE_MAX: float = 14.0     # tallest spike (channel value saturated)
# Scent-channel colours for the debug view (dominant channel tints each grid cell's arrow).
const SCENT_COLORS: Array = [
	Color(0.45, 0.65, 1.0, 0.8),           # PREY   — blue
	Color(1.0, 0.35, 0.2, 0.8),            # PREDATOR — red
	Color(0.9, 0.1, 0.15, 0.85),           # BLOOD  — deep red
	Color(0.6, 0.85, 0.25, 0.8),           # FOOD   — olive
	Color(1.0, 0.85, 0.2, 0.85),           # ALARM  — yellow
]


func setup(field, terrain = null) -> void:
	_field = field
	_terrain = terrain
	_im = ImmediateMesh.new()
	mesh = _im
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.no_depth_test = true               # gizmos show THROUGH terrain so they're easy to spot
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true                        # draw in world space regardless of parent transform
	global_position = Vector3.ZERO


func set_highlight(group: String, on: bool) -> void:
	if on:
		_highlight[group] = true
	else:
		_highlight.erase(group)


func set_paths(on: bool) -> void:
	_paths = on


func set_wind(on: bool) -> void:
	_wind = on


func set_scent(on: bool) -> void:
	_scent = on


## Select the active field-channel heatmap ("" = off). One channel at a time — enabling a new channel
## replaces the previous. Keys match LADebugPanel VIEWS (biomass/water_phase/snow/lava/rock_fill/co2/o2/
## charge/fertility).
func set_field_channel(channel: String) -> void:
	_field_channel = channel


func _process(_delta: float) -> void:
	if _im == null:
		return
	_im.clear_surfaces()
	if _highlight.is_empty() and not _paths and not _wind and not _scent and _field_channel == "":
		return                              # nothing to draw — leave the mesh empty (no cost)
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	if not _highlight.is_empty():
		_draw_highlights()
	if _paths:
		_draw_paths()
	if _wind:
		_draw_wind()
	if _scent:
		_draw_scent()
	if _field_channel != "":
		_draw_field_channel()
	_im.surface_end()


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_im.surface_set_color(c)
	_im.surface_add_vertex(a)
	_im.surface_set_color(c)
	_im.surface_add_vertex(b)


# A colored beam rising from each member of every highlighted group, plus a small base cross, so any
# selected type is instantly findable across the whole map (even behind hills — no depth test).
func _draw_highlights() -> void:
	for group in _highlight.keys():
		var col: Color = MARKER_COLORS.get(group, Color(1.0, 0.9, 0.2))
		for node in get_tree().get_nodes_in_group(group):
			if not (node is Node3D):
				continue
			_beam((node as Node3D).global_position, col)


# A bold locator over one object: a tall thick beam, a downward chevron pointing at it, and a
# ground ring — drawn through terrain (no_depth_test) so highlighted objects pop out anywhere.
func _beam(base: Vector3, col: Color) -> void:
	var top: Vector3 = base + Vector3.UP * BEAM_HEIGHT
	# Fake line thickness with four parallel beams.
	var offs: Array = [
		Vector3(BEAM_THICK, 0.0, 0.0), Vector3(-BEAM_THICK, 0.0, 0.0),
		Vector3(0.0, 0.0, BEAM_THICK), Vector3(0.0, 0.0, -BEAM_THICK)]
	for o in offs:
		_line(base + o, top + o, col)
	# Downward chevron near the base so the eye is led right to the object.
	var apex: Vector3 = base + Vector3.UP * 0.4
	var wing: float = 0.9
	_line(apex, apex + Vector3(-wing, wing, 0.0), col)
	_line(apex, apex + Vector3(wing, wing, 0.0), col)
	_line(apex, apex + Vector3(0.0, wing, -wing), col)
	_line(apex, apex + Vector3(0.0, wing, wing), col)
	# Ground ring footprint.
	var center: Vector3 = base + Vector3.UP * 0.15
	var prev: Vector3 = center + Vector3(RING_RADIUS, 0.0, 0.0)
	for i in range(1, RING_SEGS + 1):
		var a: float = TAU * float(i) / float(RING_SEGS)
		var cur: Vector3 = center + Vector3(cos(a) * RING_RADIUS, 0.0, sin(a) * RING_RADIUS)
		_line(prev, cur, col)
		prev = cur


# A ray from each creature along its steering heading — where it currently intends to go.
func _draw_paths() -> void:
	var col: Color = Color(1.0, 1.0, 1.0, 0.8)
	for node in get_tree().get_nodes_in_group("creature"):
		if not (node is Node3D) or not node.has_method("debug_heading"):
			continue
		var h: Vector3 = node.debug_heading()
		if h.length() < 0.01:
			continue
		var p: Vector3 = (node as Node3D).global_position + Vector3.UP * 0.3
		var dir: Vector3 = h.normalized()
		var tip: Vector3 = p + dir * PATH_LEN
		_line(p, tip, col)
		# Small arrowhead so direction reads at a glance.
		var side: Vector3 = dir.cross(Vector3.UP).normalized() * 0.6
		_line(tip, tip - dir * 1.0 + side, col)
		_line(tip, tip - dir * 1.0 - side, col)


# The emergent LOCAL wind field as a grid of arrows floating above the world: each arrow is sampled from
# wind_at(x,z) at its own XZ position, so its direction AND length (= local speed) vary across the map —
# this is the primary way to SEE funneling through valley gaps and fronts pulling air into a heated low.
func _draw_wind() -> void:
	if _field == null or not _field.has_method("wind_at"):
		return
	var y: float = _field.sea_level + 48.0     # a plane above most terrain so the arrows read clearly
	var ext: float = _field.grid_half_extent() if _field.has_method("grid_half_extent") else 300.0
	var step: float = ext * 2.0 / float(WIND_GRID)
	# Map local speed (m/s-ish) to arrow length so slow air draws short stubs and jets draw long arrows.
	const SPEED_REF: float = 5.0
	const LEN_MIN: float = 4.0
	const LEN_MAX: float = 24.0
	const THICK: float = 0.7                   # parallel-line offset faking arrow thickness (visible far off)
	for gx in range(WIND_GRID):
		for gz in range(WIND_GRID):
			var wx: float = -ext + (float(gx) + 0.5) * step
			var wz: float = -ext + (float(gz) + 0.5) * step
			var w: Vector2 = _field.wind_at(wx, wz)
			var speed: float = w.length()
			if speed < 0.02:
				continue
			var dir: Vector3 = Vector3(w.x, 0.0, w.y) / speed
			var arrow: float = clampf(LEN_MIN + speed / SPEED_REF * (LEN_MAX - LEN_MIN), LEN_MIN, LEN_MAX)
			# Colour ramps calm(blue) -> fast(cyan/white) so speed reads at a glance too.
			var t: float = clampf(speed / (SPEED_REF * 1.5), 0.0, 1.0)
			var col: Color = Color(0.35 + 0.55 * t, 0.7 + 0.3 * t, 1.0, 0.85)
			var side: Vector3 = dir.cross(Vector3.UP).normalized()
			var base: Vector3 = Vector3(wx, y, wz)
			var tip: Vector3 = base + dir * arrow
			var hoff: Vector3 = side * THICK
			# Shaft (doubled for thickness) + arrowhead.
			_line(base + hoff, tip + hoff, col)
			_line(base - hoff, tip - hoff, col)
			_line(tip, tip - dir * (arrow * 0.32) + side * (arrow * 0.18), col)
			_line(tip, tip - dir * (arrow * 0.32) - side * (arrow * 0.18), col)


# The emergent SCENT field as a grid of markers above the ground: each cell samples all channels, and
# where any scent is present draws a vertical tick (height = intensity) + a short arrow up the DOMINANT
# channel's gradient, tinted by that channel (prey/predator/blood/food/alarm). This replaces the old marker
# MMI view — it shows scent riding the wind + pooling in valleys, off the same field creatures read.
func _draw_scent() -> void:
	if _field == null or not _field.has_method("scent_at"):
		return
	var ext: float = _field.grid_half_extent() if _field.has_method("grid_half_extent") else 300.0
	var step: float = ext * 2.0 / float(WIND_GRID)
	var y: float = _field.sea_level + 10.0
	for gx in range(WIND_GRID):
		for gz in range(WIND_GRID):
			var wx: float = -ext + (float(gx) + 0.5) * step
			var wz: float = -ext + (float(gz) + 0.5) * step
			var probe: Vector3 = Vector3(wx, y, wz)
			var best: float = 0.0
			var best_ch: int = -1
			for ch in range(SCENT_COLORS.size()):
				var s: float = _field.scent_at(probe, ch)
				if s > best:
					best = s
					best_ch = ch
			if best_ch < 0 or best < 0.01:
				continue
			var col: Color = SCENT_COLORS[best_ch]
			var base: Vector3 = Vector3(wx, y, wz)
			var h: float = clampf(1.0 + best * 3.0, 1.0, 8.0)
			_line(base, base + Vector3.UP * h, col)          # a tick whose height reads intensity
			var g: Vector3 = _field.scent_gradient(probe, best_ch)
			if g.length() > 0.001:
				_line(base, base + g.normalized() * (step * 0.35), col)


# The active FIELD CHANNEL as a heatmap over the planet surface: a lat/long grid of directions, each
# projected to the real ground (terrain.surface_point) and drawn as a colored radial spike whose height
# and colour encode the sampled channel (biomass, gas, snow, lava, charge, …). Camera-facing hemisphere
# only (back-side dirs are culled) so it stays cheap. This is the temperature-heatmap idea (sample a
# channel → colour ramp) generalized to every substrate channel, off the field's public per-cell queries.
func _draw_field_channel() -> void:
	if _field == null or _terrain == null or not _terrain.has_method("surface_point"):
		return
	var center: Vector3 = _terrain.planet_center() if _terrain.has_method("planet_center") else Vector3.ZERO
	# Cull the far hemisphere: keep directions whose outward normal faces the camera.
	var cam_dir: Vector3 = Vector3.ZERO
	var vp: Viewport = get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null:
		var to_cam: Vector3 = cam.global_position - center
		if to_cam.length() > 0.001:
			cam_dir = to_cam.normalized()
	for iy in range(1, FIELD_LAT):
		var theta: float = PI * float(iy) / float(FIELD_LAT)     # polar angle 0..PI
		var st: float = sin(theta)
		var ct: float = cos(theta)
		for ix in range(FIELD_LON):
			var phi: float = TAU * float(ix) / float(FIELD_LON)
			var dir: Vector3 = Vector3(st * cos(phi), ct, st * sin(phi))
			if cam_dir != Vector3.ZERO and dir.dot(cam_dir) < -0.15:
				continue                                          # back side — skip
			var p: Vector3 = _terrain.surface_point(dir)
			if is_nan(p.x):
				continue
			var sample: Array = _field_sample(p)
			if not bool(sample[0]):
				continue
			var col: Color = sample[1]
			var t: float = float(sample[2])
			var h: float = FIELD_SPIKE_MIN + t * (FIELD_SPIKE_MAX - FIELD_SPIKE_MIN)
			_line(p, p + dir * h, col)


# Sample the active channel at world point `p`; returns [visible, colour, t] where t in 0..1 drives the
# spike height and colour intensity. Uses only the field's public per-cell queries + a per-channel ramp.
func _field_sample(p: Vector3) -> Array:
	var val: float = 0.0
	var ref: float = 1.0
	var base: Color = Color(1, 1, 1)
	match _field_channel:
		"biomass":
			val = _field.biomass_at(p.x, p.y, p.z)
			ref = 0.4
			base = Color(0.25, 0.9, 0.3)
		"co2":
			val = _field.co2_at(p.x, p.y, p.z)
			ref = 0.6
			base = Color(0.85, 0.5, 0.35)
		"o2":
			val = _field.o2_at(p.x, p.y, p.z)
			ref = 1.4
			base = Color(0.35, 0.7, 1.0)
		"lava":
			val = _field.lava_at(p.x, p.y, p.z)
			ref = 0.5
			base = Color(1.0, 0.45, 0.1)
		"rock_fill":
			val = _field.rock_fill_at(p.x, p.y, p.z)
			ref = 1.0
			base = Color(0.55, 0.45, 0.38)
		"charge":
			val = _field.charge_at(p.x, p.y, p.z)
			ref = 1.0
			base = Color(0.7, 0.35, 0.95)
		"fertility":
			val = _field.fertility_at(p)
			ref = 1.0
			base = Color(0.6, 0.75, 0.25)
		"snow":
			val = _field.snow_depth_at(p)
			ref = 1.0
			base = Color(0.92, 0.95, 1.0)
		"water_phase":
			return _sample_water_phase(p)
		_:
			return [false, base, 0.0]
	if val <= 0.0001:
		return [false, base, 0.0]
	var t: float = clampf(val / ref, 0.06, 1.0)
	# Darken low values toward black so structure reads (dim = little, bright = a lot).
	var col: Color = Color(base.r * (0.35 + 0.65 * t), base.g * (0.35 + 0.65 * t), base.b * (0.35 + 0.65 * t), 0.9)
	return [true, col, t]


# Water-phase composite: whichever of snow (white), cloud (light blue), fog (grey) dominates the column
# tints the spike, so the frozen/aloft/near-ground H2O phases read at a glance in one view.
func _sample_water_phase(p: Vector3) -> Array:
	var snow: float = _field.snow_depth_at(p) if _field.has_method("snow_depth_at") else 0.0
	var cloud: float = _field.cloud_at(p.x, p.z) if _field.has_method("cloud_at") else 0.0
	var fog: float = _field.fog_at(p.x, p.z) if _field.has_method("fog_at") else 0.0
	var best: float = snow
	var col: Color = Color(0.92, 0.95, 1.0, 0.9)                # snow/ice = white
	var ref: float = 1.0
	if cloud > best:
		best = cloud
		col = Color(0.7, 0.82, 1.0, 0.9)                        # cloud = light blue
		ref = 0.8
	if fog > best:
		best = fog
		col = Color(0.6, 0.62, 0.66, 0.9)                       # fog = grey
		ref = 0.8
	if best <= 0.0001:
		return [false, col, 0.0]
	var t: float = clampf(best / ref, 0.06, 1.0)
	return [true, col, t]
