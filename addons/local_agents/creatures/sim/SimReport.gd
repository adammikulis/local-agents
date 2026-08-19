class_name LASimReport
extends RefCounted


static var _events: Dictionary = {}       # tally: key -> count (bare kind + per-tag breakdowns)
static var _gauges: Dictionary = {}       # name -> {"cur","min","max"}
static var _providers: Array = []         # registered Callables: func() -> Dictionary


static func reset(drop_providers: bool = false) -> void:
	_events = {}
	_gauges = {}
	if drop_providers:
		_providers = []


## Record that something happened. Bumps the bare `kind` plus `kind/<value>` for each tag value — e.g.
## event("death", {"cause": "drowned", "species": "rabbit"}) → death, death/drowned, death/rabbit.
static func event(kind: String, tags: Dictionary = {}) -> void:
	_events[kind] = int(_events.get(kind, 0)) + 1
	for k in tags:
		var key: String = kind + "/" + str(tags[k])
		_events[key] = int(_events.get(key, 0)) + 1


## Record a current metric value; tracks cur + running min/max so peaks come for free (no hand-written
## _peak_*). Writes a fresh dict rather than mutating the stored one in place, so a snapshot() caller
## holding the old dict never sees a value change out from under it.
static func gauge(name: String, value: float) -> void:
	var prev: Dictionary = _gauges.get(name, {})
	_gauges[name] = {
		"cur": value,
		"min": minf(float(prev.get("min", value)), value),
		"max": maxf(float(prev.get("max", value)), value),
	}


## Current value of a gauge (or `default_val` if not recorded yet) — a cheap single-key read for live HUD
## readouts, without the snapshot() dictionary duplication.
static func gauge_cur(name: String, default_val: float = 0.0) -> float:
	var g: Dictionary = _gauges.get(name, {})
	return float(g.get("cur", default_val))


static func register(provider: Callable) -> void:
	if not _providers.has(provider):
		_providers.append(provider)


## Read-only view of the current telemetry. `events`/`gauges` are shallow top-level copies — cheap, since
## `gauge()` never mutates a stored entry in place — marked read-only so a caller cannot corrupt the live
## tallies through the handed-out dict.
static func snapshot() -> Dictionary:
	var events_view: Dictionary = _events.duplicate()
	var gauges_view: Dictionary = _gauges.duplicate()
	events_view.make_read_only()
	gauges_view.make_read_only()
	var out: Dictionary = {"events": events_view, "gauges": gauges_view}
	var dead: Array = []
	for p in _providers:
		if p is Callable and p.is_valid():
			var d = p.call()
			if d is Dictionary:
				for k in d:
					out[k] = d[k]
		else:
			dead.append(p)          # provider's node was freed → drop it so _providers doesn't accrete dead refs
	for p in dead:
		_providers.erase(p)
	return out


## Emit the snapshot as one line the harness/tools scrape.
static func emit() -> void:
	print("SIM_REPORT=", JSON.stringify(snapshot()))
