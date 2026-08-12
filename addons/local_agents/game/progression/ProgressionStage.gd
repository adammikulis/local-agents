class_name LAProgressionStage
extends Resource


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
