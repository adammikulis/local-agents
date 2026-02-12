extends Node
class_name LocalAgentsFixedStepSimulation

signal tick_started(tick)
signal tick_finished(tick, state_hash)
signal simulation_error(message)

const ClockScript = preload("res://addons/local_agents/simulation/SimulationClock.gd")
const HasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")
const ControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

@export var fixed_delta: float = 1.0
@export var ticks_per_frame: int = 1

var _clock
var _hasher
var _controller
var _pending_steps: int = 0

func _ready() -> void:
    _clock = ClockScript.new()
    _clock.configure(fixed_delta, ticks_per_frame)
    _hasher = HasherScript.new()
    if _controller == null:
        _controller = ControllerScript.new()
        add_child(_controller)

func configure(seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
    _ensure_ready()
    _controller.configure(seed_text, narrator_enabled, dream_llm_enabled)

func controller():
    _ensure_ready()
    return _controller

func play() -> void:
    _ensure_ready()
    _clock.play()

func pause() -> void:
    _ensure_ready()
    _clock.pause()

func step_once() -> void:
    _ensure_ready()
    _pending_steps += 1

func rewind_to(tick: int) -> void:
    _ensure_ready()
    _clock.rewind_to(tick)

func set_speed(new_ticks_per_frame: int) -> void:
    _ensure_ready()
    _clock.set_ticks_per_frame(new_ticks_per_frame)

func _process(_delta: float) -> void:
    if _clock == null:
        return
    var steps = 0
    if _clock.is_playing():
        steps += _clock.ticks_per_frame
    if _pending_steps > 0:
        steps += _pending_steps
        _pending_steps = 0
    if steps <= 0:
        return
    for _i in steps:
        _run_tick()

func _run_tick() -> void:
    var tick = _clock.advance()
    emit_signal("tick_started", tick)
    var result: Dictionary = _controller.process_tick(tick, _clock.fixed_delta)
    if result.is_empty():
        emit_signal("simulation_error", "tick_failed")
        return
    var state_hash = _hasher.hash_state(result)
    emit_signal("tick_finished", tick, state_hash)

func _ensure_ready() -> void:
    if _clock == null or _hasher == null or _controller == null:
        _ready()
