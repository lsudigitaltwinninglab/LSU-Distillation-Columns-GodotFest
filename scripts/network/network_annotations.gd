extends Node3D
class_name NetworkAnnotations

## Shared 3D drawing for every peer (Map/NetworkAnnotations in ar_network_arena).
##
## Drawing is done with a grabbable pencil (PencilTool) that is NOT always on: each player turns it
## on from the menu's Pencil toggle, which spawns it in front of them. Grab it with grip, then
## (all peers, host and clients):
## - RIGHT A (hold): draw ink from the pencil tip
## - LEFT X (tap): erase your last stroke
## - LEFT X (hold): erase all your strokes — the host erases everyone's
## Nothing draws or erases unless the pencil is in your hand.
##
## - Strokes are parented under the model root (MainStage) in model-local space, so ink stays
##   pinned to the equipment regardless of each peer's own QR anchor, placement, or toy scale.
## - Every peer gets a distinct ink color from its peer id.
## - Any peer may draw; RPCs relay through the server, which keeps the history.
##   Late joiners request the history once their arena has loaded.
## - Drawing is suppressed while the host is in model placement mode (A = confirm there).
##
## RPC inventory:
## | RPC | Direction | Reliability | Purpose |
## |-----|-----------|-------------|---------|
## | _rpc_begin_stroke | any → all | reliable | New stroke (key, color, width) |
## | _rpc_add_points | any → all | reliable | Append batched model-local points |
## | _rpc_remove_strokes | any → all | reliable | Undo / clear (own strokes; host: any) |
## | _rpc_request_history | client → host | reliable | Late join: ask for existing strokes |
## | _rpc_pencil_pose | any → all | unreliable | Where this player's pencil is (model-local) + ink color |
## | _rpc_pencil_removed | any → all | reliable | This player put their pencil away |
##
## Everyone sees everyone's pencil (PencilVisual in model space, so it sits right against the equipment
## whatever each peer's tracking space or the model's size).
## The host can swap between yellow and red ink with the right B button while holding the pencil.

@export var draw_button: String = "ax_button"
@export var undo_button: String = "ax_button"
## Host only: swaps between the host's yellow and red ink (right controller, while holding the pencil).
@export var ink_swap_button: String = "by_button"
## Where the pencil appears when switched on: metres in front of / below the headset.
@export var pencil_spawn_distance: float = 0.45
@export var pencil_spawn_drop: float = 0.25
## Ink width in world metres at the moment the stroke is drawn.
@export var line_width: float = 0.008
## Minimum world distance between recorded points.
@export var min_point_spacing: float = 0.006
## How often batched points are sent to other peers (seconds).
@export var send_interval: float = 0.05
@export var clear_hold_time: float = 1.0
@export var show_controls_hint: bool = true

const HISTORY_RETRY_SEC := 1.0
const HISTORY_MAX_TRIES := 20
const MAX_POINTS_PER_STROKE := 1200
const MAX_STROKES := 200
## The host's second ink color (its default is gold, PALETTE[0]).
const HOST_RED_INK := Color(1.0, 0.15, 0.15)
const PENCIL_SEND_INTERVAL := 0.066
const PENCIL_KEEPALIVE := 1.0
## A remote pencil that hasn't been heard from for this long is removed (keep-alives arrive every second).
const PENCIL_STALE_SECONDS := 5.0
const PENCIL_FOLLOW_RATE := 25.0
const PALETTE: Array[Color] = [
	Color(1.0, 0.85, 0.1),   # gold
	Color(0.2, 0.75, 1.0),   # sky
	Color(1.0, 0.35, 0.35),  # red
	Color(0.35, 1.0, 0.45),  # green
	Color(0.8, 0.45, 1.0),   # violet
	Color(1.0, 0.6, 0.2),    # orange
	Color(0.2, 1.0, 0.9),    # teal
	Color(1.0, 0.5, 0.8),    # pink
]

var _model_root: Node3D
var _container: Node3D
var _left_controller: XRController3D
var _right_controller: XRController3D
var _camera: XRCamera3D
var _pencil: PencilTool

## stroke key ("peer:id") -> { peer, color, width, points: PackedVector3Array, mesh: MeshInstance3D }
var _strokes: Dictionary = {}
var _stroke_order: Array[String] = []
var _materials: Dictionary = {}

var _local_stroke_counter: int = 0
var _active_key: String = ""
var _last_world_point: Vector3 = Vector3.INF
var _pending_points := PackedVector3Array()
var _send_timer: float = 0.0
var _dirty_keys: Dictionary = {}
var _undo_hold_time: float = -1.0
var _undo_fired: bool = false
var _history_received: bool = false
var _history_tries: int = 0
var _history_retry_timer: Timer

var _host_red: bool = false
var _ink_swap_down: bool = false

var _pencil_send_timer: float = 0.0
var _pencil_keepalive: float = PENCIL_KEEPALIVE
var _last_sent_pencil: Transform3D = Transform3D.IDENTITY
## peer id -> { visual: PencilVisual, target: Transform3D, seen: float (msec) }
var _remote_pencils: Dictionary = {}


func _ready() -> void:
	add_to_group("network_annotations")
	# Wait for the arena (and MainStage instance) to finish entering the tree.
	await get_tree().process_frame
	_resolve_model_root()
	_find_controllers()
	if MenuControl and MenuControl.has_signal("pencil_toggled"):
		MenuControl.pencil_toggled.connect(set_pencil_enabled)
	multiplayer.peer_disconnected.connect(_remove_remote_pencil)

	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_history_retry_timer = Timer.new()
		_history_retry_timer.one_shot = true
		_history_retry_timer.wait_time = HISTORY_RETRY_SEC
		_history_retry_timer.timeout.connect(_request_history)
		add_child(_history_retry_timer)
		_request_history()


## Ask the host for existing strokes; retried until the host's reply arrives (its arena may still be loading).
func _request_history() -> void:
	if _history_received or not multiplayer.has_multiplayer_peer():
		return
	if _history_tries >= HISTORY_MAX_TRIES:
		push_warning("[NetworkAnnotations] Host never sent stroke history")
		return
	_history_tries += 1
	_rpc_request_history.rpc_id(1)
	_history_retry_timer.start()


func _resolve_model_root() -> void:
	var sync_manager := get_tree().get_first_node_in_group("model_sync_manager")
	if sync_manager and sync_manager.get("model_root"):
		_model_root = sync_manager.model_root
	if not _model_root:
		_model_root = get_node_or_null("../MainStage") as Node3D
	if not _model_root:
		_model_root = self
		push_warning("[NetworkAnnotations] Model root not found; strokes will be world-space")

	_container = Node3D.new()
	_container.name = "SharedAnnotations"
	_model_root.add_child(_container)


func _find_controllers() -> void:
	var origin := get_tree().get_first_node_in_group("xr_origin") as XROrigin3D
	if not origin:
		push_warning("[NetworkAnnotations] XROrigin3D not found; local drawing disabled")
		return
	_left_controller = origin.get_node_or_null("LeftHand") as XRController3D
	_right_controller = origin.get_node_or_null("RightHand") as XRController3D
	_camera = origin.get_node_or_null("XRCamera3D") as XRCamera3D


### Pencil (menu toggle) ###

## Menu Pencil toggle: spawn the grabbable pencil in front of the player, or put it away.
func set_pencil_enabled(enabled: bool) -> void:
	if enabled:
		if is_instance_valid(_pencil):
			return
		_spawn_pencil()
	else:
		if _active_key != "":
			_end_local_stroke()
		if is_instance_valid(_pencil):
			_pencil.queue_free()
			if multiplayer.has_multiplayer_peer():
				_rpc_pencil_removed.rpc()
		_pencil = null


func _spawn_pencil() -> void:
	_pencil = PencilTool.new()
	_pencil.name = "Pencil"
	add_child(_pencil)
	_apply_ink_color()
	_pencil_keepalive = PENCIL_KEEPALIVE  # announce it to everyone straight away
	# Rest it flat in front of the player, tip pointing away from them, within easy reach.
	var forward := Vector3.FORWARD
	var origin_point := Vector3.ZERO
	if _camera:
		forward = -_camera.global_transform.basis.z
		forward.y = 0.0
		forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
		origin_point = _camera.global_position
	_pencil.global_transform = Transform3D(
		Basis.looking_at(forward, Vector3.UP),
		origin_point + forward * pencil_spawn_distance - Vector3(0.0, pencil_spawn_drop, 0.0),
	)


func _pencil_held() -> bool:
	return is_instance_valid(_pencil) and _pencil.is_held()


## Pencil band + hint follow the current ink color.
func _apply_ink_color() -> void:
	if not is_instance_valid(_pencil):
		return
	_pencil.set_ink_color(_local_color())
	if show_controls_hint:
		var lines := PackedStringArray([player_name_for_peer(multiplayer.get_unique_id())])
		lines.append("Hold A: draw  |  X: erase")
		lines.append("Hold X: erase all%s" % ("" if _is_host() else " mine"))
		if _is_host():
			lines.append("B: switch to %s ink" % ("yellow" if _host_red else "red"))
		_pencil.set_hint_text("\n".join(lines))
	# Other players' copy of the pencil changes color too.
	_pencil_keepalive = PENCIL_KEEPALIVE


### Host ink swap ###

func _process_ink_swap() -> void:
	if not _is_host() or not _pencil_held() or not _right_controller or not _right_controller.get_is_active():
		_ink_swap_down = false
		return
	var down := _right_controller.is_button_pressed(ink_swap_button)
	if down and not _ink_swap_down:
		_host_red = not _host_red
		_apply_ink_color()
		_pencil.pulse()
	_ink_swap_down = down


### Showing pencils to other players ###

## Sends this player's pencil (model-local) a few times a second while it moves, and once a second otherwise.
func _stream_pencil(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not _container or not is_instance_valid(_pencil):
		return
	_pencil_send_timer += delta
	_pencil_keepalive += delta
	if _pencil_send_timer < PENCIL_SEND_INTERVAL:
		return
	_pencil_send_timer = 0.0
	var local := _container.global_transform.affine_inverse() * _pencil.global_transform
	if local.is_equal_approx(_last_sent_pencil) and _pencil_keepalive < PENCIL_KEEPALIVE:
		return
	_last_sent_pencil = local
	_pencil_keepalive = 0.0
	_rpc_pencil_pose.rpc(local, _local_color())


func _update_remote_pencils(delta: float) -> void:
	if _remote_pencils.is_empty():
		return
	var weight := 1.0 - exp(-PENCIL_FOLLOW_RATE * delta)
	var now := Time.get_ticks_msec()
	for peer_id in _remote_pencils.keys():
		var entry: Dictionary = _remote_pencils[peer_id]
		var visual: PencilVisual = entry.visual
		if not is_instance_valid(visual) or now - int(entry.seen) > int(PENCIL_STALE_SECONDS * 1000.0):
			_remove_remote_pencil(peer_id)
			continue
		visual.transform = visual.transform.interpolate_with(entry.target, weight)


func _remove_remote_pencil(peer_id: int) -> void:
	var entry: Dictionary = _remote_pencils.get(peer_id, {})
	if entry.is_empty():
		return
	if is_instance_valid(entry.visual):
		entry.visual.queue_free()
	_remote_pencils.erase(peer_id)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_pencil_pose(local_transform: Transform3D, color: Color) -> void:
	if not _container:
		return
	var sender := multiplayer.get_remote_sender_id()
	var entry: Dictionary = _remote_pencils.get(sender, {})
	if entry.is_empty():
		var visual := PencilVisual.new()
		visual.name = "Pencil_%d" % sender
		_container.add_child(visual)
		visual.transform = local_transform
		var label := Label3D.new()
		label.text = player_name_for_peer(sender)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 24
		label.pixel_size = 0.0006
		label.outline_size = 6
		label.no_depth_test = true
		label.position = Vector3(0.0, 0.05, 0.0)
		label.modulate = color
		visual.add_child(label)
		entry = {"visual": visual, "target": local_transform, "seen": 0, "label": label}
		_remote_pencils[sender] = entry
	entry.target = local_transform
	entry.seen = Time.get_ticks_msec()
	entry.visual.set_ink_color(color)
	(entry.label as Label3D).modulate = color


@rpc("any_peer", "call_remote", "reliable")
func _rpc_pencil_removed() -> void:
	_remove_remote_pencil(multiplayer.get_remote_sender_id())


func _process(delta: float) -> void:
	_process_ink_swap()
	_process_drawing(delta)
	_process_undo(delta)
	_stream_pencil(delta)
	_update_remote_pencils(delta)
	_rebuild_dirty_meshes()


### Local input ###

func _process_drawing(delta: float) -> void:
	var drawing := _pencil_held() and _can_draw() and _right_controller.is_button_pressed(draw_button)
	if is_instance_valid(_pencil):
		_pencil.set_drawing(drawing)

	if drawing:
		if _active_key == "":
			_begin_local_stroke()
		_sample_pen_tip()
	elif _active_key != "":
		_end_local_stroke()

	if _active_key != "" or not _pending_points.is_empty():
		_send_timer += delta
		if _send_timer >= send_interval:
			_flush_pending_points()


func _process_undo(delta: float) -> void:
	if not _left_controller or not _left_controller.get_is_active() or not _pencil_held():
		_undo_hold_time = -1.0
		return
	if _left_controller.is_button_pressed(undo_button):
		if _undo_hold_time < 0.0:
			_undo_hold_time = 0.0
			_undo_fired = false
		_undo_hold_time += delta
		if not _undo_fired and _undo_hold_time >= clear_hold_time:
			_undo_fired = true
			if _is_host():
				clear_all()
			else:
				clear_mine()
	elif _undo_hold_time >= 0.0:
		if not _undo_fired:
			undo_last()
		_undo_hold_time = -1.0


func _can_draw() -> bool:
	if not _right_controller or not _right_controller.get_is_active():
		return false
	var sync_manager := get_tree().get_first_node_in_group("model_sync_manager")
	if sync_manager and sync_manager.has_method("is_placement_mode") and sync_manager.is_placement_mode():
		return false
	return true


func _begin_local_stroke() -> void:
	if _strokes.size() >= MAX_STROKES:
		_evict_oldest_own_stroke()
	_local_stroke_counter += 1
	_active_key = "%d:%d" % [multiplayer.get_unique_id(), _local_stroke_counter]
	_last_world_point = Vector3.INF
	_pending_points.clear()
	_send_timer = 0.0
	var color := _local_color()
	var width_local := line_width / _container_scale()
	_create_stroke(_active_key, multiplayer.get_unique_id(), color, width_local)
	if multiplayer.has_multiplayer_peer():
		_rpc_begin_stroke.rpc(_active_key, color, width_local)


func _sample_pen_tip() -> void:
	if not is_instance_valid(_pencil):
		return
	var tip_world := _pencil.tip.global_position
	if _last_world_point != Vector3.INF and tip_world.distance_to(_last_world_point) < min_point_spacing:
		return
	var stroke: Dictionary = _strokes.get(_active_key, {})
	if stroke.is_empty():
		return
	if (stroke.points as PackedVector3Array).size() >= MAX_POINTS_PER_STROKE:
		# Long stroke: split so a single stroke never grows unbounded.
		_end_local_stroke()
		_begin_local_stroke()
	_last_world_point = tip_world
	_pencil.pulse()
	var local_point := _container.to_local(tip_world)
	_append_points(_active_key, PackedVector3Array([local_point]))
	_pending_points.append(local_point)


func _end_local_stroke() -> void:
	_flush_pending_points()
	_active_key = ""
	_last_world_point = Vector3.INF


func _flush_pending_points() -> void:
	_send_timer = 0.0
	if _pending_points.is_empty() or _active_key == "":
		_pending_points.clear()
		return
	if multiplayer.has_multiplayer_peer():
		_rpc_add_points.rpc(_active_key, _pending_points)
	_pending_points.clear()


### Public API (menu buttons / other scripts) ###

func undo_last() -> void:
	var prefix := "%d:" % multiplayer.get_unique_id()
	for i in range(_stroke_order.size() - 1, -1, -1):
		if _stroke_order[i].begins_with(prefix):
			_request_remove(PackedStringArray([_stroke_order[i]]))
			return


func clear_mine() -> void:
	var prefix := "%d:" % multiplayer.get_unique_id()
	var keys := PackedStringArray()
	for key in _stroke_order:
		if key.begins_with(prefix):
			keys.append(key)
	_request_remove(keys)


## Host only: wipe every peer's strokes.
func clear_all() -> void:
	if not _is_host():
		return
	_request_remove(PackedStringArray(_stroke_order))


func get_stroke_count() -> int:
	return _strokes.size()


func _request_remove(keys: PackedStringArray) -> void:
	if keys.is_empty():
		return
	if _active_key != "" and keys.has(_active_key):
		_active_key = ""
		_pending_points.clear()
	_remove_strokes(keys)
	if multiplayer.has_multiplayer_peer():
		_rpc_remove_strokes.rpc(keys)


func _evict_oldest_own_stroke() -> void:
	var prefix := "%d:" % multiplayer.get_unique_id()
	for key in _stroke_order:
		if key.begins_with(prefix):
			_request_remove(PackedStringArray([key]))
			return


### RPCs ###

@rpc("any_peer", "call_remote", "reliable")
func _rpc_begin_stroke(key: String, color: Color, width_local: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _key_owned_by(key, sender):
		return
	if _strokes.size() >= MAX_STROKES and multiplayer.is_server():
		# Keep the history bounded; the oldest stroke goes first.
		_request_remove(PackedStringArray([_stroke_order[0]]))
	_create_stroke(key, sender, color, clampf(width_local, 0.0001, 10.0))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_add_points(key: String, points: PackedVector3Array) -> void:
	if not _key_owned_by(key, multiplayer.get_remote_sender_id()):
		return
	_append_points(key, points)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_remove_strokes(keys: PackedStringArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var allowed := PackedStringArray()
	for key in keys:
		if sender == 1 or _key_owned_by(key, sender):
			allowed.append(key)
	_remove_strokes(allowed)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_history() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	print("[NetworkAnnotations] Sending %d strokes to peer %d" % [_stroke_order.size(), peer_id])
	for key in _stroke_order:
		var stroke: Dictionary = _strokes[key]
		_rpc_receive_history_stroke.rpc_id(peer_id, key, stroke.peer, stroke.color, stroke.width, stroke.points)
	_rpc_history_done.rpc_id(peer_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_history_done() -> void:
	_history_received = true
	if _history_retry_timer:
		_history_retry_timer.stop()


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_history_stroke(key: String, owner_peer: int, color: Color, width_local: float, points: PackedVector3Array) -> void:
	if _strokes.has(key):
		return
	_create_stroke(key, owner_peer, color, width_local)
	_append_points(key, points)


func _key_owned_by(key: String, peer_id: int) -> bool:
	return key.begins_with("%d:" % peer_id)


### Stroke storage + mesh building ###

func _create_stroke(key: String, owner_peer: int, color: Color, width_local: float) -> void:
	if _strokes.has(key) or not _container:
		return
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Stroke_" + key.replace(":", "_")
	mesh_instance.mesh = ImmediateMesh.new()
	mesh_instance.material_override = _material_for(color)
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_container.add_child(mesh_instance)
	_strokes[key] = {
		"peer": owner_peer,
		"color": color,
		"width": width_local,
		"points": PackedVector3Array(),
		"mesh": mesh_instance,
	}
	_stroke_order.append(key)


func _append_points(key: String, points: PackedVector3Array) -> void:
	var stroke: Dictionary = _strokes.get(key, {})
	if stroke.is_empty():
		return
	var existing: PackedVector3Array = stroke.points
	var room := MAX_POINTS_PER_STROKE - existing.size()
	if room <= 0:
		return
	existing.append_array(points.slice(0, room))
	stroke.points = existing
	_dirty_keys[key] = true


func _remove_strokes(keys: PackedStringArray) -> void:
	for key in keys:
		var stroke: Dictionary = _strokes.get(key, {})
		if stroke.is_empty():
			continue
		var mesh_instance: MeshInstance3D = stroke.mesh
		if is_instance_valid(mesh_instance):
			mesh_instance.queue_free()
		_strokes.erase(key)
		_stroke_order.erase(key)
		_dirty_keys.erase(key)


func _rebuild_dirty_meshes() -> void:
	if _dirty_keys.is_empty():
		return
	for key in _dirty_keys:
		var stroke: Dictionary = _strokes.get(key, {})
		if not stroke.is_empty():
			_build_stroke_mesh(stroke)
	_dirty_keys.clear()


## Cross-shaped ribbon (two perpendicular quads per segment) so ink reads from any angle.
func _build_stroke_mesh(stroke: Dictionary) -> void:
	var mesh_instance: MeshInstance3D = stroke.mesh
	var mesh := mesh_instance.mesh as ImmediateMesh
	var points: PackedVector3Array = stroke.points
	mesh.clear_surfaces()
	if points.is_empty():
		return
	var half_width: float = stroke.width * 0.5
	if points.size() == 1:
		points = PackedVector3Array([points[0], points[0] + Vector3(0.0, half_width, 0.0)])

	var vertices := PackedVector3Array()
	for i in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var dir := p1 - p0
		if dir.length_squared() < 1e-12:
			continue
		dir = dir.normalized()
		var helper := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var side_a := dir.cross(helper).normalized() * half_width
		var side_b := dir.cross(side_a).normalized() * half_width
		for side: Vector3 in [side_a, side_b]:
			vertices.append_array(PackedVector3Array([p0 - side, p0 + side, p1 + side, p0 - side, p1 + side, p1 - side]))
	if vertices.is_empty():
		return

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for vertex in vertices:
		mesh.surface_add_vertex(vertex)
	mesh.surface_end()


func _material_for(color: Color) -> StandardMaterial3D:
	var cache_key := color.to_html()
	if _materials.has(cache_key):
		return _materials[cache_key]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	_materials[cache_key] = mat
	return mat


### Helpers ###

func _container_scale() -> float:
	if not _container:
		return 1.0
	return maxf(_container.global_transform.basis.get_scale().x, 0.0001)


func _local_color() -> Color:
	if _is_host() and _host_red:
		return HOST_RED_INK
	return color_for_peer(multiplayer.get_unique_id())


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


static func color_for_peer(peer_id: int) -> Color:
	if peer_id == 1:
		return PALETTE[0]
	return PALETTE[1 + (absi(peer_id) % (PALETTE.size() - 1))]


static func player_name_for_peer(peer_id: int) -> String:
	return "Host" if peer_id == 1 else "Player %d" % (absi(peer_id) % 1000)
