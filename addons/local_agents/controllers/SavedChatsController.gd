@tool
extends Control
class_name LocalAgentsSavedChatsController

@onready var list: ItemList = %SavedConversationsItemList
@onready var delete_button: Button = %DeleteConversationButton

var conversations: Array = []

func _ready() -> void:
    delete_button.pressed.connect(_on_delete_pressed)
    hide()

func add_conversation(name: String, data: Dictionary) -> void:
    conversations.append({"name": name, "data": data})
    _refresh()

func _on_delete_pressed() -> void:
    var selected := list.get_selected_items()
    if selected.size() == 0:
        return
    conversations.remove_at(selected[0])
    _refresh()

func _refresh() -> void:
    list.clear()
    for convo in conversations:
        list.add_item(convo.get("name", "conversation"))

func close_panel() -> void:
    hide()

func _unhandled_input(event: InputEvent) -> void:
    if visible and event.is_action_pressed("ui_cancel"):
        close_panel()
