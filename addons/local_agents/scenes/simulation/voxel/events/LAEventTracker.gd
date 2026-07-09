class_name LAEventTracker
extends Node

## The emergent PHENOMENON EVENT TRACKER — the SINGLE source for FIELD-SUBSTRATE phenomena. It watches the
## shared field each sample and emits typed discrete LAEvents ("eruption", "wildfire", "flood", "storm",
## "lightning", "impact") with type + intensity + frame/time (and a best-effort locus). Every event is
## derived purely from field aggregates — never from a scripted disaster actor. The streamer commentary and
## SIM_REPORT telemetry (and, later, the dissolved disaster actors' visuals) all CONSUME these events
## instead of each scanning the world themselves — one emergent source, many consumers.
##
## SCOPE — field phenomena only (dissolve-don't-patch / no parallel systems): this deliberately does NOT
## detect creature-ecology beats (deaths/births/stalks/…). The streamer already owns a RICHER, per-species,
## located narration scan for those, and duplicating it here would be a parallel system. What this DOES
## dissolve is the streamer's crude FIELD detection (a "destruction spike" proxy + a raw fire count) — those
## now arrive as proper field-derived events. If the disaster actors are later fully dissolved, ecology
## detectors can move here too (one more plugin each), but not while the streamer is their better owner.
##
## Composable-plugins form: this thin HOST owns the shared per-sample snapshot + an ordered REGISTRY of
## tiny LAEventDetector plugins (one per phenomenon). Adding a phenomenon = drop in a detector, never patch
## a monolith.
##
## Big-O / LOD: detection is CHEAP. It samples at a COARSE cadence (1 Hz, not per frame) and computes ONLY
## the few scalar aggregates its detectors actually read — lava_total, peak_heat, water_total, wind, bolts —
## NOT the field's full ~25-scan report() reduction (calling that at frame cadence was measured to halve fps;
## it is a snapshot-only reduction). That is a handful of O(cells) reductions per second (~sub-ms/frame
## amortised). Each detector is O(1) threshold/counter/rate arithmetic over the snapshot, so the pass is
## O(detectors) per sample. No O(n²), no per-frame full-grid sweep.
##
## Exposes both a SIGNAL (event_emitted) and a recent_events() query so pull- and push-style consumers both
## work. (Explicit types only — project rule: no ':=' inferred typing.)

const ThresholdDetectorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/events/LAThresholdDetector.gd")

signal event_emitted(event: LAEvent)

const SAMPLE_INTERVAL: float = 1.0    # coarse detection cadence — 1 Hz, not per frame (phenomena last seconds)
const RECENT_MAX: int = 32            # ring-buffer of the latest events a consumer can pull

var _world: Node = null
var _material = null                  # LAMaterialField3D — the shared substrate; source of the field aggregates
var _queries = null                   # LAMaterialFieldQueries3D — the field's read accessors (lava_total lives here)
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
		_queries = _material.get("_queries")   # the read-accessor object (lava_total lives here, not on the hub)
	_build_registry()
	LASimReport.register(Callable(self, "report"))
	_log_dormant_detectors()


## The ordered registry — all field phenomena are CONFIGURED records of the one generic threshold detector
## (config over `if type == X`). A new phenomenon appends one entry here; a bespoke phenomenon that needs
## richer logic would subclass LAEventDetector and drop its instance in the same list.
func _build_registry() -> void:
	_detectors = [
		# Eruption: molten-rock (lava) total ramps up from ~0 as a vent supplies it, and stays up. Escalates
		# as the supply builds. This is the primary live geological signal on the sphere path (add_lava).
		_threshold("eruption", "lava_total", "cross_up", 0.5, 0.1, 12.0, 0.02,
			"a volcano is erupting — molten lava is pouring out"),
		# Wildfire: the ecology fire count rising off zero (fire ignited and is spreading).
		_threshold("wildfire", "fires", "cross_up", 0.5, 0.5, 7.0, 1.5,
			"a wildfire has broken out and is spreading"),
		# Impact: a meteor's shock/sound wave (shock cells appearing). heat_peak is NOT used — it is shared
		# with the eruption/geothermal core (pinned hot), so it can't distinguish an impact. NOTE: the sphere
		# shock channel is stubbed to 0, so this is DORMANT until it is read back (logged), same as lightning.
		_threshold_increment("impact", "shock_cells", 1.0, 3.0, 12.0,
			"a violent impact just shook the ground"),
		# Flood: a FAST rise in dynamic liquid water over a large baseline (a surge/pool-fill).
		_threshold_rate("flood", "water_total", 40.0, 5.0, 12.0, 0.02,
			"floodwater is rising fast"),
		# Storm: the emergent wind speed crossing high (a gale whipping up). Scalar wind() magnitude.
		_threshold("storm", "wind", "cross_up", 8.0, 4.0, 10.0, 0.5,
			"a storm is whipping up — the wind is howling"),
		# Lightning: each bolt is one strike (cumulative counter increment). NOTE: bolts/charge are stubbed
		# to 0 on the sphere path, so this is DORMANT until the sphere charge channel is read back (logged).
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


## Compose the per-sample snapshot from ONLY the scalar aggregates the detectors read — a couple of O(cells)
## reductions, NOT the field's full report() (that bundles ~25 scans and is snapshot-only). No creature loop
## either (the streamer owns creature-narration scanning). Keys: lava_total (eruption), water_total (flood),
## wind (storm), fires (wildfire), plus the cheap stub counters bolts (lightning) and shock_cells (impact).
func _snapshot() -> Dictionary:
	var snap: Dictionary = {}
	if _material != null:
		if _material.has_method("water_total"):
			snap["water_total"] = _material.water_total()
		if _material.has_method("wind"):
			snap["wind"] = (_material.wind() as Vector2).length()
		if _material.has_method("bolts_fired"):
			snap["bolts"] = _material.bolts_fired()
		if _material.has_method("shock_cell_count"):
			snap["shock_cells"] = _material.shock_cell_count()
	if _queries != null and _queries.has_method("lava_total"):
		snap["lava_total"] = _queries.lava_total()
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


## Startup diagnostic: LOG (never silently skip) which detectors are watching a signal that is not live yet
## on this build — the bolts/charge/shock/magma channels are stubbed to 0 on the sphere path.
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
