extends Resource
class_name LocalAgentsCognitionContractConfigResource

const LlmRequestProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd")

@export var schema_version: int = 1
@export var llm_profile_version: String = "slice_v1"
@export var simulation_profile_id: String = "vertical_slice_default"
@export var context_schema_version: int = 1
@export var max_prompt_chars: int = 6000

@export var narrator_profile: Resource
@export var thought_profile: Resource
@export var dialogue_profile: Resource
@export var dream_profile: Resource
@export var oral_driver_profile: Resource

@export var budget_state_chars: int = 420
@export var budget_waking_memories: int = 4
@export var budget_dream_memories: int = 2
@export var budget_beliefs: int = 3
@export var budget_conflicts: int = 2
@export var budget_oral_knowledge: int = 3
@export var budget_ritual_events: int = 2
@export var budget_taboo_ids: int = 6

func _init() -> void:
	ensure_defaults()

func ensure_defaults() -> void:
	if narrator_profile == null:
		var p = LlmRequestProfileResourceScript.new()
		p.profile_id = "narrator_direction"
		p.temperature = 0.2
		p.top_p = 0.9
		p.max_tokens = 160
		p.stop = PackedStringArray(["\n\nUser:", "\n\nVillager:"])
		p.retry_count = 1
		narrator_profile = p
	if thought_profile == null:
		var p = LlmRequestProfileResourceScript.new()
		p.profile_id = "internal_thought"
		p.temperature = 0.55
		p.top_p = 0.9
		p.max_tokens = 120
		p.stop = PackedStringArray(["\nVillager:", "\nNarrator hint:"])
		p.retry_count = 1
		thought_profile = p
	if dialogue_profile == null:
		var p = LlmRequestProfileResourceScript.new()
		p.profile_id = "dialogue_exchange"
		p.temperature = 0.5
		p.top_p = 0.92
		p.max_tokens = 140
		p.stop = PackedStringArray(["\nNarrator hint:"])
		p.retry_count = 1
		dialogue_profile = p
	if dream_profile == null:
		var p = LlmRequestProfileResourceScript.new()
		p.profile_id = "dream_generation"
		p.temperature = 0.7
		p.top_p = 0.95
		p.max_tokens = 140
		p.stop = PackedStringArray(["\nVillager:", "\nNarrator hint:"])
		p.retry_count = 1
		dream_profile = p
	if oral_driver_profile == null:
		var p = LlmRequestProfileResourceScript.new()
		p.profile_id = "oral_transmission_utterance"
		p.temperature = 0.35
		p.top_p = 0.9
		p.max_tokens = 420
		p.stop = PackedStringArray()
		p.output_json = true
		p.retry_count = 0
		oral_driver_profile = p

func profile_for_task(task: String):
	ensure_defaults()
	match task:
		"narrator_direction":
			return narrator_profile
		"internal_thought":
			return thought_profile
		"dialogue_exchange":
			return dialogue_profile
		"dream_generation":
			return dream_profile
		"oral_transmission_utterance":
			return oral_driver_profile
		_:
			return thought_profile

func to_dict() -> Dictionary:
	ensure_defaults()
	return {
		"schema_version": schema_version,
		"llm_profile_version": llm_profile_version,
		"simulation_profile_id": simulation_profile_id,
		"context_schema_version": context_schema_version,
		"max_prompt_chars": max_prompt_chars,
		"budget_state_chars": budget_state_chars,
		"budget_waking_memories": budget_waking_memories,
		"budget_dream_memories": budget_dream_memories,
		"budget_beliefs": budget_beliefs,
		"budget_conflicts": budget_conflicts,
		"budget_oral_knowledge": budget_oral_knowledge,
		"budget_ritual_events": budget_ritual_events,
		"budget_taboo_ids": budget_taboo_ids,
		"narrator_profile": _profile_to_dict(narrator_profile),
		"thought_profile": _profile_to_dict(thought_profile),
		"dialogue_profile": _profile_to_dict(dialogue_profile),
		"dream_profile": _profile_to_dict(dream_profile),
		"oral_driver_profile": _profile_to_dict(oral_driver_profile),
	}

func _profile_to_dict(profile_resource: Resource) -> Dictionary:
	if profile_resource == null:
		return {}
	if profile_resource.has_method("to_dict"):
		return profile_resource.call("to_dict")
	return {}
