extends Node

## Toy Model Mode — turn, slide and resize the model with the controllers (Map/ToyModelManipulator in ar_network_arena).
##
## Host only (the host owns the model; ModelSyncManager streams the result to clients).
##
## Everything works about the model's pivot — the bottom centre of the plant (ModelSyncManager.get_toy_pivot_world) —
## so the model turns, shrinks and grows in place.
##
## - RIGHT GRIP: hold to turn the model in place in the + direction (counter-clockwise seen from above).
## - LEFT GRIP:  hold to turn it in place in the - direction.
## - BOTH GRIPS: pinch to scale (hands apart = bigger, together = smaller), about the pivot — no turning.
## - STICKS:     left stick slides the model, right stick left/right turns it, right stick up/down scales it.
## - QR LOCK:    while the model is pinned to a QR code (QRMarkerManager) it can't be slid; turning happens about
##               the QR code (and is remembered by the lock), scaling still works about the code.
## - The scale lock on the toy panel freezes the size.
##
## A hand holding (or reaching for) a pickable such as the pencil is ignored. World-grab is off in toy mode.

const GRIP_ON := 0.7
const GRIP_OFF := 0.5
const GRIP_TURN_SPEED := 60.0  # degrees/s while a grip is held
const STICK_DEADZONE := 0.2
const STICK_SLIDE_SPEED := 1.0  # m/s
const STICK_TURN_SPEED := 90.0  # degrees/s at full deflection
const STICK_SCALE_RATE := 0.8  # exponential growth rate per second at full deflection
const MIN_FACTOR := 0.02
const MAX_FACTOR := 1.0
const MIN_PINCH_SPAN := 0.05  # meters; hands closer than this don't define a pinch
## How fast the size catches up with the hands (1/s). High enough to feel attached, low enough to hide hand jitter.
const PINCH_FOLLOW_RATE := 30.0

var _sync: Node
var _qr: Node
var _camera: XRCamera3D
var _hands: Array[XRController3D] = [null, null]  # [left, right]

var _active: bool = false
var _scale_locked: bool = false
var _gripping: Array[bool] = [false, false]
## True while grips or sticks are changing the model; when it stops, the final pose is sent reliably.
var _manipulating: bool = false
var _last_factor_emitted: float = -1.0

# Pinch: hand span and model size when both grips closed, and the smoothed size actually applied
var _pinching: bool = false
var _pinch_ref_span: float = 0.0
var _pinch_ref_factor: float = 1.0
var _pinch_factor: float = 1.0


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
		_finish_manipulation()
		_gripping = [false, false]
		_pinching = false
	set_process(_active)


func _on_scale_lock_changed(locked: bool) -> void:
	_scale_locked = locked


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _process(delta: float) -> void:
	if not _resolve_nodes():
		return
	if _sync.is_placement_mode():
		_finish_manipulation()
		return

	_update_grips()
	var left_free := _gripping[0] and _hand_is_free(0)
	var right_free := _gripping[1] and _hand_is_free(1)
	var changed := false
	if left_free and right_free:
		changed = _update_pinch(delta)
	else:
		_pinching = false
		changed = _update_grip_turn(delta, left_free, right_free)
	changed = _update_sticks(delta) or changed
	if changed:
		_manipulating = true
	else:
		_finish_manipulation()


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


## A hand holding or reaching for a real pickable (the pencil, a P&ID...) isn't turning the model.
## The hand's pickup also "holds" the world-grab area and climbables on every grip; those don't count.
func _hand_is_free(index: int) -> bool:
	var pickup := _hands[index].get_node_or_null("FunctionPickup") as XRToolsFunctionPickup
	if not pickup:
		return true
	return not (pickup.picked_up_object is XRToolsPickable or pickup.closest_object is XRToolsPickable)


### Grip turning ###

## Right grip turns +, left grip turns -. Returns true if the model turned this frame.
func _update_grip_turn(delta: float, left: bool, right: bool) -> bool:
	var direction := (1.0 if right else 0.0) - (1.0 if left else 0.0)
	if direction == 0.0:
		return false
	_turn_in_place(direction * deg_to_rad(GRIP_TURN_SPEED) * delta)
	return true


### Two-hand pinch ###

## Both grips: the model's size follows the distance between the hands (about the pivot, or about the
## QR code while pinned to one). Returns true while the pinch is changing the size.
func _update_pinch(delta: float) -> bool:
	var span := _hands[0].global_position.distance_to(_hands[1].global_position)
	if not _pinching:
		_pinching = true
		_pinch_ref_span = span
		_pinch_ref_factor = _sync.get_toy_scale_factor()
		_pinch_factor = _pinch_ref_factor
	if _scale_locked or _pinch_ref_span < MIN_PINCH_SPAN or span < MIN_PINCH_SPAN:
		return _manipulating
	var target := clampf(_pinch_ref_factor * span / _pinch_ref_span, MIN_FACTOR, MAX_FACTOR)
	_pinch_factor = lerpf(_pinch_factor, target, 1.0 - exp(-PINCH_FOLLOW_RATE * delta))
	if _qr_locked():
		_apply_scale_only(_pinch_factor)
	else:
		_apply(_sync.get_toy_pivot_world(), _model().global_rotation.y, _pinch_factor)
	return true


## Turns the model about the world up axis without moving it: about its pivot, or about the QR code
## while it is pinned to one (the lock keeps the extra turn, so re-locking doesn't undo it).
func _turn_in_place(angle: float) -> void:
	if _qr_locked():
		if _qr.has_method("turn_locked_model"):
			_qr.turn_locked_model(angle)
			_sync._sync_toy_pose_to_clients(false)
		return
	_apply(_sync.get_toy_pivot_world(), _model().global_rotation.y + angle, _sync.get_toy_scale_factor())


### Stick controls ###

## Returns true if the sticks changed the model this frame.
func _update_sticks(delta: float) -> bool:
	var slide := _deadzone(_hands[0].get_vector2("primary") if _hands[0].get_is_active() else Vector2.ZERO)
	var steer := _deadzone(_hands[1].get_vector2("primary") if _hands[1].get_is_active() else Vector2.ZERO)
	var changed := false

	# Pinned to the QR code: sticks can turn (about the code) and resize, but not slide.
	if _qr_locked():
		if steer.x != 0.0:
			_turn_in_place(deg_to_rad(STICK_TURN_SPEED) * steer.x * delta)
			changed = true
		if not _scale_locked and steer.y != 0.0:
			var locked_factor: float = _sync.get_toy_scale_factor()
			_apply_scale_only(clampf(locked_factor * exp(steer.y * STICK_SCALE_RATE * delta), MIN_FACTOR, MAX_FACTOR))
			changed = true
		return changed

	var pivot: Vector3 = _sync.get_toy_pivot_world()
	var yaw := _model().global_rotation.y
	var factor: float = _sync.get_toy_scale_factor()

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
		_apply(pivot, yaw, factor)
	return changed


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


## Keeps the size slider / label on the toy panel in step with the sticks.
func _report_factor(factor: float) -> void:
	if MenuControl and absf(factor - _last_factor_emitted) > 0.002:
		_last_factor_emitted = factor
		MenuControl.emit_signal("toy_scale_changed", factor)


## Grips and sticks let go: send the final pose reliably.
func _finish_manipulation() -> void:
	if _manipulating and is_instance_valid(_sync):
		_sync.end_toy_manipulation()
	_manipulating = false
