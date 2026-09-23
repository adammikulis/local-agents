class_name LALightningStrike
extends Node3D


const LINGER: float = 0.7                 # seconds of afterglow before free

## The discharge met the ground at `point`.
signal struck(point: Vector3)

var _age: float = 0.0


## Strike the ground at `point`. No physics: that emerges in the field.
func strike(point: Vector3) -> void:
	global_position = point
	struck.emit(point)


## The share of the afterglow still to run: 1 at the strike, 0 as the node is freed.
func remaining() -> float:
	return maxf(0.0, 1.0 - _age / LINGER)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LINGER:
		queue_free()
