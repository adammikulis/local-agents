extends RefCounted
class_name LocalAgentsSimulationLoopController

signal tick_started(tick: int)
signal tick_completed(tick: int)

@export_range(1.0, 25.0, 0.5) var sim_budget_ms_per_frame: float = 6.0
@export_range(1, 24, 1) var max_sim_ticks_per_frame: int = 6

func run_ticks(delta: float, accumulator: float, tick_duration: float, run_tick: Callable) -> Dictionary:
	var processed = 0
	accumulator += maxf(0.0, delta)
	var frame_start_us = Time.get_ticks_usec()
	var budget_us = int(round(maxf(1.0, sim_budget_ms_per_frame) * 1000.0))
	while accumulator >= tick_duration and processed < maxi(1, max_sim_ticks_per_frame):
		accumulator -= tick_duration
		processed += 1
		emit_signal("tick_started", processed)
		run_tick.call()
		emit_signal("tick_completed", processed)
		if Time.get_ticks_usec() - frame_start_us >= budget_us:
			break
	return {"processed": processed, "accumulator": accumulator}
