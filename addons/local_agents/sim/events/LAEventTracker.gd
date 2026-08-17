class_name LAEventTracker
extends Node


const ThresholdDetectorScript: GDScript = preload("res://addons/local_agents/sim/events/LAThresholdDetector.gd")

signal event_emitted(event: LAEvent)

const SAMPLE_INTERVAL: float = 1.0    # coarse detection cadence — 1 Hz, not per frame (phenomena last seconds)
const RECENT_MAX: int = 32            # ring-buffer of the latest events a consumer can pull

var _world: Node = null
var _material = null                  # LAMaterialField3D — the shared substrate; source of the field aggregates
var _queries = null                   # LAMaterialFieldQueries3D — the field's read accessors
var _ecology = null                   # LAEcologyService — source of the fire count
var _detectors: Array = []            # ordered registry of LAEventDetector plugins
var _prev: Dictionary = {}            # previous snapshot (detectors read prev -> cur deltas)
var _accum: float = 0.0
var _recent: Array = []               # ring of the latest LAEvents (newest last)
var _total_emitted: int = 0
var _kind_counts: Dictionary = {}     # type -> count, for the SIM_REPORT summary


## Wire from the composition root. Pulls the substrate + ecology off the world (no extra args needed), builds
## the detector registry, and registers itself as a SIM_REPORT telemetry source.
func setup(world: Node) -> void:
	_world = world
	_material = world.get("_material")
	_ecology = world.get("_ecology")
	if _material != null:
		_queries = _material.get("_queries")   # the read-accessor object, not the hub
	_build_registry()
	LASimReport.register(Callable(self, "report"))
	_log_dormant_detectors()


## The ordered registry — all field phenomena are CONFIGURED records of the one generic threshold detector
## (config over `if type == X`). A new phenomenon appends one entry here; a bespoke phenomenon that needs
## richer logic would subclass LAEventDetector and drop its instance in the same list.
func _build_registry() -> void:
	_detectors = [
		# Eruption: molten-rock (lava) total ramps up from ~0 as a vent supplies it, and stays up. Escalates
		_threshold("eruption", "melt_total", "cross_up", 0.5, 0.1, 12.0, 0.02,
			"a volcano is erupting — molten lava is pouring out"),
		# Wildfire: the ecology fire count rising off zero (fire ignited and is spreading).
		_threshold("wildfire", "fires", "cross_up", 0.5, 0.5, 7.0, 1.5,
			"a wildfire has broken out and is spreading"),
		_threshold_increment("impact", "shock_cells", 1.0, 3.0, 12.0,
			"a violent impact just shook the ground"),
		# NO FLOOD DETECTOR. `water_total` is a GLOBAL sum, and a flood is local: one valley filling while
		# another dries sums to zero. What a global rise in liquid water actually means is planet-wide net
		_threshold("storm", "wind", "cross_up", 8.0, 4.0, 10.0, 0.5,
			"a storm is whipping up — the wind is howling"),
		# Lightning: each bolt is one strike, off the bolt_cells reduce row.
		_threshold_increment("lightning", "bolts", 1.0, 1.5, 12.0,
			"lightning just struck"),
	]


func _threshold(type_name: String, key: String, mode: String, threshold: float, rearm: float, intensity_base: float, intensity_scale: float, text: String) -> LAThresholdDetector:
	var d: LAThresholdDetector = ThresholdDetectorScript.new()
	d.type_name = type_name
	d.key = key
	d.mode = mode
	d.threshold = threshold
	d.rearm = rearm
	d.intensity_base = intensity_base
	d.intensity_scale = intensity_scale
	d.description_text = text
	return d


func _threshold_rate(type_name: String, key: String, rate_threshold: float, cooldown_s: float, intensity_base: float, intensity_scale: float, text: String) -> LAThresholdDetector:
	var d: LAThresholdDetector = _threshold(type_name, key, "rate", rate_threshold, 0.0, intensity_base, intensity_scale, text)
	d.cooldown_s = cooldown_s
	return d


func _threshold_increment(type_name: String, key: String, step: float, cooldown_s: float, intensity_base: float, text: String) -> LAThresholdDetector:
	var d: LAThresholdDetector = _threshold(type_name, key, "increment", step, 0.0, intensity_base, 0.0, text)
	d.cooldown_s = cooldown_s
	return d


func _process(delta: float) -> void:
	_accum += delta
	if _accum < SAMPLE_INTERVAL:
		return
	var dt: float = _accum
	_accum = 0.0
	_sample(dt)


## One detection pass: build the current snapshot (field aggregates + ecology tally), run every detector over
## (prev -> cur), and emit whatever crossed. Cheap: one report() reduction + one O(creatures) tally per sample.
func _sample(dt: float) -> void:
	var cur: Dictionary = _snapshot()
	if not _prev.is_empty():
		for d in _detectors:
			var events: Array = d.detect(_prev, cur, dt)
			for e in events:
				_emit(e)
	_prev = cur


func _snapshot() -> Dictionary:
	var snap: Dictionary = {}
	if _material != null:
		if _material.has_method("total_water"):
			snap["water_total"] = _material.total_water()
		if _material.has_method("wind"):
			snap["wind"] = (_material.wind() as Vector2).length()
		if _material.has_method("bolts_fired"):
			snap["bolts"] = _material.bolts_fired()
		if _material.has_method("shock_cell_count"):
			snap["shock_cells"] = _material.shock_cell_count()
	if _queries != null and _queries.has_method("melt_total"):
		snap["melt_total"] = _queries.melt_total()
	snap["fires"] = _fire_count()
	return snap


func _fire_count() -> int:
	if _ecology != null and _ecology.has_method("fire_system"):
		var fs = _ecology.fire_system()
		if fs != null and fs.has_method("active_fire_count"):
			return int(fs.active_fire_count())
	return 0


## Stamp, record, tally, and broadcast one event. Tallying into LASimReport.event() surfaces it in
## SIM_REPORT.events automatically ("phenomenon" + "phenomenon/<type>" breakdown for free).
func _emit(e: LAEvent) -> void:
	e.frame = Engine.get_physics_frames()
	e.time = float(Time.get_ticks_msec()) / 1000.0
	_recent.append(e)
	while _recent.size() > RECENT_MAX:
		_recent.pop_front()
	_total_emitted += 1
	_kind_counts[e.type] = int(_kind_counts.get(e.type, 0)) + 1
	LASimReport.event("phenomenon", {"type": e.type})
	emit_signal("event_emitted", e)


## Pull query — the most recent events (newest last), up to `count`. Consumers that prefer polling over the
## signal (telemetry snapshots, a HUD) read this.
func recent_events(count: int = RECENT_MAX) -> Array:
	if count >= _recent.size():
		return _recent.duplicate()
	return _recent.slice(_recent.size() - count, _recent.size())


## SIM_REPORT telemetry provider — a compact summary of what the tracker has emitted, so phenomena surface in
## the one-line report even with the streamer disabled.
func report() -> Dictionary:
	var latest: Array = []
	var tail: Array = recent_events(6)
	for e in tail:
		latest.append("%s@%d" % [e.type, e.frame])
	return {
		"phenomena_tracked": _total_emitted,
		"phenomena_kinds": _kind_counts.duplicate(),
		"phenomena_recent": latest,
	}


## Startup diagnostic: LOG (never silently skip) which detectors watch a signal nothing has written.
func _log_dormant_detectors() -> void:
	var probe: Dictionary = _snapshot()
	var dormant: Array = []
	var live: Array = []
	for d in _detectors:
		if d.has_method("signal_live") and not d.signal_live(probe):
			dormant.append(d.phenomenon())
		else:
			live.append(d.phenomenon())
	print("EVENT_TRACKER={live:%s, dormant:%s}" % [str(live), str(dormant)])
