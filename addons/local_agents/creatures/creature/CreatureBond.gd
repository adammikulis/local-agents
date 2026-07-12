class_name LACreatureBond
extends RefCounted

## LACreatureBond — the per-creature TAMENESS / COMPANION state, owned as an instance on each creature
## (`creature.bond`) so all of it lives HERE, off the Creature monolith (imitating the `disease` seam).
## A wild creature starts at zero tameness. Repeated FRIENDLY interaction — being fed/petted, or lingering
## calm at the player's hand — raises it (befriend()); with no attention it decays slowly back toward wild.
## Once tameness crosses the bond threshold the creature is BONDED: it will accept a standing player command
## (come / stay / follow) which its decision cascade obeys, pre-empting its autonomous drive. An unbonded (or
## lapsed) creature carries no command and behaves exactly as before, so the sim is unchanged until a creature
## is actually tamed. State lives here; the command STEERING lives in LACreatureThink.execute_action, and the
## command/beacon are broadcast by LACompanionController. (Explicit types only — project rule: no ':='.)

# How strong the bond is, 0 (wild) .. 1 (devoted). Rises with friendly interaction, decays slowly otherwise.
var tameness: float = 0.0
# The standing player command this creature obeys while bonded: "" (free) | "come" | "stay" | "follow".
var command_name: String = ""
# The player "beacon" the come/follow steering homes to (the hand point on the terrain). Kept current by
# LACompanionController each tick while bonded; `_has_target` guards it until the first push.
var _target: Vector3 = Vector3.ZERO
var _has_target: bool = false

const BOND_THRESHOLD: float = 0.5     # tameness at/above this = bonded (accepts + obeys commands)
const DECAY: float = 0.006            # tameness lost per second with no attention (slow — a pet stays tame a while)
const MAX_TAMENESS: float = 1.0


## Initialise from the creature's expressed config. A species (or an individual) may be born partly trusting
## via a `tameness` gene (default 0 = fully wild); everything above that is earned by interaction.
func setup(_creature, config: Dictionary) -> void:
	tameness = clampf(float(config.get("tameness", 0.0)), 0.0, MAX_TAMENESS)


## Per-frame upkeep: tameness decays slowly toward wild, and a bond that has lapsed below the threshold drops
## its command so the creature returns to full autonomy. Cheap; runs every frame from Creature._physics_process.
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
