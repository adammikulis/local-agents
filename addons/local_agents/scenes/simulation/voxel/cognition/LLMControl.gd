class_name LALLMControl
extends RefCounted

## Player-facing control over the per-creature local-LLM "slow brain": bulk-enable/disable the slow-brain
## escalation across a GROUP (one species, or all creatures) and the PREDICATE that picks out creatures
## currently consulting (thinking) or waiting on (queued) the shared LACognitionScheduler. Pure static
## helpers over the scene tree + the shared scheduler — no per-species branches, driven by the creature's
## config-set `llm_enabled` flag and the scheduler's live activity set. The two highlight KEYS below double
## as the tint-registry categories (LACreature reuses the behavior-tint registry for them).
##
## (Explicit types only — project rule: no ':=' inferred typing.)

# Tint-registry categories for the LLM highlight (reused by LACreature's behavior-tint path).
const HL_THINKING: String = "llm_thinking"   # a slow-brain escalation is in flight / just resolved
const HL_QUEUED: String = "llm_queued"        # wanted to escalate but the shared budget was full


## Enable/disable the slow-brain escalation for a whole group. species == "" targets every creature;
## otherwise only that species. Returns how many creatures were changed. The flag gates _should_escalate
## in LACognition, so a disabled creature falls back cleanly to its fast reinforced policy + innate cascade.
static func set_group(tree: SceneTree, species: String, on: bool) -> int:
	if tree == null:
		return 0
	var group: String = "creature" if species == "" else "species_" + species
	var n: int = 0
	for c in tree.get_nodes_in_group(group):
		if is_instance_valid(c) and "llm_enabled" in c:
			c.llm_enabled = on
			n += 1
	return n


## True if creature `c` currently matches `kind` ("thinking" | "queued" | "any") per the shared scheduler.
## `sched` is the LACognitionScheduler (may be null → no match). O(1) scheduler lookups.
static func matches(c, kind: String, sched) -> bool:
	if c == null or sched == null:
		return false
	var thinking: bool = sched.has_method("is_thinking") and sched.is_thinking(c)
	var queued: bool = sched.has_method("is_queued") and sched.is_queued(c)
	match kind:
		"thinking":
			return thinking
		"queued":
			return queued
		_:
			return thinking or queued


## Count creatures matching `kind` (status text / harness logging). O(creatures).
static func count(tree: SceneTree, kind: String, sched) -> int:
	if tree == null or sched == null:
		return 0
	var n: int = 0
	for c in tree.get_nodes_in_group("creature"):
		if is_instance_valid(c) and matches(c, kind, sched):
			n += 1
	return n
