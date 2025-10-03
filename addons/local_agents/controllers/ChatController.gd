@tool
extends Control
class_name LocalAgentsChatController

signal prompt_input_received(text)

const DEFAULT_STORE := preload("res://addons/local_agents/controllers/ConversationStore.gd")

@onready var _model_option: OptionButton = %ModelOptionButton
@onready var _manage_model_button: Button = %ManageModelButton
@onready var _inference_option: OptionButton = %InferenceOptionButton
@onready var _manage_inference_button: Button = %ManageInferenceButton
@onready var _load_model_button: Button = %LoadModelButton
@onready var _saved_chats_button: Button = %SavedChatsButton
@onready var _status_label: Label = %StatusLabel
@onready var _conversation_status_label: Label = %ConversationStatusLabel
@onready var _conversation_list: ItemList = %ConversationList
@onready var _new_conversation_button: Button = %NewConversationButton
@onready var _rename_conversation_button: Button = %RenameConversationButton
@onready var _delete_conversation_button: Button = %DeleteConversationButton
@onready var _conversation_graph: Tree = %ConversationGraph
@onready var _history_label: RichTextLabel = %ModelOutputRichTextLabel
@onready var _prompt_edit: TextEdit = %PromptTextEdit
@onready var _send_button: Button = %SendButton
@onready var _clear_button: Button = %ClearButton
@onready var _model_config_window: Window = %ModelConfigWindow
@onready var _inference_config_window: Window = %InferenceConfigWindow
@onready var _saved_chats_window: Window = %SavedChatsWindow
@onready var _saved_chats_controller: LocalAgentsSavedChatsController = %SavedChatsController
@onready var _rename_window: Window = %RenameConversationWindow
@onready var _rename_line_edit: LineEdit = %RenameLineEdit
@onready var _rename_cancel_button: Button = %RenameCancelButton
@onready var _rename_confirm_button: Button = %RenameConfirmButton

var _conversation_store: Node
var _conversation_index: Array = []
var _selected_conversation_id: int = -1
var _manager: LocalAgentsAgentManager
var _agent: LocalAgentsAgent
var _is_generating := false

func _ready() -> void:
    _connect_ui()
    _ensure_conversation_store()
    _ensure_manager()
    _refresh_configs()
    _refresh_conversations()
    _update_state_labels()

func _connect_ui() -> void:
    _model_option.item_selected.connect(_on_model_selected)
    _manage_model_button.pressed.connect(func(): _toggle_window(_model_config_window))
    _inference_option.item_selected.connect(_on_inference_selected)
    _manage_inference_button.pressed.connect(func(): _toggle_window(_inference_config_window))
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
    _conversation_store = get_node_or_null("/root/ConversationStore")
    if _conversation_store == null:
        _conversation_store = DEFAULT_STORE.new()
        _conversation_store.name = "ConversationStore"
        get_tree().root.add_child(_conversation_store)
        _conversation_store.owner = null

func _ensure_manager() -> void:
    _manager = get_node_or_null("/root/AgentManager")
    if _manager:
        _manager.agent_ready.connect(_on_agent_ready)
        _manager.configs_updated.connect(_refresh_configs)
        if _manager.agent:
            _on_agent_ready(_manager.agent)

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
        var cfg = configs[idx]
        var label := cfg.get(label_field, "config %d" % idx)
        button.add_item(label, idx)
    button.select(0)

func _refresh_conversations() -> void:
    if not _conversation_store:
        return
    var desired_id := _selected_conversation_id
    _conversation_index = []
    var raw_list: Array = _conversation_store.list_conversations()
    for i in raw_list.size():
        var entry := raw_list[i]
        if not entry.has("id"):
            entry = entry.duplicate(true)
            entry["id"] = entry.get("conversation_id", i)
        _conversation_index.append(entry)
    _conversation_index.sort_custom(Callable(self, "_sort_conversation_index"))
    _conversation_list.clear()
    for convo in _conversation_index:
        var title := _get_conversation_title_from_entry(convo)
        _conversation_list.add_item(title)
    _saved_chats_controller.set_conversations(_conversation_index)
    if _conversation_index.is_empty():
        if _conversation_store.has_method("create_conversation"):
            var created := _conversation_store.create_conversation("Conversation 1")
            _conversation_index = [created]
            _conversation_list.add_item(created.get("title", "Conversation"))
        else:
            var fallback_entry := {"id": 0, "title": "Conversation"}
            _conversation_index = [fallback_entry]
            _conversation_list.add_item("Conversation")
    var selected_index := 0
    if desired_id != -1:
        for idx in _conversation_index.size():
            if _conversation_index[idx].get("id", -1) == desired_id:
                selected_index = idx
                break
    _conversation_list.select(selected_index)
    _selected_conversation_id = _conversation_index[selected_index].get("id", selected_index)
    _load_conversation(_selected_conversation_id)

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
    var default_model := _agent.agent_node.get_default_model_path()
    var ok := _agent.agent_node.load_model(default_model, {})
    var status_text := "Model loaded" if ok else "Failed to load model"
    _update_status(status_text)
    _update_state_labels()

func _on_saved_chats_pressed() -> void:
    _saved_chats_window.popup()

func _on_conversation_selected(index: int) -> void:
    if index < 0 or index >= _conversation_index.size():
        return
    _selected_conversation_id = _conversation_index[index].get("id", index)
    _load_conversation(_selected_conversation_id)

func _on_conversation_activated(index: int) -> void:
    _on_conversation_selected(index)

func _on_new_conversation_pressed() -> void:
    if not _conversation_store:
        return
    var title := "Conversation %d" % (_conversation_index.size() + 1)
    var convo := {}
    if _conversation_store.has_method("create_conversation"):
        convo = _conversation_store.create_conversation(title)
    _selected_conversation_id = convo.get("id", -1)
    _refresh_conversations()

func _on_rename_conversation_pressed() -> void:
    if _selected_conversation_id == -1:
        return
    var current_title := _get_conversation_title(_selected_conversation_id)
    _rename_line_edit.text = current_title
    _rename_window.popup()
    _rename_line_edit.grab_focus()

func _on_rename_confirmed() -> void:
    if _selected_conversation_id == -1 or not _conversation_store:
        _rename_window.hide()
        return
    var new_title := _rename_line_edit.text.strip_edges()
    if new_title.is_empty():
        _rename_window.hide()
        return
    _apply_conversation_title(_selected_conversation_id, new_title)
    _rename_window.hide()

func _on_delete_conversation_pressed() -> void:
    if _selected_conversation_id == -1 or not _conversation_store:
        return
    if _conversation_index.size() <= 1:
        _update_status("Cannot delete the last conversation")
        return
    if _conversation_store.has_method("delete_conversation"):
        _conversation_store.delete_conversation(_selected_conversation_id)
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
    _add_message_to_store("user", text)
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
        return
    _is_generating = true
    _update_status("Thinking…")
    _update_send_button_state()
    var result := _agent.think(prompt)
    if result.get("ok", false):
        var text := result.get("text", "").strip_edges()
        if not text.is_empty():
            _add_message_to_store("assistant", text)
            _append_to_history("[color=#6ab0ff][b]Agent[/b][/color]: %s" % text)
    else:
        _update_status("Generation failed: %s" % result.get("error", "unknown"))
    _is_generating = false
    _update_status("Idle")
    _update_send_button_state()
    _refresh_graph()

func _add_message_to_store(role: String, content: String) -> void:
    if not _conversation_store or _selected_conversation_id == -1:
        return
    if _conversation_store.has_method("append_message"):
        _conversation_store.append_message(_selected_conversation_id, role, content)
    _refresh_graph()

func _append_to_history(text: String) -> void:
    _history_label.append_text("%s\n" % text)
    _history_label.scroll_active = true

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
    if not _conversation_store:
        return
    var convo := _conversation_store.load_conversation(conversation_id)
    _history_label.clear()
    var messages: Array = convo.get("messages", [])
    messages.sort_custom(Callable(self, "_sort_messages"))
    for message in messages:
        var role := message.get("role", "user")
        if role == "system":
            continue
        var label: String = "Agent" if role == "assistant" else role.capitalize()
        _append_to_history("[b]%s[/b]: %s" % [label, message.get("content", "")])
    _selected_conversation_id = conversation_id
    _refresh_graph_with_conversation(convo)
    _update_state_labels()

func _refresh_graph() -> void:
    if _selected_conversation_id == -1:
        return
    var convo := _conversation_store.load_conversation(_selected_conversation_id)
    _refresh_graph_with_conversation(convo)

func _refresh_graph_with_conversation(convo: Dictionary) -> void:
    _conversation_graph.clear()
    var root := _conversation_graph.create_item()
    root.set_text(0, convo.get("title", "Conversation"))
    for message in convo.get("messages", []):
        var item := _conversation_graph.create_item(root)
        item.set_text(0, "%s #%d" % [message.get("role", "user"), message.get("order", 0)])
        item.set_metadata(0, message)

func _get_conversation_title(conversation_id: int) -> String:
    for convo in _conversation_index:
        if convo.get("id", -1) == conversation_id:
            return _get_conversation_title_from_entry(convo)
    return "Conversation"

func _get_conversation_title_from_entry(entry: Dictionary) -> String:
    if entry.has("title"):
        return entry["title"]
    if entry.has("name"):
        return entry["name"]
    return "Conversation"

func _apply_conversation_title(conversation_id: int, new_title: String) -> void:
    if not _conversation_store:
        return
    if _conversation_store.has_method("rename_conversation"):
        _conversation_store.rename_conversation(conversation_id, new_title)
    else:
        if _conversation_store.has_method("append_message"):
            _conversation_store.append_message(conversation_id, "system", "rename:%s" % new_title, {"title": new_title})
    for entry in _conversation_index:
        if entry.get("id", -1) == conversation_id:
            entry["title"] = new_title
    _refresh_conversations()

func _on_saved_chat_selected(conversation_id: int) -> void:
    for idx in _conversation_index.size():
        if _conversation_index[idx].get("id", -1) == conversation_id:
            _conversation_list.select(idx)
            _on_conversation_selected(idx)
            break
    _saved_chats_window.hide()

func _on_saved_chat_deleted(conversation_id: int) -> void:
    if not _conversation_store:
        return
    if _conversation_store.has_method("delete_conversation"):
        _conversation_store.delete_conversation(conversation_id)
    _refresh_conversations()

func _update_status(text: String) -> void:
    _status_label.text = text

func _update_state_labels() -> void:
    var convo_name := _get_conversation_title(_selected_conversation_id)
    _conversation_status_label.text = convo_name
    var model_loaded := _agent and _agent.agent_node and _agent.agent_node.get_default_model_path() != ""
    _load_model_button.disabled = not _agent
    _status_label.text = "Model ready" if model_loaded else "Model not loaded"
    _update_send_button_state()

func _toggle_window(window: Window) -> void:
    if window.visible:
        window.hide()
    else:
        window.popup()

func _sort_conversation_index(a: Dictionary, b: Dictionary) -> bool:
    return int(a.get("created_at", 0)) < int(b.get("created_at", 0))

func _sort_messages(a: Dictionary, b: Dictionary) -> bool:
    return int(a.get("order", 0)) < int(b.get("order", 0))
