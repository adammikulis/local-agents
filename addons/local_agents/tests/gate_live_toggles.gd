extends SceneTree

## ONE REGISTRY, ONE SWITCH. A process the rung contains switches off and on mid-run; a body released
## from a co-rotating point then coasts along the tangent it was released on, at the speed it was
## released with, until the switch comes back. A process the rung LACKS is refused.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const N: int = 32
const CELL: float = 10.0
const BODY_R: float = 6.371e6            # m
const BODY_M: float = 5.972e24           # kg
const DROP_H: float = 200.0              # m above the floor
const DT: float = 0.01                   # s
const STEPS: int = 200                   # per leg
const TANGENT_V: float = 10.0            # m/s, the ground's own speed at the release point
const REL: float = 1.0e-3
## The scheduled switch this probe is handed, in LA_ABLATE.
const SCHEDULED: String = "gravity@2"
const FLUX_PASS: String = "res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd"
const GRAVITY_PASS: String = "res://addons/local_agents/sim/material/sphere_passes/GravityPass.gd"

var _fail: int = 0


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


func _boxes_of(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is CheckButton or child is OptionButton:
			out.append(child)
		_boxes_of(child, out)


func _run(steps: int) -> void:
	for i in range(steps):
		LABallistics.step(DT)


func _init() -> void:
	QuietWindow.apply_if_automated()
	LAProcessSet.declare(LAProcessSet.GRAVITY)

	# --- the switch list is the rung's own processes ------------------------------------------------
	var names: PackedStringArray = LAProcessSet.process_names()
	if not names.has("gravity"):
		_say("A rung-1 world lists no \"gravity\" switch: %s" % ", ".join(names))
	if names.has("mom_flux"):
		_say("A rung-1 world offers a switch for the momentum row it does not contain.")
	if not LAProcessSet.process_names(LAProcessSet.ACOUSTIC).has("mom_flux"):
		_say("The acoustic rung's momentum row has no switch, so a transport row cannot be switched.")

	# --- the panel draws that list and nothing else -------------------------------------------------
	var panel: LASwitchPanel = LASwitchPanel.new()
	panel.build()
	var boxes: Array = []
	_boxes_of(panel, boxes)
	var want: PackedStringArray = LAAblate.names()
	if boxes.size() != want.size():
		_say("The panel drew %d switches for %d names." % [boxes.size(), want.size()])
	for name in want:
		if panel.control_of(name) == null:
			_say("The panel drew no switch for \"%s\"." % name)

	# --- a stand-in is a THREE-position switch, off / fake / real ------------------------------------
	for r in LAFakes.RECORDS:
		var fake_name: String = String(r["name"])
		var opt: OptionButton = panel.control_of(fake_name) as OptionButton
		if opt == null:
			_say("The stand-in \"%s\" has no three-position control." % fake_name)
		elif opt.item_count != 3:
			_say("The \"%s\" control offers %d states, not three." % [fake_name, opt.item_count])
	panel.free()

	# --- and each of the three reaches the seam ------------------------------------------------------
	var mark: String = String(LAFakes.RECORDS[0]["name"])
	LAAblate.set_state(mark, LAAblate.state_fake())
	if not LAFakes.stands_in(mark) or LAFakes.draw(mark, 1.0) != 1.0:
		_say("\"%s\" switched to fake hands nothing out." % mark)
	for state in [LAAblate.state_off(), LAAblate.state_real()]:
		LAAblate.set_state(mark, state)
		if LAFakes.stands_in(mark) or LAFakes.draw(mark, 1.0) != 0.0:
			_say("\"%s\" switched to %s still hands out the stand-in's own supply." % [mark, state])
	LAAblate.set_state(mark, LAAblate.default_state(mark))
	LAFakes.reset()

	# --- a process the rung lacks has no switch -----------------------------------------------------
	if LAProcessSet.set_live("mom_flux", false):
		_say("A rung-1 world accepted a switch for the momentum row it does not contain.")
	LAAblate.set_on("mom_flux", false)
	if LAProcessSet.live_mask().has("mom_flux"):
		_say("The mask carries an entry for a process this world does not contain.")

	# --- `--ablate=name@step` lands on the SIM CLOCK, not before it ---------------------------------
	if OS.get_environment("LA_ABLATE") != SCHEDULED:
		_say("This probe is run with LA_ABLATE=%s; it was handed \"%s\"."
			% [SCHEDULED, OS.get_environment("LA_ABLATE")])
	for step in [0, 1]:
		LAAblate.apply_schedule(step)
		if not bool(LAProcessSet.live_mask().get("gravity", false)):
			_say("A switch scheduled for step 2 was thrown at step %d." % step)
	LAAblate.apply_schedule(2)
	if bool(LAProcessSet.live_mask().get("gravity", true)):
		_say("A switch scheduled for step 2 was not thrown at step 2.")
	LAAblate.set_on("gravity", true)

	# --- a free body under the switch ---------------------------------------------------------------
	var grid = LAVoxelGrid.new()
	grid.build(N, N, N, CELL, Vector3(-0.5 * N * CELL, -5.0 * CELL, -0.5 * N * CELL))
	var centre: Vector3 = Vector3(0.0, -BODY_R, 0.0)
	var g_field: PackedFloat32Array = PackedFloat32Array()
	g_field.resize(grid.cell_count * 3)
	var solid: PackedByteArray = PackedByteArray()
	solid.resize(grid.cell_count)
	for c in grid.cell_count:
		var p: Vector3 = grid.cell_world_pos(c)
		var d: Vector3 = centre - p
		var r: float = d.length()
		var gv: Vector3 = d.normalized() * (LAPhysical.GRAVITATIONAL_CONSTANT * BODY_M / (r * r))
		g_field[c * 3] = gv.x
		g_field[c * 3 + 1] = gv.y
		g_field[c * 3 + 2] = gv.z
		solid[c] = 1 if p.y < 0.0 else 0
	LABallistics.set_system([])
	LABallistics.set_field(grid, g_field, solid, [], Basis.IDENTITY, Vector3.ZERO)

	var start: Vector3 = Vector3(0.0, DROP_H, 0.0)
	# The ground's tangential velocity at the release point: what LATestMasses hands drop().
	var v0: Vector3 = Vector3(TANGENT_V, 0.0, 0.0)
	var g0: float = LABallistics.g_at(start).length()
	if not (g0 > 0.0):
		_say("The rig's own field reads no gravity at the release point, so nothing here is a test.")
		_report()
		return
	var id: int = LABallistics.drop(start, v0, 0.0, 0.0)
	var t: float = float(STEPS) * DT

	# ON: it accelerates, |v| = sqrt(v0^2 + (g t)^2) for a horizontal release.
	_run(STEPS)
	var s1: Dictionary = LABallistics.state(id)
	var want_v: float = sqrt(TANGENT_V * TANGENT_V + g0 * t * g0 * t)
	if absf(float(s1["speed"]) - want_v) / want_v > REL:
		_say("Under gravity the body reached %.4f m/s where sqrt(v0^2 + (g t)^2) is %.4f m/s."
			% [float(s1["speed"]), want_v])

	# OFF: no pull anywhere, so the velocity it had is the velocity it keeps.
	LAAblate.set_on("gravity", false)
	if LAWorldOffers.has_gravity():
		_say("The offers still report a solved gravity field with the switch off.")
	if bool(LAProcessSet.live_mask().get("gravity", true)):
		_say("The mask still reads gravity live with the switch off.")
	if LABallistics.g_at(s1["position"]).length() != 0.0:
		_say("g_at still pulls with the gravity switch off.")
	var p1: Vector3 = s1["position"]
	var v1: Vector3 = s1["velocity"]
	_run(STEPS)
	var s2: Dictionary = LABallistics.state(id)
	var v2: Vector3 = s2["velocity"]
	if (v2 - v1).length() > REL * v1.length():
		_say("With gravity off the velocity changed from %s to %s." % [v1, v2])
	var drift: Vector3 = (s2["position"] as Vector3) - p1
	if (drift - v1 * t).length() > REL * (v1 * t).length():
		_say("With gravity off the body moved %s where the tangent gives %s." % [drift, v1 * t])

	# ON AGAIN: it accelerates from the velocity it coasted at.
	LAAblate.set_on("gravity", true)
	if not LAWorldOffers.has_gravity():
		_say("The offers still report gravity absent after the switch came back.")
	_run(STEPS)
	var s3: Dictionary = LABallistics.state(id)
	var want3: float = (v2 + Vector3(0.0, -g0 * t, 0.0)).length()
	if absf(float(s3["speed"]) - want3) / want3 > REL:
		_say("After the switch came back the body reached %.4f m/s where |v + g t| is %.4f m/s."
			% [float(s3["speed"]), want3])
	LABallistics.release(id)
	LABallistics.clear_field()

	# --- a transport row switches through the same registry ----------------------------------------
	LAProcessSet.declare(LAProcessSet.ACOUSTIC)
	if not LAWorldOffers.has_wind():
		_say("An acoustic world reports no wind before any switch is thrown.")
	LAAblate.set_on("mom_flux", false)
	if LAWorldOffers.has_wind():
		_say("The offers still report a wind with the momentum row switched off.")
	if LAProcessSet.is_active("transport", "mom_flux"):
		_say("The momentum row is still active with its switch off.")
	LAAblate.set_on("mom_flux", true)
	if not LAWorldOffers.has_wind():
		_say("The wind did not come back when the momentum row's switch did.")

	# --- the driver reads each pass's OWN record and its OWN MOVES_STATE ----------------------------
	var driver: LAFieldDriver = LAFieldDriver.new()
	var flux: RefCounted = load(FLUX_PASS).new()
	var gravity_pass: RefCounted = load(GRAVITY_PASS).new()
	if not driver.moves_state([flux]):
		_say("The driver does not read FluxPass's own MOVES_STATE, so a world holding it reads as at rest.")
	if driver.moves_state([gravity_pass]):
		_say("The driver calls a world whose only pass is GravityPass a writer of matter.")
	LAAblate.set_on("flux", false)
	if driver.moves_state([flux]):
		_say("A switched-off writer still counts as a writer, so the world never comes to rest.")
	_report()


func _report() -> void:
	print('LIVE_TOGGLE_PROBE={"failures":%d}' % _fail)
	quit(1 if _fail > 0 else 0)
