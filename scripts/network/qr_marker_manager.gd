extends Node3D
class_name QRMarkerManager

## QR marker manager — pins the model to a physical QR code (OpenXR marker tracking).
##
## Design: QR position is intentionally NOT networked. Each peer runs OpenXR marker
## tracking locally and anchors the model in their own XR space. When all headsets
## look at the same physical QR code, they align naturally without streaming pose data.
##
## Flow:
## 1. OpenXR session begins → scan for marker-type XR trackers (including ones that already exist)
## 2. On detect → create XRAnchor3D under XROrigin3D. The model is NOT moved yet.
## 3. EVERY update from the code goes through look-to-confirm: the player keeps looking at it for
##    confirm_look_time seconds (a ring fills up in its middle), then the model snaps to the code's
##    pose as it was at that moment, and the host sends that pose to clients over a reliable RPC.
##    That covers the first lock, switching to another code, and the locked code having moved (by
##    more than UPDATE_MIN_DISTANCE / UPDATE_MIN_ANGLE). Nothing follows the code live, so tracking
##    noise or a glimpse never moves the model.
## 4. Re-locking (QR Lock button, toy mode on/off, a scale change) re-applies the last confirmed pose
##    without reading the code again. If the tracker is removed the model stays where it was.
##
## The lock can be released (set_lock_enabled(false), the toy panel's "QR Lock" button) so the
## model can be repositioned by hand while the marker keeps being tracked.
##
## Anchors must be children of XROrigin3D for correct positioning in local tracking space.

signal marker_detected(marker_transform: Transform3D, marker_data: String)
signal marker_lost(marker_data: String)
## Emitted when the model starts or stops being pinned to the marker.
signal lock_changed(locked: bool)

## Show debug cube at QR code location (set to false to hide)
@export var show_debug_cube: bool = false

## Cube size in meters
@export var cube_size: float = 0.1

## Cube color (pink like SidneyAR)
@export var cube_color: Color = Color(1.0, 0.46, 1.0, 1.0)

## Automatically anchor model when QR detected (each peer anchors from their own camera — no host→client position sync).
@export var auto_anchor_model: bool = true

## Copy only the marker's yaw so the model always stands level (QR codes lying on a table).
## Off (default): the model copies the marker's full rotation, so a code on a wall or tilted surface tilts it too.
@export var upright_only: bool = false

## The QR code lies flat (on a table / the floor): the model stands up on it, its up pointing out of the code.
## Turn off for a code mounted on a wall that the model should hang on, so the model's up follows the code's up.
@export var marker_lies_flat: bool = true

## Rotation offset in degrees (Y-axis) - adjust if model faces wrong direction
@export var rotation_offset_y: float = 0.0

@export var conference_demo_mode: bool = true
@export var marker_settle_time: float = 0.15
@export var small_qr_mode: bool = true
@export var small_qr_settle_time: float = 0.05

## Seconds the player must keep looking at a QR code before the model takes its pose.
@export var confirm_look_time: float = 3.0
## How far (degrees) from the centre of the player's view the code may be and still count as looked at.
@export var confirm_look_angle: float = 15.0
## Diameter of the progress ring drawn on the code, in meters.
@export var confirm_ring_size: float = 0.12
@export var confirm_ring_color: Color = Color(0.35, 0.9, 1.0, 1.0)

## The locked code only offers an update (shows its ring) once it has moved further than tracking noise.
const UPDATE_MIN_DISTANCE := 0.03  # meters
const UPDATE_MIN_ANGLE := deg_to_rad(3.0)
## At or above this size (1.0 = full) the plant collides with the player (main_stage.gd SMALL_MODEL_SCALE),
## so a QR lock only sets where it stands and which way it faces: upright, on the arena floor.
const WALKABLE_MODEL_SCALE := 0.5
## Looking away drains the confirm progress this many times faster than looking fills it, so a
## one-frame tracking dropout doesn't restart the count but a real look-away soon does.
const CONFIRM_DRAIN_RATE := 2.0

const CONFIRM_RING_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled;
uniform float progress = 0.0;
uniform vec4 fill_color : source_color = vec4(0.35, 0.9, 1.0, 1.0);
uniform vec4 track_color : source_color = vec4(1.0, 1.0, 1.0, 0.25);
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float aa = fwidth(r);
	float ring = smoothstep(0.68 - aa, 0.68, r) * (1.0 - smoothstep(0.95, 0.95 + aa, r));
	// 0 at twelve o'clock, increasing clockwise.
	float turn = mod(atan(p.x, -p.y) / 6.28318530718 + 1.0, 1.0);
	vec4 color = turn <= progress ? fill_color : track_color;
	ALBEDO = color.rgb;
	ALPHA = color.a * ring;
}
"""
static var _confirm_ring_shader: Shader

## How many marker trackers the headset has reported this session (shown on the toy panel for troubleshooting).
var markers_seen: int = 0

## True = model is pinned to the marker. False = marker still tracked, model free to be moved by hand.
var lock_enabled: bool = true

# Track created nodes keyed by tracker
var _marker_nodes: Dictionary = {}  # OpenXRMarkerTracker -> XRAnchor3D
var _tracker_count: int = 0
var _xr_origin: XROrigin3D = null  # Anchors must be children of XROrigin3D
var _model_sync_manager: Node = null
var _active_anchor: XRAnchor3D = null  # The anchor we're following
var _model_root: Node3D = null  # Cached reference to model

# The code's pose (XROrigin3D-local) when the player last confirmed it — the only marker data the model uses
var _confirmed_marker: Transform3D = Transform3D.IDENTITY
## Extra turn (radians, about world up) the toy grips added on top of the code's rotation; kept across re-locks.
var _user_yaw: float = 0.0

# Look-to-confirm: seconds each detected code has been looked at, and its ring
var _confirm_progress: Dictionary = {}  # XRAnchor3D -> float
var _confirm_rings: Dictionary = {}  # XRAnchor3D -> MeshInstance3D
var _camera: Camera3D = null


func _ready() -> void:
	add_to_group("qr_marker_manager")
	print("[QRMarkerManager] Ready - waiting for XR session")

	# Find XROrigin3D and ModelSyncManager
	await get_tree().process_frame
	_find_required_nodes()
	_connect_menu_signals()


func _connect_menu_signals() -> void:
	if not MenuControl:
		return
	if MenuControl.has_signal("toy_model_mode"):
		if not MenuControl.is_connected("toy_model_mode", _on_toy_model_mode_toggled):
			MenuControl.connect("toy_model_mode", _on_toy_model_mode_toggled)
	if MenuControl.has_signal("toy_qr_lock_changed"):
		if not MenuControl.is_connected("toy_qr_lock_changed", set_lock_enabled):
			MenuControl.connect("toy_qr_lock_changed", set_lock_enabled)


func _on_toy_model_mode_toggled(_toggled_on: bool) -> void:
	# Every toy-mode session (and the return to normal) starts pinned to the QR code.
	set_lock_enabled(true)
	force_reanchor_now()


func _find_required_nodes() -> void:
	# Find XROrigin3D - anchors must be children of it for correct positioning
	var origins = get_tree().get_nodes_in_group("xr_origin")
	if origins.size() > 0:
		_xr_origin = origins[0] as XROrigin3D
		print("[QRMarkerManager] Found XROrigin3D: ", _xr_origin.name)
	else:
		# Fallback - search for any XROrigin3D
		_xr_origin = _find_node_by_class(get_tree().root, "XROrigin3D") as XROrigin3D
		if _xr_origin:
			print("[QRMarkerManager] Found XROrigin3D by search: ", _xr_origin.name)
		else:
			print("[QRMarkerManager] WARNING: No XROrigin3D found! Anchors will be added to this node.")

	# Find ModelSyncManager for anchoring the model
	_model_sync_manager = get_tree().get_first_node_in_group("model_sync_manager")
	if _model_sync_manager:
		print("[QRMarkerManager] Found ModelSyncManager")
		_resolve_model_root()
	else:
		print("[QRMarkerManager] WARNING: ModelSyncManager not found - model won't be anchored")


func _resolve_model_root() -> bool:
	if is_instance_valid(_model_root):
		return true
	if _model_sync_manager and "model_root" in _model_sync_manager:
		_model_root = _model_sync_manager.model_root
	return is_instance_valid(_model_root)


## Runs on all peers; each uses their own QR (no position sync).
func _process(delta: float) -> void:
	_update_look_to_confirm(delta)


## Fills the ring of the code the player is looking at and drains the others; a full ring locks the
## model to that code.
func _update_look_to_confirm(delta: float) -> void:
	if not auto_anchor_model or _marker_nodes.is_empty():
		return
	var looked_at := _looked_at_marker()
	for anchor in _marker_nodes.values():
		if not is_instance_valid(anchor):
			continue
		var seconds: float = _confirm_progress.get(anchor, 0.0)
		if anchor == looked_at:
			seconds += delta
		else:
			seconds = maxf(seconds - delta * CONFIRM_DRAIN_RATE, 0.0)
		if seconds >= confirm_look_time:
			seconds = 0.0
			print("[QRMarkerManager] QR code confirmed by looking at it: ", anchor.tracker)
			_anchor_model_to_marker(anchor, str(anchor.tracker))
		_confirm_progress[anchor] = seconds
		_show_confirm_ring(anchor, seconds / confirm_look_time)


## The in-view code nearest the centre of the player's view (within confirm_look_angle) that has an
## update to give (see _offers_update).
func _looked_at_marker() -> XRAnchor3D:
	if not is_instance_valid(_camera):
		_camera = _xr_origin.get_node_or_null("XRCamera3D") as Camera3D if _xr_origin else null
		if not _camera:
			_camera = get_viewport().get_camera_3d()
		if not _camera:
			return null
	var forward := -_camera.global_transform.basis.z
	var best: XRAnchor3D = null
	var best_angle := deg_to_rad(confirm_look_angle)
	for anchor in _marker_nodes.values():
		if not is_instance_valid(anchor) or not anchor.get_has_tracking_data() or not _offers_update(anchor):
			continue
		var to_marker: Vector3 = anchor.global_position - _camera.global_position
		if to_marker.length() < 0.01:
			continue
		var angle := forward.angle_to(to_marker)
		if angle < best_angle:
			best = anchor
			best_angle = angle
	return best


## Any other code can be confirmed; the locked one only once it has really moved (and the lock is on).
func _offers_update(anchor: XRAnchor3D) -> bool:
	if anchor != _active_anchor:
		return true
	if not lock_enabled or not _xr_origin:
		return false
	var live := _marker_local(anchor)
	var turned := live.basis.get_rotation_quaternion().angle_to(_confirmed_marker.basis.get_rotation_quaternion())
	return live.origin.distance_to(_confirmed_marker.origin) > UPDATE_MIN_DISTANCE or turned > UPDATE_MIN_ANGLE


func _marker_local(anchor: XRAnchor3D) -> Transform3D:
	var t := _xr_origin.global_transform.affine_inverse() * anchor.global_transform
	return t.orthonormalized()


func _show_confirm_ring(anchor: XRAnchor3D, fraction: float) -> void:
	var ring: MeshInstance3D = _confirm_rings.get(anchor)
	if fraction <= 0.0:
		if ring:
			ring.visible = false
		return
	if not ring:
		ring = _create_confirm_ring()
		anchor.add_child(ring)
		_confirm_rings[anchor] = ring
	ring.visible = true
	(ring.material_override as ShaderMaterial).set_shader_parameter("progress", fraction)


## A flat ring lying on the code (the marker's Z axis points out of the code, like QuadMesh's normal).
func _create_confirm_ring() -> MeshInstance3D:
	if not _confirm_ring_shader:
		_confirm_ring_shader = Shader.new()
		_confirm_ring_shader.code = CONFIRM_RING_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _confirm_ring_shader
	mat.set_shader_parameter("fill_color", confirm_ring_color)
	mat.render_priority = 20

	var quad := QuadMesh.new()
	quad.size = Vector2(confirm_ring_size, confirm_ring_size)

	var ring := MeshInstance3D.new()
	ring.name = "ConfirmRing"
	ring.mesh = quad
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(0.0, 0.0, 0.002)  # just above the code
	return ring


## How far (0..1) the player is through confirming a new QR code by looking at it.
func get_confirm_progress() -> float:
	var best := 0.0
	for seconds: float in _confirm_progress.values():
		best = maxf(best, seconds / confirm_look_time)
	return best


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	for child in node.get_children():
		var found = _find_node_by_class(child, class_name_str)
		if found:
			return found
	return null


func _exit_tree() -> void:
	# Disconnect signals
	if XRServer.tracker_added.is_connected(_on_tracker_added):
		XRServer.tracker_added.disconnect(_on_tracker_added)
	if XRServer.tracker_removed.is_connected(_on_tracker_removed):
		XRServer.tracker_removed.disconnect(_on_tracker_removed)

	# Clean up all marker nodes
	for tr in _marker_nodes.keys():
		var node: XRAnchor3D = _marker_nodes[tr]
		if is_instance_valid(node):
			if node.get_parent():
				node.get_parent().remove_child(node)
			node.queue_free()
	_marker_nodes.clear()
	_confirm_progress.clear()
	_confirm_rings.clear()


## Call this when XR session begins (from external script like multiplayer_scene_base)
func _on_session_begun() -> void:
	print("[QRMarkerManager] XR Session Begun")

	# Quest only tracks QR codes once the user has granted the spatial data (Scene) permission.
	_request_spatial_permission()

	# Check if QR codes are supported
	if is_qr_supported():
		print("[QRMarkerManager] QR Codes ARE Supported!")
	else:
		print("[QRMarkerManager] QR Codes are NOT supported (needs Horizon OS v83+, the Scene permission, and an app restart after first granting it)")

	# Connect to tracker lifecycle signals
	if not XRServer.tracker_added.is_connected(_on_tracker_added):
		XRServer.tracker_added.connect(_on_tracker_added)
	if not XRServer.tracker_removed.is_connected(_on_tracker_removed):
		XRServer.tracker_removed.connect(_on_tracker_removed)

	# Pick up markers that were announced before we started listening.
	for tracker_name in XRServer.get_trackers(XRServer.TRACKER_ANCHOR):
		_on_tracker_added(tracker_name, XRServer.TRACKER_ANCHOR)

	print("[QRMarkerManager] Now listening for trackers")


## Android runtime permission Quest needs before it will report QR codes (declared in the export preset).
const SPATIAL_PERMISSION := "com.oculus.permission.USE_SCENE"


func _request_spatial_permission() -> void:
	if OS.get_name() != "Android":
		return
	if SPATIAL_PERMISSION in OS.get_granted_permissions():
		print("[QRMarkerManager] Spatial data permission already granted")
		return
	print("[QRMarkerManager] Requesting spatial data permission (accept the prompt, then restart the app once)")
	OS.request_permission(SPATIAL_PERMISSION)


## True if the headset's runtime can track QR codes (false on desktop / older Horizon OS / permission missing).
func is_qr_supported() -> bool:
	var xr_interface := XRServer.find_interface("OpenXR")
	if not xr_interface or not xr_interface.is_initialized():
		return false
	return OpenXRSpatialMarkerTrackingCapability.is_qrcode_supported()


## Call this when XR session ends
func _on_session_ended() -> void:
	print("[QRMarkerManager] XR Session Ended")

	if XRServer.tracker_added.is_connected(_on_tracker_added):
		XRServer.tracker_added.disconnect(_on_tracker_added)
	if XRServer.tracker_removed.is_connected(_on_tracker_removed):
		XRServer.tracker_removed.disconnect(_on_tracker_removed)


func _on_tracker_added(tracker_name: StringName, type: int) -> void:
	print("[QRMarkerManager] Tracker added: ", tracker_name, " type: ", type)

	# Only process anchor-type trackers (like SidneyAR)
	if type != XRServer.TRACKER_ANCHOR:
		print("[QRMarkerManager] Skipping - not an anchor type")
		return

	var tr: XRTracker = XRServer.get_tracker(tracker_name)
	if tr is OpenXRMarkerTracker:
		if _marker_nodes.has(tr):
			return
		print("[QRMarkerManager] Found OpenXRMarkerTracker!")
		markers_seen += 1
		_add_marker(tr)
	else:
		print("[QRMarkerManager] Tracker is not OpenXRMarkerTracker: ", tr.get_class() if tr else "null")


func _on_tracker_removed(tracker_name: StringName, type: int) -> void:
	print("[QRMarkerManager] Tracker removed: ", tracker_name)

	if type != XRServer.TRACKER_ANCHOR:
		return

	var tr: XRTracker = XRServer.get_tracker(tracker_name)
	if _marker_nodes.has(tr):
		var node: XRAnchor3D = _marker_nodes[tr]

		# Clear active anchor if this was it
		if _active_anchor == node:
			_active_anchor = null
			if _model_sync_manager and _model_sync_manager.has_method("set_local_qr_anchor_mode"):
				_model_sync_manager.set_local_qr_anchor_mode(false, "")
			lock_changed.emit(false)
			print("[QRMarkerManager] Active anchor removed - model stays where it was")

		_confirm_progress.erase(node)
		_confirm_rings.erase(node)  # freed with the anchor
		_marker_nodes.erase(tr)
		if is_instance_valid(node):
			if node.get_parent():
				node.get_parent().remove_child(node)
			node.queue_free()

		marker_lost.emit(tracker_name)


func _add_marker(tr: OpenXRMarkerTracker) -> void:
	_tracker_count += 1
	print("[QRMarkerManager] Adding Marker #", _tracker_count, " type: ", tr.marker_type)

	# Create an XRAnchor3D bound to this tracker (exactly like SidneyAR)
	var anchor := XRAnchor3D.new()
	anchor.tracker = tr.name
	anchor.pose = "default"

	# IMPORTANT: Add anchor as child of XROrigin3D for correct positioning
	# This is how SidneyAR does it (QRAnchorManager is under XROrigin3D)
	if _xr_origin:
		_xr_origin.add_child(anchor)
		print("[QRMarkerManager] Added anchor to XROrigin3D")
	else:
		add_child(anchor)
		print("[QRMarkerManager] WARNING: Added anchor to self (no XROrigin3D)")

	# DEBUG: Create a simple cube as child of the anchor (hidden by default)
	if show_debug_cube:
		var cube := _create_cube()
		anchor.add_child(cube)
		print("[QRMarkerManager] Debug cube added")

	_marker_nodes[tr] = anchor

	# Wait a frame for transform to be valid
	await get_tree().process_frame
	if conference_demo_mode:
		var settle_time: float = small_qr_settle_time if small_qr_mode else marker_settle_time
		await get_tree().create_timer(settle_time).timeout

	if is_instance_valid(anchor):
		var marker_transform = anchor.global_transform
		marker_detected.emit(marker_transform, tr.name)
		print("[QRMarkerManager] Marker detected at: ", anchor.global_position)
		# The model locks to it once the player has looked at it long enough (_update_look_to_confirm).


func _anchor_model_to_marker(anchor: XRAnchor3D, marker_data: String) -> void:
	if not _model_sync_manager:
		print("[QRMarkerManager] Cannot anchor - no ModelSyncManager")
		return

	# This marker is now the one the model is locked to, at the pose it has right now
	_active_anchor = anchor
	if _xr_origin:
		_confirmed_marker = _marker_local(anchor)

	# Set local anchor state only (no RPC) — each peer tracks their own QR
	if _model_sync_manager.has_method("set_local_qr_anchor_mode"):
		_model_sync_manager.set_local_qr_anchor_mode(lock_enabled, marker_data)

	print("[QRMarkerManager] Locking model to QR code (local): ", marker_data)
	print("[QRMarkerManager] Anchor position: ", anchor.global_position)

	if lock_enabled:
		_apply_confirmed_pose()
	lock_changed.emit(is_locking())


## Moves the model onto the last confirmed marker pose (scale is preserved) and, on the host, sends it
## reliably to clients. Works in XROrigin3D-local space so the pose can be sent to clients unchanged.
## [param send]: false while the toy grips are turning it (ToyModelManipulator streams that itself).
func _apply_confirmed_pose(send: bool = true) -> void:
	if not _xr_origin or not _resolve_model_root():
		return
	# Client: if the host has placed the model relative to this same code, use that placement.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		if _model_sync_manager and _model_sync_manager.has_method("apply_qr_relative_pose") and _model_sync_manager.apply_qr_relative_pose():
			return

	var target_position := _confirmed_marker.origin
	var walkable := _is_model_walkable()
	# The toy grips' turn on top of the code's own rotation, about the vertical through the code.
	var target_rotation := Quaternion(Vector3.UP, _user_yaw) * _target_rotation(_confirmed_marker.basis, walkable)
	if walkable:
		# A full-size plant is solid to the player: keep it standing on the arena floor. Lifting it to
		# the code's height (a table) or tilting it with the code drives its floors up through the player.
		var floor_global := _xr_origin.global_transform * target_position
		floor_global.y = _model_sync_manager.get_toy_floor_y() if _model_sync_manager.has_method("get_toy_floor_y") else 0.0
		target_position = _xr_origin.global_transform.affine_inverse() * floor_global

	var model_scale := _model_root.scale
	_model_root.global_transform = _xr_origin.global_transform * Transform3D(Basis(target_rotation), target_position)
	_model_root.scale = model_scale

	# Host: one reliable send for peers that are not locking to a QR code themselves.
	if send and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		if _model_sync_manager and _model_sync_manager.has_method("set_model_position_rotation_local_to_origin"):
			_model_sync_manager.set_model_position_rotation_local_to_origin(target_position, target_rotation.get_euler(), true)


## True while the model is big enough to collide with the player (main_stage.gd SMALL_MODEL_SCALE).
func _is_model_walkable() -> bool:
	if _model_sync_manager and _model_sync_manager.has_method("get_toy_scale_factor"):
		return _model_sync_manager.get_toy_scale_factor() >= WALKABLE_MODEL_SCALE
	return true


func _target_rotation(marker_basis: Basis, force_upright: bool = false) -> Quaternion:
	var basis := marker_basis.orthonormalized()
	if marker_lies_flat:
		# A marker's Z axis points out of the code; the model's Y axis is its up. Turn the model a
		# quarter turn so it stands on the code instead of lying on its side.
		basis = basis * Basis(Vector3.RIGHT, PI * 0.5)
	var yaw_offset := deg_to_rad(rotation_offset_y)
	if upright_only or force_upright:
		return Quaternion(Vector3.UP, basis.get_euler().y + yaw_offset)
	return Quaternion(Vector3.UP, yaw_offset) * basis.get_rotation_quaternion()


## The confirmed code as a level frame in the world: at the code, turned to its yaw. Every peer that
## confirmed the same physical code has this frame at the same real-world spot, so a model pose taken
## relative to it means the same place for everyone (see ModelSyncManager's QR-relative sync).
func get_shared_frame() -> Transform3D:
	var level := Basis(_target_rotation(_confirmed_marker.basis, true))
	return _xr_origin.global_transform * Transform3D(level, _confirmed_marker.origin)


func has_shared_frame() -> bool:
	return is_locking() and _xr_origin != null


## Toy grips / stick: turn the pinned model in place about the code. The caller syncs clients.
func turn_locked_model(angle: float) -> void:
	if not is_locking():
		return
	_user_yaw = wrapf(_user_yaw + angle, -PI, PI)
	_apply_confirmed_pose(false)


## "Reset Model": drop the toy grips' extra turn.
func reset_user_turn() -> void:
	_user_yaw = 0.0


## True while a QR code is tracked and the model is pinned to it.
func is_locking() -> bool:
	return lock_enabled and is_tracking()


## Pin the model to the QR code (true) or release it so it can be moved by hand (false).
## The marker keeps being tracked either way; turning the lock back on puts the model back on the last
## confirmed pose (look at the code again to take a new one).
func set_lock_enabled(enabled: bool) -> void:
	if lock_enabled == enabled:
		return
	lock_enabled = enabled
	if _model_sync_manager and _model_sync_manager.has_method("set_local_qr_anchor_mode"):
		_model_sync_manager.set_local_qr_anchor_mode(is_locking(), get_marker_data())
	if is_locking():
		_apply_confirmed_pose()
	lock_changed.emit(is_locking())
	print("[QRMarkerManager] QR lock ", "ON" if enabled else "OFF")


func is_tracking() -> bool:
	return is_instance_valid(_active_anchor)


## True when the QR code is currently in view (not just remembered).
func is_marker_visible() -> bool:
	return is_tracking() and _active_anchor.get_has_tracking_data()


func get_marker_transform() -> Transform3D:
	if is_tracking():
		return _active_anchor.global_transform
	return Transform3D.IDENTITY


func get_marker_data() -> String:
	if is_tracking():
		return str(_active_anchor.tracker)
	return ""


## Put the model back on the last confirmed marker pose (e.g. after its scale changed or toy mode
## started). Does not read the code again: new marker data only comes in through look-to-confirm.
func force_reanchor_now() -> void:
	if not is_locking():
		return
	_apply_confirmed_pose()


func _create_cube() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()

	# Create box mesh
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(cube_size, cube_size, cube_size)
	mesh_instance.mesh = box_mesh

	# Create material with color
	var material := StandardMaterial3D.new()
	material.albedo_color = cube_color
	material.emission_enabled = true
	material.emission = cube_color
	material.emission_energy_multiplier = 0.5
	mesh_instance.material_override = material

	return mesh_instance
