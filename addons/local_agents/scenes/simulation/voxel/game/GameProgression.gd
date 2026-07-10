class_name LAGameProgression
extends Node

## LAGameProgression — the campaign progression spine. The player starts CONSTRAINED (camera locked near the
## surface, most spawns hidden, the solar-system view unavailable) and earns EXISTING capabilities by meeting
## objectives, ending with the solar-system overview as the capstone unlock. It invents no new powers and no
## bespoke trackers: every objective is a cheap read on a cadence from the sim's own telemetry
## (LASimReport.snapshot() — population, cognition, herd gauges, phenomenon events), and every reward is an
## existing capability (camera zoom ceiling, view mode, spawn-palette entry) it simply GATES.
##
## Data-driven ladder: `_stages` is a list of LAProgressionStage records (objective metric + threshold +
## unlock set), evaluated by ONE generic function. Adding a stage is a new record, not a new branch.
##
## Modes (read from the GameMode autoload):
##   - CAMPAIGN — gating on: begin at the baseline unlock set, complete stages to earn the rest.
##   - SANDBOX  — gating off: everything unlocked from the start (the same game, no ladder).
##
## Access: gating consumers (the camera rig, the view-controls cluster, the spawn palette) QUERY this via the
## static singleton `LAGameProgression.active()` and listen to `capability_unlocked` / `objective_completed`.
## When no instance exists (isolated tests, tools), the static fallbacks report everything unlocked so nothing
## is gated off by accident. Wired into VoxelWorld with one add_child line. (Explicit types only.)

signal capability_unlocked(id: String)
signal objective_completed(id: String)

const StageScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/game/ProgressionStage.gd")

const CONFIG_PATH: String = "user://progression.cfg"
const CONFIG_SECTION: String = "campaign"
## How often objectives are re-evaluated (seconds). A handful of cheap telemetry reads per second — never
## per-frame, never a full-grid sweep (Big-O trivial).
const CHECK_INTERVAL: float = 0.5
## Sandbox / no-cap sentinel for the zoom-ceiling query — the camera min()s it against its own hard maximum.
const ZOOM_MULT_UNBOUNDED: float = 999.0

# Capabilities and zoom ceiling handed to the player before any objective is met (campaign). Sandbox ignores
# these and unlocks the full set. Baseline = plants + trees, the close orbit + fly views, camera near surface.
const BASELINE_ZOOM_MULT: float = 1.5
const BASELINE_UNLOCKS: PackedStringArray = [
	"spawn_plant", "spawn_tree", "view_orbit", "view_fly",
]

# Every capability id the game knows about — the full set granted in sandbox (and eventually in campaign).
const ALL_SPAWN_KINDS: PackedStringArray = [
	"plant", "tree", "rabbit", "fox", "bird", "vulture", "villager", "fish",
	"meteor", "volcano", "lightning", "earthquake", "flood", "tornado", "thunderstorm", "hurricane",
]
const ALL_VIEWS: PackedStringArray = [
	"view_orbit", "view_fly", "view_geosync", "view_solar",
]
# Non-spawn, non-view player abilities that are gated the same way. "grab" is the Black & White hand
# (click-to-carry / throw). Deliberately withheld at the start so the player first learns to shape the world
# by SPAWNING; it is earned once they've grown a living world (granted by the 'thriving' stage below).
const ALL_ABILITIES: PackedStringArray = ["grab"]

static var _active: LAGameProgression = null

var _sandbox: bool = false
var _stages: Array = []             # Array[LAProgressionStage] — the ordered ladder (campaign)
var _current: int = 0               # index of the stage whose objective is still open (== _stages.size() when done)
var _unlocked: Dictionary = {}      # capability id -> true
var _zoom_mult: float = BASELINE_ZOOM_MULT
var _hold_accum: float = 0.0        # seconds the current stage's metric has held at/above threshold
var _accum: float = 0.0


## The live instance, or null when none is in the tree (isolated tests / tools). Gating consumers use the
## static fallbacks (cap_unlocked / spawn_unlocked / zoom_ceiling_mult) so a null is treated as "unlocked".
static func active() -> LAGameProgression:
	return _active


## Static-safe capability query: unlocked when there is no progression instance (tests), else delegates.
static func cap_unlocked(cap: String) -> bool:
	return _active == null or _active.is_unlocked(cap)


## Static-safe spawn-kind query (kind is the palette id, e.g. "fox").
static func spawn_unlocked(kind: String) -> bool:
	return _active == null or _active.is_spawn_unlocked(kind)


## Static-safe orbit zoom ceiling (planet radii); unbounded when there is no instance.
static func zoom_ceiling_mult() -> float:
	return ZOOM_MULT_UNBOUNDED if _active == null else _active.max_orbit_distance_mult()


func _ready() -> void:
	_active = self
	_build_ladder()
	# Sandbox when the GameMode autoload says so; campaign otherwise (and when GameMode is absent in a tool/test,
	# default to campaign so the gating path is what gets exercised).
	var gm: Object = _game_mode()
	_sandbox = gm != null and gm.is_sandbox()
	if _sandbox:
		_unlock_everything()
	else:
		_apply_baseline()
		# Only RESUME saved progression when actually loading a save (a pending load slot). A genuinely NEW
		# campaign (start_campaign cleared the slot) stays at BASELINE — otherwise it inherits the previous
		# campaign's unlocks/stage from the shared global progression.cfg and boots with the gating bypassed.
		if gm != null and String(gm.pending_load_slot) != "":
			load_from_disk()
	LASimReport.register(Callable(self, "report"))
	print("PROGRESSION={mode:%s, stage:%d/%d, zoom_mult:%.2f, unlocked:%d}" % [
		("sandbox" if _sandbox else "campaign"), _current, _stages.size(), _zoom_mult, _unlocked.size()])


func _exit_tree() -> void:
	if _active == self:
		_active = null


## Resolve the GameMode autoload without a hard dependency (kept queryable from tools/tests where it is absent).
func _game_mode() -> Object:
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GameMode")


# --- The ladder (data, not logic) -------------------------------------------------------------------------
# Each rung: an objective read from live telemetry, the capabilities it grants, and the zoom ceiling it opens.
# Chosen so every metric genuinely starts below its threshold and climbs from the sim's own dynamics — a herd
# forming, the population growing, a bloodline breeding to a third generation, a disaster striking — so the
# capabilities are earned, not handed over at spawn. Thresholds are tunable data; behaviour is generic.
func _build_ladder() -> void:
	_stages = [
		# Plant vegetation: the player's first act. Needs PLAYER action (baseline spawn_plant/tree are unlocked
		# from the start), so — unlike a herd metric that a fresh population satisfies instantly — it can't
		# auto-complete. Reaching the target opens rabbits (which then have food). Pairs with a sparse curated
		# start area (few initial plants) so `plants` genuinely starts below the threshold.
		_stage("plant_life", "Plant vegetation so rabbits can feed", "plants", 30.0, 0.0,
			PackedStringArray(["spawn_rabbit", "spawn_fox", "spawn_fish"]), 2.4),
		# A thriving world: total living creatures grow past the founding stock (needs births beyond the initial spawn).
		_stage("thriving", "Grow the world to 170 creatures", "creatures", 170.0, 0.0,
			PackedStringArray(["spawn_bird", "spawn_vulture", "view_geosync", "grab"]), 3.4),
		# An enduring bloodline: a founding lineage breeds through to a third generation (generation index reaches 2).
		_stage("lineage", "Raise a bloodline to the third generation", "max_generation", 2.0, 0.0,
			PackedStringArray(["spawn_villager", "spawn_meteor", "spawn_volcano", "spawn_lightning",
				"spawn_earthquake", "spawn_flood", "spawn_tornado", "spawn_thunderstorm", "spawn_hurricane"]), 4.6),
		# Capstone — weather the storm: survive a natural disaster (any tracked field phenomenon), then ascend to
		# the whole solar system.
		_stage("survive_disaster", "Weather a natural disaster, then survey the heavens", "phenomena_tracked", 1.0, 0.0,
			PackedStringArray(["view_solar"]), 6.0),
	]


func _stage(id: String, title: String, metric: String, threshold: float, hold_seconds: float, unlocks: PackedStringArray, zoom_mult: float) -> LAProgressionStage:
	var s: LAProgressionStage = StageScript.new()
	s.id = id
	s.title = title
	s.metric = metric
	s.threshold = threshold
	s.hold_seconds = hold_seconds
	s.unlocks = unlocks
	s.zoom_mult = zoom_mult
	return s


func _apply_baseline() -> void:
	_current = 0
	_zoom_mult = BASELINE_ZOOM_MULT
	_unlocked = {}
	for cap in BASELINE_UNLOCKS:
		_unlocked[cap] = true


func _unlock_everything() -> void:
	_unlocked = {}
	for k in ALL_SPAWN_KINDS:
		_unlocked["spawn_" + k] = true
	for v in ALL_VIEWS:
		_unlocked[v] = true
	for a in ALL_ABILITIES:
		_unlocked[a] = true
	_zoom_mult = ZOOM_MULT_UNBOUNDED
	_current = _stages.size()


# --- Queries (gating consumers call these) ----------------------------------------------------------------

## True when capability `cap` is available. Sandbox and the null-instance fallback report everything unlocked.
func is_unlocked(cap: String) -> bool:
	return _sandbox or bool(_unlocked.get(cap, false))


## True when the spawn-palette entry for `kind` (e.g. "fox") is available.
func is_spawn_unlocked(kind: String) -> bool:
	return is_unlocked("spawn_" + kind)


## The orbit max-distance ceiling in planet radii. Sandbox is unbounded (the camera clamps to its own hard max).
func max_orbit_distance_mult() -> float:
	return ZOOM_MULT_UNBOUNDED if _sandbox else _zoom_mult


## Index of the stage whose objective is currently open (== stage count once the ladder is complete).
func current_stage() -> int:
	return _current


## The active objective's short description (for a HUD / tutorial), or "" when the ladder is complete.
func current_objective() -> String:
	if _sandbox or _current >= _stages.size():
		return ""
	return (_stages[_current] as LAProgressionStage).title


## True when gating is off (sandbox) — the HUD hides objectives and shows a Sandbox tag instead.
func is_sandbox() -> bool:
	return _sandbox


## Read-only snapshot of the active objective for a HUD: title, 1-based stage index + total, and progress
## toward the threshold (value + ratio, read from the SAME live telemetry the evaluator uses — no duplicated
## metric logic). `done` is true once the ladder is complete (or in sandbox). Cheap: one telemetry snapshot.
func current_progress() -> Dictionary:
	var total: int = _stages.size()
	if _sandbox or _current >= total:
		return {
			"sandbox": _sandbox, "title": "", "stage": total, "stages_total": total,
			"value": 0.0, "threshold": 0.0, "ratio": 1.0, "done": true,
		}
	var stage: LAProgressionStage = _stages[_current]
	var value: float = _read_metric(LASimReport.snapshot(), stage.metric)
	var denom: float = maxf(stage.threshold, 0.0001)
	return {
		"sandbox": false, "title": stage.title, "stage": _current + 1, "stages_total": total,
		"value": value, "threshold": stage.threshold, "ratio": clampf(value / denom, 0.0, 1.0), "done": false,
	}


# --- Objective evaluation (cadence, not per-frame) --------------------------------------------------------

func _process(delta: float) -> void:
	if _sandbox or _current >= _stages.size():
		return
	_accum += delta
	if _accum < CHECK_INTERVAL:
		return
	var dt: float = _accum
	_accum = 0.0
	_evaluate(dt)


## Evaluate the single open stage against the live telemetry snapshot. One dictionary read + threshold test;
## the hold timer accumulates while the metric stays at/above threshold and resets when it drops.
func _evaluate(dt: float) -> void:
	var stage: LAProgressionStage = _stages[_current]
	var snapshot: Dictionary = LASimReport.snapshot()
	var value: float = _read_metric(snapshot, stage.metric)
	if value < stage.threshold:
		_hold_accum = 0.0
		return
	_hold_accum += dt
	if _hold_accum < stage.hold_seconds:
		return
	_complete_stage(stage)


## Grant a completed stage's rewards: raise the zoom ceiling, unlock its capabilities (emitting per id), then
## advance to the next rung and persist. Emits objective_completed for HUD/audio/tutorial consumers.
func _complete_stage(stage: LAProgressionStage) -> void:
	if stage.zoom_mult > _zoom_mult:
		_zoom_mult = stage.zoom_mult
	for cap in stage.unlocks:
		if not bool(_unlocked.get(cap, false)):
			_unlocked[cap] = true
			capability_unlocked.emit(cap)
			print("CAPABILITY_UNLOCKED={id:%s}" % cap)
	print("OBJECTIVE_COMPLETE={id:%s, stage:%d, zoom_mult:%.2f}" % [stage.id, _current, _zoom_mult])
	objective_completed.emit(stage.id)
	_current += 1
	_hold_accum = 0.0
	save_to_disk()


## Walk a slash-separated path into the snapshot dictionary, returning the numeric leaf (0.0 if any hop is
## missing or non-numeric). Handles both the flat provider keys and the nested gauges/<name>/<min|cur|max>.
func _read_metric(snapshot: Dictionary, path: String) -> float:
	var cursor: Variant = snapshot
	for part in path.split("/", false):
		if cursor is Dictionary and (cursor as Dictionary).has(part):
			cursor = (cursor as Dictionary)[part]
		else:
			return 0.0
	if cursor is float or cursor is int:
		return float(cursor)
	return 0.0


# --- Persistence ------------------------------------------------------------------------------------------

## Snapshot of the progression for the save interface (mode + stage + unlocked set + zoom ceiling).
func serialize() -> Dictionary:
	return {
		"mode": ("sandbox" if _sandbox else "campaign"),
		"current_stage": _current,
		"zoom_mult": _zoom_mult,
		"unlocked": _unlocked.keys(),
	}


## Restore from a serialize() dictionary. Sandbox stays fully unlocked regardless (the same game with gating off).
func restore(data: Dictionary) -> void:
	if _sandbox:
		return
	_current = int(data.get("current_stage", 0))
	_zoom_mult = float(data.get("zoom_mult", BASELINE_ZOOM_MULT))
	_unlocked = {}
	for cap in data.get("unlocked", []):
		_unlocked[str(cap)] = true


## Persist the campaign progression to a ConfigFile (no-op in sandbox — nothing to save when all is unlocked).
func save_to_disk() -> void:
	if _sandbox:
		return
	var cfg: ConfigFile = ConfigFile.new()
	var state: Dictionary = serialize()
	cfg.set_value(CONFIG_SECTION, "current_stage", state["current_stage"])
	cfg.set_value(CONFIG_SECTION, "zoom_mult", state["zoom_mult"])
	cfg.set_value(CONFIG_SECTION, "unlocked", state["unlocked"])
	cfg.save(CONFIG_PATH)


## Load persisted campaign progression if present; otherwise the baseline (already applied) stands.
func load_from_disk() -> void:
	if _sandbox or not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	restore({
		"current_stage": cfg.get_value(CONFIG_SECTION, "current_stage", 0),
		"zoom_mult": cfg.get_value(CONFIG_SECTION, "zoom_mult", BASELINE_ZOOM_MULT),
		"unlocked": cfg.get_value(CONFIG_SECTION, "unlocked", []),
	})


## SIM_REPORT telemetry provider — surfaces progression state in the one-line report for the harness/gates.
func report() -> Dictionary:
	return {
		"progression_mode": ("sandbox" if _sandbox else "campaign"),
		"progression_stage": _current,
		"progression_stages_total": _stages.size(),
		"progression_zoom_mult": _zoom_mult,
		"progression_unlocked": _unlocked.size(),
		"progression_solar": is_unlocked("view_solar"),
	}
