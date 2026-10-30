extends Node3D

@onready var movement_world_grab: XRToolsMovementWorldGrab = $"../../MovementWorldGrab"
@onready var world_scale_label: Label3D = $WorldScaleLabel
@onready var locked_icon: Sprite3D = $LockScaleButton/LockedIcon
@onready var un_locked_icon: Sprite3D = $LockScaleButton/UnLockedIcon
@onready var xr_tools_interactable_area: XRToolsInteractableArea = $LockScaleButton/XRToolsInteractableArea


var original_transform = transform.origin
var original_scale = scale
var world_scale_locked : bool = false
var saved_collision_layer : int

func _ready() -> void:
	set_process(false)
	if not movement_world_grab:
		push_warning("WorldScale: MovementWorldGrab not found")
		return
	
	# Connect signals to know when world scale is being adjusted
	if movement_world_grab.has_signal("player_world_grab_start"):
		if not movement_world_grab.is_connected("player_world_grab_start", Callable(self, "_on_player_world_grab_start")):
			movement_world_grab.connect("player_world_grab_start", Callable(self, "_on_player_world_grab_start"))
	else:
		push_warning("player_world_grab_start signal not found!")

	if movement_world_grab.has_signal("player_world_grab_end"):
		if not movement_world_grab.is_connected("player_world_grab_end", Callable(self, "_on_player_world_grab_end")):
			movement_world_grab.connect("player_world_grab_end", Callable(self, "_on_player_world_grab_end"))
	else:
		push_warning("player_world_grab_end signal not found!")
	
	if xr_tools_interactable_area.has_signal("pointer_event"):
		if not xr_tools_interactable_area.is_connected("pointer_event", Callable(self, "_on_xr_tools_interactable_area_pointer_event")):
			xr_tools_interactable_area.connect("pointer_event", Callable(self, "_on_xr_tools_interactable_area_pointer_event"))
	else:
		push_warning("xr_tools_pointer_event signal not found!")


func _process(_delta: float) -> void:
	_update_label(XRServer.world_scale)
	_update_transform(XRServer.world_scale)

func _on_player_world_grab_start() -> void:
	set_process(true)
	
func _on_player_world_grab_end() -> void:
	set_process(false)

func _update_label(updated_scale: float) -> void:
	world_scale_label.text = "Model Scale: %.1f" % updated_scale

func _update_transform(updated_scale: float) -> void:
	transform.origin = original_transform * updated_scale
	scale = original_scale * updated_scale


func _on_xr_tools_interactable_area_pointer_event(event: Variant) -> void:
	if event.event_type ==XRToolsPointerEvent.Type.PRESSED:
		world_scale_locked = !world_scale_locked
		# Set locked/unlocked Icons
		locked_icon.visible = world_scale_locked
		un_locked_icon.visible = !world_scale_locked
		# Enable/disable MovementWorldGrab
		movement_world_grab.enabled = !world_scale_locked


func _on_world_scale_label_visibility_changed() -> void:
	_update_label(XRServer.world_scale)
