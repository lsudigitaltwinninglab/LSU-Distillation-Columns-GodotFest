extends XROrigin3D

## Local player rig (ar_network_arena.tscn XROrigin3D) — menu-driven movement and toy mode UX.
##
## - Movement providers: direct, turn, sprint, climb, world-grab (disabled until toy/coord modes)
## - AR mode: disables left-stick locomotion and right-stick turning
## - Toy mode: enables world-grab + toy panel; converts grip world_scale to model scale via MenuControl
## - Demo: hides host menu viewport on clients (host-only controls)
##
## Model transform/scale authority: ModelSyncManager on the host. This script does not move MainStage directly.

var movement_direct: XRToolsMovementDirect
var movement_turn: XRToolsMovementTurn
var movement_world_grab: XRToolsMovementWorldGrab
var movement_sprint: XRToolsMovementSprint
var movement_climb: XRToolsMovementClimb
var movement_footstep: XRToolsMovementFootstep
var viewport_2_din_3d_coord_adjustment: XRToolsViewport2DIn3D
var viewport_toy_model_controls: Node3D  # UI for toy model controls
var player_body: XRToolsPlayerBody
var world_scale_node: Node3D
var xr_tools_interactable_area: XRToolsInteractableArea

var saved_collision_mask: int
var saved_player_position: Vector3
var saved_player_rotation: Vector3
var initial_spawn_position: Vector3  # Position when player first joined
var initial_spawn_rotation: Vector3
var locked_scale_collision_layer: int = 0
var toy_model_active: bool = false

# Grip pinch → model scale (world_scale is reset to 1.0 so the player stays human-sized)
var _last_world_scale: float = 1.0
var _current_model_scale: float = 1.0
var _scale_locked: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Add to group for multiplayer avatar driver discovery
	add_to_group("xr_origin")
	
	# Save initial spawn position (for reset to spawn feature)
	initial_spawn_position = global_position
	initial_spawn_rotation = rotation
	
	# Find nodes with fallback paths (different scenes use different structures)
	movement_direct = get_node_or_null("LeftController/MovementDirect")
	if not movement_direct:
		movement_direct = get_node_or_null("LeftHand/MovementDirect")
	
	movement_turn = get_node_or_null("RightController/MovementTurn")
	if not movement_turn:
		movement_turn = get_node_or_null("RightHand/MovementTurn")
	
	movement_world_grab = get_node_or_null("MovementWorldGrab")
	movement_sprint = get_node_or_null("MovementSprint")
	movement_climb = get_node_or_null("MovementClimb")
	movement_footstep = get_node_or_null("MovementFootstep")
	player_body = get_node_or_null("PlayerBody")
	viewport_2_din_3d_coord_adjustment = get_node_or_null("XRCamera3D/Viewport2Din3D_Coord_Adjustment")
	viewport_toy_model_controls = get_node_or_null("XRCamera3D/Viewport2Din3D_ToyModel")
	world_scale_node = get_node_or_null("XRCamera3D/WorldScale")
	xr_tools_interactable_area = get_node_or_null("XRCamera3D/WorldScale/LockScaleButton/XRToolsInteractableArea")
	
	# Debug: Log what nodes were found
	print("[XRPlayerPointer] Movement Direct: ", movement_direct != null)
	print("[XRPlayerPointer] Movement Turn: ", movement_turn != null)
	print("[XRPlayerPointer] Movement World Grab: ", movement_world_grab != null)
	print("[XRPlayerPointer] Movement Sprint: ", movement_sprint != null)
	print("[XRPlayerPointer] Movement Climb: ", movement_climb != null)
	print("[XRPlayerPointer] Movement Footstep: ", movement_footstep != null)
	print("[XRPlayerPointer] Player Body: ", player_body != null)
	print("[XRPlayerPointer] Toy Model Viewport: ", viewport_toy_model_controls != null)
	print("[XRPlayerPointer] Initial spawn position: ", initial_spawn_position)
	
	# Demo mode: clients only get the pencil in the menu (host controls everything else)
	if multiplayer.multiplayer_peer and not multiplayer.is_server():
		var menu_viewport = get_node_or_null("Viewport2Din3D_Menu")
		if menu_viewport:
			menu_viewport.visible = false
			print("[XRPlayerPointer][DemoMode] Client: menu limited to pencil (peer_id=%s)" % multiplayer.get_unique_id())
		else:
			print("[XRPlayerPointer][DemoMode] Client: Viewport2Din3D_Menu not found")
	else:
		print("[XRPlayerPointer][DemoMode] Host: menu available (peer_id=%s)" % (multiplayer.get_unique_id() if multiplayer.multiplayer_peer else "none"))
	_connect_menu_signal()
	if player_body:
		saved_collision_mask = player_body.collision_mask # store collision mask to toggle on/off for ToyModelMode
		_ignore_own_hands()
	# Keep world-grab disabled in normal movement to prevent accidental flying/drift.
	if movement_world_grab:
		movement_world_grab.enabled = false
	if xr_tools_interactable_area:
		locked_scale_collision_layer = xr_tools_interactable_area.collision_layer
		xr_tools_interactable_area.collision_layer = 0 # Button collisions only active in ToyModelMode
	if movement_footstep and movement_footstep.has_signal("footstep"):
		movement_footstep.footstep.connect(_on_footstep)
	set_process(false)


### Own hands never push the player ###
## The player body collides with layers 1-25, which includes the hands' poke spheres (layer 18) and whatever
## the hands are holding. A hand reaching into the body then made move_and_slide shove the player away
## along the hand, sending them flying. Exempt everything the player's own hands carry.

func _ignore_own_hands() -> void:
	for hand_name in ["LeftHand", "RightHand"]:
		var hand := get_node_or_null(hand_name)
		if not hand:
			continue
		for node in hand.find_children("*", "PhysicsBody3D", true, false):
			_set_ignored_by_body(node as PhysicsBody3D, true)
		var pickup := hand.get_node_or_null("FunctionPickup") as XRToolsFunctionPickup
		if pickup:
			pickup.has_picked_up.connect(func(what): _set_ignored_by_body(what as PhysicsBody3D, true))
			pickup.has_dropped.connect(func(): _release_held_exceptions())


var _held_exceptions: Array[PhysicsBody3D] = []


func _set_ignored_by_body(body: PhysicsBody3D, ignored: bool) -> void:
	if not body or not player_body or body == player_body:
		return
	if ignored:
		player_body.add_collision_exception_with(body)
		body.add_collision_exception_with(player_body)
		if body is XRToolsPickable and not _held_exceptions.has(body):
			_held_exceptions.append(body)
	else:
		player_body.remove_collision_exception_with(body)
		body.remove_collision_exception_with(player_body)


## Something was let go: stop ignoring held objects that neither hand holds any more.
func _release_held_exceptions() -> void:
	var still_held: Array = []
	for hand_name in ["LeftHand", "RightHand"]:
		var pickup := get_node_or_null(hand_name + "/FunctionPickup") as XRToolsFunctionPickup
		if pickup and is_instance_valid(pickup.picked_up_object):
			still_held.append(pickup.picked_up_object)
	for body in _held_exceptions.duplicate():
		if not is_instance_valid(body):
			_held_exceptions.erase(body)
		elif not still_held.has(body):
			_set_ignored_by_body(body, false)
			_held_exceptions.erase(body)


func _process(_delta: float) -> void:
	# Sprint while airborne can feel like floating; force-stop sprint until grounded again.
	if movement_sprint and player_body and not player_body.on_ground and movement_sprint.is_active:
		movement_sprint.set_sprinting(false)

	# Grip turning and stick slide / turn / scale of the model live in ToyModelManipulator (scripts/plant).
	# World-grab stays off in toy mode, so world_scale must stay at 1.0 to keep the player human-sized.
	if toy_model_active and XRServer.world_scale != 1.0:
		XRServer.world_scale = 1.0
		_last_world_scale = 1.0


func _connect_menu_signal() -> void:
	# Connect all signals to the Main Menu
	if MenuControl.has_signal("player_movement_locked"):
		MenuControl.connect("player_movement_locked", Callable(self, "_on_player_movement_locked"))
	else:
		print("player_movement_locked signal not found!")
	
	if MenuControl.has_signal("coordinate_adjustment_activated"):
		MenuControl.connect("coordinate_adjustment_activated", Callable(self, "_on_coordinate_adjustment_activated"))
	else:
		print("coordinate_adjustment_activated signal not found!")
	
	if MenuControl.has_signal("toy_model_mode"):
		MenuControl.connect("toy_model_mode", Callable(self, "_on_toy_model_mode_activated"))
	else:
		print("toy_model_mode signal not found!")
	
	# New toy model controls
	# reset_to_spawn_requested resets the model (ModelSyncManager), not the player, so it isn't wired here.
	
	if MenuControl.has_signal("toy_scale_changed"):
		MenuControl.connect("toy_scale_changed", Callable(self, "_on_toy_scale_changed"))
	
	if MenuControl.has_signal("keep_toy_scale_requested"):
		MenuControl.connect("keep_toy_scale_requested", Callable(self, "_on_keep_toy_scale"))
	
	if MenuControl.has_signal("reset_toy_scale_requested"):
		MenuControl.connect("reset_toy_scale_requested", Callable(self, "_on_reset_toy_scale"))
	
	if MenuControl.has_signal("scale_lock_changed"):
		MenuControl.connect("scale_lock_changed", Callable(self, "_on_scale_lock_changed"))
	
	# AR mode - lock movement when in AR
	if MenuControl.has_signal("ar_state_changed"):
		MenuControl.connect("ar_state_changed", Callable(self, "_on_ar_mode_changed"))


var _ar_mode_active: bool = false

### AR mode — restrict locomotion ###

func _on_ar_mode_changed(ar_enabled: bool) -> void:
	_ar_mode_active = ar_enabled
	print("[XRPlayerPointer] AR mode changed: ", ar_enabled)
	
	# Lock left stick (direct movement) and right stick (turning) in AR mode: the virtual world must stay
	# lined up with the real room, so the player only moves and turns by physically walking and turning.
	if movement_direct:
		movement_direct.enabled = not ar_enabled
	if movement_turn:
		movement_turn.enabled = not ar_enabled
	print("[XRPlayerPointer] Stick movement and turning ", "DISABLED for AR mode" if ar_enabled else "ENABLED for VR mode")


func _on_player_movement_locked(toggled_on: bool) -> void:
	print("[XRPlayerPointer] Movement locked: ", toggled_on)
	if toggled_on:
		# Lock all movement
		if movement_world_grab:
			movement_world_grab.enabled = false
			print("[XRPlayerPointer] World Grab disabled")
		if movement_direct:
			movement_direct.enabled = false
			print("[XRPlayerPointer] Direct movement disabled")
		if movement_turn:
			movement_turn.enabled = false
			print("[XRPlayerPointer] Turn movement disabled")
		if movement_sprint:
			movement_sprint.enabled = false
			print("[XRPlayerPointer] Sprint disabled")
		if movement_climb:
			movement_climb.enabled = false
			print("[XRPlayerPointer] Climb disabled")
	else:
		# Unlock movement
		if movement_world_grab:
			movement_world_grab.enabled = false
			print("[XRPlayerPointer] World Grab disabled")
		# AR mode keeps stick movement and turning off (see _on_ar_mode_changed).
		if movement_direct:
			movement_direct.enabled = not _ar_mode_active
			print("[XRPlayerPointer] Direct movement enabled: ", movement_direct.enabled)
		if movement_turn:
			movement_turn.enabled = not _ar_mode_active
			print("[XRPlayerPointer] Turn movement enabled: ", movement_turn.enabled)
		if movement_sprint:
			movement_sprint.enabled = true
			print("[XRPlayerPointer] Sprint enabled")
		if movement_climb:
			movement_climb.enabled = true
			print("[XRPlayerPointer] Climb enabled")
		
		
func _on_coordinate_adjustment_activated(toggled_on: bool) -> void:
	if toggled_on:
		if movement_world_grab:
			movement_world_grab.enabled = true
			movement_world_grab.world_scale_min = 1.0
			movement_world_grab.world_scale_max = 1.0
		if viewport_2_din_3d_coord_adjustment:
			viewport_2_din_3d_coord_adjustment.visible = true
	else:
		if movement_world_grab:
			movement_world_grab.enabled = false
		if viewport_2_din_3d_coord_adjustment:
			viewport_2_din_3d_coord_adjustment.visible = false

### Toy model mode — world grab, UI, grip scaling ###

func _on_toy_model_mode_activated(toggled_on: bool) -> void:
	toy_model_active = toggled_on
	set_process(toggled_on)
	print("[XRPlayerPointer] Toy Model Mode: ", toggled_on)
	
	if toggled_on:
		# Model scaling mode - model shrinks via slider or grip gestures
		saved_player_position = global_position
		saved_player_rotation = rotation
		
		# Reset scale tracking
		_current_model_scale = 1.0
		_last_world_scale = 1.0
		XRServer.world_scale = 1.0
		
		# Grips now turn the model in place (ToyModelManipulator), not grab the world.
		if movement_world_grab:
			movement_world_grab.enabled = false
		if world_scale_node:
			world_scale_node.visible = true
		if viewport_toy_model_controls:
			viewport_toy_model_controls.visible = true
		if xr_tools_interactable_area:
			xr_tools_interactable_area.collision_layer = locked_scale_collision_layer
	else:
		# Exiting toy model mode - ensure world_scale is reset
		XRServer.world_scale = 1.0
		_last_world_scale = 1.0
		
		if movement_world_grab:
			movement_world_grab.world_scale_min = 1.0
			movement_world_grab.world_scale_max = 1.0
		if player_body:
			player_body.collision_mask = saved_collision_mask
		if world_scale_node:
			world_scale_node.visible = false
		if viewport_toy_model_controls:
			viewport_toy_model_controls.visible = false
		if xr_tools_interactable_area:
			xr_tools_interactable_area.collision_layer = 0


## Reset player to initial spawn position
func _on_reset_to_spawn() -> void:
	print("[XRPlayerPointer] Resetting to spawn position")
	global_position = initial_spawn_position
	rotation = initial_spawn_rotation


## Handle scale slider changes - model scale is handled by ModelSyncManager
func _on_toy_scale_changed(scale_value: float) -> void:
	if not toy_model_active:
		return
	# Track the current model scale (for grip gesture calculations)
	_current_model_scale = scale_value
	# Model scaling is handled by ModelSyncManager via MenuControl.toy_scale_changed signal
	print("[XRPlayerPointer] Toy scale changed to: ", scale_value * 100.0, "%")


## Keep the current model scale when exiting toy model mode
func _on_keep_toy_scale() -> void:
	# Model scale persistence is handled by ModelSyncManager
	print("[XRPlayerPointer] Model scale will be kept")


## Reset model scale back to normal (100%)
func _on_reset_toy_scale() -> void:
	# Model scale reset is handled by ModelSyncManager
	_current_model_scale = 1.0
	print("[XRPlayerPointer] Model scale reset requested")


## Scale lock changed - prevents grip gestures from changing scale
func _on_scale_lock_changed(locked: bool) -> void:
	_scale_locked = locked
	print("[XRPlayerPointer] Scale lock: ", locked)


func _on_footstep(_surface_name: String) -> void:
	# Lightweight haptic pulse on each generated step.
	XRToolsRumbleManager.add(self, preload("res://addons/godot-xr-tools/rumble/tap_rumble.tres"), [StringName("left_hand"), StringName("right_hand")])
