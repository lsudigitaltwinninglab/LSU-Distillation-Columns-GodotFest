extends Control

## Toy Model panel (Viewport2Din3D_ToyModel on the camera rig).
##
## UI only — forwards actions through MenuControl autoload signals:
## - Scale slider → toy_scale_changed → ModelSyncManager (host applies scale, RPC to clients)
## - Reset scale → reset_toy_scale_requested → restores full baseline size (slider 1.0 = 100%)
## - Reset Model → reset_to_spawn_requested → ModelSyncManager puts the model back at its spawn
##   location, rotation and scale
## - Lock → scale_lock_changed → blocks grip pinch scaling in xr_player_pointer
##
## - QR Lock → toy_qr_lock_changed → QRMarkerManager pins / releases the model on the QR code
##
## Two-hand pinch and the sticks (ToyModelManipulator) also drive the slider via toy_scale_changed.

@onready var scale_label: Label = $Panel/VBoxContainer/ScaleLockContainer/ScaleLabel
@onready var scale_slider: HSlider = $Panel/VBoxContainer/ScaleSlider
@onready var lock_button: Button = $Panel/VBoxContainer/ScaleLockContainer/LockButton
@onready var qr_status: Label = $Panel/VBoxContainer/QRContainer/QRStatus
@onready var qr_lock_button: Button = $Panel/VBoxContainer/QRContainer/QRLockButton
@onready var panel: Panel = $Panel
@onready var maximize_button: Button = $MaximizeButton

const QR_POLL_INTERVAL := 0.25
## Size of the minimized tab, in viewport pixels.
const MINIMIZED_VIEWPORT_SIZE := Vector2(130, 36)

## True while syncing slider from external events — avoids feedback loop to MenuControl.
var _updating_slider: bool = false
var _scale_locked: bool = false
var _qr_poll_timer: float = 0.0
var _minimized: bool = false
## Full-size Viewport2Din3D settings, captured on first minimize so they can be restored.
var _full_viewport_size: Vector2
var _full_screen_size: Vector2
var _full_position: Vector3


func _ready() -> void:
	_update_scale_display(1.0)
	_refresh_qr_status()

	if MenuControl.has_signal("toy_scale_changed"):
		MenuControl.connect("toy_scale_changed", _on_external_scale_changed)


func _process(delta: float) -> void:
	_qr_poll_timer += delta
	if _qr_poll_timer >= QR_POLL_INTERVAL:
		_qr_poll_timer = 0.0
		_refresh_qr_status()


func _on_minimize_button_pressed() -> void:
	_set_minimized.call_deferred(true)


func _on_maximize_button_pressed() -> void:
	_set_minimized.call_deferred(false)


## Swaps the full panel for a small tab and shrinks the 3D screen to match, so the
## hidden area no longer blocks the pointer. The top edge stays put.
func _set_minimized(minimized: bool) -> void:
	if minimized == _minimized:
		return
	_minimized = minimized
	panel.visible = not minimized
	maximize_button.visible = minimized

	# The panel lives in a SubViewport whose parent is the Viewport2Din3D node.
	var host := get_viewport().get_parent() as Node3D
	if not host or not "screen_size" in host or not "viewport_size" in host:
		return
	if minimized:
		_full_viewport_size = host.viewport_size
		_full_screen_size = host.screen_size
		_full_position = host.position
		# Keep the same pixel density as the full panel.
		var pixels_to_meters: Vector2 = _full_screen_size / _full_viewport_size
		var small_screen: Vector2 = MINIMIZED_VIEWPORT_SIZE * pixels_to_meters
		host.viewport_size = MINIMIZED_VIEWPORT_SIZE
		host.screen_size = small_screen
		host.position = _full_position + Vector3(0.0, (_full_screen_size.y - small_screen.y) * 0.5, 0.0)
	else:
		host.viewport_size = _full_viewport_size
		host.screen_size = _full_screen_size
		host.position = _full_position


func _on_qr_lock_button_toggled(toggled_on: bool) -> void:
	qr_lock_button.text = "QR Lock: ON" if toggled_on else "QR Lock: OFF"
	if MenuControl:
		MenuControl._on_toy_qr_lock_changed(toggled_on)


## Shows whether a QR code is seen / pinning the model, and keeps the button in step when the
## manager changes the lock itself (it re-pins at the start and end of every toy-mode session).
func _refresh_qr_status() -> void:
	var qr := get_tree().get_first_node_in_group("qr_marker_manager")
	if not qr or not qr.has_method("is_tracking") or not qr.is_tracking():
		# Tell "can't scan at all" apart from "nothing in view yet".
		if qr and qr.has_method("is_qr_supported") and not qr.is_qr_supported():
			qr_status.text = "QR: unavailable"
		elif qr and qr.has_method("get_confirm_progress") and qr.get_confirm_progress() > 0.0:
			qr_status.text = "QR: hold gaze %d%%" % roundi(qr.get_confirm_progress() * 100.0)
		else:
			qr_status.text = "QR: scanning (%d seen)" % (qr.markers_seen if "markers_seen" in qr else 0)
		return
	var locked: bool = qr.is_locking()
	if qr_lock_button.button_pressed != qr.lock_enabled:
		qr_lock_button.set_pressed_no_signal(qr.lock_enabled)
		qr_lock_button.text = "QR Lock: ON" if qr.lock_enabled else "QR Lock: OFF"
	if not locked:
		qr_status.text = "QR: released"
	elif qr.is_marker_visible():
		qr_status.text = "QR: locked"
	else:
		qr_status.text = "QR: locked (out of view)"


func _on_external_scale_changed(scale_value: float) -> void:
	if _scale_locked:
		return
	_updating_slider = true
	scale_slider.value = scale_value
	_update_scale_display(scale_value)
	_updating_slider = false


func _on_lock_button_toggled(toggled_on: bool) -> void:
	_scale_locked = toggled_on
	scale_slider.editable = not toggled_on
	lock_button.text = "LOCKED" if toggled_on else "Unlocked"

	if MenuControl:
		MenuControl._on_scale_lock_changed(toggled_on)


func _update_scale_display(scale_value: float) -> void:
	if scale_label:
		scale_label.text = "Model Size: %.1f%%" % (scale_value * 100.0)


func _on_scale_slider_value_changed(value: float) -> void:
	if _updating_slider:
		return
	_update_scale_display(value)
	if MenuControl:
		MenuControl._on_toy_scale_slider_changed(value)


func _on_reset_spawn_button_pressed() -> void:
	# The model's location, rotation and scale are reset by ModelSyncManager (host); keep the slider in step.
	_updating_slider = true
	scale_slider.value = 1.0
	_update_scale_display(1.0)
	_updating_slider = false
	if MenuControl:
		MenuControl._on_reset_to_spawn_pressed()


func _on_keep_scale_button_pressed() -> void:
	if MenuControl:
		MenuControl._on_keep_scale_pressed()


func _on_reset_scale_button_pressed() -> void:
	# Update UI immediately; host ModelSyncManager applies full scale and emits toy_scale_changed(1.0).
	_updating_slider = true
	scale_slider.value = 1.0
	_update_scale_display(1.0)
	_updating_slider = false
	if MenuControl:
		MenuControl._on_reset_scale_pressed()
