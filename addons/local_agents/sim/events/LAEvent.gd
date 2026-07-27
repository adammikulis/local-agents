class_name LAEvent
extends Resource

## One discrete PHENOMENON EVENT emitted by LAEventTracker — a typed record that something crossed a
## threshold in the shared field/substrate ("eruption", "wildfire", "flood", "storm", "lightning",
## "impact", "death", "birth", "extinction", a behaviour spike). It is derived purely from field/ecology
## state, never authored by a scripted disaster actor. The streamer commentary, SIM_REPORT telemetry, and
## (later) the dissolved disaster actors' visuals all consume THESE instead of scanning the world
## themselves — one emergent source, many consumers.
##
## Typed Resource rather than a loose Dictionary so consumers get a stable, self-documenting shape.
## (Explicit types only — project rule: no ':=' inferred typing.)

## Phenomenon kind, e.g. "eruption", "wildfire", "flood", "storm", "lightning", "impact", "death",
## "birth", "extinction", "stampede", "chase", "stalk", "circle". Detectors own their own type strings.
@export var type: String = ""

## World locus of the event. Field aggregates are SCALAR reductions (a total/peak/count over the grid),
## so most events carry a GLOBAL locus (Vector3.ZERO) until the field exposes cheap per-phenomenon peak
## cells — see LAEventTracker's TODO. Detectors that already have a cheap locus may fill this.
@export var position: Vector3 = Vector3.ZERO

## Rough "how big a deal" weight on the streamer's scale (threshold ~6, a disaster ~12). Scales with the
## magnitude of what actually happened (a bigger lava surge / more deaths → higher intensity).
@export var intensity: float = 0.0

## Physics-frame the event was detected on (Engine.get_physics_frames()).
@export var frame: int = 0

## Wall-clock seconds since engine start when detected (Time.get_ticks_msec() / 1000).
@export var time: float = 0.0

## One human sentence a consumer can narrate directly ("a volcano is erupting — lava is pouring out").
@export var description: String = ""


## Build a fully-populated event in one call (frame/time stamped by the tracker at emit).
static func make(p_type: String, p_intensity: float, p_description: String, p_position: Vector3 = Vector3.ZERO) -> LAEvent:
	var e: LAEvent = LAEvent.new()
	e.type = p_type
	e.intensity = p_intensity
	e.description = p_description
	e.position = p_position
	return e


func as_dict() -> Dictionary:
	return {
		"type": type, "intensity": intensity, "frame": frame, "time": time,
		"position": [position.x, position.y, position.z], "description": description,
	}
