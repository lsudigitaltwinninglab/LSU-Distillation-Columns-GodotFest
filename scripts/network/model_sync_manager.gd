extends Node3D
class_name ModelSyncManager

## Manages AR multiplayer synchronization (Map/ModelSyncManager in ar_network_arena).
##
## - Model transform / scale: host authority, RPC to clients
## - AR mode, visibility toggles, toy model mode + scale slider / reset
## - Placement: joystick or QR anchor (QR position not synced — each peer tracks locally)
## - Toy scale: slider factor × _original_model_scale; reset restores baseline from _ready
## - Toy gravity: enables MovementToyModeGravity on all peers (not WorldGrabArea override)
##
## RPC inventory (host authority unless noted):
## | RPC | Reliability | Syncs |
## |-----|-------------|-------|
## | _rpc_sync_model_transform | reliable | Full model transform (joystick confirm) |
## | _rpc_sync_model_position_rotation | unreliable | Position + rotation |
## | _rpc_sync_model_position_rotation_local | unreliable | Position/rotation vs local XROrigin |
## | _rpc_sync_anchor_mode | reliable | Anchor mode flag + marker data |
## | _rpc_sync_ar_mode | reliable | AR vs VR passthrough |
## | _rpc_sync_visibility | reliable | Facilities / P&ID visibility |
## | _rpc_sync_toy_model_mode | reliable | Toy model mode on/off |
## | _rpc_sync_model_scale | unreliable | Model scale (toy mode slider) |

signal model_placed(transform: Transform3D)
signal model_transform_changed(transform: Transform3D)
signal model_scale_changed(scale: Vector3)
signal ar_mode_synced(enabled: bool)
signal visibility_synced(facilities: bool, pid: bool)
signal placement_mode_changed(active: bool)
signal qr_anchor_status_changed(is_anchored: bool, marker_data: String)

## Anchor modes - how the model position was determined
enum AnchorMode {
	NONE,           ## Model at default position
	JOYSTICK,       ## Host placed via joystick
	QR_CODE         ## Anchored to QR code marker
}

var _anchor_mode: AnchorMode = AnchorMode.NONE
var _qr_marker_data: String = ""  # Data from QR code if anchored that way

# The node containing the distillery model (MainStage or SceneCollection)
@export var model_root: Node3D
@export var placement_distance: float = 2.0
@export var placement_height_offset: float = 0.0  # Adjust model height during placement

# Reference to the player's XROrigin for local alignment
var _xr_origin: XROrigin3D
var _xr_camera: XRCamera3D
var _left_controller: XRController3D
var _right_controller: XRController3D
var _local_offset: Transform3D = Transform3D.IDENTITY

# Synced properties
var _synced_model_transform: Transform3D = Transform3D.IDENTITY
var _synced_model_scale: Vector3 = Vector3.ONE  # Model scale for toy model mode

# Client-side smoothing for QR sync (reduces jitter from host updates)
var _target_model_position: Vector3 = Vector3.ZERO
var _target_model_rotation: Vector3 = Vector3.ZERO
var _smooth_position_rotation: bool = false  # True when we have a target to lerp to
@export var qr_sync_smooth_speed: float = 5.0  # How fast to interpolate (lower = smoother on client, less shaky; higher = snappier)
@export var conference_demo_mode: bool = true
@export var demo_qr_sync_smooth_speed: float = 3.0
@export var placement_confirm_stable_time: float = 0.45
@export var lock_to_table_plane_on_confirm: bool = true
@export var table_plane_y: float = 0.0
@export var quick_recenter_distance: float = 1.8
@export var quick_recenter_height: float = 0.78
var _synced_ar_mode: bool = false
var _synced_show_facilities: bool = false
var _synced_pid_visible: bool = false

# --- Toy model scale (host authority) ---
# Slider factor 1.0 = _original_model_scale (captured once at _ready, not on toy toggle).
var _last_synced_scale: Vector3 = Vector3.ONE
var _original_model_scale: Vector3 = Vector3.ONE
const MIN_TOY_SCALE := 0.02  # Avoid near-zero scale physics bugs

# Hand/stick manipulation sync throttle (host → clients)
const TOY_SYNC_INTERVAL_MSEC := 50
var _last_toy_sync_msec: int = 0
var _toy_sync_flush_pending: bool = false

# Placement mode
var _placement_mode: bool = false
var _original_model_transform: Transform3D  # Store original position for cancel
var _spawn_model_transform: Transform3D = Transform3D.IDENTITY  # Position, rotation and scale at load
var _placement_indicator: Node3D  # Visual indicator during placement
var _stable_confirm_timer: float = 0.0
var _last_placement_position: Vector3 = Vector3.INF
var _last_placement_rotation: float = 0.0

const PLACE_STABLE_POS_EPSILON := 0.015
const PLACE_STABLE_ROT_EPSILON := deg_to_rad(1.0)


func _update_physics_process_state() -> void:
	set_physics_process(_placement_mode)


func _ready() -> void:
	add_to_group("model_sync_manager")
	
	# Find the XROrigin and controllers
	await get_tree().process_frame
	_find_xr_nodes()
	
	# Auto-find model_root if not set
	# We want MainStage (the whole instanced scene), not just SceneCollection
	if not model_root:
		# First try to find MainStage directly
		model_root = get_node_or_null("../MainStage")
		if not model_root:
			# Try finding via SceneCollection and going up to parent
			var scene_collection = get_tree().get_first_node_in_group("scene_collection")
			if scene_collection:
				# SceneCollection's parent should be MainStage (the "Main" root of main_stage.tscn)
				model_root = scene_collection.get_parent()
				if model_root and model_root.name == "Main":
					print("[ModelSyncManager] Found MainStage via SceneCollection parent")
				else:
					# Fallback to SceneCollection itself
					model_root = scene_collection
	
	if model_root:
		_synced_model_transform = model_root.global_transform
		_spawn_model_transform = model_root.global_transform  # where "Reset Model" puts it back
		# Full-size baseline for toy slider (1.0 = 100%). Do not overwrite when entering toy mode.
		_original_model_scale = model_root.scale
		_synced_model_scale = model_root.scale
		print("[ModelSyncManager] Found model root: ", model_root.name, " full scale: ", _original_model_scale)
	else:
		print("[ModelSyncManager] WARNING: No model root found!")
	if conference_demo_mode:
		qr_sync_smooth_speed = demo_qr_sync_smooth_speed
	
	# Connect to MenuControl signals if its the local player
	_connect_menu_signals()
	
	# Connect to QR marker manager if available
	_connect_qr_marker_manager()
	
	# Only run _process on clients when smoothing (saves server from empty _process calls)
	set_process(false)
	set_physics_process(false)

	# Clients pull the host's state once their arena is loaded. The host must not push it on
	# peer_connected: at that moment the client is still in the lobby, so the RPCs would be dropped.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_start_state_requests()
	elif multiplayer.has_multiplayer_peer():
		_start_spectator_stream()

func _find_xr_nodes() -> void:
	_xr_origin = get_tree().get_first_node_in_group("xr_origin")
	if not _xr_origin:
		var origins = get_tree().get_nodes_in_group("xr_origin")
		if origins.size() > 0:
			_xr_origin = origins[0]
	
	if _xr_origin:
		_xr_camera = _xr_origin.get_node_or_null("XRCamera3D")
		_left_controller = _xr_origin.get_node_or_null("LeftHand")
		_right_controller = _xr_origin.get_node_or_null("RightHand")
		
		# Connect controller signals for placement confirmation
		if _left_controller:
			if not _left_controller.is_connected("button_pressed", _on_controller_button):
				_left_controller.button_pressed.connect(_on_controller_button)
		if _right_controller:
			if not _right_controller.is_connected("button_pressed", _on_controller_button):
				_right_controller.button_pressed.connect(_on_controller_button)
		
		print("[ModelSyncManager] Found XR nodes - Camera: ", _xr_camera != null, " Controllers: ", _left_controller != null, "/", _right_controller != null)

func _connect_menu_signals() -> void:
	if not MenuControl:
		print("[ModelSyncManager] MenuControl autoload not found")
		return
	
	# Connect to local menu changes to broadcast them
	if MenuControl.has_signal("ar_state_changed"):
		if not MenuControl.is_connected("ar_state_changed", _on_local_ar_state_changed):
			MenuControl.connect("ar_state_changed", _on_local_ar_state_changed)
	
	if MenuControl.has_signal("show_existing_facilities_toggled"):
		if not MenuControl.is_connected("show_existing_facilities_toggled", _on_local_show_facilities_toggled):
			MenuControl.connect("show_existing_facilities_toggled", _on_local_show_facilities_toggled)
	
	if MenuControl.has_signal("pid_visible_toggled"):
		if not MenuControl.is_connected("pid_visible_toggled", _on_local_pid_visible_toggled):
			MenuControl.connect("pid_visible_toggled", _on_local_pid_visible_toggled)
	
	# Toy model scale syncing
	if MenuControl.has_signal("toy_scale_changed"):
		if not MenuControl.is_connected("toy_scale_changed", _on_local_toy_scale_changed):
			MenuControl.connect("toy_scale_changed", _on_local_toy_scale_changed)
	
	if MenuControl.has_signal("toy_model_mode"):
		if not MenuControl.is_connected("toy_model_mode", _on_local_toy_model_mode):
			MenuControl.connect("toy_model_mode", _on_local_toy_model_mode)
	
	if MenuControl.has_signal("reset_toy_scale_requested"):
		if not MenuControl.is_connected("reset_toy_scale_requested", _on_local_reset_toy_scale):
			MenuControl.connect("reset_toy_scale_requested", _on_local_reset_toy_scale)

	if MenuControl.has_signal("reset_to_spawn_requested"):
		if not MenuControl.is_connected("reset_to_spawn_requested", _on_local_reset_model_to_spawn):
			MenuControl.connect("reset_to_spawn_requested", _on_local_reset_model_to_spawn)


func _connect_qr_marker_manager() -> void:
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if qr_manager:
		if qr_manager.has_signal("marker_detected"):
			if not qr_manager.is_connected("marker_detected", _on_qr_marker_detected):
				qr_manager.connect("marker_detected", _on_qr_marker_detected)
		if qr_manager.has_signal("marker_lost"):
			if not qr_manager.is_connected("marker_lost", _on_qr_marker_lost):
				qr_manager.connect("marker_lost", _on_qr_marker_lost)
		print("[ModelSyncManager] Connected to QRMarkerManager")
	else:
		print("[ModelSyncManager] QRMarkerManager not found (QR anchoring disabled)")

###Change this to make it auto anchor and we have the choice to update
func _on_qr_marker_detected(marker_transform: Transform3D, marker_data: String) -> void:
	print("[ModelSyncManager] QR marker detected: ", marker_data)
	# Don't auto-anchor - let the host decide via button press
	# The QRMarkerManager handles auto_anchor_on_detect if enabled


func _on_qr_marker_lost(marker_data: String) -> void:
	print("[ModelSyncManager] QR marker lost: ", marker_data)
	# Model stays where it was anchored - don't reset position


### JOYSTICK PLACEMENT CONTROLS ###

@export var move_speed: float = 2.0  # Units per second
@export var rotate_speed: float = 90.0  # Degrees per second
@export var height_speed: float = 1.0  # Units per second

var _current_placement_pos: Vector3 = Vector3.ZERO
var _current_placement_rotation: float = 0.0
var _current_placement_height: float = 0.0

func _on_controller_button(button_name: String) -> void:
	if not _placement_mode:
		return
	
	# Trigger confirms placement
	if button_name == "trigger_click" or button_name == "ax_button":
		confirm_placement()
	# B/Y cancels placement
	elif button_name == "by_button":
		cancel_placement()
	# Thumbstick click recenters quickly in demo mode
	elif conference_demo_mode and button_name == "primary_click":
		quick_recenter_to_camera()

func _physics_process(delta: float) -> void:
	if not _placement_mode or not model_root:
		return
	
	# Get joystick input from controllers
	var move_input := Vector2.ZERO
	var rotate_input := 0.0
	var height_input := 0.0
	
	if _left_controller:
		# Left joystick: Move model
		move_input.x = _left_controller.get_vector2("primary").x  # Left/Right
		move_input.y = _left_controller.get_vector2("primary").y  # Forward/Back
		# Left grip: Lower model
		if _left_controller.is_button_pressed("grip_click"):
			height_input -= 1.0
	
	if _right_controller:
		# Right joystick X: Rotate model
		rotate_input = _right_controller.get_vector2("primary").x
		# Right grip: Raise model
		if _right_controller.is_button_pressed("grip_click"):
			height_input += 1.0
	
	# Apply movement relative to camera facing direction
	if move_input.length() > 0.1:
		var cam_basis = _xr_camera.global_transform.basis if _xr_camera else Basis.IDENTITY
		var forward = -cam_basis.z
		forward.y = 0
		forward = forward.normalized()
		var right = cam_basis.x
		right.y = 0
		right = right.normalized()
		
		var movement = (forward * move_input.y + right * move_input.x) * move_speed * delta
		_current_placement_pos += movement
	
	# Apply rotation
	if abs(rotate_input) > 0.1:
		_current_placement_rotation += rotate_input * rotate_speed * delta
	
	# Apply height change
	if abs(height_input) > 0.1:
		_current_placement_height += height_input * height_speed * delta
		_current_placement_height = clamp(_current_placement_height, -2.0, 5.0)  # Reasonable limits
	
	# Update model transform
	model_root.global_position = _current_placement_pos + Vector3(0, _current_placement_height, 0)
	model_root.rotation_degrees.y = _current_placement_rotation
	_update_placement_stability(delta)


func _update_placement_stability(delta: float) -> void:
	var current_pos: Vector3 = model_root.global_position
	var current_rot_y: float = model_root.global_rotation.y
	if _last_placement_position == Vector3.INF:
		_last_placement_position = current_pos
		_last_placement_rotation = current_rot_y
		_stable_confirm_timer = 0.0
		return
	var pos_delta: float = current_pos.distance_to(_last_placement_position)
	var rot_delta: float = absf(wrapf(current_rot_y - _last_placement_rotation, -PI, PI))
	if pos_delta <= PLACE_STABLE_POS_EPSILON and rot_delta <= PLACE_STABLE_ROT_EPSILON:
		_stable_confirm_timer += delta
	else:
		_stable_confirm_timer = 0.0
	_last_placement_position = current_pos
	_last_placement_rotation = current_rot_y


### HOST: Place Model Anchor ###


## Called by host to enter placement mode
func enter_placement_mode() -> void:
	if not multiplayer.is_server():
		print("[ModelSyncManager] Only host can place the model")
		return
	
	if _placement_mode:
		# Already in placement mode, confirm it
		confirm_placement()
		return
	
	_placement_mode = true
	_update_physics_process_state()
	_stable_confirm_timer = 0.0
	_last_placement_position = Vector3.INF
	_last_placement_rotation = 0.0
	if model_root:
		_original_model_transform = model_root.global_transform
		# Start placement at current position or in front of player
		if _xr_camera:
			var forward = -_xr_camera.global_transform.basis.z
			forward.y = 0
			forward = forward.normalized()
			_current_placement_pos = _xr_camera.global_position + forward * placement_distance
			_current_placement_pos.y = 0
		else:
			_current_placement_pos = model_root.global_position
		_current_placement_rotation = model_root.rotation_degrees.y
		_current_placement_height = 0.0
	
	# Create visual feedback
	_create_placement_indicator()
	
	placement_mode_changed.emit(true)
	print("[ModelSyncManager] === PLACEMENT MODE ACTIVE ===")
	print("[ModelSyncManager] - LEFT STICK: Move model")
	print("[ModelSyncManager] - RIGHT STICK: Rotate model")
	print("[ModelSyncManager] - GRIP buttons: Adjust height")
	print("[ModelSyncManager] - TRIGGER: CONFIRM")
	print("[ModelSyncManager] - B/Y: CANCEL")
	if conference_demo_mode:
		print("[ModelSyncManager] - L-STICK CLICK: QUICK RECENTER")

## Client-side smoothing of host position/rotation updates
func _process(delta: float) -> void:
	if _spectator_has_target and model_root:
		_smooth_toward_spectator_target(delta)
		return
	if not multiplayer.is_server() and _smooth_position_rotation and model_root and _anchor_mode != AnchorMode.QR_CODE:
		var current_scale := model_root.scale
		var pos := model_root.global_position
		var rot := model_root.global_rotation
		var t := 1.0 - exp(-qr_sync_smooth_speed * delta)
		model_root.global_position = pos.lerp(_target_model_position, t)
		var from_q := Quaternion.from_euler(rot)
		var to_q := Quaternion.from_euler(_target_model_rotation)
		model_root.global_rotation = from_q.slerp(to_q, t).get_euler()
		model_root.scale = current_scale
		_synced_model_transform = model_root.global_transform

## Called by host to confirm model placement
func confirm_placement() -> void:
	if not multiplayer.is_server() or not _placement_mode:
		return
	if conference_demo_mode and _stable_confirm_timer < placement_confirm_stable_time:
		print("[ModelSyncManager] Hold position steady before confirm (", snapped(_stable_confirm_timer, 0.01), "/", placement_confirm_stable_time, "s)")
		return
	
	_placement_mode = false
	_update_physics_process_state()
	_remove_placement_indicator()
	
	if model_root:
		if lock_to_table_plane_on_confirm:
			var t := model_root.global_transform
			t.origin.y = table_plane_y
			model_root.global_transform = t
		_synced_model_transform = model_root.global_transform
		_anchor_mode = AnchorMode.JOYSTICK
		_qr_marker_data = ""
		# Broadcast to all clients
		_rpc_sync_model_transform.rpc(_synced_model_transform)
		_rpc_sync_anchor_mode.rpc(AnchorMode.JOYSTICK, "")
		model_placed.emit(_synced_model_transform)
		print("[ModelSyncManager] ✓ Model CONFIRMED at: ", _synced_model_transform.origin)
	
	placement_mode_changed.emit(false)

## Called to cancel placement and restore original position
func cancel_placement() -> void:
	if not _placement_mode:
		return
	
	_placement_mode = false
	_update_physics_process_state()
	_remove_placement_indicator()
	_stable_confirm_timer = 0.0
	_last_placement_position = Vector3.INF
	
	if model_root:
		model_root.global_transform = _original_model_transform
		print("[ModelSyncManager] ✗ Placement CANCELLED - restored original position")
	
	placement_mode_changed.emit(false)

## Host can manually set model transform
func set_model_transform(new_transform: Transform3D) -> void:
	if not multiplayer.is_server():
		return
	
	_synced_model_transform = new_transform
	if model_root:
		model_root.global_transform = new_transform
	_rpc_sync_model_transform.rpc(new_transform)


## Host can set model position/rotation while preserving current scale
func set_model_position_rotation(new_position: Vector3, new_rotation: Vector3) -> void:
	if not multiplayer.is_server():
		return
	
	if model_root:
		var current_scale = model_root.scale
		model_root.global_position = new_position
		model_root.global_rotation = new_rotation
		model_root.scale = current_scale  # Preserve scale
		# IMPORTANT: Keep _synced_model_transform updated for new peer sync
		_synced_model_transform = model_root.global_transform
		_synced_model_scale = current_scale
	
	_rpc_sync_model_position_rotation.rpc(new_position, new_rotation)


## Sync model using position/rotation *local to XROrigin3D* so clients place the model in their own origin space (fixes model flying away on client when host moves).
## [param reliable]: send over the reliable channel (one-off poses such as a newly confirmed QR lock).
func set_model_position_rotation_local_to_origin(local_position: Vector3, local_rotation: Vector3, reliable: bool = false) -> void:
	if not multiplayer.is_server():
		return
	if not _xr_origin:
		return
	var local_t := Transform3D(Basis.from_euler(local_rotation), local_position)
	var global_t := _xr_origin.global_transform * local_t
	if model_root:
		var current_scale = model_root.scale
		model_root.global_transform = global_t
		model_root.scale = current_scale
		_synced_model_transform = model_root.global_transform
		_synced_model_scale = current_scale
	if reliable:
		_rpc_sync_model_position_rotation_local_reliable.rpc(local_position, local_rotation)
	else:
		_rpc_sync_model_position_rotation_local.rpc(local_position, local_rotation)
	_send_qr_relative_pose(reliable)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_model_position_rotation_local_reliable(local_position: Vector3, local_rotation: Vector3) -> void:
	_rpc_sync_model_position_rotation_local(local_position, local_rotation)


@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_model_position_rotation_local(local_position: Vector3, local_rotation: Vector3) -> void:
	if SpectatorMode.is_active():
		return  # spectators get the world transform stream instead
	# Client in local QR mode uses their own QR — ignore host position
	if not multiplayer.is_server() and _anchor_mode == AnchorMode.QR_CODE:
		return
	if not _xr_origin:
		return
	var local_t := Transform3D(Basis.from_euler(local_rotation), local_position)
	var global_t := _xr_origin.global_transform * local_t
	var global_pos := global_t.origin
	var global_rot := global_t.basis.get_euler()
	_synced_model_transform = global_t
	if multiplayer.is_server():
		if model_root:
			var current_scale = model_root.scale
			model_root.global_transform = global_t
			model_root.scale = current_scale
	else:
		_target_model_position = global_pos
		_target_model_rotation = global_rot
		if not model_root:
			_smooth_position_rotation = false
		else:
			if not _smooth_position_rotation:
				model_root.global_position = global_pos
				model_root.global_rotation = global_rot
			_smooth_position_rotation = true
			set_process(true)


@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_model_position_rotation(new_position: Vector3, new_rotation: Vector3) -> void:
	if SpectatorMode.is_active():
		return  # spectators get the world transform stream instead
	# Client in local QR mode uses their own QR — ignore host position
	if not multiplayer.is_server() and _anchor_mode == AnchorMode.QR_CODE:
		return
	_synced_model_transform = Transform3D(Basis.from_euler(new_rotation), new_position)
	if multiplayer.is_server():
		if model_root:
			var current_scale = model_root.scale
			model_root.global_position = new_position
			model_root.global_rotation = new_rotation
			model_root.scale = current_scale
			_synced_model_transform = model_root.global_transform
	else:
		# Client: smooth towards target to reduce QR jitter instead of snapping
		_target_model_position = new_position
		_target_model_rotation = new_rotation
		if not model_root:
			_smooth_position_rotation = false
		else:
			# First sync (e.g. on join): snap so we don't slide from zero
			if not _smooth_position_rotation:
				model_root.global_position = new_position
				model_root.global_rotation = new_rotation
			_smooth_position_rotation = true
			set_process(true)
			print("[ModelSyncManager][Perf] _process enabled (client position/rotation smoothing)")


### QR CODE ANCHORING ###


## Host anchors the model to a QR code marker position
## Called by QRMarkerManager or menu button
func anchor_to_qr(marker_transform: Transform3D, marker_data: String = "") -> void:
	if not multiplayer.is_server():
		print("[ModelSyncManager] Only host can anchor the model")
		return
	
	# Cancel any active joystick placement
	if _placement_mode:
		cancel_placement()
	
	_anchor_mode = AnchorMode.QR_CODE
	_qr_marker_data = marker_data
	_synced_model_transform = marker_transform
	
	if model_root:
		model_root.global_transform = marker_transform
	
	# Sync to all clients
	_rpc_sync_model_transform.rpc(marker_transform)
	_rpc_sync_anchor_mode.rpc(AnchorMode.QR_CODE, marker_data)
	
	model_placed.emit(marker_transform)
	qr_anchor_status_changed.emit(true, marker_data)
	
	print("[ModelSyncManager] ✓ Model anchored to QR code: ", marker_data)
	print("[ModelSyncManager]   Position: ", marker_transform.origin)


## Request QR anchor from menu - finds QRMarkerManager and triggers anchor
func request_qr_anchor() -> void:
	if not multiplayer.is_server():
		print("[ModelSyncManager] Only host can anchor the model")
		return
	
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if not qr_manager:
		print("[ModelSyncManager] ERROR: QRMarkerManager not found!")
		return
	
	if qr_manager.is_tracking():
		var marker_transform = qr_manager.get_marker_transform()
		var marker_data = qr_manager.get_marker_data()
		anchor_to_qr(marker_transform, marker_data)
	else:
		print("[ModelSyncManager] No QR marker currently detected")
		print("[ModelSyncManager] Point your headset at a QR code and try again")


## Check if QR marker is currently being tracked
func is_qr_marker_available() -> bool:
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if qr_manager:
		return qr_manager.is_tracking()
	return false


## Enter adjustment mode after QR anchoring - allows fine-tuning with joysticks
## This is similar to placement mode but starts from the current QR-anchored position
func enter_adjustment_mode() -> void:
	if not multiplayer.is_server():
		print("[ModelSyncManager] Only host can adjust the model")
		return
	
	if _placement_mode:
		# Already adjusting
		return
	
	_placement_mode = true
	_update_physics_process_state()
	_stable_confirm_timer = 0.0
	_last_placement_position = Vector3.INF
	_last_placement_rotation = 0.0
	if model_root:
		_original_model_transform = model_root.global_transform
		_current_placement_pos = model_root.global_position
		_current_placement_pos.y = 0  # Keep base position
		_current_placement_rotation = model_root.rotation_degrees.y
		_current_placement_height = model_root.global_position.y
	
	# Create visual feedback
	_create_adjustment_indicator()
	
	placement_mode_changed.emit(true)
	print("[ModelSyncManager] === ADJUSTMENT MODE ACTIVE ===")
	print("[ModelSyncManager] Fine-tune QR anchor position:")
	print("[ModelSyncManager] - LEFT STICK: Move model")
	print("[ModelSyncManager] - RIGHT STICK: Rotate model")
	print("[ModelSyncManager] - GRIP buttons: Adjust height")
	print("[ModelSyncManager] - TRIGGER: CONFIRM adjustment")
	print("[ModelSyncManager] - B/Y: CANCEL (return to QR position)")


func _create_adjustment_indicator() -> void:
	# Create indicator showing adjustment mode is active
	if _placement_indicator:
		return
	
	_placement_indicator = Node3D.new()
	_placement_indicator.name = "AdjustmentIndicator"
	
	# Create a glowing ring mesh (different color for adjustment)
	var mesh_instance = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius = 1.5
	torus.outer_radius = 1.8
	mesh_instance.mesh = torus
	mesh_instance.rotation_degrees.x = 90  # Lay flat
	
	# Blue glowing material for adjustment mode
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 1.0, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.6, 1.0)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = mat
	
	_placement_indicator.add_child(mesh_instance)
	
	# Add label
	var label = Label3D.new()
	label.text = "QR ADJUSTMENT MODE\nL-Stick: Move | R-Stick: Rotate | Grips: Height\nTRIGGER = Confirm | B/Y = Reset to QR"
	label.position.y = 0.5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.outline_size = 8
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placement_indicator.add_child(label)
	
	if model_root:
		model_root.add_child(_placement_indicator)
	
	print("[ModelSyncManager] Created adjustment indicator")


## Called by QRMarkerManager when this peer starts/stops tracking a QR (local only — no RPC).
## Each peer anchors from their own camera, so they sync naturally when looking at the same QR.
func set_local_qr_anchor_mode(active: bool, marker_data: String) -> void:
	if active:
		_anchor_mode = AnchorMode.QR_CODE
		_qr_marker_data = marker_data
		# Stop easing toward the last host pose: on a client that pose is relative to the host's own
		# tracking space, and _process would keep dragging the model off this peer's QR code.
		_smooth_position_rotation = false
	else:
		_anchor_mode = AnchorMode.NONE
		_qr_marker_data = ""
	_update_physics_process_state()
	qr_anchor_status_changed.emit(active, marker_data)


## Called by QRMarkerManager when it starts/stops tracking (host-only, with RPC) — kept for menu/request_qr_anchor path if needed.
func notify_qr_anchor_active(marker_data: String) -> void:
	if not multiplayer.is_server():
		return
	_anchor_mode = AnchorMode.QR_CODE
	_qr_marker_data = marker_data
	_rpc_sync_anchor_mode.rpc(AnchorMode.QR_CODE, marker_data)
	qr_anchor_status_changed.emit(true, marker_data)


func notify_qr_anchor_inactive() -> void:
	if not multiplayer.is_server():
		return
	_anchor_mode = AnchorMode.NONE
	_qr_marker_data = ""
	_rpc_sync_anchor_mode.rpc(AnchorMode.NONE, "")
	qr_anchor_status_changed.emit(false, "")


## Get current anchor mode
func get_anchor_mode() -> AnchorMode:
	return _anchor_mode


## Get QR marker data if anchored via QR
func get_qr_marker_data() -> String:
	return _qr_marker_data


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_anchor_mode(mode: int, marker_data: String) -> void:
	# A client locked to its own QR code keeps that lock (the host's join-time state says NONE and is
	# re-sent until it arrives, which can land after the client has already confirmed its code).
	if not multiplayer.is_server() and _anchor_mode == AnchorMode.QR_CODE and mode != AnchorMode.QR_CODE:
		var qr := get_tree().get_first_node_in_group("qr_marker_manager")
		if qr and qr.has_method("is_locking") and qr.is_locking():
			return
	_anchor_mode = mode as AnchorMode
	_qr_marker_data = marker_data
	if mode != AnchorMode.QR_CODE:
		_smooth_position_rotation = false  # Stop smoothing when leaving QR mode
		set_process(false)
		print("[ModelSyncManager][Perf] _process disabled (left QR anchor mode)")
	qr_anchor_status_changed.emit(mode == AnchorMode.QR_CODE, marker_data)
	print("[ModelSyncManager] Anchor mode synced: ", AnchorMode.keys()[mode], " data: ", marker_data)


### PLACEMENT VISUAL INDICATOR ###


func _create_placement_indicator() -> void:
	# Create a simple ring/marker to show placement is active
	if _placement_indicator:
		return
	
	_placement_indicator = Node3D.new()
	_placement_indicator.name = "PlacementIndicator"
	
	# Create a glowing ring mesh
	var mesh_instance = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius = 1.5
	torus.outer_radius = 1.8
	mesh_instance.mesh = torus
	mesh_instance.rotation_degrees.x = 90  # Lay flat
	
	# Glowing material
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.4, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 1.0, 0.4)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = mat
	
	_placement_indicator.add_child(mesh_instance)
	
	# Add label
	var label = Label3D.new()
	label.text = "L-Stick: Move | R-Stick: Rotate | Grips: Height\nTRIGGER = Confirm | B/Y = Cancel"
	label.position.y = 0.5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.outline_size = 8
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placement_indicator.add_child(label)
	
	if model_root:
		model_root.add_child(_placement_indicator)
	
	print("[ModelSyncManager] Created placement indicator")

func _remove_placement_indicator() -> void:
	if _placement_indicator:
		_placement_indicator.queue_free()
		_placement_indicator = null


### CLIENT: Align Local View ###


## Clients call this to align their local origin to the model
## This makes the model appear at their current forward position
func align_to_model() -> void:
	if not _xr_origin or not model_root:
		print("[ModelSyncManager] Cannot align - missing XROrigin or model")
		return
	
	var camera = _xr_origin.get_node_or_null("XRCamera3D")
	if not camera:
		return
	
	# Calculate offset so model appears in front of player
	var forward = -camera.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	
	var desired_model_pos = camera.global_position + forward * placement_distance
	desired_model_pos.y = 0
	
	# Calculate the offset needed
	var current_model_pos = model_root.global_position
	var offset = desired_model_pos - current_model_pos
	
	# Apply offset to XROrigin (moves the player relative to the model)
	_xr_origin.global_position += offset
	
	print("[ModelSyncManager] Aligned view - offset applied: ", offset)

## Reset local alignment to default
func reset_alignment() -> void:
	if _xr_origin:
		_xr_origin.global_position = Vector3.ZERO
		print("[ModelSyncManager] Alignment reset")


### SYNC: Model Transform ###


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_model_transform(new_transform: Transform3D) -> void:
	if SpectatorMode.is_active():
		return  # spectators get the world transform stream instead
	# Client in local QR mode uses their own QR — ignore host transform
	if not multiplayer.is_server() and _anchor_mode == AnchorMode.QR_CODE:
		return
	_smooth_position_rotation = false  # Full transform = snap (e.g. joystick confirm)
	set_process(false)
	if not multiplayer.is_server():
		print("[ModelSyncManager][Perf] _process disabled (received full transform sync)")
	_synced_model_transform = new_transform
	_target_model_position = new_transform.origin
	_target_model_rotation = new_transform.basis.get_euler()
	if model_root:
		model_root.global_transform = new_transform
	model_transform_changed.emit(new_transform)
	print("[ModelSyncManager] Received model transform from host")


### SYNC: Menu State (AR mode, P&ID Drawing visibility) ###


func _on_local_ar_state_changed(enabled: bool) -> void:
	if multiplayer.is_server():
		_synced_ar_mode = enabled
		_rpc_sync_ar_mode.rpc(enabled)

func _on_local_show_facilities_toggled(enabled: bool) -> void:
	if multiplayer.is_server():
		_synced_show_facilities = enabled
		_rpc_sync_visibility.rpc(_synced_show_facilities, _synced_pid_visible)

func _on_local_pid_visible_toggled(enabled: bool) -> void:
	if multiplayer.is_server():
		_synced_pid_visible = enabled
		_rpc_sync_visibility.rpc(_synced_show_facilities, _synced_pid_visible)

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_ar_mode(enabled: bool) -> void:
	_synced_ar_mode = enabled
	# Emit signal so main_stage.gd picks it up
	if MenuControl and MenuControl.has_signal("ar_state_changed"):
		MenuControl.emit_signal("ar_state_changed", enabled)
	ar_mode_synced.emit(enabled)
	print("[ModelSyncManager] AR mode synced: ", enabled)

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_visibility(facilities: bool, pid: bool) -> void:
	_synced_show_facilities = facilities
	_synced_pid_visible = pid
	
	# Emit signals so scene_collection.gd picks them up
	if MenuControl:
		if MenuControl.has_signal("show_existing_facilities_toggled"):
			MenuControl.emit_signal("show_existing_facilities_toggled", facilities)
		if MenuControl.has_signal("pid_visible_toggled"):
			MenuControl.emit_signal("pid_visible_toggled", pid)
	
	visibility_synced.emit(facilities, pid)
	print("[ModelSyncManager] Visibility synced - Facilities:", facilities, " PID:", pid)


### SYNC: Toy Model Scale ###
## Host-only scale changes; clients receive _rpc_sync_model_scale.
## Gravity: toggles MovementToyModeGravity via group toy_mode_gravity_override (not WorldGrabArea).

var _toy_model_active: bool = false
## Pivot in the model's own space; Vector3.INF = not computed yet (recomputed each toy session).
var _toy_pivot_local: Vector3 = Vector3.INF
## Player body collision mask to restore when toy mode ends (-1 = not saved).
var _saved_player_collision_mask: int = -1

func _on_local_toy_model_mode(enabled: bool) -> void:
	_toy_model_active = enabled
	_toy_pivot_local = Vector3.INF
	# Toy mode should be marker-locked; don't leave host in manual placement state.
	if enabled and _placement_mode:
		cancel_placement()
	_update_physics_process_state()
	if enabled:
		var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
		if qr_manager and qr_manager.has_method("force_reanchor_now"):
			qr_manager.force_reanchor_now()
	if multiplayer.is_server():
		_rpc_sync_toy_model_mode.rpc(enabled)
	# Host: apply gravity the same way as clients so host and client stay in sync (no fall when in toy mode)
	_apply_toy_mode_gravity(enabled)


func _on_local_toy_scale_changed(scale_value: float) -> void:
	# This is called when the host changes the scale slider
	# scale_value: 1.0 = full size (100%), 0.5 = half size (50%). Clamp minimum to avoid flying.
	if multiplayer.is_server() and model_root:
		var safe_factor := maxf(scale_value, MIN_TOY_SCALE)
		# Hand/stick gestures (apply_toy_manipulation) have already applied this scale.
		if is_equal_approx(get_toy_scale_factor(), safe_factor):
			return
		var new_scale := _original_model_scale * safe_factor
		_apply_toy_scale_about_pivot(new_scale)
		_synced_model_scale = new_scale
		_rpc_sync_model_scale.rpc(new_scale)
		# Scaling about the player also shifts the model, so keep clients that aren't QR-locked in step.
		_sync_toy_pose_to_clients(false)
		_refresh_qr_anchor_if_toy_mode()
		print("[ModelSyncManager] Model scale set to: ", new_scale, " (", safe_factor * 100.0, "%)")


func _on_local_reset_toy_scale() -> void:
	# Reset model to full baseline scale (slider 100%).
	if not multiplayer.is_server() or not model_root:
		return
	_apply_toy_scale_about_pivot(_original_model_scale)
	_synced_model_scale = _original_model_scale
	_rpc_sync_model_scale.rpc(_original_model_scale)
	_refresh_qr_anchor_if_toy_mode()
	if MenuControl:
		MenuControl.emit_signal("toy_scale_changed", 1.0)
	print("[ModelSyncManager] Model scale reset to full: ", _original_model_scale)


## Toy panel "Reset Model": put the model back where it spawned — location, rotation and scale.
## A model pinned to a QR code goes back to full size and snaps to the code instead.
func _on_local_reset_model_to_spawn() -> void:
	if not multiplayer.is_server() or not model_root:
		return
	if _placement_mode:
		cancel_placement()
	model_root.global_transform = _spawn_model_transform
	model_root.scale = _original_model_scale
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if qr_manager and qr_manager.has_method("reset_user_turn"):
		qr_manager.reset_user_turn()
	_synced_model_transform = model_root.global_transform
	_synced_model_scale = _original_model_scale
	_refresh_qr_anchor_if_toy_mode()
	_sync_toy_pose_to_clients(true)
	if MenuControl:
		MenuControl.emit_signal("toy_scale_changed", 1.0)
	print("[ModelSyncManager] Model reset to spawn")


## In toy mode the model is a tabletop object, not a place to stand: the player's body must not collide
## with it, or growing / moving the model under (or into) the player shoves them up and away — and with
## gravity off they would stay there until toy mode ends and they dropped from the sky.
func _set_player_collides_with_world(collides: bool) -> void:
	var body := _xr_origin.get_node_or_null("PlayerBody") as XRToolsPlayerBody if _xr_origin else null
	if not body:
		return
	if collides:
		if _saved_player_collision_mask >= 0:
			body.collision_mask = _saved_player_collision_mask
			_saved_player_collision_mask = -1
	elif _saved_player_collision_mask < 0:
		_saved_player_collision_mask = body.collision_mask
		body.collision_mask = 0


func _apply_toy_mode_gravity(toy_mode_on: bool) -> void:
	# MovementToyModeGravity (order 5) zeros player gravity after MovementEarthGravity (order 4).
	# Do not use WorldGrabArea SPACE_OVERRIDE + zero gravity — it caused slow upward drift.
	var providers := get_tree().get_nodes_in_group("toy_mode_gravity_override")
	for node in providers:
		if "enabled" in node:
			node.enabled = toy_mode_on
		elif node is XRToolsMovementProvider:
			node.enabled = toy_mode_on
	_set_player_collides_with_world(not toy_mode_on)
	if not multiplayer.is_server() and toy_mode_on:
		set_process(true)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_toy_model_mode(enabled: bool) -> void:
	_toy_model_active = enabled
	_toy_pivot_local = Vector3.INF
	# Apply same gravity as host on clients (gravity off in toy mode so model doesn't fall).
	# Defer so client applies gravity after scene tree is ready.
	if not multiplayer.is_server():
		call_deferred("_apply_toy_mode_gravity", enabled)
	else:
		_apply_toy_mode_gravity(enabled)
	print("[ModelSyncManager] Toy model mode synced: ", enabled)


@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_model_scale(new_scale: Vector3) -> void:
	if SpectatorMode.is_active():
		return  # spectators get the world transform stream (scale included) instead
	# Clamp to minimum so clients never get zero/near-zero scale (avoids physics launch bug)
	var safe_scale := Vector3(
		maxf(new_scale.x, MIN_TOY_SCALE),
		maxf(new_scale.y, MIN_TOY_SCALE),
		maxf(new_scale.z, MIN_TOY_SCALE)
	)
	_synced_model_scale = safe_scale
	if model_root:
		_apply_toy_scale_about_pivot(safe_scale)
	model_scale_changed.emit(safe_scale)
	_refresh_qr_anchor_if_toy_mode()


## Resizes the model about its pivot (see get_toy_pivot_local), so it shrinks toward — and grows back
## from — the same spot on the floor instead of drifting toward the player.
func _apply_toy_scale_about_pivot(new_scale: Vector3) -> void:
	if not model_root:
		return
	# If QR is actively anchoring, the code is the pivot: only change scale.
	if _anchor_mode == AnchorMode.QR_CODE:
		model_root.scale = new_scale
		return

	var pivot_local := get_toy_pivot_local()
	var pivot_world := model_root.to_global(pivot_local)
	model_root.scale = new_scale
	var new_position := model_root.global_position + (pivot_world - model_root.to_global(pivot_local))
	new_position.y = maxf(new_position.y, get_toy_floor_y())
	model_root.global_position = new_position


## The point the model scales about and is placed by: the bottom centre of the plant's footprint,
## in the model's own space (the model's origin is a corner far from its middle). Because it is
## fixed in model space it travels with the model when the player moves it, so the model always
## shrinks toward and grows back from wherever it currently sits.
func get_toy_pivot_local() -> Vector3:
	if model_root and _toy_pivot_local == Vector3.INF:
		_toy_pivot_local = _compute_footprint_pivot()
	return Vector3.ZERO if _toy_pivot_local == Vector3.INF else _toy_pivot_local


## Where the pivot currently is in the world.
func get_toy_pivot_world() -> Vector3:
	return model_root.to_global(get_toy_pivot_local()) if model_root else Vector3.ZERO


func _compute_footprint_pivot() -> Vector3:
	var to_local := model_root.global_transform.affine_inverse()
	var bounds := AABB()
	var found := false
	for mesh_instance in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_instance as MeshInstance3D
		if not mesh.mesh or not mesh.is_visible_in_tree():
			continue
		# Skip shared ink strokes and placement indicators parented under the model.
		if mesh.name.begins_with("Stroke_") or mesh.get_parent().name == "SharedAnnotations" or mesh.get_parent().name.ends_with("Indicator"):
			continue
		var mesh_bounds: AABB = to_local * mesh.global_transform * mesh.get_aabb()
		if mesh_bounds.size.length() > 500.0:
			continue  # sky / ground planes, not part of the plant
		bounds = mesh_bounds if not found else bounds.merge(mesh_bounds)
		found = true
	if not found:
		return Vector3.ZERO
	var centre := bounds.get_center()
	return Vector3(centre.x, bounds.position.y, centre.z)


func _refresh_qr_anchor_if_toy_mode() -> void:
	if not _toy_model_active:
		return
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if qr_manager and qr_manager.has_method("force_reanchor_now"):
		qr_manager.force_reanchor_now()


### TOY MODE: hand / stick manipulation (host authority) ###
## ToyModelManipulator computes the pose; these apply it and keep clients in step.


## Current toy scale as the slider factor (1.0 = full size).
func get_toy_scale_factor() -> float:
	if not model_root or _original_model_scale.x <= 0.0:
		return 1.0
	return model_root.scale.x / _original_model_scale.x


## Lowest height the toy model's origin (its ground level) may reach: the arena floor, a fixed height.
## It must not follow the player: the model carries colliders, so anything tied to the player's height
## would lift the player and the model into the sky together.
func get_toy_floor_y() -> float:
	return minf(table_plane_y, _spawn_model_transform.origin.y)


## Host only: place the model so its pivot (get_toy_pivot_world) is at [param pivot_position], turned
## to [param new_yaw] and sized to [param scale_factor] (1.0 = full size), keeping it upright. Turning
## and resizing therefore happen about the pivot. The model never goes below the floor.
func apply_toy_manipulation(pivot_position: Vector3, new_yaw: float, scale_factor: float) -> void:
	if not multiplayer.is_server() or not model_root:
		return
	var new_scale := _original_model_scale * clampf(scale_factor, MIN_TOY_SCALE, 1.0)
	var rotation_basis := Basis.from_euler(Vector3(0.0, new_yaw, 0.0))
	var origin := pivot_position - rotation_basis * (get_toy_pivot_local() * new_scale)
	origin.y = maxf(origin.y, get_toy_floor_y())
	model_root.global_position = origin
	model_root.global_rotation = Vector3(0.0, new_yaw, 0.0)
	model_root.scale = new_scale
	_synced_model_transform = model_root.global_transform
	_synced_model_scale = new_scale
	_sync_toy_pose_to_clients(false)


## Host only: change only the size, leaving position and rotation untouched (QR-locked models may be tilted).
func apply_toy_scale_only(scale_factor: float) -> void:
	if not multiplayer.is_server() or not model_root:
		return
	var new_scale := _original_model_scale * clampf(scale_factor, MIN_TOY_SCALE, 1.0)
	model_root.scale = new_scale
	_synced_model_scale = new_scale
	_sync_toy_pose_to_clients(false)


## Host only: a gesture ended — send the final pose reliably.
func end_toy_manipulation() -> void:
	_sync_toy_pose_to_clients(true)


## Streams the model's scale and pose (relative to the host's XROrigin3D, like the QR path) to clients.
## Clients that are locked to their own QR code ignore the position. Mid-gesture calls are throttled
## with a trailing reliable send so the last pose always arrives.
func _sync_toy_pose_to_clients(final: bool) -> void:
	if not multiplayer.is_server() or not model_root:
		return
	var now := Time.get_ticks_msec()
	if not final and now - _last_toy_sync_msec < TOY_SYNC_INTERVAL_MSEC:
		if not _toy_sync_flush_pending:
			_toy_sync_flush_pending = true
			get_tree().create_timer(TOY_SYNC_INTERVAL_MSEC / 1000.0).timeout.connect(_flush_toy_sync)
		return
	_last_toy_sync_msec = now

	_send_qr_relative_pose(final)
	if not _xr_origin:
		_rpc_sync_model_scale.rpc(model_root.scale)
		_rpc_sync_model_position_rotation.rpc(model_root.global_position, model_root.global_rotation)
		return
	var local_t := _xr_origin.global_transform.affine_inverse() * model_root.global_transform
	var local_position := local_t.origin
	var local_rotation := local_t.basis.orthonormalized().get_euler()
	if final:
		_rpc_sync_toy_pose_final.rpc(local_position, local_rotation, model_root.scale)
	else:
		_rpc_sync_model_scale.rpc(model_root.scale)
		_rpc_sync_model_position_rotation_local.rpc(local_position, local_rotation)


func _flush_toy_sync() -> void:
	_toy_sync_flush_pending = false
	_sync_toy_pose_to_clients(true)


### SYNC: Model pose relative to the QR code ###
## Each headset has its own tracking space, so a pose relative to the host's XROrigin3D lands somewhere
## else in a client's room. A client locked to the same physical QR code instead gets the model's pose
## relative to that code (QRMarkerManager.get_shared_frame) and applies it to its own view of the code,
## so host and client see the model in the same real-world spot — including after the host moves it.

var _qr_relative_pose: Transform3D = Transform3D.IDENTITY
var _has_qr_relative_pose: bool = false


## Host: send the model's pose relative to the host's confirmed QR code (if the host has one).
## Scale is not included; it travels in _rpc_sync_model_scale.
func _send_qr_relative_pose(reliable: bool, peer_id: int = 0) -> void:
	if not multiplayer.is_server() or not model_root:
		return
	var qr := get_tree().get_first_node_in_group("qr_marker_manager")
	if not qr or not qr.has_method("has_shared_frame") or not qr.has_shared_frame():
		return
	var relative: Transform3D = (qr.get_shared_frame().affine_inverse() * model_root.global_transform).orthonormalized()
	if peer_id != 0:
		_rpc_sync_model_qr_relative_reliable.rpc_id(peer_id, relative)
	elif reliable:
		_rpc_sync_model_qr_relative_reliable.rpc(relative)
	else:
		_rpc_sync_model_qr_relative.rpc(relative)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_model_qr_relative_reliable(relative: Transform3D) -> void:
	_rpc_sync_model_qr_relative(relative)


@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_model_qr_relative(relative: Transform3D) -> void:
	_qr_relative_pose = relative
	_has_qr_relative_pose = true
	apply_qr_relative_pose()


## Client locked to its own QR code: place the model where the host has it relative to that code.
## Returns false (nothing done) when there is no host pose yet or this client isn't QR-locked.
func apply_qr_relative_pose() -> bool:
	if multiplayer.is_server() or not _has_qr_relative_pose or not model_root or SpectatorMode.is_active():
		return false
	if _anchor_mode != AnchorMode.QR_CODE:
		return false
	var qr := get_tree().get_first_node_in_group("qr_marker_manager")
	if not qr or not qr.has_method("has_shared_frame") or not qr.has_shared_frame():
		return false
	var model_scale := model_root.scale
	model_root.global_transform = qr.get_shared_frame() * _qr_relative_pose
	model_root.scale = model_scale
	_synced_model_transform = model_root.global_transform
	return true


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_toy_pose_final(local_position: Vector3, local_rotation: Vector3, new_scale: Vector3) -> void:
	_rpc_sync_model_scale(new_scale)
	_rpc_sync_model_position_rotation_local(local_position, local_rotation)


### SPECTATORS ###
## Spectators (desktop, no headset) share no tracking space with anyone, so the QR / origin-relative
## syncs mean nothing to them. The host streams the model's world transform (scale included) instead,
## and a spectator ignores the other model pose RPCs.

const SPECTATOR_STREAM_INTERVAL := 0.1
const SPECTATOR_SMOOTH_SPEED := 10.0

var _spectator_target: Transform3D = Transform3D.IDENTITY
var _spectator_has_target: bool = false


func _start_spectator_stream() -> void:
	var timer := Timer.new()
	timer.wait_time = SPECTATOR_STREAM_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_stream_pose_to_spectators)
	add_child(timer)


func _stream_pose_to_spectators() -> void:
	if not multiplayer.is_server() or not model_root:
		return
	var scene := get_tree().get_first_node_in_group("multiplayer_scene")
	if not scene or not scene.has_method("get_spectator_ids"):
		return
	for peer_id in scene.get_spectator_ids():
		_rpc_sync_model_for_spectator.rpc_id(peer_id, model_root.global_transform)


@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_model_for_spectator(world_transform: Transform3D) -> void:
	if not SpectatorMode.is_active() or not model_root:
		return
	_spectator_target = world_transform
	if not _spectator_has_target:
		_spectator_has_target = true
		model_root.global_transform = world_transform
	set_process(true)


func _smooth_toward_spectator_target(delta: float) -> void:
	var weight := 1.0 - exp(-SPECTATOR_SMOOTH_SPEED * delta)
	var current := model_root.global_transform
	var new_position := current.origin.lerp(_spectator_target.origin, weight)
	var new_rotation := current.basis.get_rotation_quaternion().slerp(_spectator_target.basis.get_rotation_quaternion(), weight)
	var new_scale := current.basis.get_scale().lerp(_spectator_target.basis.get_scale(), weight)
	model_root.global_transform = Transform3D(Basis(new_rotation).scaled(new_scale), new_position)


### NEW PEER: Send current state ###
## Client asks, host answers. The request is retried until the host's reply arrives, because the
## host's own arena may still be loading when an early client's first request lands.

const STATE_REQUEST_RETRY_SEC := 1.0
const STATE_REQUEST_MAX_TRIES := 20

var _host_state_received: bool = false
var _state_request_tries: int = 0
var _state_retry_timer: Timer


func _start_state_requests() -> void:
	_state_retry_timer = Timer.new()
	_state_retry_timer.one_shot = true
	_state_retry_timer.wait_time = STATE_REQUEST_RETRY_SEC
	_state_retry_timer.timeout.connect(_request_state_from_host)
	add_child(_state_retry_timer)
	_request_state_from_host()


func _request_state_from_host() -> void:
	if _host_state_received or not multiplayer.has_multiplayer_peer():
		return
	if _state_request_tries >= STATE_REQUEST_MAX_TRIES:
		push_warning("[ModelSyncManager] Host never answered the state request; model may be out of sync")
		return
	_state_request_tries += 1
	_rpc_request_state.rpc_id(1)
	_state_retry_timer.start()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_state() -> void:
	if not multiplayer.is_server():
		return
	_send_state_to_peer(multiplayer.get_remote_sender_id())


## Last packet of the host's reply (reliable channel is ordered, so everything before it has arrived).
@rpc("authority", "call_remote", "reliable")
func _rpc_state_complete() -> void:
	_host_state_received = true
	if _state_retry_timer:
		_state_retry_timer.stop()
	print("[ModelSyncManager] Host state received")


func _send_state_to_peer(peer_id: int) -> void:
	print("[ModelSyncManager] Sending state to new peer: ", peer_id)

	var current_scale = _synced_model_scale
	if model_root:
		current_scale = model_root.scale

	# QR position is not synced — each peer uses their own QR detection. Send global position as initial placeholder so new peer sees the model until they look at the QR.
	var current_pos = Vector3.ZERO
	var current_rot = Vector3.ZERO
	if model_root:
		current_pos = model_root.global_position
		current_rot = model_root.global_rotation
	_rpc_sync_model_position_rotation.rpc_id(peer_id, current_pos, current_rot)

	_rpc_sync_model_scale.rpc_id(peer_id, current_scale)
	_rpc_sync_ar_mode.rpc_id(peer_id, _synced_ar_mode)
	_rpc_sync_visibility.rpc_id(peer_id, _synced_show_facilities, _synced_pid_visible)
	# Send NONE for anchor mode so new peer relies on their own QR when they see it (no host QR position sync).
	_rpc_sync_anchor_mode.rpc_id(peer_id, AnchorMode.NONE, "")
	_rpc_sync_toy_model_mode.rpc_id(peer_id, _toy_model_active)
	_send_qr_relative_pose(true, peer_id)
	_rpc_state_complete.rpc_id(peer_id)
	print("[ModelSyncManager] Sent state to peer (scale, no QR position sync) scale=", current_scale)


### PUBLIC API (for menu script and etc) ###


func get_model_transform() -> Transform3D:
	return _synced_model_transform


func quick_recenter_to_camera() -> void:
	if not multiplayer.is_server() or not _xr_camera or not model_root:
		return
	var forward := -_xr_camera.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	_current_placement_pos = _xr_camera.global_position + forward * quick_recenter_distance
	_current_placement_height = quick_recenter_height
	_current_placement_rotation = _xr_camera.global_rotation.y * 180.0 / PI
	model_root.global_position = _current_placement_pos + Vector3(0.0, _current_placement_height, 0.0)
	model_root.rotation_degrees.y = _current_placement_rotation
	_stable_confirm_timer = 0.0
	_last_placement_position = Vector3.INF
	print("[ModelSyncManager] Quick recenter applied")

func is_placement_mode() -> bool:
	return _placement_mode

func is_ar_mode() -> bool:
	return _synced_ar_mode
