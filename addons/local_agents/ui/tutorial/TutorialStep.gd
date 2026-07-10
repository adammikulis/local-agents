class_name LATutorialStep
extends Resource

## One step in a guided tutorial: the instruction text, what on screen it points at, and the condition
## that advances to the next step. Pure data — a typed Resource so steps can be authored in the inspector
## or built in code, then handed to an LATutorialSequencer. Game-agnostic: nothing here knows about the
## voxel sim or any particular scene. (Explicit types only — no ':=' .)

## What the step's highlight points at.
enum TargetKind {
	NONE,     ## no spotlight — just a centered callout (intro / outro text)
	CONTROL,  ## a Control node resolved from `control_path` relative to the sequencer's target root
	RECT,     ## a fixed screen-space Rect2 (`rect`)
	WORLD,    ## a world-space point (`world_point`) projected to screen via the sequencer's Camera3D
}

## What makes the step advance to the next one.
enum Advance {
	NEXT_BUTTON,    ## the player presses the callout's "Next" button
	TARGET_PRESSED, ## the target Control is a BaseButton and the player presses it
	PREDICATE,      ## `advance_predicate` (a Callable returning bool) becomes true — polled each frame
	SIGNAL,         ## `signal_source` emits `signal_name` (e.g. an "objective met" broadcast)
}

@export_multiline var text: String = ""          ## the instruction body shown in the callout
@export var title: String = ""                    ## optional bold heading above the body
@export var target_kind: TargetKind = TargetKind.NONE
@export var control_path: NodePath = NodePath()   ## for CONTROL: path relative to the sequencer target root
@export var rect: Rect2 = Rect2()                 ## for RECT: the screen rectangle to spotlight
@export var world_point: Vector3 = Vector3.ZERO   ## for WORLD: the world position to point at
@export var target_pad: float = 8.0               ## extra pixels of breathing room around the spotlight
@export var advance: Advance = Advance.NEXT_BUTTON

# Runtime-only wiring (Callables/Signals don't serialize on a Resource, so these are assigned in code
# when the step list is built). Left empty for inspector-authored NEXT_BUTTON / TARGET_PRESSED steps.
var advance_predicate: Callable = Callable()      ## for PREDICATE: called each frame, returns bool
var signal_source: Object = null                  ## for SIGNAL: the emitter
var signal_name: StringName = &""                 ## for SIGNAL: the signal to await


## Convenience: build a step that spotlights a Control and advances when the player presses it (the
## common "click this button" case). `path` is relative to the sequencer's target root.
static func for_control(path: NodePath, body: String, heading: String = "", adv: Advance = Advance.TARGET_PRESSED) -> LATutorialStep:
	var s: LATutorialStep = LATutorialStep.new()
	s.target_kind = TargetKind.CONTROL
	s.control_path = path
	s.text = body
	s.title = heading
	s.advance = adv
	return s


## Convenience: a text-only step (no spotlight) advanced by the Next button — intro/outro cards.
static func message(body: String, heading: String = "") -> LATutorialStep:
	var s: LATutorialStep = LATutorialStep.new()
	s.target_kind = TargetKind.NONE
	s.text = body
	s.title = heading
	s.advance = Advance.NEXT_BUTTON
	return s


## Convenience: spotlight a world-space point (projected via the sequencer camera), advance by Next.
static func for_world(point: Vector3, body: String, heading: String = "") -> LATutorialStep:
	var s: LATutorialStep = LATutorialStep.new()
	s.target_kind = TargetKind.WORLD
	s.world_point = point
	s.text = body
	s.title = heading
	s.advance = Advance.NEXT_BUTTON
	return s


## Build a step from a loose dictionary (handy for JSON-authored tutorials). Recognized keys mirror the
## exported properties: text, title, target_kind (int or one of "none"/"control"/"rect"/"world"),
## control_path, rect, world_point, advance (int or "next"/"target"/"predicate"/"signal").
static func from_dict(d: Dictionary) -> LATutorialStep:
	var s: LATutorialStep = LATutorialStep.new()
	s.text = String(d.get("text", ""))
	s.title = String(d.get("title", ""))
	s.target_kind = _parse_kind(d.get("target_kind", TargetKind.NONE))
	s.control_path = NodePath(String(d.get("control_path", "")))
	if d.has("rect"):
		s.rect = d["rect"]
	if d.has("world_point"):
		s.world_point = d["world_point"]
	s.target_pad = float(d.get("target_pad", 8.0))
	s.advance = _parse_advance(d.get("advance", Advance.NEXT_BUTTON))
	return s


static func _parse_kind(v) -> TargetKind:
	if v is String:
		match String(v).to_lower():
			"control": return TargetKind.CONTROL
			"rect": return TargetKind.RECT
			"world": return TargetKind.WORLD
			_: return TargetKind.NONE
	return int(v) as TargetKind


static func _parse_advance(v) -> Advance:
	if v is String:
		match String(v).to_lower():
			"target", "target_pressed": return Advance.TARGET_PRESSED
			"predicate": return Advance.PREDICATE
			"signal": return Advance.SIGNAL
			_: return Advance.NEXT_BUTTON
	return int(v) as Advance
