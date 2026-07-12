class_name LASimRng
extends RefCounted

## The ONE seeded random source for deterministic simulation stochastics — heredity (DNA crossover /
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
## (Explicit types only — project rule: no ':=' inferred typing.)

# A fixed default so an unconfigured run is still deterministic (same sequence every launch) rather than
# time-randomized. Override per world via set_seed()/setup(), or globally via the LA_SIM_SEED env var.
const DEFAULT_SEED: int = 1469598103934665603

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = DEFAULT_SEED


## Seed the generator (alias of set_seed, kept for the setup(seed) convention other services use).
func setup(seed: int) -> void:
	set_seed(seed)


## Reseed and reset the stream to the start of that seed's sequence.
func set_seed(seed: int) -> void:
	_rng.seed = seed


## Uniform float in [0, 1).
func randf() -> float:
	return _rng.randf()


## Uniform float in [a, b].
func randf_range(a: float, b: float) -> float:
	return _rng.randf_range(a, b)


## Uniform integer in [a, b] inclusive.
func randi_range(a: int, b: int) -> int:
	return _rng.randi_range(a, b)


## Uniform 32-bit unsigned-ish integer (matches Godot's global randi(); use for `randi() % n` replacements).
func randi() -> int:
	return _rng.randi()


## Normally-distributed float (mean, deviation) — the seeded counterpart of Godot's global randfn().
func randfn(mean: float = 0.0, deviation: float = 1.0) -> float:
	return _rng.randfn(mean, deviation)


## A random unit-ish direction vector, each component in [-1, 1) (seeded replacement for the common
## `Vector3(randf()*2-1, ...)` idiom used to pick a direction on the sphere).
func rand_dir() -> Vector3:
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
		if OS.has_environment("LA_SIM_SEED"):
			_shared.set_seed(int(OS.get_environment("LA_SIM_SEED")))
	return _shared


## Install an explicitly-constructed generator as the shared one (tests / a chosen world seed).
static func install(rng: LASimRng) -> void:
	_shared = rng


## Reseed the shared generator to a fresh sequence (call once at world setup for a chosen world seed).
static func reset(seed: int) -> void:
	shared().set_seed(seed)
