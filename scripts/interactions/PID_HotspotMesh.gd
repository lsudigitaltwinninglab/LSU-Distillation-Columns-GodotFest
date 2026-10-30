extends MeshInstance3D

signal clicked(mesh_name: String)


func _ready() -> void:
	call_deferred("_connect_area")


func _connect_area() -> void:
	for child in get_children():
		if child is XRToolsInteractableArea:
			if not child.pointer_event.is_connected(_on_xr_tools_interactable_area_pointer_event):
				child.pointer_event.connect(_on_xr_tools_interactable_area_pointer_event)
			break


func _on_xr_tools_interactable_area_pointer_event(event: XRToolsPointerEvent) -> void:
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		clicked.emit(name)
