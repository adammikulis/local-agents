class_name LAEventDetector
extends RefCounted

## Base interface for one PHENOMENON DETECTOR plugin in LAEventTracker's ordered registry. Each detector
## reads the tracker's cheap per-sample snapshot (field aggregates + ecology tallies — NO new grid scan)
## and returns the discrete LAEvents that just crossed a threshold. Adding a phenomenon = drop a new
## detector into the registry, never patch a monolith (composable-plugins mandate).
##
## The contract is deliberately tiny: `detect(prev, cur, dt) -> Array[LAEvent]`. `prev`/`cur` are the two
## most recent snapshot Dictionaries (same keys), `dt` is the wall-clock seconds between them. A detector
## holds its OWN debounce/hysteresis state so one ongoing eruption is not re-emitted every sample.
## (Explicit types only — project rule: no ':=' inferred typing.)


## Return the events detected between the previous and current snapshot. Default: nothing.
func detect(_prev: Dictionary, _cur: Dictionary, _dt: float) -> Array:
	return []


## A short human-readable name for the phenomenon this detector watches — used by the tracker's startup
## log so a NOT-YET-TRACKED / dormant signal is surfaced, never silently skipped.
func phenomenon() -> String:
	return "unknown"


## True if the signal this detector reads is actually live in the current build (some field channels —
## bolts/charge/shock/magma — are stubbed to 0 on the sphere path). The tracker LOGS the dormant ones.
func signal_live(_cur: Dictionary) -> bool:
	return true
