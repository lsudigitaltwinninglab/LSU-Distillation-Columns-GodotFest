extends Node3D

## Plant geometry visibility layers — toggled via MenuControl signals.
##
## Layers controlled:
## - PickablePID: distillery P&ID panel (pid_visible_toggled)
##
## In multiplayer, host menu changes → ModelSyncManager RPC → MenuControl signal → here.

@export var pid_distance : float = 1.15 # arm's-length spawn distance
@export var pid_height : float = -0.05 # slight downward tilt for reading
@export var pid_menu_offset_distance: float = 0.65
@export var pid_right_offset: float = 0.35
@export var pid_hide_position: Vector3 = Vector3(0.0, -100.0, 0.0)

@onready var pickable_pid: XRToolsPickable = get_node_or_null("PickablePID")


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Add to group for multiplayer model-relative positioning
	add_to_group("scene_collection")
	if MenuControl.has_signal("pid_visible_toggled"):
		MenuControl.connect("pid_visible_toggled", Callable(self, "_on_pid_visible_toggled"))
	else:
		print("pid_visible_toggled not found!")

	call_deferred("_apply_startup_visibility")


func _apply_startup_visibility() -> void:
	# Match menu_control.tscn defaults (P&ID off).
	_on_pid_visible_toggled(false)


func _on_pid_visible_toggled(toggled_on: bool) -> void:
	if not pickable_pid:
		return
	pickable_pid.visible = toggled_on
	# Toggle on/off all collosions with visibility
	_set_pid_collisions(toggled_on)
	# Hidden: take it out of physics entirely. It is a child of the model, so the hide position below
	# moves and shrinks with it in toy mode (ending up right under the model) — that alone isn't enough.
	pickable_pid.process_mode = Node.PROCESS_MODE_INHERIT if toggled_on else Node.PROCESS_MODE_DISABLED
	
	if toggled_on:
		call_deferred("_position_pid_in_front")
	else:
		call_deferred("_hide_pid_position") # Positions P&ID to not interact with Player in Hidden state


func _position_pid_in_front() -> void:
	if not pickable_pid:
		return
	
	# Freeze physics during positioning to prevent collision spinning
	if pickable_pid is RigidBody3D:
		pickable_pid.freeze = true
		# Also reset any existing velocities
		pickable_pid.linear_velocity = Vector3.ZERO
		pickable_pid.angular_velocity = Vector3.ZERO
	
	var menu_node := get_tree().current_scene.get_node_or_null("XROrigin3D/Viewport2Din3D_Menu") as Node3D
	var camera := get_tree().get_first_node_in_group("xr_camera") as Node3D
	if not menu_node and not camera:
		# Unfreeze if we can't position
		if pickable_pid is RigidBody3D:
			pickable_pid.freeze = false
		return

	var anchor_transform: Transform3D = menu_node.global_transform if menu_node else camera.global_transform
	var forward_dir := -anchor_transform.basis.z
	var right_dir := anchor_transform.basis.x
	forward_dir.y = 0.0
	right_dir.y = 0.0
	if forward_dir.length() > 0.01:
		forward_dir = forward_dir.normalized()
	if right_dir.length() > 0.01:
		right_dir = right_dir.normalized()
	var target_pos: Vector3
	if menu_node:
		target_pos = anchor_transform.origin - (forward_dir * pid_menu_offset_distance) + (right_dir * pid_right_offset)
	else:
		target_pos = anchor_transform.origin + (forward_dir * pid_distance) + (right_dir * pid_right_offset) + Vector3.UP * pid_height
	pickable_pid.global_transform.origin = target_pos
	pickable_pid.look_at(anchor_transform.origin, Vector3.UP)
	pickable_pid.rotate_object_local(Vector3.UP, PI)
	# Slight tilt so the diagram reads naturally at arm's length before grabbing.
	pickable_pid.rotate_object_local(Vector3.RIGHT, deg_to_rad(-8.0))
	
	# Unfreeze after positioning (with a small delay to let physics settle)
	if pickable_pid is RigidBody3D:
		await get_tree().create_timer(0.1).timeout
		if pickable_pid and is_instance_valid(pickable_pid):
			pickable_pid.linear_velocity = Vector3.ZERO
			pickable_pid.angular_velocity = Vector3.ZERO
			pickable_pid.freeze = false
			print("[SceneCollection] P&ID positioned and unfrozen")

func _hide_pid_position() -> void:
	if not pickable_pid:
		return
	pickable_pid.global_position = pid_hide_position


func _set_pid_collisions(toggled_on: bool) -> void:
	if not pickable_pid:
		return
	# Recursively walk and toggle each Area3D and StaticBody3D
	_recurse_toggle_collisions(pickable_pid, toggled_on)

func _recurse_toggle_collisions(node: Node, enable: bool) -> void:
	for child in node.get_children():
		if child is Area3D:
			child.monitorable = enable
			if enable:
				child.collision_layer = 1048577
		elif child is StaticBody3D:
			child.disabled = not enable
		_recurse_toggle_collisions(child, enable)
