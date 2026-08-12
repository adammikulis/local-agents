class_name LASimRng
extends RefCounted


const DEFAULT_SEED: int = 1469598103934665603

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

static var trace_enabled: bool = OS.get_environment("LA_RNG_TRACE") != ""
var draws: int = 0
var _tags: Dictionary = {}          # caller tag -> draw count, only populated under LA_RNG_TRACE


func _init() -> void:
	_rng.seed = DEFAULT_SEED


func _count() -> void:
	draws += 1
	if trace_enabled:
		# Attribute the draw to its immediate caller, so the report says WHICH subsystem drifted.
		var st: Array = get_stack()
		if st.size() > 2:
			var f: Dictionary = st[2]
			var tag: String = "%s:%s" % [String(f.get("source", "?")).get_file(), f.get("function", "?")]
			_tags[tag] = int(_tags.get(tag, 0)) + 1


func trace_report() -> Dictionary:
	return {"draws": draws, "tags": _tags.duplicate()}


func setup(seed: int) -> void:
	set_seed(seed)


## Reseed and reset the stream to the start of that seed's sequence.
func set_seed(seed: int) -> void:
	_rng.seed = seed
	draws = 0
	_tags.clear()


func randf() -> float:
	_count()
	return _rng.randf()


func randf_range(a: float, b: float) -> float:
	_count()
	return _rng.randf_range(a, b)


func randi_range(a: int, b: int) -> int:
	_count()
	return _rng.randi_range(a, b)


## Uniform 32-bit unsigned-ish integer (matches Godot's global randi(); use for `randi() % n` replacements).
func randi() -> int:
	_count()
	return _rng.randi()


## Normally-distributed float (mean, deviation) — the seeded counterpart of Godot's global randfn().
func randfn(mean: float = 0.0, deviation: float = 1.0) -> float:
	_count()
	return _rng.randfn(mean, deviation)


func rand_dir() -> Vector3:
	_count()
	return Vector3(_rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0)


## Capture the exact stream position (seed + internal state) so restore() resumes the identical sequence.
func snapshot() -> Dictionary:
	return {"seed": int(_rng.seed), "state": int(_rng.state)}


func restore(d: Dictionary) -> void:
	if d == null or d.is_empty():
		return
	_rng.seed = int(d.get("seed", DEFAULT_SEED))
	_rng.state = int(d.get("state", _rng.state))


static var _shared: LASimRng = null


static func shared() -> LASimRng:
	if _shared == null:
		_shared = LASimRng.new()
		if OS.get_environment("LA_SIM_SEED") != "":
			_shared.set_seed(int(OS.get_environment("LA_SIM_SEED")))
	return _shared


static func install(rng: LASimRng) -> void:
	_shared = rng


## Reseed the shared generator to a fresh sequence (call once at world setup for a chosen world seed).
static func reset(seed: int) -> void:
	shared().set_seed(seed)
	_world_seed = seed
	for k in _domains:
		(_domains[k] as LASimRng).set_seed(derive(seed, String(k)))


# Per-domain streams.
static var _world_seed: int = DEFAULT_SEED
static var _domains: Dictionary = {}


# FNV-1a over the domain name, mixed with the world seed.
static func derive(seed: int, domain: String) -> int:
	var h: int = 1469598103934665603
	for i in domain.length():
		h = (h ^ domain.unicode_at(i)) * 1099511628211
		h = h & 0x7FFFFFFFFFFFFFFF          # keep it positive; RandomNumberGenerator takes any int
	return (seed ^ h) & 0x7FFFFFFFFFFFFFFF


## A stream owned by ONE world: seeded from that world's seed and a domain name, touching nothing static.
static func make(world_seed: int, domain: String) -> LASimRng:
	var r: LASimRng = LASimRng.new()
	r.set_seed(derive(world_seed, domain))
	return r


## A process-wide stream for one domain.
static func for_domain(domain: String) -> LASimRng:
	if not _domains.has(domain):
		var r: LASimRng = LASimRng.new()
		r.set_seed(derive(_world_seed, domain))
		_domains[domain] = r
	return _domains[domain]


## Per-domain trace snapshot (LA_RNG_TRACE): draw count AND the per-caller breakdown, per stream.
static func domain_trace() -> Dictionary:
	var out: Dictionary = {}
	for k in _domains:
		out[k] = (_domains[k] as LASimRng).trace_report()
	return out
