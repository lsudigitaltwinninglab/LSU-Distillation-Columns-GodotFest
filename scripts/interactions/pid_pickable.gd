extends XRToolsPickable

## Clipboard-style distillery P&ID — grip to grab, read while held, trigger for hotspots.
## Physics body does not block the player; pointer areas remain interactable.

const POINTER_LAYER := 1048577


func _ready() -> void:
	super._ready()
	call_deferred("_configure_non_blocking_physics")


func _configure_non_blocking_physics() -> void:
	collision_mask = 0
	for body in get_tree().get_nodes_in_group("player_body"):
		if body is PhysicsBody3D:
			add_collision_exception_with(body)


func pick_up(by: Node3D) -> void:
	super.pick_up(by)
	_ensure_hotspot_layers(true)


func let_go(by: Node3D, p_linear_velocity: Vector3, p_angular_velocity: Vector3) -> void:
	super.let_go(by, p_linear_velocity, p_angular_velocity)
	collision_mask = 0
	if visible:
		_ensure_hotspot_layers(true)


func _ensure_hotspot_layers(_enable: bool) -> void:
	_recurse_hotspot_layers(self)


func _recurse_hotspot_layers(node: Node) -> void:
	for child in node.get_children():
		if child is Area3D:
			child.monitorable = true
			child.collision_layer = POINTER_LAYER
		_recurse_hotspot_layers(child)
