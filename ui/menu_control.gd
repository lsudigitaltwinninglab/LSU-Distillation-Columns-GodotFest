extends Control

## Global signal bus (MenuControl autoload) — host UI actions and synced state fan-out.
##
## Host-only actions (guarded in ModelSyncManager by multiplayer.is_server()):
## - place_model_requested / adjust_position_requested → placement mode
## - ar_state_changed, show_* toggles, toy_model_mode, toy_scale_changed
##
## On clients: ModelSyncManager receives RPCs and re-emits these signals so local
## scenes (scene_collection.gd, main_stage.gd) apply visibility/AR state without
## duplicating network logic in UI scripts.

signal ar_state_changed(toggled_on)
signal player_movement_locked(toggled_on)
signal coordinate_adjustment_activated(toggled_on)
signal show_existing_facilities_toggled(toggled_on)
signal pid_visible_toggled(toggled_on)
signal toy_model_mode(toggled_on)

# AR Multiplayer sync signals
signal place_model_requested()
signal adjust_position_requested()

# Toy Model Mode controls
signal reset_to_spawn_requested()
signal toy_scale_changed(scale_value: float)
signal keep_toy_scale_requested()
signal reset_toy_scale_requested()
signal scale_lock_changed(locked: bool)
signal toy_qr_lock_changed(enabled: bool)

# Drawing tool (local to each player; strokes are shared by NetworkAnnotations)
signal pencil_toggled(toggled_on: bool)

func _ready() -> void:
	pass


### AR Multiplayer Sync Functions ###

## Called when host presses "Place Model" button
func _on_place_model_pressed() -> void:
	var sync_manager = _get_model_sync_manager()
	if sync_manager:
		sync_manager.enter_placement_mode()
		print("[MenuControl] Placement mode activated - use controller to confirm/cancel")
	else:
		print("[MenuControl] ERROR: ModelSyncManager not found!")
	emit_signal("place_model_requested")

## Called when host presses "Adjust Position" button
## Enters adjustment mode to fine-tune model position with joysticks
func _on_adjust_position_pressed() -> void:
	var sync_manager = _get_model_sync_manager()
	if sync_manager:
		if sync_manager.has_method("enter_adjustment_mode"):
			sync_manager.enter_adjustment_mode()
			print("[MenuControl] Adjustment mode activated")
		else:
			print("[MenuControl] ERROR: enter_adjustment_mode method not found!")
	else:
		print("[MenuControl] ERROR: ModelSyncManager not found!")

func _get_model_sync_manager() -> Node:
	if not is_inside_tree():
		return null
	var managers = get_tree().get_nodes_in_group("model_sync_manager")
	if managers.size() > 0:
		return managers[0]
	return null

# Toggles between VR Mode (bool = false) and AR Mode (true)
func _on_vrar_h_box_container_ar_toggle(ar_toggled_on: bool) -> void:
	emit_signal("ar_state_changed", ar_toggled_on)

# Deactiveates player movement with controllers (bool = true)
func _on_movement_controller_activated(toggle_selection: bool) -> void:
	var selection = toggle_selection
	emit_signal("player_movement_locked", toggle_selection)
	print("player movement locked: " + str(selection))

# Activates coordinate origin and pivot center option (bool = true)
func _on_coordinate_adjustment_activated(toggle_selection: bool) -> void:
	var selection = toggle_selection
	emit_signal("coordinate_adjustment_activated", toggle_selection)
	print("coordinate adjustment: " + str(selection))

func _on_toy_model_mode_activated(toggle_selection: bool) -> void:
	var selection = toggle_selection
	emit_signal("toy_model_mode", toggle_selection)
	print(" Toy Model Mode: " + str(selection))

# Shows geometry associated with the existing facility
func _on_show_existing_facilities_toggled(toggled_on: bool) -> void:
	emit_signal("show_existing_facilities_toggled", toggled_on)
	print("show existing faciltiies toggle state: " + str(toggled_on))
#
# Makes interactable P&ID visible 
func _on_pid_visible_toggled(toggled_on: bool) -> void:
	emit_signal("pid_visible_toggled", toggled_on)
	print("pid visible toggle state: " + str(toggled_on))


### Toy Model Mode Controls ###
## Signal hub between panel_toy_model.gd, xr_player_pointer.gd, and ModelSyncManager.
## Scale slider value is a 0..1 factor (1.0 = full size). Only the host applies world scale.

# Reset player to spawn position
func _on_reset_to_spawn_pressed() -> void:
	emit_signal("reset_to_spawn_requested")
	print("[MenuControl] Reset to spawn requested")

# Scale slider changed
func _on_toy_scale_slider_changed(value: float) -> void:
	emit_signal("toy_scale_changed", value)
	print("[MenuControl] Toy scale changed: " + str(value))

# Keep current scale button pressed
func _on_keep_scale_pressed() -> void:
	emit_signal("keep_toy_scale_requested")
	print("[MenuControl] Keep scale requested")

# Reset to default scale button pressed
func _on_reset_scale_pressed() -> void:
	emit_signal("reset_toy_scale_requested")
	print("[MenuControl] Reset scale requested")

# Scale lock changed
func _on_scale_lock_changed(locked: bool) -> void:
	emit_signal("scale_lock_changed", locked)
	print("[MenuControl] Scale lock: " + str(locked))

# QR lock toggled (true = model pinned to the QR code, false = move it by hand)
func _on_toy_qr_lock_changed(enabled: bool) -> void:
	emit_signal("toy_qr_lock_changed", enabled)
	print("[MenuControl] QR lock: " + str(enabled))


### Drawing tool ###

# Pencil toggle in the menu: spawns / removes the grabbable pencil for this player
func _on_pencil_toggled(toggled_on: bool) -> void:
	emit_signal("pencil_toggled", toggled_on)
	print("[MenuControl] Pencil: " + str(toggled_on))
