@tool
extends RefCounted
class_name LocalAgentsBackstoryCypherPlaybook

static func build_playbook(resolved_npc_id: String, resolved_day: int, resolved_limit: int, version: String) -> Dictionary:
	var window_start = maxi(0, resolved_day - 14)
	var common_params = {
		"npc_id": resolved_npc_id,
		"world_day": resolved_day,
		"window_start": window_start,
		"limit": resolved_limit,
	}
	var queries = {
		"upsert_npc": {
			"description": "Create/update one NPC node",
			"params": {"npc_id": resolved_npc_id, "name": "<name>"},
			"cypher": "MERGE (n:NPC {npc_id: $npc_id})\nSET n.name = $name,\n    n.updated_at = timestamp()\nRETURN n;",
		},
		"upsert_memory_and_link": {
			"description": "Create/update memory and attach it to an NPC",
			"params": {
				"npc_id": resolved_npc_id,
				"memory_id": "<memory_id>",
				"summary": "<summary>",
				"importance": 0.8,
				"confidence": 0.9,
				"world_day": resolved_day,
			},
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})\nMERGE (m:Memory {memory_id: $memory_id})\nSET m.summary = $summary,\n    m.importance = $importance,\n    m.confidence = $confidence,\n    m.world_day = $world_day,\n    m.updated_at = timestamp()\nMERGE (n)-[r:HAS_MEMORY]->(m)\nSET r.confidence = $confidence,\n    r.world_day = $world_day\nRETURN n, r, m;",
		},
		"relationship_state": {
			"description": "Inspect directional relationship profile + recent event aggregate",
			"params": {"source_npc_id": resolved_npc_id, "target_npc_id": "<target_npc_id>", "window_start": window_start, "world_day": resolved_day},
			"cypher": "MATCH (a:NPC {npc_id: $source_npc_id})\nMATCH (b:NPC {npc_id: $target_npc_id})\nOPTIONAL MATCH (a)-[:HAS_RELATIONSHIP_PROFILE]->(p:RelationshipProfile)-[:TARGETS_NPC]->(b)\nOPTIONAL MATCH (e:RelationshipEvent {source_npc_id: $source_npc_id, target_npc_id: $target_npc_id})\nWHERE e.world_day >= $window_start AND e.world_day <= $world_day\nRETURN p, count(e) AS recent_count, avg(e.valence_delta) AS recent_valence_avg, avg(e.trust_delta) AS recent_trust_avg, avg(e.respect_delta) AS recent_respect_avg;",
		},
		"npc_backstory_context": {
			"description": "Fetch relationship, memory, quest state, and dialogue state context for an NPC",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})\nOPTIONAL MATCH (n)-[rel]->(x)\nWHERE (x:Memory OR x:QuestState OR x:DialogueState OR x:RelationshipProfile OR type(rel) IN ['HAS_MEMORY', 'HAS_QUEST_STATE', 'HAS_DIALOGUE_STATE', 'HAS_RELATIONSHIP_PROFILE'])\nRETURN n, rel, x\nORDER BY coalesce(x.world_day, 0) DESC, coalesce(x.updated_at, 0) DESC\nLIMIT $limit;",
		},
		"recent_relationship_events": {
			"description": "Inspect recent directional interaction events for an NPC pair",
			"params": {"source_npc_id": resolved_npc_id, "target_npc_id": "<target_npc_id>", "window_start": window_start, "world_day": resolved_day, "limit": resolved_limit},
			"cypher": "MATCH (e:RelationshipEvent {source_npc_id: $source_npc_id, target_npc_id: $target_npc_id})\nWHERE e.world_day >= $window_start AND e.world_day <= $world_day\nRETURN e\nORDER BY e.world_day DESC, e.updated_at DESC\nLIMIT $limit;",
		},
		"quest_state_timeline": {
			"description": "Show one NPC's quest progression over time",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_QUEST_STATE]->(qs:QuestState)\nRETURN qs.quest_id AS quest_id, qs.state AS state, qs.is_active AS is_active, qs.world_day AS world_day, qs.updated_at AS updated_at\nORDER BY qs.world_day ASC, qs.updated_at ASC\nLIMIT $limit;",
		},
		"exclusive_membership_conflicts": {
			"description": "Find NPCs with multiple active exclusive memberships",
			"params": {"limit": resolved_limit},
			"cypher": "MATCH (n:NPC)-[m:MEMBER_OF]->(f:Faction)\nWHERE coalesce(m.exclusive, false) = true AND coalesce(m.to_day, -1) = -1\nWITH n, collect(f.faction_id) AS factions, count(m) AS cnt\nWHERE cnt > 1\nRETURN n.npc_id AS npc_id, factions, cnt\nORDER BY cnt DESC\nLIMIT $limit;",
		},
		"post_death_activity": {
			"description": "Find quest activity after a declared death day",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_DIALOGUE_STATE]->(life:DialogueState {state_key: 'life_status'})\nMATCH (n)-[:HAS_DIALOGUE_STATE]->(death:DialogueState {state_key: 'death_day'})\nMATCH (n)-[:HAS_QUEST_STATE]->(qs:QuestState)\nWHERE life.state_value = 'dead' AND qs.world_day > toInteger(death.state_value)\nRETURN n.npc_id AS npc_id, toInteger(death.state_value) AS death_day, qs.quest_id AS quest_id, qs.state AS quest_state, qs.world_day AS world_day\nORDER BY qs.world_day ASC\nLIMIT $limit;",
		},
		"memory_recall_candidates": {
			"description": "Top memories for prompt grounding",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_MEMORY]->(m:Memory)\nRETURN m.memory_id AS memory_id, m.summary AS summary, m.world_day AS world_day, m.importance AS importance, m.confidence AS confidence\nORDER BY coalesce(m.importance, 0.0) DESC, coalesce(m.world_day, -1) DESC\nLIMIT $limit;",
		},
		"truths_for_subject": {
			"description": "Inspect canonical truth claims for an entity (subject)",
			"params": {"subject_id": "<subject_id>", "world_day": resolved_day, "limit": resolved_limit},
			"cypher": "MATCH (t:Truth {subject_id: $subject_id})\nWHERE coalesce(t.world_day, -1) <= $world_day OR t.world_day = -1\nRETURN t.claim_key AS claim_key, t.predicate AS predicate, t.object_value AS object_value, t.confidence AS confidence, t.world_day AS world_day, t.updated_at AS updated_at\nORDER BY coalesce(t.world_day, -1) DESC, coalesce(t.updated_at, 0) DESC\nLIMIT $limit;",
		},
		"beliefs_for_npc": {
			"description": "Inspect one NPC's beliefs (which may differ from truth)",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_BELIEF]->(b:Belief)\nWHERE coalesce(b.world_day, -1) <= $world_day OR b.world_day = -1\nRETURN b.claim_key AS claim_key, b.subject_id AS subject_id, b.predicate AS predicate, b.object_value AS object_value, b.confidence AS confidence, b.world_day AS world_day, b.updated_at AS updated_at\nORDER BY coalesce(b.world_day, -1) DESC, coalesce(b.updated_at, 0) DESC\nLIMIT $limit;",
		},
		"belief_truth_conflicts": {
			"description": "Find where an NPC belief value conflicts with canonical truth for the same claim key",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_BELIEF]->(b:Belief)\nMATCH (t:Truth {claim_key: b.claim_key})\nWHERE (coalesce(b.world_day, -1) <= $world_day OR b.world_day = -1) AND (coalesce(t.world_day, -1) <= $world_day OR t.world_day = -1) AND coalesce(b.object_norm, toString(b.object_value)) <> coalesce(t.object_norm, toString(t.object_value))\nRETURN b.claim_key AS claim_key, b.subject_id AS subject_id, b.predicate AS predicate, b.object_value AS believed_value, t.object_value AS true_value, b.confidence AS belief_confidence, t.confidence AS truth_confidence, b.world_day AS belief_day, t.world_day AS truth_day\nORDER BY coalesce(b.confidence, 0.0) DESC\nLIMIT $limit;",
		},
		"oral_knowledge_for_npc": {
			"description": "List oral knowledge items owned by an NPC",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:HAS_ORAL_KNOWLEDGE]->(ok:OralKnowledge)\nWHERE coalesce(ok.world_day, -1) <= $world_day OR ok.world_day = -1\nRETURN ok.knowledge_id AS knowledge_id, ok.category AS category, ok.content AS content, ok.confidence AS confidence, ok.motifs AS motifs, ok.world_day AS world_day, ok.updated_at AS updated_at\nORDER BY coalesce(ok.world_day, -1) DESC, coalesce(ok.updated_at, 0) DESC\nLIMIT $limit;",
		},
		"oral_transmission_timeline": {
			"description": "Trace the lineage chain for an oral knowledge unit",
			"params": {"knowledge_id": "<knowledge_id>", "limit": resolved_limit},
			"cypher": "MATCH (ok:OralKnowledge {knowledge_id: $knowledge_id})\nOPTIONAL MATCH path=(ok)-[:DERIVES_FROM*0..]->(ancestor:OralKnowledge)\nUNWIND nodes(path) AS node\nRETURN DISTINCT node.knowledge_id AS knowledge_id, node.category AS category, node.world_day AS world_day, node.updated_at AS updated_at\nORDER BY node.world_day DESC, node.updated_at DESC\nLIMIT $limit;",
		},
		"ritual_event_participants": {
			"description": "Inspect ritual events that feature an NPC",
			"params": common_params,
			"cypher": "MATCH (n:NPC {npc_id: $npc_id})-[:PARTICIPATED_IN]->(r:RitualEvent)\nWHERE coalesce(r.world_day, -1) <= $world_day\nRETURN r.ritual_id AS ritual_id, r.site_id AS site_id, r.participants AS participants, r.effects AS effects, r.world_day AS world_day\nORDER BY r.world_day DESC, r.updated_at DESC\nLIMIT $limit;",
		},
		"sacred_site_ritual_history": {
			"description": "Fetch ritual events tied to a sacred site",
			"params": {"site_id": "<site_id>", "world_day": resolved_day, "limit": resolved_limit},
			"cypher": "MATCH (r:RitualEvent {site_id: $site_id})\nWHERE coalesce(r.world_day, -1) <= $world_day\nRETURN r.ritual_id AS ritual_id, r.participants AS participants, r.effects AS effects, r.world_day AS world_day, r.updated_at AS updated_at\nORDER BY r.world_day DESC, r.updated_at DESC\nLIMIT $limit;",
		},
		"sacred_site_taboo_log": {
			"description": "Inspect taboos associated with a sacred site",
			"params": {"site_id": "<site_id>"},
			"cypher": "MATCH (s:SacredSite {site_id: $site_id})\nRETURN s.site_id AS site_id, s.site_type AS site_type, s.taboo_ids AS taboo_ids, s.world_day AS world_day, s.updated_at AS updated_at;",
		},
	}
	return {
		"version": version,
		"params": common_params,
		"queries": queries,
	}
