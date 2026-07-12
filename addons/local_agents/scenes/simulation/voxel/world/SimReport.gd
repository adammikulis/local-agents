class_name LASimReport
extends RefCounted

## Central sim telemetry — the ONE place everything reports to, replacing scattered one-off tallies (a static
## death dict on Creature, HERD_DEBUG/BREATH_DBG prints, …) and the brittle hand-synced SMOKE_SUMMARY string.
##
## Three ways in, one way out:
##   • event(kind, tags)  — record that something HAPPENED (a death, birth, ignition, bolt). Auto-tallies the
##                          bare kind AND a per-tag breakdown, so "how many rabbits drowned" is free.
##   • gauge(name, value) — record a current metric; tracks running min/max (free peak tracking).
##   • register(provider) — a subsystem hands over a `func() -> Dictionary` of its aggregates, polled only
##                          when a snapshot is taken (so heavy grid scans don't run per frame).
##   snapshot()/emit()    — merge it all into one structured dict; emit() prints `SIM_REPORT={…}`.
##
## All STATIC so any node reports without needing a reference. A live HUD / the streamer can read snapshot()
## too — one source of truth for headless smoke, on-screen debug, and commentary. (Explicit types only.)

static var _events: Dictionary = {}       # tally: key -> count (bare kind + per-tag breakdowns)
static var _gauges: Dictionary = {}       # name -> {"cur","min","max"}
static var _providers: Array = []         # registered Callables: func() -> Dictionary


## Clear per-run telemetry — call once at world setup (a fresh headless process starts empty already; this
## matters on in-editor scene reloads). Keeps registered providers unless drop_providers.
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


## Register a subsystem aggregate provider — a Callable returning a Dictionary merged into snapshot(). No-op
## if already registered (safe to call from _ready).
static func register(provider: Callable) -> void:
	if not _providers.has(provider):
		_providers.append(provider)


## One structured snapshot: {events, gauges} plus each provider's dict merged in. Providers are polled HERE,
## not per frame, so their (possibly heavy) scans only run when a snapshot is actually taken.
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


## Emit the snapshot as one line the harness/tools scrape. Replaces the hand-synced SMOKE_SUMMARY string.
static func emit() -> void:
	print("SIM_REPORT=", JSON.stringify(snapshot()))
