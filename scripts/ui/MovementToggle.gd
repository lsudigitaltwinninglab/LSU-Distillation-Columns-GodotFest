extends HBoxContainer


@onready var controller_activated: Button = $ControllerActivated

var button_group: ButtonGroup


func _ready() -> void:
	button_group = ButtonGroup.new()
	for child in get_children():
		if child is Button:
			child.toggle_mode = true
			child.button_group = button_group


func _on_controller_activated_toggled(toggled_on: bool) -> void:
	if toggled_on:
		MenuControl._on_movement_controller_activated(false)
		MenuControl._on_toy_model_mode_activated(false)


func _on_toy_model_mode_toggled(toggled_on: bool) -> void:
	if toggled_on:
		MenuControl._on_movement_controller_activated(true)
		MenuControl._on_toy_model_mode_activated(true)
