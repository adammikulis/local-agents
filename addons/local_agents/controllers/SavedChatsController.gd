@tool
extends Control
class_name LocalAgentsSavedChatsController

signal conversation_selected(conversation_id)
signal conversation_deleted(conversation_id)
signal close_requested()

@onready var list: ItemList = %SavedConversationsItemList
@onready var select_button: Button = %SelectConversationButton
@onready var delete_button: Button = %DeleteConversationButton
@onready var close_button: Button = %CloseButton

var conversations: Array = []

func _ready() -> void:
    list.item_activated.connect(_on_item_activated)
    list.item_selected.connect(_on_item_selected)
    select_button.pressed.connect(_emit_selected_conversation)
    delete_button.pressed.connect(_on_delete_pressed)
    close_button.pressed.connect(_on_close_pressed)
    hide()

func set_conversations(items: Array) -> void:
    conversations = items.duplicate(true)
    _refresh()

func _refresh() -> void:
    list.clear()
    for convo in conversations:
        var label: String = convo.get("title", convo.get("name", "conversation"))
        list.add_item(label)
    _update_buttons()

func _on_item_selected(_index: int) -> void:
    _update_buttons()

func _on_item_activated(index: int) -> void:
    _emit_selected_conversation(index)

func _emit_selected_conversation(index: int = -1) -> void:
    if index == -1:
        var selected := list.get_selected_items()
        if selected.is_empty():
            return
        index = selected[0]
    if index < 0 or index >= conversations.size():
        return
    var convo_id: int = conversations[index].get("id", index)
    emit_signal("conversation_selected", convo_id)

func _on_delete_pressed() -> void:
    var selected := list.get_selected_items()
    if selected.is_empty():
        return
    var index := selected[0]
    if index < 0 or index >= conversations.size():
        return
    var convo_id: int = conversations[index].get("id", index)
    conversations.remove_at(index)
    _refresh()
    emit_signal("conversation_deleted", convo_id)

func _on_close_pressed() -> void:
    hide()
    emit_signal("close_requested")

func close_panel() -> void:
    hide()

func _update_buttons() -> void:
    var has_selection := not list.get_selected_items().is_empty()
    select_button.disabled = not has_selection
    delete_button.disabled = not has_selection

func _unhandled_input(event: InputEvent) -> void:
    if visible and event.is_action_pressed("ui_cancel"):
        close_panel()
