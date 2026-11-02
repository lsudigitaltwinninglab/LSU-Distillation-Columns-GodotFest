extends MultiplayerSceneBase

## AR Network Arena — multiplayer XR session for passthrough demo.
##
## Responsibilities:
## - Host-authoritative model sync via Map/ModelSyncManager
## - Arena room (Map/ArenaGround + Map/ArenaWalls): beige floor and walls; hidden in AR + toy mode; collision stays on
## - MainStage plant floor mesh hidden and its collider turned off at load (the arena floor is the only floor)
## - Toy mode: hide demo clutter (ladders, PID, etc.) so only the scaled plant remains
## - Runtime stair box colliders + Syngenta collision volume bake for walking
## - Longer ENet timeouts so idle headsets do not drop clients

const AVATAR := preload("res://addons/godot-xr-avatar/avatars/human/base_avatar.tscn")
const LOBBY_SCENE := "res://scenes/network/lobby/network_lobby.tscn"
## Show the arena floor and walls? Off: they are invisible but still solid.
const ARENA_ROOM_VISIBLE := false
## Explicit nodes to hide when toy model mode is on (clutter that isn't part of the plant).
## Not the P&ID: toy mode turns it off through pid_visible_toggled, and showing it again on exit here
## would bypass the P&ID toggle (it popped up under the model).
const TOY_MODE_HIDE_PATHS := [
	"Map/MainStage/SceneCollection/SampleBox"
]
## Arena props that belong to the plant and must move, turn and scale with it (they were placed at the
## plant's own spot, so they are re-parented under the model root keeping their current transform).
const MODEL_ATTACHED_PROPS := ["Map/Ladder"]
## Blender stair mesh names — each gets a simple box ramp collider at runtime.
const STAIR_NODE_NAMES := [
	"SP_STairGenerator_001",
	"SP_STairGenerator_002",
	"SP_STairGenerator_003",
	"SP_StairGenerator_001",
	"SP_StairGenerator_002",
	"SP_StairGenerator_003"
]
const ANKLE_HEIGHT_Y := 0.15

## ENet peer timeout: keep clients connected when headset is off (idle). Default is ~30s.
## Increase so client doesn't disconnect if they take the headset off for a minute or two.
const PEER_TIMEOUT_MAX_MS := 120000  # 2 minutes max before disconnect (was ENet default ~30s)
const PEER_TIMEOUT_MIN_MS := 5000
const PEER_TIMEOUT_FACTOR_MS := 5000

@onready var map_root: Node = $Map
@onready var model_sync_manager: Node = $Map/ModelSyncManager
@onready var arena_ground_mesh: MeshInstance3D = $Map/ArenaGround/Ground_MeshInstance3D
@onready var arena_walls: Node3D = $Map/ArenaWalls

var _toy_mode_targets: Array[Node3D] = []
## VR default: floor + walls visible; hidden in AR / toy mode (collision stays on).
var _arena_ar_active: bool = false
var _arena_toy_active: bool = false


func _ready() -> void:
	super()

	# Subscribe to network events
	var disconnected_callback := Callable(self, "_on_server_disconnected")
	if not multiplayer.server_disconnected.is_connected(disconnected_callback):
		multiplayer.server_disconnected.connect(disconnected_callback)

	_cache_toy_mode_targets()
	_connect_toy_mode_cleanup()
	_connect_arena_ground_visibility()
	if model_sync_manager and model_sync_manager.has_signal("ar_mode_synced"):
		var ar_net_cb := Callable(self, "_on_ar_mode_network_synced")
		if not model_sync_manager.ar_mode_synced.is_connected(ar_net_cb):
			model_sync_manager.ar_mode_synced.connect(ar_net_cb)


func _exit_tree() -> void:
	if ServiceDiscovery and ServiceDiscovery.is_servering:
		ServiceDiscovery.close_server()

	var disconnected_callback := Callable(self, "_on_server_disconnected")
	if multiplayer.server_disconnected.is_connected(disconnected_callback):
		multiplayer.server_disconnected.disconnect(disconnected_callback)

	var peer_connected_callback := Callable(self, "_on_peer_connected_set_timeout")
	if multiplayer.peer_connected.is_connected(peer_connected_callback):
		multiplayer.peer_connected.disconnect(peer_connected_callback)

	if MenuControl and MenuControl.has_signal("toy_model_mode"):
		var toy_mode_callback := Callable(self, "_on_toy_model_mode_cleanup")
		if MenuControl.toy_model_mode.is_connected(toy_mode_callback):
			MenuControl.toy_model_mode.disconnect(toy_mode_callback)

	if MenuControl and MenuControl.has_signal("ar_state_changed"):
		var ar_cb := Callable(self, "_on_arena_ar_visibility_changed")
		if MenuControl.ar_state_changed.is_connected(ar_cb):
			MenuControl.ar_state_changed.disconnect(ar_cb)

	if model_sync_manager and model_sync_manager.has_signal("ar_mode_synced"):
		var ar_net_cb := Callable(self, "_on_ar_mode_network_synced")
		if model_sync_manager.ar_mode_synced.is_connected(ar_net_cb):
			model_sync_manager.ar_mode_synced.disconnect(ar_net_cb)


func scene_loaded(user_data = null):
	super(user_data)

	# No headset: watch through the spectator camera instead of an XR rig.
	if SpectatorMode.is_active():
		_start_spectator()

	_attach_props_to_model()

	# Set up ModelSyncManager authority (host controls model sync)
	if model_sync_manager:
		if multiplayer.is_server():
			model_sync_manager.set_multiplayer_authority(1)  # Server is authority
	
	# Ensure QR manager has XR session connected on all peers (same tracking logic as host)
	_ensure_qr_manager_session()
	_hide_main_stage_ground_visual()
	call_deferred("_disable_map_shadow_casting")
	_configure_stair_walkables()
	_build_syngenta_static_colliders()
	
	# ENet: longer peer timeout so client doesn't disconnect when headset is off (idle)
	_apply_peer_timeouts()
	var peer_connected_callback := Callable(self, "_on_peer_connected_set_timeout")
	if not multiplayer.peer_connected.is_connected(peer_connected_callback):
		multiplayer.peer_connected.connect(peer_connected_callback)

	# Defer so ModelSyncManager has applied any join-time AR RPC before we read is_ar_mode().
	call_deferred("_sync_arena_ground_mesh_from_network_state")

	# Host: only advertise on the LAN now that this arena can answer RPCs from joining clients.
	if multiplayer.is_server() and ServiceDiscovery:
		ServiceDiscovery.set_server()


### Props that belong to the plant ###

## The climbable ladder (and anything else listed in MODEL_ATTACHED_PROPS) was placed at the plant's own spot in
## the arena scene, so it stayed behind whenever toy mode moved or shrank the plant. Re-parent it under the
## model root, keeping where it is now, and it follows the model's position, rotation and scale from then on.
func _attach_props_to_model() -> void:
	var model := get_node_or_null("Map/MainStage") as Node3D
	if not model:
		return
	for path in MODEL_ATTACHED_PROPS:
		var prop := get_node_or_null(path) as Node3D
		if prop and prop.get_parent() != model:
			prop.reparent(model, true)


### Spectator (desktop, no headset) ###

func _start_spectator() -> void:
	# The XR rig (hands, menus, movement, physics body) is unused without a headset.
	var origin := get_node_or_null("XROrigin3D")
	if origin:
		origin.process_mode = Node.PROCESS_MODE_DISABLED
		origin.visible = false

	var controller := SpectatorController.new()
	controller.name = "SpectatorController"
	add_child(controller)
	controller.setup(get_node_or_null("Avatars"))


### Arena floor visibility (Map/ArenaGround/Ground_MeshInstance3D) ###

func _on_ar_mode_network_synced(ar_enabled: bool) -> void:
	_arena_ar_active = ar_enabled
	_update_arena_ground_mesh_visibility()


func _connect_arena_ground_visibility() -> void:
	if MenuControl and MenuControl.has_signal("ar_state_changed"):
		var ar_cb := Callable(self, "_on_arena_ar_visibility_changed")
		if not MenuControl.ar_state_changed.is_connected(ar_cb):
			MenuControl.ar_state_changed.connect(ar_cb)


func _on_arena_ar_visibility_changed(ar_enabled: bool) -> void:
	_arena_ar_active = ar_enabled
	_update_arena_ground_mesh_visibility()


func _sync_arena_ground_mesh_from_network_state() -> void:
	if model_sync_manager and model_sync_manager.has_method("is_ar_mode"):
		_arena_ar_active = model_sync_manager.is_ar_mode()
	_update_arena_ground_mesh_visibility()


func _update_arena_ground_mesh_visibility() -> void:
	# The arena room is invisible but solid: only the meshes are hidden, the StaticBody3D collision
	# (floor + walls) stays, so players still stand on the floor and can't walk through the walls.
	# Set ARENA_ROOM_VISIBLE to true to see the room again (e.g. while debugging).
	var room_visible := ARENA_ROOM_VISIBLE and not (_arena_ar_active or _arena_toy_active)
	if arena_ground_mesh:
		arena_ground_mesh.visible = room_visible
	if arena_walls:
		arena_walls.visible = room_visible


### Toy mode — hide demo geometry ###

func _connect_toy_mode_cleanup() -> void:
	if MenuControl and MenuControl.has_signal("toy_model_mode"):
		var toy_mode_callback := Callable(self, "_on_toy_model_mode_cleanup")
		if not MenuControl.toy_model_mode.is_connected(toy_mode_callback):
			MenuControl.toy_model_mode.connect(toy_mode_callback)


func _on_toy_model_mode_cleanup(toggled_on: bool) -> void:
	_arena_toy_active = toggled_on
	_update_arena_ground_mesh_visibility()
	# Hide all demo clutter while toy mode is on (Syngenta plant stays under MainStage; QR lock handles placement).
	for target in _toy_mode_targets:
		target.visible = not toggled_on

	if toggled_on and MenuControl and MenuControl.has_signal("pid_visible_toggled"):
		MenuControl.emit_signal("pid_visible_toggled", false)


func _cache_toy_mode_targets() -> void:
	_toy_mode_targets.clear()

	for path in TOY_MODE_HIDE_PATHS:
		var node := get_node_or_null(path)
		if node is Node3D:
			_add_toy_mode_target(node as Node3D)


func _add_toy_mode_target(node: Node3D) -> void:
	if _toy_mode_targets.has(node):
		return
	_toy_mode_targets.append(node)


### Walkability — stairs and plant collision ###

func _configure_stair_walkables() -> void:
	var main_stage := get_node_or_null("Map/MainStage")
	if not main_stage:
		return

	for stair_name in STAIR_NODE_NAMES:
		var stair_node := _find_node_by_name(main_stage, stair_name)
		if stair_node:
			_ensure_stair_ramp(stair_node)


func _hide_main_stage_ground_visual() -> void:
	# Hide the plant's ground mesh (passthrough / toy table) and turn off its collider: the arena has its own
	# fixed floor (Map/ArenaGround). The plant's ground is a 128 m slab that moves and turns with the model, so
	# a QR lock lifting or tilting the model swung it up through the player and shoved them out of the arena.
	var main_stage := get_node_or_null("Map/MainStage")
	if not main_stage:
		return
	var ground_body := main_stage.get_node_or_null("SceneCollection/Ground") as StaticBody3D
	if ground_body:
		ground_body.collision_layer = 0
		ground_body.collision_mask = 0
	# main_stage.gd would otherwise switch this ground mesh back on in VR mode.
	if "ground_always_hidden" in main_stage:
		main_stage.ground_always_hidden = true
	var mesh := main_stage.get_node_or_null("SceneCollection/Ground/Ground_MeshInstance3D") as MeshInstance3D
	if mesh:
		mesh.visible = false
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Disable shadow casting on all arena geometry (ground, ladders, plant GLB children).
func _disable_map_shadow_casting() -> void:
	if not map_root:
		return
	for node in map_root.find_children("*", "GeometryInstance3D", true, false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var key_light := map_root.get_node_or_null("MainStage/DirectionalLight3D") as DirectionalLight3D
	if key_light:
		key_light.shadow_enabled = false


func _ensure_stair_ramp(stair_root: Node) -> void:
	if stair_root.get_node_or_null("StairRampCollider"):
		return
	var mesh_node: MeshInstance3D = null
	if stair_root is MeshInstance3D:
		mesh_node = stair_root as MeshInstance3D
	else:
		var mesh_children := stair_root.find_children("*", "MeshInstance3D", true, false)
		if not mesh_children.is_empty():
			mesh_node = mesh_children[0] as MeshInstance3D
	if not mesh_node or not mesh_node.mesh:
		return

	var aabb := mesh_node.mesh.get_aabb()
	var size := aabb.size
	if size.length() <= 0.01:
		return

	var ramp_body := StaticBody3D.new()
	ramp_body.name = "StairRampCollider"
	ramp_body.collision_layer = 1
	ramp_body.collision_mask = 0
	stair_root.add_child(ramp_body)
	ramp_body.global_transform = mesh_node.global_transform

	var ramp_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(size.x, 0.4), maxf(size.y * 0.35, 0.15), maxf(size.z, 0.4))
	ramp_shape.shape = box
	ramp_body.add_child(ramp_shape)
	ramp_shape.transform.origin = Vector3(aabb.position.x + size.x * 0.5, aabb.position.y + size.y * 0.5, aabb.position.z + size.z * 0.5)


func _build_syngenta_static_colliders() -> void:
	var main_stage := get_node_or_null("Map/MainStage")
	if not main_stage:
		return

	var collision_volumes := main_stage.get_node_or_null("Collision Volumes")
	if not collision_volumes:
		return

	var generated := main_stage.get_node_or_null("GeneratedCollisionBodies")
	if generated:
		return
	generated = Node3D.new()
	generated.name = "GeneratedCollisionBodies"
	main_stage.add_child(generated)

	for source in collision_volumes.get_children():
		if not source is Area3D:
			continue

		var shape_nodes := source.find_children("*", "CollisionShape3D", true, false)
		for shape_node in shape_nodes:
			var source_shape := shape_node as CollisionShape3D
			if not source_shape.shape:
				continue
			if source_shape.global_position.y < ANKLE_HEIGHT_Y:
				continue

			var body := StaticBody3D.new()
			body.name = "%s_Body" % source.name
			body.collision_layer = 1
			body.collision_mask = 0
			generated.add_child(body)
			body.global_transform = source.global_transform

			var collider := CollisionShape3D.new()
			collider.shape = source_shape.shape.duplicate(true)
			body.add_child(collider)
			collider.global_transform = source_shape.global_transform


func _find_node_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found := _find_node_by_name(child, target_name)
		if found:
			return found
	return null


### Network / QR / avatars ###

func _ensure_qr_manager_session() -> void:
	var qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if not qr_manager or not qr_manager.has_method("_on_session_begun"):
		return
	var xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface:
		return
	if xr_interface.has_signal("session_begun") and not xr_interface.session_begun.is_connected(qr_manager._on_session_begun):
		xr_interface.session_begun.connect(qr_manager._on_session_begun)
	if xr_interface.has_signal("session_stopping") and not xr_interface.session_stopping.is_connected(qr_manager._on_session_ended):
		xr_interface.session_stopping.connect(qr_manager._on_session_ended)
	if xr_interface.is_initialized():
		qr_manager._on_session_begun()


func _on_server_disconnected() -> void:
	# On server disconnect switch back to the lobby
	load_scene(LOBBY_SCENE)


### ENet — keep peers connected when headset is idle ###

func _apply_peer_timeouts() -> void:
	var enet_peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if not enet_peer:
		return
	# Client: set longer timeout for the server connection (peer id 1)
	if not multiplayer.is_server():
		var server_peer = enet_peer.get_peer(1)
		if server_peer:
			server_peer.set_timeout(PEER_TIMEOUT_FACTOR_MS, PEER_TIMEOUT_MIN_MS, PEER_TIMEOUT_MAX_MS)
		return
	# Server: set longer timeout for each connected client
	for peer_id in multiplayer.get_peers():
		var peer = enet_peer.get_peer(peer_id)
		if peer:
			peer.set_timeout(PEER_TIMEOUT_FACTOR_MS, PEER_TIMEOUT_MIN_MS, PEER_TIMEOUT_MAX_MS)


func _on_peer_connected_set_timeout(peer_id: int) -> void:
	# Server: when a new client joins, give them the longer timeout
	if not multiplayer.is_server():
		return
	var enet_peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if not enet_peer:
		return
	var peer = enet_peer.get_peer(peer_id)
	if peer:
		peer.set_timeout(PEER_TIMEOUT_FACTOR_MS, PEER_TIMEOUT_MIN_MS, PEER_TIMEOUT_MAX_MS)


func _create_avatar(p_peer : int) -> XRAvatarBase:
	var avatar = AVATAR.instantiate()
	return avatar
