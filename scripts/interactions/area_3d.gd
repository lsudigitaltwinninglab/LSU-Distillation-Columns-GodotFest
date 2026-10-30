extends XRToolsInteractableArea

@export var metadata_id: String = ""
@export var part_name: String = ""


func _ready() -> void:
	if metadata_id == "":
		metadata_id = name
	if not pointer_event.is_connected(_forward_pointer_event):
		pointer_event.connect(_forward_pointer_event)


func _forward_pointer_event(event: XRToolsPointerEvent) -> void:
	for child in get_children():
		if child.has_method("pointer_event"):
			child.pointer_event(event)
