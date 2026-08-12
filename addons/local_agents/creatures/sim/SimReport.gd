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


## Record a current metric value; tracks cur + running min/max so peaks come for free (no hand-written _peak_*).
static func gauge(name: String, value: float) -> void:
	var g: Dictionary = _gauges.get(name, {"cur": value, "min": value, "max": value})
	g["cur"] = value
	g["min"] = minf(float(g["min"]), value)
	g["max"] = maxf(float(g["max"]), value)
	_gauges[name] = g


## Current value of a gauge (or `default_val` if not recorded yet) — a cheap single-key read for live HUD
## readouts, without the snapshot() dictionary duplication.
static func gauge_cur(name: String, default_val: float = 0.0) -> float:
	var g: Dictionary = _gauges.get(name, {})
	return float(g.get("cur", default_val))


static func register(provider: Callable) -> void:
	if not _providers.has(provider):
		_providers.append(provider)


static func snapshot() -> Dictionary:
	var out: Dictionary = {"events": _events.duplicate(true), "gauges": _gauges.duplicate(true)}
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
