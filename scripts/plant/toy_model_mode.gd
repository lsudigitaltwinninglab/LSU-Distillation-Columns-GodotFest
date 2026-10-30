extends Node

## Toy Model Mode — keeps world-grab out of the way on Map/WorldGrabArea.
##
## Attached under WorldGrabArea in ar_network_arena.tscn (and main_stage.tscn).
## Grip no longer grabs the *world* in toy mode: ToyModelManipulator moves, turns and scales the
## model itself, so MovementWorldGrab is forced off whether toy mode is on or off.
##
## Does NOT change Area3D gravity (that caused slow upward drift). Player gravity in toy mode
## is handled by MovementToyModeGravity on XROrigin3D, enabled by ModelSyncManager.
##
## Model scale, reset, and multiplayer sync: ModelSyncManager + ui/panel_toy_model.gd.

@onready var world_grab_area: XRToolsWorldGrabArea = get_parent() as XRToolsWorldGrabArea
@onready var world_grab_provider: Node = get_tree().current_scene.get_node_or_null("XROrigin3D/MovementWorldGrab")


func _ready() -> void:
	if MenuControl and MenuControl.has_signal("toy_model_mode"):
		var cb := Callable(self, "_on_toy_model_mode_toggled")
		if not MenuControl.toy_model_mode.is_connected(cb):
			MenuControl.toy_model_mode.connect(cb)
	else:
		push_error("[ToyModelMode] ERROR: MenuControl or toy_model_mode signal not found!")

	if not world_grab_area:
		push_error("[ToyModelMode] ERROR: WorldGrabArea parent not found!")
	_disable_world_grab_provider()


func _on_toy_model_mode_toggled(_toggled_on: bool) -> void:
	_disable_world_grab_provider()


func _disable_world_grab_provider() -> void:
	if not world_grab_provider:
		world_grab_provider = get_tree().current_scene.get_node_or_null("XROrigin3D/MovementWorldGrab")
	if world_grab_provider and "enabled" in world_grab_provider:
		world_grab_provider.enabled = false
