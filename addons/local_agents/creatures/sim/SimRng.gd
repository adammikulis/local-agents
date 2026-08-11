class_name LASimRng
extends RefCounted

## The ONE seeded random source for deterministic simulation stochastics: heredity (DNA crossover /
## mutation), and the coming evolution/affinity work. Wrapping a single RandomNumberGenerator behind a
## shared locator means a whole run reproduces bit-for-bit from its seed: no scattered bare `randf()`
## calls (which draw from Godot's global, un-seeded generator and make runs irreproducible). Any code
## that must be deterministic draws through the injected instance instead.
##
## IDIOM: like LASimReport / LAAblate, a static locator (`shared()`) hands the one instance to callers
## that can't be threaded a reference (the DNA statics, breeding). The instance itself is ordinary and
## can be created/installed/reseeded explicitly for tests or a chosen world seed. `snapshot()`/`restore()`
## capture the exact stream position so a save resumes the same sequence.
##
## Reproducible-run knob: set env `LA_SIM_SEED=<int>` to seed the shared generator on first use.
## (Explicit types only, no ':=' inferred typing.)

# A fixed default so an unconfigured run is still deterministic (same sequence every launch) rather than
# time-randomized. Override per world via set_seed()/setup(), or globally via the LA_SIM_SEED env var.
const DEFAULT_SEED: int = 1469598103934665603

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# DIVERGENCE PROBE (LA_RNG_TRACE=1). `draws` counts every draw through this generator, so two runs can be
# diffed to find the FIRST frame their stream positions differ. That names the subsystem drawing a
# frame-count-dependent number of times instead of leaving it to be guessed at — the guesses cost a session.
# Zero cost when the env var is absent: one static bool read per draw.
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


## Per-tag draw counts captured so far (LA_RNG_TRACE only). Diff two runs' dictionaries to find the
## subsystem whose count differs — that is the one perturbing everyone else's stream position.
func trace_report() -> Dictionary:
	return {"draws": draws, "tags": _tags.duplicate()}


## Seed the generator (alias of set_seed, kept for the setup(seed) convention other services use).
func setup(seed: int) -> void:
	set_seed(seed)


## Reseed and reset the stream to the start of that seed's sequence.
func set_seed(seed: int) -> void:
	_rng.seed = seed
	draws = 0
	_tags.clear()


## Uniform float in [0, 1).
func randf() -> float:
	_count()
	return _rng.randf()


## Uniform float in [a, b].
func randf_range(a: float, b: float) -> float:
	_count()
	return _rng.randf_range(a, b)


## Uniform integer in [a, b] inclusive.
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


## A random unit-ish direction vector, each component in [-1, 1) (seeded replacement for the common
## `Vector3(randf()*2-1, ...)` idiom used to pick a direction on the sphere).
func rand_dir() -> Vector3:
	_count()
	return Vector3(_rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0, _rng.randf() * 2.0 - 1.0)


## Capture the exact stream position (seed + internal state) so restore() resumes the identical sequence.
func snapshot() -> Dictionary:
	return {"seed": int(_rng.seed), "state": int(_rng.state)}


## Restore a captured stream position. Seed is applied first (it resets state), then the saved state is
## re-applied so the very next draw matches the moment the snapshot was taken.
func restore(d: Dictionary) -> void:
	if d == null or d.is_empty():
		return
	_rng.seed = int(d.get("seed", DEFAULT_SEED))
	_rng.state = int(d.get("state", _rng.state))


# --- SHARED LOCATOR -----------------------------------------------------------------------------------------

static var _shared: LASimRng = null


## The one shared generator. Lazily created on first use, seeded from LA_SIM_SEED when present so a run is
## reproducible without any wiring; otherwise it carries DEFAULT_SEED. Callers that can't be handed a
## reference (LADNA statics, breeding) draw through this.
static func shared() -> LASimRng:
	if _shared == null:
		_shared = LASimRng.new()
		if OS.get_environment("LA_SIM_SEED") != "":
			_shared.set_seed(int(OS.get_environment("LA_SIM_SEED")))
	return _shared


## Install an explicitly-constructed generator as the shared one (tests / a chosen world seed).
static func install(rng: LASimRng) -> void:
	_shared = rng


## Reseed the shared generator to a fresh sequence (call once at world setup for a chosen world seed).
static func reset(seed: int) -> void:
	shared().set_seed(seed)
	_world_seed = seed
	for k in _domains:
		(_domains[k] as LASimRng).set_seed(derive(seed, String(k)))


# --- PER-DOMAIN STREAMS ---------------------------------------------------------------------------------
#
# THE PLANET MUST NOT SHARE A STREAM WITH THE CREATURES. One shared generator makes every consumer's draw
# VALUES depend on how many times every OTHER consumer has drawn, so a subsystem that is itself perfectly
# seeded still diverges when something unrelated upstream draws a different number of times.
#
# Measured 2026-08-03, two runs at --seed=4242, 400 frames, via LA_RNG_TRACE. LAPlateTectonics drew exactly
# 48 `_rand_unit` values in BOTH runs — it ticked identically — yet `_fire_boundary_event` fired 1 time in
# one run and 3 in the other. Its tick count was deterministic; the VALUES it read were not, because
# `DNA.gd:mutate` (1057 vs 678) and `Cognition.gd:observe` (713 vs 732) had moved the shared cursor first.
#
# And the root of THAT is real time: a cognition escalation holds its slot until the model's answer ARRIVES,
# so how fast the LLM replied decides how many draws creature code makes this frame. Sharing one stream
# therefore made the geology depend on inference latency. Seeding harder cannot fix it — only separation can.
#
# Each domain gets an independent generator whose seed is derived from the world seed and the domain NAME, so
# domains stay reproducible individually and cannot perturb one another however many times any of them draws.
static var _world_seed: int = DEFAULT_SEED
static var _domains: Dictionary = {}


# FNV-1a over the domain name, mixed with the world seed. Deterministic across runs and platforms (no
# String.hash(), whose value is not guaranteed stable), and well-separated for short names.
static func derive(seed: int, domain: String) -> int:
	var h: int = 1469598103934665603
	for i in domain.length():
		h = (h ^ domain.unicode_at(i)) * 1099511628211
		h = h & 0x7FFFFFFFFFFFFFFF          # keep it positive; RandomNumberGenerator takes any int
	return (seed ^ h) & 0x7FFFFFFFFFFFFFFF


## An INDEPENDENT stream OWNED BY ITS CALLER, seeded from that caller's own world seed and a domain name.
## Nothing static is touched, so two worlds in one process cannot share or perturb each other's stream. This
## is the form to use wherever the drawing object knows which world it belongs to; `for_domain()` below is
## the process-wide fallback for callers that still have no world reference.
static func make(world_seed: int, domain: String) -> LASimRng:
	var r: LASimRng = LASimRng.new()
	r.set_seed(derive(world_seed, domain))
	return r


## An INDEPENDENT seeded stream for one simulation domain — "planet", "creatures", "weather", … Use this for
## anything whose reproducibility must not depend on unrelated subsystems' draw counts. Planet-side callers
## (tectonics, the ambient disaster director, field injection) should draw from `for_domain("planet")` rather
## than `shared()`, so the world's geology reproduces regardless of what the creatures or the LLM did.
static func for_domain(domain: String) -> LASimRng:
	if not _domains.has(domain):
		var r: LASimRng = LASimRng.new()
		r.set_seed(derive(_world_seed, domain))
		_domains[domain] = r
	return _domains[domain]


## Per-domain trace snapshot (LA_RNG_TRACE), so a divergence hunt can see each stream separately.
static func domain_trace() -> Dictionary:
	var out: Dictionary = {}
	for k in _domains:
		out[k] = (_domains[k] as LASimRng).draws
	return out
