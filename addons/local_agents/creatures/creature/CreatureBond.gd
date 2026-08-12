class_name LACreatureBond
extends RefCounted


var tameness: float = 0.0
# The standing player command this creature obeys while bonded: "" (free) | "come" | "stay" | "follow".
var command_name: String = ""
var _target: Vector3 = Vector3.ZERO
var _has_target: bool = false

const BOND_THRESHOLD: float = 0.5     # tameness at/above this = bonded (accepts + obeys commands)
const DECAY: float = 0.006            # tameness lost per second with no attention (slow — a pet stays tame a while)
const MAX_TAMENESS: float = 1.0


func setup(_creature, config: Dictionary) -> void:
	tameness = clampf(float(config.get("tameness", 0.0)), 0.0, MAX_TAMENESS)


func tick(_creature, delta: float) -> void:
	if tameness > 0.0:
		tameness = maxf(0.0, tameness - DECAY * delta)
	if command_name != "" and not is_bonded():
		command_name = ""


## A friendly interaction (feeding/petting, or calm proximity to the hand) warms the creature to the player.
func befriend(amount: float) -> void:
	if amount <= 0.0:
		return
	tameness = clampf(tameness + amount, 0.0, MAX_TAMENESS)


## Is this creature tamed enough to accept + obey a player command?
func is_bonded() -> bool:
	return tameness >= BOND_THRESHOLD


## Set (or clear with "") the standing command. Ignored on a creature that isn't bonded.
func set_command(cmd: String) -> void:
	if not is_bonded():
		command_name = ""
		return
	command_name = cmd


## Is a player command actively pre-empting this creature's autonomy right now?
func is_commanded() -> bool:
	return command_name != "" and is_bonded()


func command() -> String:
	return command_name


## Update the player beacon (the point come/follow steers toward).
func set_target(p: Vector3) -> void:
	_target = p
	_has_target = true


func has_target() -> bool:
	return _has_target


func target() -> Vector3:
	return _target
