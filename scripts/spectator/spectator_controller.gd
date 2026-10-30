class_name SpectatorController
extends Node3D

## Desktop spectator camera (created by ar_network_arena.gd when SpectatorMode is active).
##
## Watches the headset players through their synced avatars — no headset, no avatar of its own.
## It follows the first avatar that exists (the host first) and re-targets automatically when that
## player leaves or a headset player joins later.
##
## Modes (Tab, or 1 / 2 / 3):
## - CHASE:        smoothed camera behind and above the player; hold right mouse to orbit, scroll to zoom
## - FIRST PERSON: the player's view, stabilised (roll removed, yaw/pitch/position smoothed)
## - FREE:         fly around yourself: WASD move, Q/E down/up, Shift fast, hold right mouse to look
## Left / Right arrows switch the followed player (Q / E too, outside free-fly). H hides the help text.

enum Mode { CHASE, FIRST_PERSON, FREE }

const MODE_NAMES := ["Chase", "First person", "Free fly"]

const CHASE_START_PITCH := deg_to_rad(20.0)
const CHASE_MIN_PITCH := deg_to_rad(-10.0)
const CHASE_MAX_PITCH := deg_to_rad(70.0)
const CHASE_MIN_DISTANCE := 0.8
const CHASE_MAX_DISTANCE := 12.0
const CHASE_FOCUS_SMOOTHING := 8.0  # 1/s
const CHASE_YAW_SMOOTHING := 1.5  # 1/s (slow, so head turns don't whip the camera around)

const FIRST_PERSON_VIEW_SMOOTHING := 0.1  # seconds
const FIRST_PERSON_POSITION_SMOOTHING := 0.05  # seconds
const FIRST_PERSON_MAX_PITCH := deg_to_rad(45.0)
const FIRST_PERSON_FORWARD_OFFSET := 0.1  # metres out of the avatar's head so its face isn't in view

const FREE_SPEED := 3.0
const FREE_FAST_MULTIPLIER := 4.0
const LOOK_SENSITIVITY := 0.004

var mode: Mode = Mode.CHASE
var camera: Camera3D

var _avatars: Node3D
var _target_peer: int = 0

var _hud_layer: CanvasLayer
var _hud_label: Label
var _hud_help_visible: bool = true
var _hud_timer: float = 0.0

# Chase
var _focus: Vector3 = Vector3.ZERO
var _chase_yaw: float = 0.0
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = CHASE_START_PITCH
var _distance: float = 2.5
var _have_chase_state: bool = false

# First person
var _fp_position: Vector3 = Vector3.ZERO
var _fp_yaw: float = 0.0
var _fp_pitch: float = 0.0
var _have_fp_state: bool = false

# Free fly
var _free_yaw: float = 0.0
var _free_pitch: float = 0.0


## [param avatars] is the arena's Avatars node (children are named by peer id).
func setup(avatars: Node3D) -> void:
	_avatars = avatars


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "SpectatorCamera"
	camera.near = 0.05
	camera.far = 1000.0
	camera.fov = 75.0
	add_child(camera)
	camera.make_current()

	# Start somewhere sensible until a player appears.
	camera.global_position = Vector3(0.0, 2.0, 3.0)
	_build_hud()
	_set_mode(Mode.CHASE)


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


### Input ###

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_TAB:
				_set_mode(((mode + 1) % Mode.size()) as Mode)
			KEY_1:
				_set_mode(Mode.CHASE)
			KEY_2:
				_set_mode(Mode.FIRST_PERSON)
			KEY_3:
				_set_mode(Mode.FREE)
			KEY_RIGHT:
				_cycle_player(1)
			KEY_LEFT:
				_cycle_player(-1)
			KEY_E:
				if mode != Mode.FREE:
					_cycle_player(1)
			KEY_Q:
				if mode != Mode.FREE:
					_cycle_player(-1)
			KEY_H:
				_hud_help_visible = not _hud_help_visible
				_refresh_hud()
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and mode != Mode.FIRST_PERSON:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_WHEEL_UP:
				if mode == Mode.CHASE and event.pressed:
					_distance = clampf(_distance * 0.9, CHASE_MIN_DISTANCE, CHASE_MAX_DISTANCE)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mode == Mode.CHASE and event.pressed:
					_distance = clampf(_distance * 1.1, CHASE_MIN_DISTANCE, CHASE_MAX_DISTANCE)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		match mode:
			Mode.CHASE:
				_orbit_yaw -= event.relative.x * LOOK_SENSITIVITY
				_orbit_pitch = clampf(_orbit_pitch + event.relative.y * LOOK_SENSITIVITY, CHASE_MIN_PITCH, CHASE_MAX_PITCH)
			Mode.FREE:
				_free_yaw -= event.relative.x * LOOK_SENSITIVITY
				_free_pitch = clampf(_free_pitch - event.relative.y * LOOK_SENSITIVITY, -PI * 0.49, PI * 0.49)


func _set_mode(new_mode: Mode) -> void:
	if new_mode == Mode.FREE and mode != Mode.FREE:
		# Free fly continues from wherever the camera is now.
		_free_yaw = camera.global_rotation.y
		_free_pitch = camera.global_rotation.x
	_have_chase_state = false
	_have_fp_state = false
	mode = new_mode
	if mode == Mode.FIRST_PERSON:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_hud()


### Following ###

func _players() -> Array[Node3D]:
	var players: Array[Node3D] = []
	if not is_instance_valid(_avatars):
		return players
	for child in _avatars.get_children():
		if child is Node3D and child.name.is_valid_int():
			players.append(child)
	players.sort_custom(func(a: Node3D, b: Node3D) -> bool: return int(a.name) < int(b.name))
	return players


func _target_avatar() -> Node3D:
	for avatar in _players():
		if int(avatar.name) == _target_peer:
			return avatar
	return null


## Follow the first player available (the host first) whenever the current one is gone.
func _ensure_target() -> void:
	if _target_avatar():
		return
	var players := _players()
	_target_peer = int(players[0].name) if not players.is_empty() else 0
	_have_chase_state = false
	_have_fp_state = false
	_refresh_hud()


func _cycle_player(step: int) -> void:
	var players := _players()
	if players.size() < 2:
		return
	var index := 0
	for i in players.size():
		if int(players[i].name) == _target_peer:
			index = i
	_target_peer = int(players[posmod(index + step, players.size())].name)
	_have_chase_state = false
	_have_fp_state = false
	_refresh_hud()


func _head_transform(avatar: Node3D) -> Transform3D:
	var head := avatar.get_node_or_null("Head") as Node3D
	return head.global_transform if head else avatar.global_transform


### Camera ###

func _process(delta: float) -> void:
	_ensure_target()
	var avatar := _target_avatar()
	match mode:
		Mode.CHASE:
			if avatar:
				_update_chase(avatar, delta)
		Mode.FIRST_PERSON:
			if avatar:
				_update_first_person(avatar, delta)
		Mode.FREE:
			_update_free(delta)

	_hud_timer += delta
	if _hud_timer >= 0.5:
		_hud_timer = 0.0
		_refresh_hud()


func _yaw_of(forward: Vector3) -> float:
	return atan2(-forward.x, -forward.z)


func _update_chase(avatar: Node3D, delta: float) -> void:
	var head := _head_transform(avatar)
	var focus_target := head.origin + Vector3(0.0, -0.15, 0.0)
	var forward := -head.basis.z
	forward.y = 0.0
	var head_yaw := _chase_yaw if forward.length_squared() < 0.01 else _yaw_of(forward)

	if not _have_chase_state:
		_focus = focus_target
		_chase_yaw = head_yaw
		_have_chase_state = true
	_focus = _focus.lerp(focus_target, 1.0 - exp(-CHASE_FOCUS_SMOOTHING * delta))
	_chase_yaw = lerp_angle(_chase_yaw, head_yaw, 1.0 - exp(-CHASE_YAW_SMOOTHING * delta))

	var direction := Basis(Vector3.UP, _chase_yaw + _orbit_yaw) * Basis(Vector3.RIGHT, -_orbit_pitch) * Vector3.BACK
	camera.look_at_from_position(_focus + direction * _distance, _focus, Vector3.UP)


func _update_first_person(avatar: Node3D, delta: float) -> void:
	var head := _head_transform(avatar)
	var forward := -head.basis.z
	var flat := Vector3(forward.x, 0.0, forward.z)
	var target_yaw := _fp_yaw if flat.length_squared() < 0.0001 else _yaw_of(forward)
	var target_pitch := clampf(asin(clampf(forward.y, -1.0, 1.0)), -FIRST_PERSON_MAX_PITCH, FIRST_PERSON_MAX_PITCH)
	var target_position := head.origin
	if flat.length_squared() > 0.0001:
		target_position += flat.normalized() * FIRST_PERSON_FORWARD_OFFSET

	if not _have_fp_state:
		_fp_position = target_position
		_fp_yaw = target_yaw
		_fp_pitch = target_pitch
		_have_fp_state = true
	_fp_position = _fp_position.lerp(target_position, 1.0 - exp(-delta / FIRST_PERSON_POSITION_SMOOTHING))
	var view_weight := 1.0 - exp(-delta / FIRST_PERSON_VIEW_SMOOTHING)
	_fp_yaw = lerp_angle(_fp_yaw, target_yaw, view_weight)
	_fp_pitch = lerpf(_fp_pitch, target_pitch, view_weight)

	# No roll: the view stays level however the player tilts their head.
	camera.global_transform = Transform3D(Basis.from_euler(Vector3(_fp_pitch, _fp_yaw, 0.0)), _fp_position)


func _update_free(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0
	var lift := 0.0
	if Input.is_physical_key_pressed(KEY_E):
		lift += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		lift -= 1.0

	var basis := Basis.from_euler(Vector3(_free_pitch, _free_yaw, 0.0))
	var speed := FREE_SPEED * (FREE_FAST_MULTIPLIER if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	var velocity := (basis * move + Vector3.UP * lift) * speed
	camera.global_transform = Transform3D(basis, camera.global_position + velocity * delta)


### HUD ###

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "SpectatorHUD"
	_hud_layer.layer = 20
	add_child(_hud_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16.0, 16.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10.0)
	panel.add_theme_stylebox_override("panel", style)
	_hud_layer.add_child(panel)

	_hud_label = Label.new()
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_label.add_theme_font_size_override("font_size", 16)
	panel.add_child(_hud_label)


func _refresh_hud() -> void:
	if not _hud_label:
		return
	var lines := PackedStringArray()
	lines.append("SPECTATOR  -  %s" % MODE_NAMES[mode])
	if mode == Mode.FREE:
		lines.append("Flying freely")
	elif _target_peer != 0:
		lines.append("Following: %s" % NetworkAnnotations.player_name_for_peer(_target_peer))
	else:
		lines.append("Waiting for a headset player to join...")
	if _hud_help_visible:
		lines.append("")
		lines.append("[Tab / 1 2 3] mode    [Left / Right] switch player")
		match mode:
			Mode.CHASE:
				lines.append("Hold right mouse: orbit    Scroll: zoom")
			Mode.FIRST_PERSON:
				lines.append("Stabilised view from the player's eyes")
			Mode.FREE:
				lines.append("WASD move    Q / E down / up    Shift fast    Hold right mouse: look")
		lines.append("[H] hide help")
	_hud_label.text = "\n".join(lines)
