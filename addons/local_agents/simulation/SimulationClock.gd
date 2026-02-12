extends RefCounted
class_name LocalAgentsSimulationClock

enum Mode {
    PAUSED,
    PLAYING,
}

var fixed_delta: float = 1.0
var tick: int = 0
var mode: Mode = Mode.PAUSED
var ticks_per_frame: int = 1

func configure(step_seconds: float, speed_ticks_per_frame: int = 1) -> void:
    fixed_delta = max(step_seconds, 0.001)
    ticks_per_frame = max(speed_ticks_per_frame, 1)

func play() -> void:
    mode = Mode.PLAYING

func pause() -> void:
    mode = Mode.PAUSED

func is_playing() -> bool:
    return mode == Mode.PLAYING

func set_ticks_per_frame(value: int) -> void:
    ticks_per_frame = max(value, 1)

func advance() -> int:
    tick += 1
    return tick

func rewind_to(target_tick: int) -> void:
    tick = max(target_tick, 0)
