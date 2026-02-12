extends RefCounted
class_name LocalAgentsConversationHistoryService

func append_to_history(history_label: RichTextLabel, text: String) -> void:
    history_label.append_text("%s\n" % text)
    history_label.scroll_active = true

func render_conversation(history_label: RichTextLabel, messages: Array) -> void:
    history_label.clear()
    for message_variant in messages:
        var message: Dictionary = {}
        if message_variant is Dictionary:
            message = message_variant
        var role := message.get("role", "user")
        if role == "system":
            continue
        var label: String = "Agent" if role == "assistant" else role.capitalize()
        append_to_history(history_label, "[b]%s[/b]: %s" % [label, message.get("content", "")])

func sorted_messages_from_conversation(convo: Dictionary) -> Array:
    var messages_variant := convo.get("messages", [])
    var messages: Array = []
    if messages_variant is Array:
        messages = messages_variant
    messages.sort_custom(Callable(self, "sort_messages"))
    return messages

func build_agent_history(messages: Array) -> Array:
    var filtered: Array = []
    for message_variant in messages:
        var message: Dictionary = {}
        if message_variant is Dictionary:
            message = message_variant
        else:
            continue
        var role_value := message.get("role", "")
        var content_value := message.get("content", "")
        var role := role_value as String if role_value is String else str(role_value)
        var content := content_value as String if content_value is String else str(content_value)
        if role == "system" or content.strip_edges().is_empty():
            continue
        filtered.append({
            "role": role,
            "content": content,
        })
    return filtered

func sort_messages(a: Dictionary, b: Dictionary) -> bool:
    return int(a.get("order", 0)) < int(b.get("order", 0))
