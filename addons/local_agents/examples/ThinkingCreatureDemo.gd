extends Node3D

## ThinkingCreatureDemo — the CORE showcase: creatures that stand, wander and think on a plain flat
## floor, with NO voxel world, no MaterialField, no ecology and no planet.
##
## THE SCENE IS THE DEMO. Everything you can see was placed and configured in the editor, not built
## here in code:
##   - Spawner (LocalAgentCreatureSpawner) makes the population and its floor. Type species and counts
##     into its Counts dictionary; it instantiates Creature.tscn, scatters it and calls setup_standalone.
##   - Camera3D / DirectionalLight3D frame and light it.
##   - LlmService + CognitionScheduler are the no-code path to a thinking creature: the scheduler
##     auto-adopts anything in its Adopt Group ("la_creatures"), which every standalone creature joins
##     on setup. Both ship INERT — LlmService.Enabled is off, and the spawner's Llm Enabled is off — so
##     the demo boots with no model and no server. Point LlmService at a .gguf, tick its Enabled, tick
##     the spawner's Llm Enabled, and the same creatures start escalating to the model. No code changes.
##   - DemoHarness gives the scene `-- --run-frames=N`, which prints THINKING_CREATURE_REPORT and quits.
##
## All that is left in this script is the thing a game author would actually write: what the run should
## measure. (Explicit types only — project rule: no ':=' inferred typing.)

@onready var _spawner: LocalAgentCreatureSpawner = %Spawner as LocalAgentCreatureSpawner

var _harness_frames: int = 0


# LocalAgentDemoHarness hands back the resolved command line, so the report can quote the frame budget
# it was actually given without this scene re-reading argv.
func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


# The payload LocalAgentDemoHarness prints at the end of a `--run-frames=N` run. "on_floor" is the
# check that matters: a creature that lost its terrain adapter falls away from the ground plane, and
# creatures != on_floor is what that looks like from here.
func demo_report() -> Dictionary:
	var alive: Array[Node] = _spawner.spawned()
	var on_floor: int = 0
	for c in alive:
		if c is Node3D and absf((c as Node3D).global_position.y - _spawner.ground_y) < 5.0:
			on_floor += 1
	return {
		"frames": _harness_frames,
		"creatures": alive.size(),
		"on_floor": on_floor,
		"species": _species_label(),
	}


# The species this run actually asked for, read back off the spawner rather than duplicated here, so
# editing the Counts dictionary in the inspector also moves the report.
func _species_label() -> String:
	var kinds: Array = _spawner.counts.keys()
	kinds.sort()
	var names: PackedStringArray = PackedStringArray()
	for k in kinds:
		names.append(String(k))
	return "+".join(names)
