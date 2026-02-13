extends RefCounted
class_name LocalAgentsCulturalCycleSystem

const LlmRequestProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd")
const CulturalCycleHelpersScript = preload("res://addons/local_agents/simulation/CulturalCycleHelpers.gd")
const CulturalCycleTopicRuntimeScript = preload("res://addons/local_agents/simulation/culture/CulturalCycleTopicRuntime.gd")
const CulturalCycleDriverSynthesizerScript = preload("res://addons/local_agents/simulation/culture/CulturalCycleDriverSynthesizer.gd")

var _oral_last_item: Dictionary = {}
var _confidence_by_topic: Dictionary = {}
var _last_driver_digest: Dictionary = {}
var llm_enabled: bool = true
var _request_profile = LlmRequestProfileResourceScript.new()
var _runtime_options: Dictionary = {}
var _topic_runtime = CulturalCycleTopicRuntimeScript.new()
var _driver_synthesizer = CulturalCycleDriverSynthesizerScript.new()

func _init() -> void:
	_request_profile.profile_id = "oral_transmission_utterance"
	_request_profile.temperature = 0.35
	_request_profile.top_p = 0.9
	_request_profile.max_tokens = 420
	_request_profile.stop = PackedStringArray()
	_request_profile.reset_context = true
	_request_profile.cache_prompt = false
	_request_profile.retry_count = 0
	_request_profile.retry_seed_step = 1
	_request_profile.output_json = true

func set_request_profile(profile_resource: Resource) -> void:
	if profile_resource == null:
		return
	if profile_resource.has_method("to_dict"):
		_request_profile.from_dict(profile_resource.call("to_dict"))

func request_profile_id() -> String:
	return String(_request_profile.profile_id)

func set_runtime_options(options: Dictionary) -> void:
	_runtime_options = options.duplicate(true)

func export_state() -> Dictionary:
	var retention_snapshot = _retention_metrics()
	return {
		"oral_last_item": _oral_last_item.duplicate(true),
		"confidence_by_topic": _confidence_by_topic.duplicate(true),
		"last_driver_digest": _last_driver_digest.duplicate(true),
		"retention_by_topic": retention_snapshot.get("retention_by_topic", {}).duplicate(true),
		"retention_summary": retention_snapshot.get("summary", {}).duplicate(true),
	}

func import_state(payload: Dictionary) -> void:
	_oral_last_item = payload.get("oral_last_item", {}).duplicate(true)
	_confidence_by_topic = payload.get("confidence_by_topic", {}).duplicate(true)
	_last_driver_digest = payload.get("last_driver_digest", {}).duplicate(true)

func step(tick: int, context: Dictionary) -> Dictionary:
	var oral_events: Array = []
	var ritual_events: Array = []
	var drivers: Array = []
	var driver_trace: Dictionary = {}
	var graph = context.get("graph_service", null)
	if graph == null:
		return {"oral_events": oral_events, "ritual_events": ritual_events, "drivers": drivers, "trace": driver_trace}
	var rng = context.get("rng", null)
	var world_id = String(context.get("world_id", "world_main"))
	var branch_id = String(context.get("branch_id", "main"))
	var household_members: Dictionary = context.get("household_members", {})
	var npc_ids: Array = context.get("npc_ids", [])
	var sacred_site_id = String(context.get("sacred_site_id", ""))
	var context_snapshot: Dictionary = context.get("culture_context", {})
	var context_cues: Dictionary = context.get("context_cues", {})
	var deterministic_seed = int(context.get("deterministic_seed", 1))
	var synthesis: Dictionary = _synthesize_cultural_drivers(tick, world_id, branch_id, context_snapshot, context_cues, deterministic_seed)
	drivers = synthesis.get("drivers", [])
	driver_trace = synthesis.get("trace", {})
	if tick > 0 and tick % 24 == 18:
		_decay_confidence()
		oral_events = _run_oral_schedule(tick, graph, rng, world_id, branch_id, household_members, context_snapshot, context_cues, drivers)
	if sacred_site_id != "" and tick > 0 and tick % 72 == 30:
		ritual_events = _run_ritual_schedule(tick, graph, rng, world_id, branch_id, sacred_site_id, npc_ids, drivers)
	_last_driver_digest = _driver_digest(drivers)
	return {"oral_events": oral_events, "ritual_events": ritual_events, "drivers": drivers, "trace": driver_trace}

func _run_oral_schedule(tick: int, graph, rng, world_id: String, branch_id: String, household_members: Dictionary, context_snapshot: Dictionary, context_cues: Dictionary, drivers: Array) -> Array:
	return _topic_runtime.run_oral_schedule(self, tick, graph, rng, world_id, branch_id, household_members, context_snapshot, context_cues, drivers)

func _run_ritual_schedule(tick: int, graph, rng, world_id: String, branch_id: String, sacred_site_id: String, npc_ids: Array, drivers: Array) -> Array:
	return _topic_runtime.run_ritual_schedule(tick, graph, rng, world_id, branch_id, sacred_site_id, npc_ids, drivers)

func _decay_confidence() -> void:
	_topic_runtime.decay_confidence(_confidence_by_topic)

func _topic_content(topic: String, household_id: String, household_context: Dictionary, drivers: Array, detail_drift: float = 0.0) -> String:
	return _topic_runtime.topic_content(topic, household_id, household_context, drivers, detail_drift)

func _topic_base_content(topic: String, household_id: String, household_context: Dictionary, drivers: Array) -> String:
	return _topic_runtime.topic_base_content(topic, household_id, household_context, drivers)

func _topic_detail_variant(topic: String, detail_drift: float) -> String:
	return _topic_runtime.topic_detail_variant(topic, detail_drift)

func _compute_detail_drift(topic: String, household_id: String, branch_id: String, tick: int, confidence: float, salience: float, gain_loss: float, rng) -> float:
	return _topic_runtime.compute_detail_drift(topic, household_id, branch_id, tick, confidence, salience, gain_loss, rng)

func _topic_motifs(topic: String) -> Array:
	return _topic_runtime.topic_motifs(topic)

func retention_metrics() -> Dictionary:
	return _retention_metrics()

func _retention_metrics() -> Dictionary:
	return _topic_runtime.retention_metrics(_confidence_by_topic)

func _household_context_for(household_id: String, context_snapshot: Dictionary) -> Dictionary:
	return _topic_runtime.household_context_for(household_id, context_snapshot)

func _topic_weights_for_household(household_id: String, household_context: Dictionary, context_cues: Dictionary, drivers: Array) -> Dictionary:
	return _topic_runtime.topic_weights_for_household(household_id, household_context, context_cues, drivers)

func _apply_context_cues_to_topic_weights(weights: Dictionary, context_cues: Dictionary) -> void:
	_topic_runtime.apply_context_cues_to_topic_weights(weights, context_cues)

func _select_weighted_topic(topic_weights: Dictionary, rng, household_id: String, branch_id: String, tick: int) -> String:
	return _topic_runtime.select_weighted_topic(topic_weights, rng, household_id, branch_id, tick)

func _topic_salience(topic: String, household_id: String, drivers: Array) -> float:
	return _topic_runtime.topic_salience(topic, household_id, drivers)

func _tag_matches_topic(tag: String, topic: String) -> bool:
	return _topic_runtime.tag_matches_topic(tag, topic)

func _ritual_driver_intensity(drivers: Array) -> float:
	return _topic_runtime.ritual_driver_intensity(drivers)

func _ritual_gain_loss(drivers: Array) -> float:
	return _topic_runtime.ritual_gain_loss(drivers)

func _dominant_driver_label(drivers: Array) -> String:
	return _topic_runtime.dominant_driver_label(drivers)

func _topic_gain_loss(topic: String, household_id: String, drivers: Array) -> float:
	return _topic_runtime.topic_gain_loss(topic, household_id, drivers)

func _driver_digest(drivers: Array) -> Dictionary:
	return _topic_runtime.driver_digest(drivers)

func _synthesize_cultural_drivers(tick: int, world_id: String, branch_id: String, context_snapshot: Dictionary, context_cues: Dictionary, deterministic_seed: int) -> Dictionary:
	return _driver_synthesizer.synthesize(self, tick, world_id, branch_id, context_snapshot, context_cues, deterministic_seed)

func _merge_with_context_cue_drivers(rows: Array, context_cues: Dictionary) -> Array:
	return _driver_synthesizer._merge_with_context_cue_drivers(rows, context_cues)

func _build_driver_prompt(world_id: String, branch_id: String, tick: int, context_snapshot: Dictionary) -> String:
	return _driver_synthesizer._build_driver_prompt(world_id, branch_id, tick, context_snapshot)

func _generate_driver_payload(prompt: String, deterministic_seed: int) -> Dictionary:
	return _driver_synthesizer._generate_driver_payload(self, prompt, deterministic_seed)

func _merged_runtime_options(seed: int) -> Dictionary:
	return _driver_synthesizer._merged_runtime_options(self, seed)

func _parse_json_anywhere(text: String):
	return _driver_synthesizer._parse_json_anywhere(text)

func _try_parse_json(text: String):
	return _driver_synthesizer._try_parse_json(text)

func _driver_json_schema() -> Dictionary:
	return CulturalCycleHelpersScript.driver_json_schema()

func _compact_context_for_prompt(context_snapshot: Dictionary) -> Dictionary:
	return CulturalCycleHelpersScript.compact_context_for_prompt(context_snapshot)

func _heuristic_driver_payload(context_snapshot: Dictionary) -> Array:
	return CulturalCycleHelpersScript.heuristic_driver_payload(context_snapshot)

func _sanitize_drivers(rows: Array) -> Array:
	return CulturalCycleHelpersScript.sanitize_drivers(rows)
