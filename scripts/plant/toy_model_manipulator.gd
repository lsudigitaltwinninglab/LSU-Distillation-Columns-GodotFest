extends Node

## Toy Model Mode — grab the model with your hands (Map/ToyModelManipulator in ar_network_arena).
##
## Host only (the host owns the model; ModelSyncManager streams the result to clients).
##
## Everything works about the model's pivot — the bottom centre of the plant (ModelSyncManager.get_toy_pivot_world) —
## so the model shrinks toward, and grows back from, the same spot. Moving it with your hands moves the pivot, so
## from then on it shrinks and grows about its new spot.
##
## - ONE GRIP:   grab the model — it follows your hand. Move your hand to move it, twist your wrist to turn it.
## - BOTH GRIPS: pinch to scale (hands apart = bigger, together = smaller), move both hands to move it,
##               rotate your hands around each other to turn it. Scale and turn happen about the model's centre.
## - STICKS:     left stick slides the model, right stick left/right turns it, right stick up/down scales it
##               (for fine adjustments without grabbing).
## - QR LOCK:    while the model is pinned to a QR code (QRMarkerManager) it can't be moved or turned —
##               scaling still works, about the QR code. Release the lock from the toy panel to move it by hand.
## - The scale lock on the toy panel freezes the size.
##
## A hand holding (or reaching for) a pickable such as the pencil is ignored. World-grab is off in toy mode.

const GRIP_ON := 0.7
const GRIP_OFF := 0.5
const STICK_DEADZONE := 0.2
const STICK_SLIDE_SPEED := 1.0  # m/s
const STICK_TURN_SPEED := 90.0  # degrees/s at full deflection
const STICK_SCALE_RATE := 0.8  # exponential growth rate per second at full deflection
const MIN_FACTOR := 0.02
const MAX_FACTOR := 1.0
const MIN_PINCH_SPAN := 0.05  # meters; hands closer than this don't define a pinch
## How fast the model catches up with the hands (1/s). High enough to feel attached, low enough to hide hand jitter.
const FOLLOW_RATE := 30.0

var _sync: Node
var _qr: Node
var _camera: XRCamera3D
var _hands: Array[XRController3D] = [null, null]  # [left, right]

var _active: bool = false
var _scale_locked: bool = false
var _gripping: Array[bool] = [false, false]
var _gesture: Array[int] = []  # indices of the hands currently manipulating the model
var _sticks_active: bool = false
var _last_factor_emitted: float = -1.0

# Snapshot taken when a gesture starts / changes hands
var _ref_hand_position: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _ref_hand_rotation: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]
var _ref_pivot: Vector3 = Vector3.ZERO
var _ref_yaw: float = 0.0
var _ref_factor: float = 1.0

# Where the hands want the model, and the smoothed pose actually applied
var _target_pivot: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _target_factor: float = 1.0
var _pivot: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _factor: float = 1.0


func _ready() -> void:
	set_process(false)
	if MenuControl:
		if MenuControl.has_signal("toy_model_mode"):
			MenuControl.toy_model_mode.connect(_on_toy_model_mode)
		if MenuControl.has_signal("scale_lock_changed"):
			MenuControl.scale_lock_changed.connect(_on_scale_lock_changed)


func _on_toy_model_mode(enabled: bool) -> void:
	_active = enabled and _is_host()
	if not _active:
		_finish_gestures()
	set_process(_active)


func _on_scale_lock_changed(locked: bool) -> void:
	_scale_locked = locked


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _process(delta: float) -> void:
	if not _resolve_nodes():
		return
	if _sync.is_placement_mode():
		_finish_gestures()
		return

	_update_grips()
	var usable: Array[int] = []
	for i in 2:
		if _gripping[i] and _hand_is_free(i):
			usable.append(i)

	if usable != _gesture:
		if not _gesture.is_empty():
			_flush_gesture()
		_gesture = usable
		if not _gesture.is_empty():
			_begin_gesture()

	if _gesture.is_empty():
		_update_sticks(delta)
	else:
		_update_gesture(delta)


func _resolve_nodes() -> bool:
	if not is_instance_valid(_sync):
		_sync = get_tree().get_first_node_in_group("model_sync_manager")
	if not is_instance_valid(_qr):
		_qr = get_tree().get_first_node_in_group("qr_marker_manager")
	if not _hands[0] or not _hands[1]:
		var origin := get_tree().get_first_node_in_group("xr_origin") as XROrigin3D
		if origin:
			_hands[0] = origin.get_node_or_null("LeftHand") as XRController3D
			_hands[1] = origin.get_node_or_null("RightHand") as XRController3D
			_camera = origin.get_node_or_null("XRCamera3D") as XRCamera3D
	return is_instance_valid(_sync) and is_instance_valid(_sync.model_root) and _hands[0] != null and _hands[1] != null


func _model() -> Node3D:
	return _sync.model_root


func _qr_locked() -> bool:
	return is_instance_valid(_qr) and _qr.has_method("is_locking") and _qr.is_locking()


### Input ###

func _update_grips() -> void:
	for i in 2:
		var hand := _hands[i]
		if not hand.get_is_active():
			_gripping[i] = false
			continue
		var grip := hand.get_float("grip")
		if _gripping[i] and grip < GRIP_OFF:
			_gripping[i] = false
		elif not _gripping[i] and grip > GRIP_ON:
			_gripping[i] = true


## A hand holding or reaching for a real pickable (the pencil, a P&ID...) isn't grabbing the model.
## The hand's pickup also "holds" the world-grab area and climbables on every grip; those don't count.
func _hand_is_free(index: int) -> bool:
	var pickup := _hands[index].get_node_or_null("FunctionPickup") as XRToolsFunctionPickup
	if not pickup:
		return true
	return not (pickup.picked_up_object is XRToolsPickable or pickup.closest_object is XRToolsPickable)


### Grip gestures ###

func _begin_gesture() -> void:
	for i in _gesture:
		_ref_hand_position[i] = _hands[i].global_position
		_ref_hand_rotation[i] = _hands[i].global_basis.get_rotation_quaternion()
	_ref_pivot = _sync.get_toy_pivot_world()
	_ref_yaw = _model().global_rotation.y
	_ref_factor = _sync.get_toy_scale_factor()
	_pivot = _ref_pivot
	_yaw = _ref_yaw
	_factor = _ref_factor
	_target_pivot = _pivot
	_target_yaw = _yaw
	_target_factor = _factor
	# Tell the user the model is pinned instead of leaving them wondering why it won't move.
	if _gesture.size() == 1 and _qr_locked():
		_hands[_gesture[0]].trigger_haptic_pulse("haptic", 0.0, 0.5, 0.15, 0.0)


func _update_gesture(delta: float) -> void:
	var locked := _qr_locked()
	if _gesture.size() == 1:
		if locked:
			return
		var i := _gesture[0]
		var hand_position := _hands[i].global_position
		var hand_rotation := _hands[i].global_basis.get_rotation_quaternion()
		var turn := _twist_about_up(hand_rotation * _ref_hand_rotation[i].inverse())
		# Rigid motion about the hand: the pivot swings around it as the model turns.
		_target_pivot = hand_position + Basis(Vector3.UP, turn) * (_ref_pivot - _ref_hand_position[i])
		_target_yaw = _ref_yaw + turn
		_target_factor = _ref_factor
	else:
		# Two hands: the pivot follows the midpoint, the model turns with the line between the hands
		# and scales with the distance between them — both about the pivot, so it stays put while pinching.
		var left := _hands[0].global_position
		var right := _hands[1].global_position
		var span := right - left
		var ref_span := _ref_hand_position[1] - _ref_hand_position[0]

		_target_factor = _ref_factor
		if not _scale_locked and ref_span.length() > MIN_PINCH_SPAN and span.length() > MIN_PINCH_SPAN:
			_target_factor = clampf(_ref_factor * span.length() / ref_span.length(), MIN_FACTOR, MAX_FACTOR)

		if locked:
			# Pinned to the QR code: only the size changes (about the code).
			_smooth_toward_targets(delta)
			_apply_scale_only(_factor)
			return

		var flat_span := Vector2(span.x, -span.z)
		var flat_ref := Vector2(ref_span.x, -ref_span.z)
		var turn := 0.0
		if flat_span.length() > MIN_PINCH_SPAN and flat_ref.length() > MIN_PINCH_SPAN:
			turn = wrapf(flat_span.angle() - flat_ref.angle(), -PI, PI)
		var midpoint := (left + right) * 0.5
		var ref_midpoint := (_ref_hand_position[0] + _ref_hand_position[1]) * 0.5
		_target_pivot = _ref_pivot + (midpoint - ref_midpoint)
		_target_yaw = _ref_yaw + turn

	_smooth_toward_targets(delta)
	_apply(_pivot, _yaw, _factor)


## Eases the applied pose toward the hands' pose: hides controller jitter without feeling laggy.
func _smooth_toward_targets(delta: float) -> void:
	var weight := 1.0 - exp(-FOLLOW_RATE * delta)
	_pivot = _pivot.lerp(_target_pivot, weight)
	_yaw = lerp_angle(_yaw, _target_yaw, weight)
	_factor = lerpf(_factor, _target_factor, weight)


## Gesture ending or changing hands: land exactly on where the hands left the model, then sync it.
func _flush_gesture() -> void:
	if _qr_locked():
		_apply_scale_only(_target_factor)
	else:
		_apply(_target_pivot, _target_yaw, _target_factor)
	_sync.end_toy_manipulation()


## Rotation component of q about the world up axis (swing-twist), in radians.
func _twist_about_up(q: Quaternion) -> float:
	return wrapf(2.0 * atan2(q.y, q.w), -PI, PI)


### Stick controls ###

func _update_sticks(delta: float) -> void:
	var slide := _deadzone(_hands[0].get_vector2("primary") if _hands[0].get_is_active() else Vector2.ZERO)
	var steer := _deadzone(_hands[1].get_vector2("primary") if _hands[1].get_is_active() else Vector2.ZERO)
	var locked := _qr_locked()

	var pivot: Vector3 = _sync.get_toy_pivot_world()
	var yaw := _model().global_rotation.y
	var factor: float = _sync.get_toy_scale_factor()
	var changed := false

	# Pinned to the QR code: sticks can only resize (the model may be tilted by the code).
	if locked:
		if not _scale_locked and steer.y != 0.0:
			_sticks_active = true
			_apply_scale_only(clampf(factor * exp(steer.y * STICK_SCALE_RATE * delta), MIN_FACTOR, MAX_FACTOR))
		elif _sticks_active:
			_sticks_active = false
			_sync.end_toy_manipulation()
		return

	if slide != Vector2.ZERO:
		var cam_basis := _camera.global_basis if _camera else Basis.IDENTITY
		var forward := -cam_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var side := cam_basis.x
		side.y = 0.0
		side = side.normalized()
		pivot += (forward * slide.y + side * slide.x) * STICK_SLIDE_SPEED * delta
		changed = true

	if steer.x != 0.0:
		yaw += deg_to_rad(STICK_TURN_SPEED) * steer.x * delta
		changed = true

	if not _scale_locked and steer.y != 0.0:
		factor = clampf(factor * exp(steer.y * STICK_SCALE_RATE * delta), MIN_FACTOR, MAX_FACTOR)
		changed = true

	if changed:
		_sticks_active = true
		_apply(pivot, yaw, factor)
	elif _sticks_active:
		_sticks_active = false
		_sync.end_toy_manipulation()


## Radial deadzone, rescaled so the response starts from zero at the edge of the deadzone.
func _deadzone(stick: Vector2) -> Vector2:
	var length := stick.length()
	if length < STICK_DEADZONE:
		return Vector2.ZERO
	return stick * ((length - STICK_DEADZONE) / (1.0 - STICK_DEADZONE) / length)


### Applying ###

func _apply(pivot: Vector3, yaw: float, factor: float) -> void:
	factor = clampf(factor, MIN_FACTOR, MAX_FACTOR)
	_sync.apply_toy_manipulation(pivot, yaw, factor)
	_report_factor(factor)


func _apply_scale_only(factor: float) -> void:
	factor = clampf(factor, MIN_FACTOR, MAX_FACTOR)
	_sync.apply_toy_scale_only(factor)
	_report_factor(factor)


## Keeps the size slider / label on the toy panel in step with gestures.
func _report_factor(factor: float) -> void:
	if MenuControl and absf(factor - _last_factor_emitted) > 0.002:
		_last_factor_emitted = factor
		MenuControl.emit_signal("toy_scale_changed", factor)


func _finish_gestures() -> void:
	if not _gesture.is_empty() and is_instance_valid(_sync):
		_flush_gesture()
	elif _sticks_active and is_instance_valid(_sync):
		_sync.end_toy_manipulation()
	_gesture = []
	_sticks_active = false
	_gripping = [false, false]
