extends CanvasLayer

signal play_pressed
signal pause_pressed
signal rewind_pressed
signal fast_forward_pressed
signal fork_pressed

@onready var status_label: Label = %StatusLabel

func set_status_text(text: String) -> void:
	status_label.text = text

func _on_play_button_pressed() -> void:
	emit_signal("play_pressed")

func _on_pause_button_pressed() -> void:
	emit_signal("pause_pressed")

func _on_rewind_button_pressed() -> void:
	emit_signal("rewind_pressed")

func _on_fast_forward_button_pressed() -> void:
	emit_signal("fast_forward_pressed")

func _on_fork_button_pressed() -> void:
	emit_signal("fork_pressed")
