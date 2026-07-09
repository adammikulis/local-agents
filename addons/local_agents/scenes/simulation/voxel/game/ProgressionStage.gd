class_name LAProgressionStage
extends Resource

## One rung of the campaign ladder — a pure data record (no per-stage logic). An objective is a single
## numeric read from the live telemetry snapshot (LASimReport.snapshot()) compared against a threshold,
## optionally required to hold for `hold_seconds`; completing it grants `unlocks` (capability ids) and, when
## `zoom_mult` is positive, raises the camera's orbit max-distance ceiling to that multiple of the planet
## radius. The whole ladder is a list of these records, so adding a stage is a new record, never a new branch.
##
## `metric` is a slash path into the snapshot dictionary, walked left to right:
##   "creatures"              -> snapshot["creatures"]            (a flat provider key)
##   "max_generation"         -> snapshot["max_generation"]
##   "phenomena_tracked"      -> snapshot["phenomena_tracked"]
##   "gauges/followers/max"   -> snapshot["gauges"]["followers"]["max"]  (a running-peak gauge)
## Anything missing resolves to 0.0, so an unwired metric simply never completes rather than erroring.
## (Explicit types only — no ':=' inferred typing.)

@export var id: String = ""
@export var title: String = ""
@export var metric: String = ""
@export var threshold: float = 0.0
## Seconds the metric must stay at/above the threshold before the stage completes (0 = the instant it crosses).
@export var hold_seconds: float = 0.0
## Capability ids granted on completion (e.g. "spawn_fox", "view_geosync", "view_solar").
@export var unlocks: PackedStringArray = PackedStringArray()
## When > 0, the orbit max-distance ceiling this stage raises the camera to (in planet radii). 0 = unchanged.
@export var zoom_mult: float = 0.0
