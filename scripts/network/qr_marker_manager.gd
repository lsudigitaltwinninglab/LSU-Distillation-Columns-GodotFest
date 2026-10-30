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
## 2. On detect → create XRAnchor3D under XROrigin3D, notify ModelSyncManager
## 3. Every frame the model is locked to the marker's position and rotation (scale is untouched,
##    so toy-mode scaling happens about the QR code). Tiny tracking noise is ignored and real
##    movement is smoothed, so the model stays rock-steady on the table.
## 4. If the marker leaves view the model holds its last pose; if the tracker is removed the model
##    stays where it was and re-locks when the code is seen again.
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

## How quickly the model catches up with real marker movement (higher = snappier).
@export var smoothing_speed: float = 14.0

@export var conference_demo_mode: bool = true
@export var marker_settle_time: float = 0.15
@export var small_qr_mode: bool = true
@export var small_qr_settle_time: float = 0.05

## Marker jitter below these is ignored so the locked model doesn't shimmer.
const POSITION_DEADBAND := 0.002  # meters
const ROTATION_DEADBAND := deg_to_rad(0.3)
## A marker pose this far from the model snaps instead of gliding (first lock, re-detection elsewhere).
const SNAP_DISTANCE := 0.5  # meters
## How often the host streams the locked pose to clients that have no QR lock of their own.
const SYNC_INTERVAL := 0.1

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

# Smoothed locked pose, in XROrigin3D-local space
var _locked_position: Vector3 = Vector3.ZERO
var _locked_rotation: Quaternion = Quaternion.IDENTITY
var _has_locked_pose: bool = false
var _sync_timer: float = 0.0


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


## Every frame: keep the model pinned to the marker (runs on all peers; each uses their own QR, no position sync).
func _process(delta: float) -> void:
	if not is_locking():
		return
	# Marker out of view: hold the last pose rather than following a stale one.
	if not _active_anchor.get_has_tracking_data():
		return
	_follow_marker(delta, false)


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
			_has_locked_pose = false
			if _model_sync_manager and _model_sync_manager.has_method("set_local_qr_anchor_mode"):
				_model_sync_manager.set_local_qr_anchor_mode(false, "")
			lock_changed.emit(false)
			print("[QRMarkerManager] Active anchor removed - model stays where it was")

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

		# Anchor the model to this QR code (each peer does this when they see the QR — no host→client sync)
		if auto_anchor_model:
			_anchor_model_to_marker(anchor, tr.name)


func _anchor_model_to_marker(anchor: XRAnchor3D, marker_data: String) -> void:
	if not _model_sync_manager:
		print("[QRMarkerManager] Cannot anchor - no ModelSyncManager")
		return

	# This marker is now the one the model follows
	_active_anchor = anchor
	_has_locked_pose = false

	# Set local anchor state only (no RPC) — each peer tracks their own QR
	if _model_sync_manager.has_method("set_local_qr_anchor_mode"):
		_model_sync_manager.set_local_qr_anchor_mode(lock_enabled, marker_data)

	print("[QRMarkerManager] Locking model to QR code (local): ", marker_data)
	print("[QRMarkerManager] Anchor position: ", anchor.global_position)

	# Pin the model to the marker right away (no glide on first lock)
	if lock_enabled:
		_follow_marker(0.0, true)
	lock_changed.emit(is_locking())


## Moves the model onto the marker's position and rotation (scale is preserved).
## Works in XROrigin3D-local space so the pose can be streamed to clients unchanged.
func _follow_marker(delta: float, snap: bool) -> void:
	if not _xr_origin or not _resolve_model_root():
		return

	var local_t := _xr_origin.global_transform.affine_inverse() * _active_anchor.global_transform
	var target_position := local_t.origin
	var target_rotation := _target_rotation(local_t.basis)

	if snap or not _has_locked_pose or _locked_position.distance_to(target_position) > SNAP_DISTANCE:
		_locked_position = target_position
		_locked_rotation = target_rotation
		_has_locked_pose = true
	else:
		var moved := _locked_position.distance_to(target_position) > POSITION_DEADBAND
		var turned := _locked_rotation.angle_to(target_rotation) > ROTATION_DEADBAND
		if moved or turned:
			var weight := 1.0 - exp(-smoothing_speed * delta)
			_locked_position = _locked_position.lerp(target_position, weight)
			_locked_rotation = _locked_rotation.slerp(target_rotation, weight)

	var model_scale := _model_root.scale
	_model_root.global_transform = _xr_origin.global_transform * Transform3D(Basis(_locked_rotation), _locked_position)
	_model_root.scale = model_scale

	# Host: stream the locked pose for peers that are not locking to a QR code themselves.
	_sync_timer += delta
	if (snap or _sync_timer >= SYNC_INTERVAL) and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_sync_timer = 0.0
		if _model_sync_manager and _model_sync_manager.has_method("set_model_position_rotation_local_to_origin"):
			_model_sync_manager.set_model_position_rotation_local_to_origin(_locked_position, _locked_rotation.get_euler())


func _target_rotation(marker_basis: Basis) -> Quaternion:
	var basis := marker_basis.orthonormalized()
	if marker_lies_flat:
		# A marker's Z axis points out of the code; the model's Y axis is its up. Turn the model a
		# quarter turn so it stands on the code instead of lying on its side.
		basis = basis * Basis(Vector3.RIGHT, PI * 0.5)
	var yaw_offset := deg_to_rad(rotation_offset_y)
	if upright_only:
		return Quaternion(Vector3.UP, basis.get_euler().y + yaw_offset)
	return Quaternion(Vector3.UP, yaw_offset) * basis.get_rotation_quaternion()


## True while a QR code is tracked and the model is pinned to it.
func is_locking() -> bool:
	return lock_enabled and is_tracking()


## Pin the model to the QR code (true) or release it so it can be moved by hand (false).
## The marker keeps being tracked either way; turning the lock back on snaps the model to the code.
func set_lock_enabled(enabled: bool) -> void:
	if lock_enabled == enabled:
		return
	lock_enabled = enabled
	_has_locked_pose = false
	if _model_sync_manager and _model_sync_manager.has_method("set_local_qr_anchor_mode"):
		_model_sync_manager.set_local_qr_anchor_mode(is_locking(), get_marker_data())
	if is_locking():
		_follow_marker(0.0, true)
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


## Snap the model onto the marker now (e.g. after its scale changed or toy mode started).
func force_reanchor_now() -> void:
	if not is_locking():
		return
	_has_locked_pose = false
	_follow_marker(0.0, true)


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
