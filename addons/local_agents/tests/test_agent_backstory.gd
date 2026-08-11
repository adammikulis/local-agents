@tool
extends RefCounted

## Proves a LocalAgent with a backstory service attached actually remembers what was said to it.
##
## This is a wiring test, not a store test. test_backstory_graph_service.gd already covers the store.
## What broke here, and what this exists to catch, is the connection between them: the first version
## recorded every line successfully, returned ok from every call, and recalled NOTHING, because the
## recall reader looked for row keys named `memories`/`results`/`rows` and the one that carries recent
## memories is called `candidates`. Every signal was green and the feature did nothing, which is the
## same shape as the dead `system_prompt` export. So the assertion is on the recalled TEXT, not on any
## call reporting success.
##
## Runs with no model and no llama-server. Semantic recall needs embeddings and is expected to be
## unavailable here, which is precisely why the fallback path is what gets asserted.
## (Explicit types only, project rule: no ':=' inferred typing.)

const AgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")
const SvcScript: GDScript = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")
const ExtensionLoader: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")

const DB_PATH: String = "user://local_agents/test_agent_backstory.sqlite3"
const NPC_ID: String = "test_backstory_npc"

const USER_LINE_1: String = "The relic shard is hidden under the mill."
const AGENT_LINE: String = "I will not tell anyone about the mill."
const USER_LINE_2: String = "My sister is named Mira."


func run_test(tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("NetworkGraph init failed: %s" % ExtensionLoader.get_error())
		return false
	if not ClassDB.class_exists("NetworkGraph"):
		push_error("NetworkGraph class missing after extension init.")
		return false

	# Set the path BEFORE add_child so no default handle is ever opened: _ready() opens the graph, and this
	# test's two clear_backstory_space() calls must land on its own file, never the player's shared
	# user://local_agents/network.sqlite3. This ordering used to be load-bearing and silent — a late call
	# was dropped with a warning and the test wiped the real store while reporting PASS. The service now
	# honours a late set_database_path too (it reopens), so this is belt AND braces rather than the only
	# thing standing between a green test and someone's data.
	var svc: Node = SvcScript.new()
	svc.set_database_path(DB_PATH)
	tree.get_root().add_child(svc)
	svc.clear_backstory_space()

	var agent: Node = AgentScript.new()
	agent.npc_id = NPC_ID
	agent.npc_display_name = "Test NPC"
	agent.backstory = svc
	agent.recall_memories = true
	agent.recall_limit = 8
	tree.get_root().add_child(agent)

	# Drive the ordinary entry points, not the module directly: the wiring is what is under test.
	agent.submit_user_message(USER_LINE_1)
	agent._post_think({"ok": true, "text": AGENT_LINE})
	agent.submit_user_message(USER_LINE_2)

	var ok: bool = true
	var context: String = agent.recall_context("Where is the relic?")

	ok = _assert(context.strip_edges() != "", "recall_context returned nothing; the agent remembers no lines") and ok
	ok = _assert(context.contains(USER_LINE_1), "a user line was not recalled") and ok
	ok = _assert(context.contains(AGENT_LINE), "the agent's own reply was not recalled") and ok
	ok = _assert(context.contains(USER_LINE_2), "the second user line was not recalled") and ok

	# Recall must stay opt-in: a game that never asked for it should not be paying tokens for it.
	agent.recall_memories = false
	ok = _assert(agent.recall_context("Where is the relic?") == "",
		"recall_context returned text with recall_memories off") and ok

	# An agent with no service attached must be silent rather than erroring, since that is the default.
	var bare: Node = AgentScript.new()
	tree.get_root().add_child(bare)
	bare.recall_memories = true
	ok = _assert(bare.recall_context("anything") == "", "an unattached agent recalled something") and ok
	bare.queue_free()

	svc.clear_backstory_space()
	agent.queue_free()
	svc.queue_free()
	if FileAccess.file_exists(DB_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DB_PATH))

	if ok:
		print("Agent backstory wiring test passed (%d chars recalled over 3 turns)" % context.length())
	return ok


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
