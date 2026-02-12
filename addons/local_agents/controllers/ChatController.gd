@tool
extends Control
class_name LocalAgentsChatController

signal prompt_input_received(text)

const DEFAULT_STORE := preload("res://addons/local_agents/controllers/ConversationStore.gd")
const ConversationSessionService := preload("res://addons/local_agents/controllers/services/ConversationSessionService.gd")
const ConversationHistoryService := preload("res://addons/local_agents/controllers/services/ConversationHistoryService.gd")
const RuntimeHealth := preload("res://addons/local_agents/runtime/RuntimeHealth.gd")

@onready var _model_option: OptionButton = %ModelOptionButton
@onready var _manage_model_button: Button = %ManageModelButton
@onready var _inference_option: OptionButton = %InferenceOptionButton
@onready var _manage_inference_button: Button = %ManageInferenceButton
@onready var _load_model_button: Button = %LoadModelButton
@onready var _saved_chats_button: Button = %SavedChatsButton
@onready var _status_label: Label = %StatusLabel
@onready var _conversation_status_label: Label = %ConversationStatusLabel
@onready var _runtime_state_label: Label = %RuntimeStateLabel
@onready var _speech_state_label: Label = %SpeechStateLabel
@onready var _conversation_list: ItemList = %ConversationList
@onready var _new_conversation_button: Button = %NewConversationButton
@onready var _rename_conversation_button: Button = %RenameConversationButton
@onready var _delete_conversation_button: Button = %DeleteConversationButton
@onready var _conversation_graph: Tree = %ConversationGraph
@onready var _history_label: RichTextLabel = %ModelOutputRichTextLabel
@onready var _prompt_edit: TextEdit = %PromptTextEdit
@onready var _send_button: Button = %SendButton
@onready var _clear_button: Button = %ClearButton
@onready var _saved_chats_window: Window = %SavedChatsWindow
@onready var _saved_chats_controller: LocalAgentsSavedChatsController = %SavedChatsController
@onready var _rename_window: Window = %RenameConversationWindow
@onready var _rename_line_edit: LineEdit = %RenameLineEdit
@onready var _rename_cancel_button: Button = %RenameCancelButton
@onready var _rename_confirm_button: Button = %RenameConfirmButton

var _tab_container: TabContainer
var _configuration_panel: LocalAgentsConfigurationPanel
var _conversation_session_service
var _conversation_history_service
var _manager: LocalAgentsAgentManager
var _agent: LocalAgentsAgent
var _is_generating := false
var _status_text := "Idle"

func _ready() -> void:
	_conversation_session_service = ConversationSessionService.new()
	_conversation_history_service = ConversationHistoryService.new()
	_tab_container = _locate_tab_container()
	_configuration_panel = _get_configuration_panel()
	_connect_ui()
	_ensure_conversation_store()
	_ensure_manager()
	_refresh_configs()
	_refresh_conversations()
	_update_state_labels()

func _connect_ui() -> void:
	_model_option.item_selected.connect(_on_model_selected)
	_manage_model_button.pressed.connect(func(): _open_configuration_panel("model"))
	_inference_option.item_selected.connect(_on_inference_selected)
	_manage_inference_button.pressed.connect(func(): _open_configuration_panel("inference"))
	_load_model_button.pressed.connect(_on_load_model_pressed)
	_saved_chats_button.pressed.connect(_on_saved_chats_pressed)
	_conversation_list.item_selected.connect(_on_conversation_selected)
	_conversation_list.item_activated.connect(_on_conversation_activated)
	_new_conversation_button.pressed.connect(_on_new_conversation_pressed)
	_rename_conversation_button.pressed.connect(_on_rename_conversation_pressed)
	_delete_conversation_button.pressed.connect(_on_delete_conversation_pressed)
	_send_button.pressed.connect(_on_send_pressed)
	_clear_button.pressed.connect(_on_clear_pressed)
	_prompt_edit.text_changed.connect(_update_send_button_state)
	_prompt_edit.gui_input.connect(_on_prompt_gui_input)
	_saved_chats_controller.conversation_selected.connect(_on_saved_chat_selected)
	_saved_chats_controller.conversation_deleted.connect(_on_saved_chat_deleted)
	_saved_chats_controller.close_requested.connect(func(): _saved_chats_window.hide())
	_rename_cancel_button.pressed.connect(func(): _rename_window.hide())
	_rename_confirm_button.pressed.connect(_on_rename_confirmed)

func _ensure_conversation_store() -> void:
	_conversation_session_service.ensure_conversation_store(get_tree(), DEFAULT_STORE)

func _ensure_manager() -> void:
	_manager = get_node_or_null("/root/AgentManager")
	if _manager:
		_manager.agent_ready.connect(_on_agent_ready)
		_manager.configs_updated.connect(_refresh_configs)
		if _manager.agent:
			_on_agent_ready(_manager.agent)

func _locate_tab_container() -> TabContainer:
	var node: Node = get_parent()
	while node and not (node is TabContainer):
		node = node.get_parent()
	return node as TabContainer

func _get_configuration_panel() -> LocalAgentsConfigurationPanel:
	if not _tab_container:
		return null
	var panel_node := _tab_container.get_node_or_null("Configuration")
	if panel_node and panel_node is LocalAgentsConfigurationPanel:
		return panel_node
	return null

func _open_configuration_panel(section: String) -> void:
	if not is_instance_valid(_tab_container):
		_tab_container = _locate_tab_container()
	if not is_instance_valid(_configuration_panel):
		_configuration_panel = _get_configuration_panel()
	if not _tab_container or not _configuration_panel:
		push_warning("Configuration tab unavailable")
		return
	_configuration_panel.refresh_configs()
	var tab_index := _tab_container.get_tab_idx_from_control(_configuration_panel)
	if tab_index != -1:
		_tab_container.current_tab = tab_index
	match section:
		"model":
			_configuration_panel.focus_model()
		"inference":
			_configuration_panel.focus_inference()

func _on_agent_ready(agent: LocalAgentsAgent) -> void:
	if _agent:
		if _agent.model_output_received.is_connected(_on_model_output_received):
			_agent.model_output_received.disconnect(_on_model_output_received)
		if _agent.message_emitted.is_connected(_on_agent_message):
			_agent.message_emitted.disconnect(_on_agent_message)
	_agent = agent
	if _agent:
		_agent.model_output_received.connect(_on_model_output_received)
		_agent.message_emitted.connect(_on_agent_message)
		_sync_agent_with_current_conversation()
	_update_state_labels()

func _refresh_configs() -> void:
	if not _manager:
		return
	_populate_option_button(_model_option, _manager.get_model_configs(), "model_config_name")
	_populate_option_button(_inference_option, _manager.get_inference_configs(), "inference_config_name")
	_update_state_labels()

func _populate_option_button(button: OptionButton, configs: Array, label_field: String) -> void:
	button.clear()
	if configs.is_empty():
		button.add_item("No presets", -1)
		button.disabled = true
		return
	button.disabled = false
	for idx in configs.size():
		var cfg_variant: Variant = configs[idx]
		var cfg: Dictionary = {}
		if cfg_variant is Dictionary:
			cfg = cfg_variant
		var label_value := cfg.get(label_field, "config %d" % idx)
		var label: String = label_value as String if label_value is String else str(label_value)
		button.add_item(label, idx)
	button.select(0)

func _refresh_conversations() -> void:
	var state: Dictionary = _conversation_session_service.refresh_conversations()
	var conversation_index_variant: Variant = state.get("index", [])
	var conversation_index: Array = conversation_index_variant if conversation_index_variant is Array else []
	var selected_index: int = int(state.get("selected_index", -1))
	var selected_id: int = int(state.get("selected_id", -1))
	if selected_index == -1 or selected_id == -1:
		return
	_conversation_list.clear()
	for convo in conversation_index:
		var title := _conversation_session_service.get_conversation_title_from_entry(convo)
		_conversation_list.add_item(title)
	_saved_chats_controller.set_conversations(conversation_index)
	_conversation_list.select(selected_index)
	_load_conversation(selected_id)

func _on_model_selected(index: int) -> void:
	if not _manager:
		return
	var configs := _manager.get_model_configs()
	if index < 0 or index >= configs.size():
		return
	_manager.apply_model_config(configs[index])

func _on_inference_selected(index: int) -> void:
	if not _manager:
		return
	var configs := _manager.get_inference_configs()
	if index < 0 or index >= configs.size():
		return
	_manager.apply_inference_config(configs[index])

func _on_load_model_pressed() -> void:
	if not _agent:
		_update_status("Agent is not ready")
		return
	if _agent.agent_node == null:
		_update_status("Agent runtime unavailable")
		return
	var default_model: String = _agent.agent_node.get_default_model_path()
	if default_model.strip_edges() == "":
		_update_status("No default model configured")
		return
	var ok: bool = _agent.agent_node.load_model(default_model, {})
	var status_text := "Model loaded" if ok else "Failed to load model"
	_update_status(status_text)
	_update_state_labels()

func _on_saved_chats_pressed() -> void:
	_saved_chats_window.popup()

func _on_conversation_selected(index: int) -> void:
	var conversation_id := _conversation_session_service.select_conversation_by_list_index(index)
	if conversation_id == -1:
		return
	_load_conversation(conversation_id)

func _on_conversation_activated(index: int) -> void:
	_on_conversation_selected(index)

func _on_new_conversation_pressed() -> void:
	_conversation_session_service.create_conversation()
	_refresh_conversations()

func _on_rename_conversation_pressed() -> void:
	var selected_conversation_id := _conversation_session_service.get_selected_conversation_id()
	if selected_conversation_id == -1:
		return
	var current_title := _conversation_session_service.get_conversation_title(selected_conversation_id)
	_rename_line_edit.text = current_title
	_rename_window.popup()
	_rename_line_edit.grab_focus()

func _on_rename_confirmed() -> void:
	var selected_conversation_id := _conversation_session_service.get_selected_conversation_id()
	if selected_conversation_id == -1:
		_rename_window.hide()
		return
	var new_title := _rename_line_edit.text.strip_edges()
	if new_title.is_empty():
		_rename_window.hide()
		return
	_conversation_session_service.apply_conversation_title(selected_conversation_id, new_title)
	_refresh_conversations()
	_rename_window.hide()

func _on_delete_conversation_pressed() -> void:
	var result: Dictionary = _conversation_session_service.delete_selected_conversation()
	if not result.get("ok", false):
		var error_value: Variant = result.get("error", "")
		var error_text: String = error_value as String if error_value is String else str(error_value)
		if not error_text.is_empty():
			_update_status(error_text)
		return
	_refresh_conversations()

func _on_send_pressed() -> void:
	if _is_generating:
		return
	var text := _prompt_edit.text.strip_edges()
	if text.is_empty():
		return
	_prompt_edit.text = ""
	_update_send_button_state()
	emit_signal("prompt_input_received", text)
	_add_message_to_store("user", text, false)
	_append_to_history("[b]You[/b]: %s" % text)
	_invoke_agent(text)

func _on_clear_pressed() -> void:
	_prompt_edit.text = ""
	_update_send_button_state()

func _update_send_button_state() -> void:
	_send_button.disabled = _prompt_edit.text.strip_edges().is_empty() or _is_generating

func _on_prompt_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and event.ctrl_pressed:
			_on_send_pressed()

func _invoke_agent(prompt: String) -> void:
	if not _agent:
		_update_status("Agent not ready")
		_refresh_graph()
		return
	_is_generating = true
	_update_status("Thinking…")
	_update_send_button_state()
	var result: Dictionary = _agent.think(prompt)
	if result.get("ok", false):
		var text_value: Variant = result.get("text", "")
		var text: String = text_value as String if text_value is String else str(text_value)
		text = text.strip_edges()
		if not text.is_empty():
			_add_message_to_store("assistant", text)
			_append_to_history("[color=#6ab0ff][b]Agent[/b][/color]: %s" % text)
	else:
		_update_status("Generation failed: %s" % result.get("error", "unknown"))
	_is_generating = false
	_update_status("Idle")
	_update_send_button_state()
	_refresh_graph()

func _add_message_to_store(role: String, content: String, update_graph: bool = true) -> void:
	_conversation_session_service.append_message(role, content)
	if update_graph:
		_refresh_graph()

func _append_to_history(text: String) -> void:
	_conversation_history_service.append_to_history(_history_label, text)

func _on_model_output_received(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	_append_to_history("[color=#6ab0ff][b]Agent[/b][/color]: %s" % text)
	_add_message_to_store("assistant", text)

func _on_agent_message(role: String, content: String) -> void:
	if role == "system":
		return
	var label: String = "Agent" if role == "assistant" else role.capitalize()
	_append_to_history("[b]%s[/b]: %s" % [label, content])

func _load_conversation(conversation_id: int) -> void:
	var convo: Dictionary = _conversation_session_service.load_conversation(conversation_id)
	var messages := _conversation_history_service.sorted_messages_from_conversation(convo)
	_sync_agent_with_messages(messages)
	_conversation_history_service.render_conversation(_history_label, messages)
	_conversation_session_service.set_selected_conversation_id(conversation_id)
	_refresh_graph_with_conversation(convo)
	_update_state_labels()

func _refresh_graph() -> void:
	var selected_conversation_id := _conversation_session_service.get_selected_conversation_id()
	if selected_conversation_id == -1:
		return
	var convo: Dictionary = _conversation_session_service.load_conversation(selected_conversation_id)
	var messages := _conversation_history_service.sorted_messages_from_conversation(convo)
	_sync_agent_with_messages(messages)
	_refresh_graph_with_conversation(convo)

func _refresh_graph_with_conversation(convo: Dictionary) -> void:
	_conversation_graph.clear()
	var root := _conversation_graph.create_item()
	root.set_text(0, convo.get("title", "Conversation"))
	var convo_messages_variant := convo.get("messages", [])
	var convo_messages: Array = []
	if convo_messages_variant is Array:
		convo_messages = convo_messages_variant
	for message_variant in convo_messages:
		var message: Dictionary = {}
		if message_variant is Dictionary:
			message = message_variant
		var item := _conversation_graph.create_item(root)
		item.set_text(0, "%s #%d" % [message.get("role", "user"), message.get("order", 0)])
		item.set_metadata(0, message)

func _on_saved_chat_selected(conversation_id: int) -> void:
	var index := _conversation_session_service.find_list_index_for_conversation_id(conversation_id)
	if index != -1:
		_conversation_list.select(index)
		_on_conversation_selected(index)
	_saved_chats_window.hide()

func _on_saved_chat_deleted(conversation_id: int) -> void:
	_conversation_session_service.delete_conversation(conversation_id)
	_refresh_conversations()

func _update_status(text: String) -> void:
	_status_text = text
	_status_label.text = _status_text

func _update_state_labels() -> void:
	var selected_conversation_id := _conversation_session_service.get_selected_conversation_id()
	var convo_name := _conversation_session_service.get_conversation_title(selected_conversation_id)
	_conversation_status_label.text = convo_name
	var model_loaded: bool = _agent != null and _agent.agent_node != null and _agent.agent_node.get_default_model_path() != ""
	_load_model_button.disabled = _agent == null
	_status_label.text = _status_text

	var runtime_state := RuntimeHealth.summarize()
	if _runtime_state_label:
		_runtime_state_label.text = runtime_state.get("runtime", "Runtime: unknown")
	if _speech_state_label:
		_speech_state_label.text = runtime_state.get("speech", "Speech: unknown")
	_update_send_button_state()

func _sync_agent_with_messages(messages: Array) -> void:
	if not _agent or not _agent.has_method("set_history"):
		return
	var filtered := _conversation_history_service.build_agent_history(messages)
	_agent.set_history(filtered)

func _sync_agent_with_current_conversation() -> void:
	var convo: Dictionary = _conversation_session_service.load_selected_conversation()
	if convo.is_empty():
		return
	var messages := _conversation_history_service.sorted_messages_from_conversation(convo)
	_sync_agent_with_messages(messages)
