class_name LACampaignTutorial
extends Node

## LACampaignTutorial — the first-run campaign intro. It scripts the guided tour that teaches the core
## caretaker loop the moment a player starts a CAMPAIGN, built ENTIRELY on the reusable tutorial system
## (LATutorialSequencer + LATutorialHighlightOverlay + LATutorialStep). This file owns NO tutorial
## mechanics — it only authors a data-defined step list, resolves each step's highlight target to a live
## Control, and hands the list to the sequencer. Wired into VoxelWorld with one add_child + setup line.
##
## Rules it honours:
##   - CAMPAIGN ONLY — never runs in Sandbox (queries the progression's mode).
##   - FIRST RUN ONLY — keyed to the sequencer's persisted "seen" flag (user://tutorial_state.cfg); once
##     finished OR skipped it marks itself done, so a second campaign launch skips straight past it.
##   - SKIPPABLE — the overlay's Skip button ends it (and marks it seen).
##   - Keys come from LAHotkeyRegistry (the one source of truth), never hardcoded, so the copy always
##     names the real bindings.
##
## Verification hooks (parsed from the shared -- user args, matching the repo convention):
##   --tutorial-auto        walk every step to the end by pressing Next on a cooldown (proves stepping;
##                          prints TUTORIAL_STEP=<i> per step and TUTORIAL_DONE on finish).
##   --shoot=<png>          (VoxelWorld owns the capture) — the tutorial advances to a spotlight step and
##                          HOLDS there so the screenshot shows a callout + spotlight, not the intro card.
## (Explicit types only — project rule: no ':=' inferred typing.)

const OverlayScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialHighlightOverlay.gd")
const SequencerScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialSequencer.gd")
const StepScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialStep.gd")

const TUTORIAL_ID: String = "campaign_intro"

# Step indices (named so the spotlight-hold + spawn-baseline logic reference them, not magic numbers).
const STEP_WELCOME: int = 0
const STEP_LOOK: int = 1
const STEP_SPAWN: int = 2
const STEP_MIND: int = 3
const STEP_GOAL: int = 4
const STEP_SPEED: int = 5
const STEP_TROUBLE: int = 6
const STEP_UNLOCK: int = 7

# The step a --shoot run rests on for the screenshot: LOOK highlights the view-controls bar and advances
# only on Next, so it holds a stable spotlight + callout for the capture.
const SHOT_HOLD_STEP: int = STEP_LOOK
const DRIVE_COOLDOWN: int = 30      # frames between auto-driven Next presses (lets the spotlight settle)

# Scene references (supplied by setup()); all read-only from here — the tutorial drives nothing.
var _interaction: Node = null       # LAVoxelInteraction — its selection_changed signal advances "meet a mind"
var _spawn_hud: CanvasLayer = null  # LASpawnPaletteHud — the palette we spotlight for "spawn life"
var _game_hud: CanvasLayer = null   # LAGameHud — the objective panel we spotlight for "your goal"
var _input: Node = null             # LAVoxelInputController — hosts the "ViewControls" cluster we spotlight
var _progression: LAGameProgression = null

var _layer: CanvasLayer = null
var _overlay: LATutorialHighlightOverlay = null
var _seq: LATutorialSequencer = null

var _started: bool = false
var _finished: bool = false
var _spawn_baseline: int = 0        # creature count when the "spawn life" step opened (predicate compares to it)

# Verification-drive state.
var _auto: bool = false
var _shoot: bool = false
var _cool: int = 0


## Wire the tour. Called once from VoxelWorld after the HUDs / view-controls / interaction exist. Only the
## references it genuinely reads are passed; everything else is resolved from the reusable system.
func setup(interaction: Node, spawn_hud: CanvasLayer, game_hud: CanvasLayer, input_controller: Node,
		progression: LAGameProgression) -> void:
	_interaction = interaction
	_spawn_hud = spawn_hud
	_game_hud = game_hud
	_input = input_controller
	_progression = progression
	_parse_args()


func _ready() -> void:
	# Build the overlay under our own CanvasLayer so it draws above every HUD (view-controls 120, palette 100,
	# game HUD 96) yet below the pause menu (128). The sequencer is a plain Node child.
	_layer = CanvasLayer.new()
	_layer.name = "TutorialLayer"
	_layer.layer = 126
	add_child(_layer)
	_overlay = OverlayScript.new()
	_layer.add_child(_overlay)
	_seq = SequencerScript.new()
	_seq.name = "TutorialSequencer"
	add_child(_seq)
	_seq.step_changed.connect(_on_step_changed)
	_seq.tutorial_finished.connect(_on_finished)
	# Start on the next frame so the HUD controls have laid out (their global rects are valid to spotlight).
	set_process(true)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--tutorial-auto":
			_auto = true
		elif arg.begins_with("--shoot="):
			_shoot = true


# --- Gate + start ------------------------------------------------------------------------------------------

## True only when we should run: campaign mode (never sandbox) AND not already seen this profile.
func _should_run() -> bool:
	if _progression != null and _progression.is_sandbox():
		print("TUTORIAL_SKIP={reason:sandbox}")
		return false
	if not SequencerScript.should_show(TUTORIAL_ID):
		print("TUTORIAL_SKIP={reason:already_seen, id:%s}" % TUTORIAL_ID)
		return false
	return true


func _process(_delta: float) -> void:
	if not _started:
		# Hold until the controls we spotlight are actually in the tree + laid out, then start once.
		if not _controls_ready():
			return
		_started = true
		if not _should_run():
			set_process(false)
			return
		_start_tour()
		return
	_drive()


## The view-controls cluster is created late (during VoxelInputController.bind); wait for it before starting.
func _controls_ready() -> bool:
	return _view_controls_panel() != null and _spawn_palette_panel() != null


func _start_tour() -> void:
	var steps: Array[LATutorialStep] = _build_steps()
	# Target root = the scene tree root so each step's control_path (computed via get_path_to) resolves any
	# HUD control regardless of which CanvasLayer owns it. No camera needed (no world-space targets).
	var ok: bool = _seq.start(steps, _overlay, get_tree().root, null, TUTORIAL_ID)
	if ok:
		print("TUTORIAL_START={id:%s, mode:campaign, steps:%d}" % [TUTORIAL_ID, steps.size()])
	else:
		set_process(false)


# Auto-drive for verification: press Next on a cooldown. --shoot holds at SHOT_HOLD_STEP for the capture;
# --tutorial-auto walks all the way to the end.
func _drive() -> void:
	if _finished or not _seq.is_active():
		return
	if _shoot:
		if _seq.current_index() >= SHOT_HOLD_STEP:
			return
	elif not _auto:
		return
	if _cool > 0:
		_cool -= 1
		return
	_overlay.next_pressed.emit()
	_cool = DRIVE_COOLDOWN


# --- The scripted tour (data, not logic) -------------------------------------------------------------------

func _build_steps() -> Array[LATutorialStep]:
	var steps: Array[LATutorialStep] = []

	# 0 — Welcome. Sets the caretaker frame + the local-first identity. Centred card, advance on Next.
	steps.append(StepScript.message(
		"You tend a whole living world — its creatures think and choose for themselves, on this device, "
		+ "offline. Let's walk through the basics.",
		"Welcome, caretaker"))

	# 1 — Look around. Spotlight the view-controls bar; advance on Next (looking has no single event).
	var look: LATutorialStep = _control_step(_view_controls_panel(),
		("Drag to orbit the planet and scroll to zoom. Switch between the close planet view and the "
		+ "solar-system overview here (or press %s).") % _key("view_solar"),
		"Look around")
	look.advance = LATutorialStep.Advance.NEXT_BUTTON
	steps.append(look)

	# 2 — Spawn life. Spotlight the palette + name the digit hotkey; advance once the population grows.
	var first_kind: String = LASpawnPaletteHud.LIFE_KINDS[0]      # "plant" — unlocked from the start
	var spawn: LATutorialStep = _control_step(_spawn_palette_panel(),
		("Arm a %s with %s (or click it in the palette), then click the ground to place it. "
		+ "Life is how your world begins.") % [_kind_label(first_kind), _spawn_key(first_kind)],
		"Spawn some life")
	spawn.advance = LATutorialStep.Advance.PREDICATE
	spawn.advance_predicate = Callable(self, "_placed_something")
	steps.append(spawn)

	# 3 — Meet a mind. No spotlight (they click a creature in the world); advance on the selection signal.
	var mind: LATutorialStep = StepScript.message(
		"Click any creature to open its mind — its last decision and why. Every one of them is thinking "
		+ "on your device, offline. Try it now.",
		"Meet a mind")
	mind.advance = LATutorialStep.Advance.SIGNAL
	mind.signal_source = _interaction
	mind.signal_name = &"selection_changed"
	steps.append(mind)

	# 4 — Your goal. Spotlight the objective panel; fold in the live first objective. Advance on Next.
	var goal: LATutorialStep = _control_step(_objective_panel(),
		"Your aim as caretaker: %s. Track your progress here — meeting it earns you more to work with." % _objective_text(),
		"Your goal")
	goal.advance = LATutorialStep.Advance.NEXT_BUTTON
	steps.append(goal)

	# 5 — Speed it up. The fast-forward lives in the pause menu; name the real key.
	steps.append(StepScript.message(
		"Life takes time. Press %s for the menu and pick a faster time speed — watch a herd grow in seconds." % _key("select_cursor"),
		"Speed it up"))

	# 6 — Trouble comes. Nothing is scripted: name the physics the disasters fall out of.
	steps.append(StepScript.message(
		"Storms, quakes, floods and eruptions are never scripted — they emerge from the same physics as "
		+ "everything else: heat, pressure and water finding their level. Keep your herd out of harm's way.",
		"Trouble comes"))

	# 7 — Grow to unlock. The capstone reward is the solar-system view; end warm. Finish on Next.
	steps.append(StepScript.message(
		"Meet your goals to unlock more: new creatures to spawn, wider camera views, all the way up to the "
		+ "whole solar system. Now go tend your world.",
		"Grow to unlock"))

	return steps


# --- Step / advance callbacks ------------------------------------------------------------------------------

func _on_step_changed(index: int, _step: LATutorialStep) -> void:
	print("TUTORIAL_STEP=%d" % index)
	if index == STEP_SPAWN:
		_spawn_baseline = _population()   # so "placed something" measures growth from here, not the founding stock
	_cool = DRIVE_COOLDOWN                 # let each new spotlight settle before an auto-driven press


func _on_finished(completed: bool) -> void:
	_finished = true
	# Mark the tour seen on ANY finish (walked through OR skipped) so a second campaign run skips it — the
	# reusable sequencer only persists on the "don't show again" tick, so we record completion explicitly.
	SequencerScript.set_dont_show(TUTORIAL_ID, true)
	print("TUTORIAL_DONE={completed:%s, id:%s}" % [("true" if completed else "false"), TUTORIAL_ID])
	set_process(false)


## PREDICATE for "spawn life": true once the living population has grown past the count when the step opened.
func _placed_something() -> bool:
	return _population() > _spawn_baseline


# --- Target resolution -------------------------------------------------------------------------------------
# Each step points at a live Control via a path computed from the scene root, so it resolves through whatever
# CanvasLayer owns the widget. Nodes that are momentarily absent yield an empty path (the overlay just dims).

func _control_step(control: Control, body: String, heading: String) -> LATutorialStep:
	var step: LATutorialStep = StepScript.new()
	step.title = heading
	step.text = body
	if control != null:
		step.target_kind = LATutorialStep.TargetKind.CONTROL
		step.control_path = get_tree().root.get_path_to(control)
	else:
		step.target_kind = LATutorialStep.TargetKind.NONE
	step.advance = LATutorialStep.Advance.NEXT_BUTTON
	return step


## The view-controls button cluster (first PanelContainer under the input controller's "ViewControls" layer).
func _view_controls_panel() -> Control:
	if _input == null:
		return null
	var vc: Node = _input.get_node_or_null("ViewControls")
	if vc == null:
		return null
	return _first_of_class(vc, "PanelContainer")


func _spawn_palette_panel() -> Control:
	if _spawn_hud == null:
		return null
	var n: Node = _spawn_hud.get_node_or_null("HudRoot/SpawnPalette")
	return n as Control


func _objective_panel() -> Control:
	if _game_hud == null:
		return null
	var n: Node = _game_hud.get_node_or_null("GameHudRoot/Objective")
	return n as Control


## First descendant of the given class (breadth-agnostic depth walk) — used to find the unnamed panel inside
## the view-controls layer without coupling to its internal node names.
func _first_of_class(root: Node, klass: String) -> Control:
	for child in root.get_children():
		if child.is_class(klass):
			return child as Control
		var found: Control = _first_of_class(child, klass)
		if found != null:
			return found
	return null


# --- Small helpers -----------------------------------------------------------------------------------------

func _population() -> int:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	return tree.get_nodes_in_group("creature").size()


## The active campaign objective as sentence text (lower-cased lead so it reads inside the callout copy).
func _objective_text() -> String:
	var obj: String = ""
	if _progression != null:
		obj = _progression.current_objective()
	if obj.is_empty():
		return "grow a thriving herd"
	# "Rally a herd of 12" -> "rally a herd of 12" so it flows after "Your aim as caretaker: ".
	return obj.substr(0, 1).to_lower() + obj.substr(1)


## Real bound key for an action id, from the one hotkey source of truth (never hardcoded).
func _key(action: String) -> String:
	var k: String = LAHotkeyRegistry.key_for_action(action)
	return k if k != "" else "the hotkey"


## The digit badge a spawn kind is armed with (e.g. "1"), from the shared registry.
func _spawn_key(kind: String) -> String:
	var k: String = LAHotkeyRegistry.spawn_label(kind)
	return k if k != "" else "its palette key"


func _kind_label(kind: String) -> String:
	return String(LASpawnPaletteHud.KIND_LABELS.get(kind, kind))
