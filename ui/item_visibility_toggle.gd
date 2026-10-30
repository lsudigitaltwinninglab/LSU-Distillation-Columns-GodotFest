extends HBoxContainer


@onready var pid_visible: Button = $PIDVisible
@onready var pencil_toggle: Button = $PencilToggle


func _ready() -> void:
	pencil_toggle.toggled.connect(_on_pencil_toggled)
	# Clients only get the pencil; everything else in the menu is host-controlled.
	if multiplayer.multiplayer_peer and not multiplayer.is_server():
		_hide_host_only_controls()


func _on_pid_visible_toggled(toggled_on: bool) -> void:
	MenuControl._on_pid_visible_toggled(toggled_on)


func _on_pencil_toggled(toggled_on: bool) -> void:
	pencil_toggle.text = "Pencil: ON" if toggled_on else "Pencil"
	MenuControl._on_pencil_toggled(toggled_on)


func _hide_host_only_controls() -> void:
	pid_visible.visible = false
	var column := get_parent() as BoxContainer
	if not column:
		return
	for sibling in column.get_children():
		if sibling != self and not sibling is Label:
			sibling.visible = false
	column.alignment = BoxContainer.ALIGNMENT_CENTER
