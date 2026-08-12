class_name LAEvent
extends Resource


@export var type: String = ""

@export var position: Vector3 = Vector3.ZERO

@export var intensity: float = 0.0

@export var frame: int = 0

## Wall-clock seconds since engine start when detected (Time.get_ticks_msec() / 1000).
@export var time: float = 0.0

## One human sentence a consumer can narrate directly ("a volcano is erupting, lava is pouring out").
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
