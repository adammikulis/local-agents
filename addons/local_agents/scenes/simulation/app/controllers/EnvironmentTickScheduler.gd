extends RefCounted
class_name LocalAgentsEnvironmentTickScheduler

func intervals_for_mode(mode: String) -> Dictionary:
	if mode == "cpu":
		return {"weather": 1, "erosion": 1, "solar": 1}
	if mode == "gpu_hybrid":
		return {"weather": 2, "erosion": 2, "solar": 3}
	if mode == "gpu_aggressive":
		return {"weather": 3, "erosion": 3, "solar": 4}
	return {"weather": 4, "erosion": 4, "solar": 6}

func frame_budget_us(sim_budget_ms_per_frame: float) -> int:
	return int(round(maxf(1.0, sim_budget_ms_per_frame) * 1000.0))

func should_step_subsystem(tick: int, interval: int, empty_snapshot: bool) -> bool:
	return (tick % maxi(1, interval) == 0) or empty_snapshot
