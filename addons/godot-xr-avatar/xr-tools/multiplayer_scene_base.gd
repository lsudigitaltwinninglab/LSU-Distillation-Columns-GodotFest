class_name MultiplayerSceneBase
extends XRToolsSceneBase

## XR-Avatar Multiplayer Scene Base Script
##
## This script extends [XRToolsSceneBase] to provide a scene capable of hosting
## multiple network players. The multiplayer peer must be established in a lobby
## before switching to this scene.

# Local avatar
var _avatar : XRAvatarBase

# Dictionary of peers to avatars
var _peers := {}

# Spectators (desktop peers with no avatar) — server only: peer id -> true.
# They see every avatar but never get one, so they're told about arrivals separately.
var _spectators := {}

func _ready() -> void:
	super()
	add_to_group("multiplayer_scene")


## Peer ids of the spectators in this zone (server only; empty elsewhere).
func get_spectator_ids() -> Array:
	return _spectators.keys()


# Called when this scene is loaded
func scene_loaded(user_data = null):
	print("[MultiplayerSceneBase] scene_loaded() starting")
	print("[MultiplayerSceneBase] Checking nodes before super()...")
	print("[MultiplayerSceneBase] XROrigin3D exists: ", get_node_or_null("XROrigin3D") != null)
	print("[MultiplayerSceneBase] XRCamera3D exists: ", get_node_or_null("XROrigin3D/XRCamera3D") != null)
	print("[MultiplayerSceneBase] Avatars exists: ", get_node_or_null("Avatars") != null)
	print("[MultiplayerSceneBase] Calling super()")
	super(user_data)
	print("[MultiplayerSceneBase] super() complete")

	# Subscribe to peer disconnection to remove stale peers/avatars
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[MultiplayerSceneBase] peer_disconnected connected")

	# Spectators watch only: no local avatar, and nobody else gets an avatar for them.
	if SpectatorMode.is_active():
		print("[MultiplayerSceneBase] Spectator joining zone")
		_spectator_entering_zone.rpc_id(1, multiplayer.get_unique_id())
		return

	# Create the local avatar
	print("[MultiplayerSceneBase] Creating local avatar for peer: ", multiplayer.get_unique_id())
	_avatar = _add_avatar(multiplayer.get_unique_id())
	print("[MultiplayerSceneBase] Local avatar created: ", _avatar)

	# Inform the server we are entering the zone
	print("[MultiplayerSceneBase] Calling _peer_entering_zone RPC")
	_peer_entering_zone.rpc_id(1, multiplayer.get_unique_id())
	print("[MultiplayerSceneBase] scene_loaded() complete")


# Called when we start to exit this scene
func scene_pre_exiting(user_data = null):
	super(user_data)

	# Suspend synchronization to all current peers
	if _avatar:
		for p in _peers:
			_avatar.set_visibility_for(p, false)

	# Inform the server this peer is leaving the zone
	_peer_exiting_zone.rpc_id(1, multiplayer.get_unique_id())


# Called on the server by a peer when it starts entering this zone
@rpc("any_peer", "call_local", "reliable")
func _peer_entering_zone(p_peer : int) -> void:
	# Notify the new peer of existing peers
	if p_peer != 1:
		_peers_in_zone.rpc_id(p_peer, _peers.keys())

	# Notify current peers of the new arival
	for p in _peers:
		_peer_entered_zone.rpc_id(p, p_peer)

	# Spectators get an avatar for the new peer, and the new peer shows its avatar to them
	for s in _spectators:
		_spectator_add_avatar.rpc_id(s, p_peer)
		_show_avatar_to_spectator.rpc_id(p_peer, s)


# Called on the server by a spectator when it enters this zone
@rpc("any_peer", "call_remote", "reliable")
func _spectator_entering_zone(_p_peer : int) -> void:
	if not multiplayer.is_server():
		return
	var spectator := multiplayer.get_remote_sender_id()
	_spectators[spectator] = true

	# Spectator creates avatars for everyone already here, and each of them shows theirs to it
	_peers_in_zone.rpc_id(spectator, _peers.keys())
	for p in _peers:
		_show_avatar_to_spectator.rpc_id(p, spectator)


# Called on a peer by the server so its avatar syncs to a spectator
@rpc("authority", "call_local", "reliable")
func _show_avatar_to_spectator(p_spectator : int) -> void:
	if _avatar:
		_avatar.set_visibility_for(p_spectator, true)


# Called on a spectator by the server when a new peer enters the zone
@rpc("authority", "call_remote", "reliable")
func _spectator_add_avatar(p_peer : int) -> void:
	_add_avatar(p_peer)


# Called on a new peer by the server with the list of current peers in this zone
@rpc("authority", "call_remote", "reliable")
func _peers_in_zone(p_peers_in_zone) -> void:
	# Create avatars for all peers and show our avatar to them
	for p : int in p_peers_in_zone:
		_add_avatar(p)
		if _avatar:
			_avatar.set_visibility_for(p, true)


# Called on all peers in this zone informing them when a new peer enters
@rpc("authority", "call_local", "reliable")
func _peer_entered_zone(p_peer : int) -> void:
	# Enable local avatar to be visible to the peer
	if p_peer != multiplayer.get_unique_id() and _avatar:
		_avatar.set_visibility_for(p_peer, true)

	# Add an avatar for the new peer
	_add_avatar(p_peer)


# Called on the server by a peer when it starts exiting this zone
@rpc("any_peer", "call_local", "reliable")
func _peer_exiting_zone(p_peer : int) -> void:
	_spectators.erase(p_peer)

	# Notify current peers of the new arival
	for p in _peers:
		_peer_exited_zone.rpc_id(p, p_peer)


# Called on all peers in this zone when a peer exits the zone
@rpc("authority", "call_local", "reliable")
func _peer_exited_zone(p_peer : int) -> void:
	# Disable avatar reporting to the peer
	if _avatar:
		_avatar.set_visibility_for(p_peer, false)

	# Remove the peers avatar
	_remove_avatar(p_peer)


# Called when a peer disconnect
func _on_peer_disconnected(p_peer : int) -> void:
	_spectators.erase(p_peer)

	# Skip if peer not in this zone
	if not _peers.has(p_peer):
		return

	# Disable avatar reporting to the peer
	if _avatar:
		_avatar.set_visibility_for(p_peer, false)

	# Remove the peers avatar
	_remove_avatar(p_peer)

# Add an avatar for the peer to this zone
func _add_avatar(p_peer : int) -> XRAvatarBase:
	# Check for Avatars node
	var avatars_node = get_node_or_null("Avatars")
	if not avatars_node:
		push_error("MultiplayerSceneBase: Avatars node not found!")
		return null
	
	# Check for an existing instance
	var inst : XRAvatarBase = avatars_node.get_node_or_null(str(p_peer))
	if inst:
		return inst

	# Create the avatar
	inst = _create_avatar(p_peer)
	if not inst:
		push_error("MultiplayerSceneBase: _create_avatar returned null for peer ", p_peer)
		return null
	
	inst.name = str(p_peer)
	inst.set_multiplayer_authority(p_peer)
	avatars_node.add_child(inst)
	_peers[p_peer] = inst

	# If this avatar is local then set it as the player body avatar
	if inst.is_multiplayer_authority():
		var driver = get_node_or_null("XROrigin3D/AvatarDriverPlayerBody")
		if driver:
			inst.driver = driver
		else:
			push_error("MultiplayerSceneBase: AvatarDriverPlayerBody not found!")

	# Return the avatar
	return inst


# Remove a peers avatar from this zone
func _remove_avatar(p_peer : int) -> void:
	# Check for an existing instance
	var inst : XRAvatarBase = _peers.get(p_peer)
	if inst:
		_peers.erase(p_peer)
		inst.queue_free()


# Create an avatar for the peer (override in scene)
func _create_avatar(_peer : int) -> XRAvatarBase:
	return null
