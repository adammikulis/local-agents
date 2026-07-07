class_name LASceneEnergyGraph
extends Control

## A live line graph of the SCENE'S TOTAL ENERGY, broken into its physical sources:
##   - KINETIC : the motion of the animals — Σ ½·m·v² over every creature (mass from its size, speed
##               scaled by how agitated its state is), so a calm herd reads low and a stampede spikes.
##   - SEISMIC : the ground-shake energy of impacts/quakes (the ecology's live seismic pulse ring).
##   - THERMAL : heat in the world — hot cells + lava (a meteor crater, a wildfire, a lava flow).
## Total = their weighted sum. The same number the streamer uses to gauge "how big a deal is this" — so
## the graph IS the intensity signal, made visible. Emergent: nothing is per-event, it's just the energy.
## (Explicit types only — project rule: no ':=' inferred typing.)

const SAMPLE_HZ: float = 10.0
# HARD minimum physics-frames between samples. _sample_energy() calls hot_cell_count()/lava_cell_count()
# (full 127K-cell field scans), so at low FPS the wall-clock 10Hz gate would fire EVERY frame — that was
# ~75ms/frame, the dominant streamer cost (it dropped the sim from ~28 to ~9 FPS on its own). Capping the
# sample to at most once per this many frames keeps the scan rare regardless of frame-rate; the graph is a
# background readout, so a slightly coarser update is invisible.
const MIN_FRAME_GAP: int = 30
const HISTORY: int = 300                    # ~30 s at 10 Hz
const PANEL_SIZE: Vector2 = Vector2(300.0, 132.0)

# Component weights (bring the three sources into a comparable visual range).
const W_KINETIC: float = 1.0
const W_SEISMIC: float = 8.0
const W_THERMAL: float = 0.6

# Per-state kinetic multiplier on a creature's speed: an agitated animal carries more energy than a
# grazing one. Anything not listed uses 1.0 (ordinary wandering). Emergent stampede = many in panic.
const STATE_KINETIC: Dictionary = {
	"panic": 2.2, "flee": 2.0, "chase": 2.0, "stampede": 2.4, "run": 1.8,
	"stalk": 1.3, "seek": 1.2, "swim": 1.0,
	"idle": 0.25, "rest": 0.2, "sleep": 0.1, "graze": 0.5, "eat": 0.4, "drink": 0.4,
}

var _world: Node = null
var _ecology: Node = null
var _material: Node = null

var _kin: PackedFloat32Array = PackedFloat32Array()
var _seis: PackedFloat32Array = PackedFloat32Array()
var _therm: PackedFloat32Array = PackedFloat32Array()
var _count: int = 0
var _accum: float = 0.0
var _frames_since: int = 0             # physics frames since the last (expensive) energy sample
var _peak: float = 1.0                       # rolling auto-scale ceiling


func setup(world: Node, ecology: Node, material: Node) -> void:
	_world = world
	_ecology = ecology
	_material = material
	name = "SceneEnergyGraph"
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	# Top-right, tucked under the status bar.
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	position = Vector2(-PANEL_SIZE.x - 16.0, 52.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kin.resize(HISTORY)
	_seis.resize(HISTORY)
	_therm.resize(HISTORY)


func _process(delta: float) -> void:
	_accum += delta
	_frames_since += 1
	if _accum < 1.0 / SAMPLE_HZ or _frames_since < MIN_FRAME_GAP:
		return
	_accum = 0.0
	_frames_since = 0
	var sample: Dictionary = _sample_energy()
	var i: int = _count % HISTORY
	_kin[i] = float(sample["kinetic"])
	_seis[i] = float(sample["seismic"])
	_therm[i] = float(sample["thermal"])
	_count += 1
	queue_redraw()


## Total scene energy right now (the streamer reads this too). {kinetic, seismic, thermal, total}.
func _sample_energy() -> Dictionary:
	var kinetic: float = 0.0
	var tree: SceneTree = get_tree()
	if tree != null:
		for n in tree.get_nodes_in_group("creature"):
			if not is_instance_valid(n):
				continue
			var size: float = float(n.get("size")) if n.get("size") != null else 0.5
			var speed: float = float(n.get("speed")) if n.get("speed") != null else 3.0
			var mult: float = float(STATE_KINETIC.get(String(n.get("state")), 1.0))
			var v: float = speed * mult
			var mass: float = size * size * size          # mass ∝ volume
			kinetic += 0.5 * mass * v * v

	var seismic: float = 0.0
	if _ecology != null and _ecology.has_method("total_seismic_energy"):
		seismic = float(_ecology.total_seismic_energy())

	var thermal: float = 0.0
	if _material != null:
		if _material.has_method("hot_cell_count"):
			thermal += float(_material.hot_cell_count())
		if _material.has_method("lava_cell_count"):
			thermal += 3.0 * float(_material.lava_cell_count())

	var total: float = W_KINETIC * kinetic + W_SEISMIC * seismic + W_THERMAL * thermal
	return {"kinetic": W_KINETIC * kinetic, "seismic": W_SEISMIC * seismic, "thermal": W_THERMAL * thermal, "total": total}


## The current total scene energy (0 until the first sample) — for the streamer intensity source.
func current_total() -> float:
	if _count == 0:
		return 0.0
	var i: int = (_count - 1) % HISTORY
	return _kin[i] + _seis[i] + _therm[i]


func _draw() -> void:
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.05, 0.06, 0.09, 0.72))
	draw_rect(r, Color(0.4, 0.5, 0.65, 0.5), false, 1.0)

	var n: int = mini(_count, HISTORY)
	if n < 2:
		return
	# Auto-scale to the recent peak (eased so it doesn't jitter).
	var maxv: float = 1.0
	for k in range(n):
		var t: float = _kin[k] + _seis[k] + _therm[k]
		if t > maxv:
			maxv = t
	_peak = maxf(maxv, lerpf(_peak, maxv, 0.1))
	var pad: float = 8.0
	var gx: float = pad
	var gy: float = pad + 12.0
	var gw: float = size.x - pad * 2.0
	var gh: float = size.y - gy - pad

	# Stacked area: thermal (base) + seismic + kinetic, so the TOTAL is the top line.
	var kin_c: Color = Color(0.35, 0.8, 0.45)      # green — life in motion
	var seis_c: Color = Color(0.85, 0.55, 0.25)    # orange — ground shake
	var therm_c: Color = Color(0.9, 0.3, 0.25)     # red — heat
	var start: int = _count - n
	var prev: Vector2 = Vector2.ZERO
	for k in range(n):
		var idx: int = (start + k) % HISTORY
		var frac: float = float(k) / float(HISTORY - 1)
		var x: float = gx + frac * gw
		var stack_t: float = _therm[idx]
		var stack_ts: float = stack_t + _seis[idx]
		var stack_all: float = stack_ts + _kin[idx]
		var y_t: float = gy + gh * (1.0 - clampf(stack_t / _peak, 0.0, 1.0))
		var y_ts: float = gy + gh * (1.0 - clampf(stack_ts / _peak, 0.0, 1.0))
		var y_all: float = gy + gh * (1.0 - clampf(stack_all / _peak, 0.0, 1.0))
		draw_line(Vector2(x, gy + gh), Vector2(x, y_t), therm_c, 1.0)
		draw_line(Vector2(x, y_t), Vector2(x, y_ts), seis_c, 1.0)
		draw_line(Vector2(x, y_ts), Vector2(x, y_all), kin_c, 1.0)
		if k > 0:
			draw_line(prev, Vector2(x, y_all), Color(1, 1, 1, 0.85), 1.5)
		prev = Vector2(x, y_all)

	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(pad, 14.0), "SCENE ENERGY  %.0f" % current_total(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.9, 0.95))
