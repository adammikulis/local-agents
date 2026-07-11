class_name LAVoxelTimeline
extends Node

## Snapshot ring buffer → smooth in-place REVERSE + timeline FORK. Periodically captures the whole world
## (WorldSaveController.capture_snapshot — a RAM dict, no disk) at a fixed SIM-time cadence into a BOUNDED ring
## that evicts its oldest entry (never unbounded, never touches disk). Reverse pauses the sim and restores
## progressively older snapshots to scrub back; resuming FORWARD from a scrubbed point truncates the newer
## snapshots — a fork, a divergent future from that moment (the abandoned future is dropped).
##
## Perf-first: capture is coarse (every CAPTURE_PERIOD sim-seconds) and gated on the field being ready; the
## ring is capped. DISABLED in the self-run harness (--run-frames/--smoke/--timeline-selftest) unless
## LA_SNAPSHOTS=1 opts it in as an inspection tool — so automated runs never stack snapshots.

const CAPTURE_PERIOD: float = 2.0     # sim-seconds between snapshots (the rewind resolution)
# Snapshots are actors-only by default (~100 KB each — the heavy GPU field is dropped, see WorldSaveController),
# so a deep ring is cheap: 30 × ~2s ≈ 60s of rewind history for a few MB. With LA_SNAPSHOT_FIELD=1 each snapshot
# balloons to several MB — lower this if you enable that.
const RING_CAP: int = 30
const REVERSE_STEP: float = 0.22      # wall-seconds between restoring successive older snapshots while reversing

signal timeline_changed(count: int, cursor: int, reversing: bool)
signal achievement(title: String, body: String)

# Escalating tongue-in-cheek "achievements" for the incorrigible time-meddler — fired the Nth time reverse is
# engaged this session. Pure flavour (no gameplay effect); the space/time continuum remains, regrettably, stable.
const REWIND_MILESTONES: Dictionary = {
	5:   ["⏪  Temporal Tourist", "You've rewound time 5 times. The universe is keeping count."],
	12:  ["⚠  Chrono-Meddler", "Rewinding to the past can destabilise the space/time continuum.\n(It hasn't. Yet.)"],
	25:  ["🌀  Paradox Enthusiast", "25 rewinds. Somewhere, a butterfly is filing a formal complaint."],
	50:  ["🕳  Timeline Frayed", "50 rewinds. At this point you're just showing off to the continuum."],
	100: ["♾  Lord of the Loop", "One hundred rewinds. Have you considered... moving forward?"],
}
var _rewind_count: int = 0

var _save: Node = null
var _enabled: bool = false
var _ring: Array = []                 # Array[Dictionary] snapshots, oldest first
var _since_capture: float = 0.0
var _reversing: bool = false
var _cursor: int = -1                 # -1 = live present; >=0 = viewing _ring[_cursor] (scrubbed)
var _reverse_accum: float = 0.0
var _restore_inflight: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # reverse must run while the sim is (soft-)paused


func setup(save_controller: Node) -> void:
	_save = save_controller
	_enabled = _resolve_enabled()


func is_enabled() -> bool:
	return _enabled


func is_reversing() -> bool:
	return _reversing


func snapshot_count() -> int:
	return _ring.size()


## Default ON for real play; OFF in the self-run harness so --run-frames never stacks snapshots. LA_SNAPSHOTS
## forces it either way (=0 off, anything else on) — the opt-in inspection hook for harness runs.
func _resolve_enabled() -> bool:
	if OS.has_environment("LA_SNAPSHOTS"):
		return OS.get_environment("LA_SNAPSHOTS") != "0"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--run-frames") or a == "--smoke" or a == "--timeline-selftest":
			return false
	return true


func _process(delta: float) -> void:
	if not _enabled or _save == null:
		return
	if _reversing:
		_tick_reverse(delta)
		return
	# Never capture mid-restore or while paused (the world is not advancing → no new sim-time).
	if (_save.has_method("is_restoring") and _save.is_restoring()) or get_tree().paused:
		return
	_since_capture += delta            # delta is already time-scaled, so cadence is even in SIM time
	if _since_capture >= CAPTURE_PERIOD:
		_since_capture = 0.0
		_capture()


func _capture() -> void:
	if not _save.has_method("capture_snapshot"):
		return
	var snap: Dictionary = _save.capture_snapshot()
	if snap.is_empty():
		return                          # field not ready yet — try again next cadence
	_ring.append(snap)
	while _ring.size() > RING_CAP:
		_ring.pop_front()
	var pop: int = (snap.get("creatures", []) as Array).size()
	print("TIMELINE_SNAP={count:%d, cap:%d, creatures:%d}" % [_ring.size(), RING_CAP, pop])
	timeline_changed.emit(_ring.size(), -1, false)


## Toggle scrubbing backward through history. Starting pauses the sim; stopping resumes FORWARD from the
## scrubbed point (forking — the newer snapshots are discarded).
func toggle_reverse() -> void:
	if _reversing:
		stop_reverse()
	else:
		start_reverse()


func start_reverse() -> void:
	if not _enabled or _ring.is_empty() or _reversing:
		return
	_reversing = true
	_cursor = _ring.size()             # first step lands on the most recent snapshot (size-1)
	_reverse_accum = REVERSE_STEP      # step immediately
	get_tree().paused = true
	_rewind_count += 1
	if REWIND_MILESTONES.has(_rewind_count):
		var m: Array = REWIND_MILESTONES[_rewind_count]
		achievement.emit(String(m[0]), String(m[1]))
	timeline_changed.emit(_ring.size(), _cursor, true)


## Resume forward from wherever we scrubbed to. If scrubbed into the past, truncate the ring there — the future
## beyond the cursor is abandoned; new play captures a fresh branch from this point (the fork).
func stop_reverse() -> void:
	if not _reversing:
		return
	_reversing = false
	if _cursor >= 0 and _cursor < _ring.size() - 1:
		_ring.resize(_cursor + 1)      # FORK: drop the abandoned newer future
	_cursor = -1
	_since_capture = 0.0
	get_tree().paused = false
	timeline_changed.emit(_ring.size(), -1, false)


func _tick_reverse(delta: float) -> void:
	# Wait out any restore still applying before stepping again.
	if _restore_inflight:
		if _save.has_method("is_restoring") and _save.is_restoring():
			return
		_restore_inflight = false
	_reverse_accum += delta
	if _reverse_accum < REVERSE_STEP:
		return
	_reverse_accum = 0.0
	if _cursor <= 0:
		return                          # reached the oldest snapshot — hold here (paused) until the player plays
	_cursor -= 1
	var target: Dictionary = _ring[_cursor]
	if _save.has_method("restore_snapshot"):
		_save.restore_snapshot(target)
		_restore_inflight = true
	timeline_changed.emit(_ring.size(), _cursor, true)
