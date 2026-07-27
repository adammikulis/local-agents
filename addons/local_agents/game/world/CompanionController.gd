class_name LACompanionController
extends Node

## LACompanionController — routes the player's standing COMPANION command (come / stay / follow) to every
## bonded creature and keeps the player "beacon" (the hand point on the terrain that come/follow home to)
## current on each of them. Self-ticks; thin. Taming itself is the per-creature bond (LACreatureBond) —
## this only broadcasts the command + the beacon, and lightly befriends creatures that linger calmly at the
## player's hand (emergent "calm proximity" taming). VoxelInteraction routes the tame/command keys here; the
## composition root wires it with one add_child. Dependency-free of LAVoxelWorld (dynamic access, no cyclic
## class reference). (Explicit types only — project rule: no ':=' inferred typing.)

var _camera: Camera3D = null
var _terrain = null                       # LAVoxelTerrainService (raycast_terrain for the hand point)
var _hud: CanvasLayer = null              # LASpawnPaletteHud (status line)
var _command: String = ""                 # current standing command applied to all bonded pets ("" = free)
var _beacon: Vector3 = Vector3(INF, INF, INF)   # last valid hand point on the terrain (the come/follow target)

const PROXIMITY_RADIUS: float = 6.0       # a wild creature this close to the hand, calm, slowly warms to the player
const PROXIMITY_GAIN: float = 0.05        # tameness earned per second of calm proximity to the hand
const TICK_STRIDE: int = 6                # command/beacon refresh cadence (~10 Hz) — commands don't need 60 Hz
var _frame: int = 0
var _acc: float = 0.0


func setup(camera: Camera3D, terrain, hud: CanvasLayer) -> void:
	_camera = camera
	_terrain = terrain
	_hud = hud


## Broadcast a standing command (come/stay/follow, or "" to free) to every bonded creature. Returns the count
## commanded. Called by the tame/command input path (VoxelInteraction).
func command(cmd: String) -> int:
	_command = cmd
	var n: int = 0
	for c in get_tree().get_nodes_in_group("creature"):
		if _bondable(c) and c.bond.is_bonded():
			c.bond.set_command(cmd)
			n += 1
	if _hud != null and _hud.has_method("set_status"):
		if cmd == "":
			_hud.set_status("Companions freed (%d)." % n)
		elif n == 0:
			_hud.set_status("No companions yet — feed a creature (B) to tame it first.")
		else:
			_hud.set_status("Commanded %d companion(s): %s." % [n, cmd])
	return n


## A deliberate friendly interaction (the player fed/petted `creature`): raise its bond, and if it crosses into
## being bonded, immediately adopt the current standing command so a freshly-tamed pet obeys at once.
func befriend(creature, amount: float) -> void:
	if not _bondable(creature):
		return
	creature.bond.befriend(amount)
	if creature.bond.is_bonded():
		creature.bond.set_command(_command)
		if not is_inf(_beacon.x):
			creature.bond.set_target(_beacon)
	if _hud != null and _hud.has_method("set_status"):
		var sp: String = String(creature.get("species")) if "species" in creature else "creature"
		if creature.bond.is_bonded():
			_hud.set_status("The %s is your companion (bond %d%%)." % [sp, int(creature.bond.tameness * 100.0)])
		else:
			_hud.set_status("The %s warms to you (bond %d%%)." % [sp, int(creature.bond.tameness * 100.0)])


## The current standing command (for UI / debug).
func active_command() -> String:
	return _command


func _physics_process(delta: float) -> void:
	_acc += delta
	_frame += 1
	if not LALodStride.should_run(_frame, 0, TICK_STRIDE):
		return
	var dt: float = _acc
	_acc = 0.0
	_beacon = _hand_point()
	if is_inf(_beacon.x):
		return
	for c in get_tree().get_nodes_in_group("creature"):
		if not _bondable(c):
			continue
		var b = c.bond
		if b.is_bonded():
			b.set_target(_beacon)                     # keep the come/follow beacon current on each pet
			continue
		# Calm proximity: a wild creature lingering near the player's hand slowly earns trust (emergent taming
		# with no keypress). Cheap distance test; only the few near the hand ever accrue anything.
		var d: float = (c as Node3D).global_position.distance_to(_beacon)
		if d <= PROXIMITY_RADIUS:
			b.befriend(PROXIMITY_GAIN * dt)
			if b.is_bonded():
				b.set_command(_command)
				b.set_target(_beacon)


## The player's "hand" point on the terrain — where the camera aims — used as the come/follow beacon. INF when
## the aim misses the planet.
func _hand_point() -> Vector3:
	if _camera == null or _terrain == null or not _camera.has_method("aim_ray") or not _terrain.has_method("raycast_terrain"):
		return Vector3(INF, INF, INF)
	var ray: Dictionary = _camera.aim_ray()
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 3000.0)
	if not bool(hit.get("hit", false)):
		return Vector3(INF, INF, INF)
	return hit["position"]


func _bondable(c) -> bool:
	return c is Node3D and is_instance_valid(c) and "bond" in c and c.bond != null
